#!/usr/bin/env nu
# Regenerate the OpenRouter <-> Artificial Analysis intelligence mapping.
#
# Pipeline (re-run whenever you want fresh data):
#   1. Pull OpenRouter models (id, name) via yoke.
#   2. Pull Artificial Analysis language models (slug, name, creator, intelligence index),
#      all pages, from their free data API.
#   3. Ask yoke + moonshotai/kimi-k2.7-code to fuzzy-match each OpenRouter id to an AA slug.
#   4. Resolve the mapping into per-id intelligence scores for the UI.
#
# Outputs (written next to this script, under data/):
#   data/aa-map.json    { "<openrouter_id>": "<aa_slug|null>" }   the fuzzy mapping, to eyeball
#   data/aa-index.json  { "<openrouter_id>": <intelligence_index> } consumed by serve.nu
#
# Requires env: OPENROUTER_API_KEY, ARTIFICIAL_ANALYSIS_API_KEY
# AA data (c) Artificial Analysis - https://artificialanalysis.ai (attribution required).

const SCRIPT_DIR = (path self | path dirname)
const MAP_MODEL = "moonshotai/kimi-k2.7-code"
const AA_BASE = "https://artificialanalysis.ai/api/v2/language/models/free"

# Pull every page of the AA free language-models endpoint.
def fetch-aa [key: string] {
  mut all = []
  mut page = 1
  loop {
    let resp = (http get $"($AA_BASE)?page=($page)" --headers {x-api-key: $key})
    $all = ($all | append $resp.data)
    if not ($resp.pagination.has_more? | default false) { break }
    $page = $page + 1
  }
  $all | each {|m| {
    slug: $m.slug,
    name: ($m.name? | default $m.slug),
    creator: ($m.model_creator?.name? | default ""),
    intelligence: ($m.evaluations?.artificial_analysis_intelligence_index? | default null)
  }}
}

# Ask the LLM to fuzzy-match OpenRouter ids to AA slugs. Returns a record id -> slug|null.
def generate-mapping [or_models: list, aa_models: list] {
  let or_list = ($or_models | each {|m| $"($m.id)\t($m.name)" } | str join "\n")
  let aa_list = ($aa_models | each {|m| $"($m.slug)\t($m.name)\t($m.creator)" } | str join "\n")
  let prompt = ("You are matching OpenRouter model ids to Artificial Analysis (AA) model slugs.\n\n"
    + "For each OpenRouter id in the first list, choose the single best-matching AA slug from the "
    + "second list, or null if there is no confident match. Match by model family, version number, "
    + "and vendor. Ignore suffixes like ':free', ':thinking', ':beta', ':nitro', ':online' and "
    + "vendor path prefixes when comparing. Use only slugs that appear in the AA list; never invent one.\n\n"
    + "Return ONLY a single JSON object mapping every OpenRouter id (exact string) to an AA slug "
    + "string or null. No prose, no markdown fences.\n\n"
    + "# OpenRouter ids (id<TAB>name)\n" + $or_list + "\n\n"
    + "# AA slugs (slug<TAB>name<TAB>creator)\n" + $aa_list + "\n")

  print $"    prompt ($prompt | str length) chars; calling ($MAP_MODEL) ..."
  # kimi-k2.7-code has mandatory reasoning (can't --thinking off), so give it a high
  # --max-tokens ceiling to leave room for reasoning AND the full mapping answer.
  let raw = (yoke --provider openrouter --model $MAP_MODEL --tools none --max-tokens 40000 $prompt | complete)
  if $raw.exit_code != 0 { error make {msg: $"yoke failed: ($raw.stderr)"} }

  # Concatenate the final assistant text from the JSONL event stream.
  let text = ($raw.stdout | lines | each {|l| try { $l | from json } catch { null }} | compact
    | where {|e| ($e.role? | default "") == "assistant" }
    | each {|e| $e.content? | default [] | where {|c| ($c.type? | default "") == "text" } | get text? | compact | str join "" }
    | str join "")

  # Strip any stray prose/fences: keep the outermost { ... }.
  let json_text = ($text | str replace -r '(?s)^[^{]*(\{.*\})[^}]*$' '$1')
  try { $json_text | from json } catch {
    print $"    WARN: could not parse mapping JSON \(assistant text was ($text | str length) chars\)"
    {}
  }
}

def main [] {
  let data_dir = ($SCRIPT_DIR | path join data)
  mkdir $data_dir

  let aa_key = ($env.ARTIFICIAL_ANALYSIS_API_KEY? | default "")
  if ($aa_key | is-empty) { error make {msg: "set ARTIFICIAL_ANALYSIS_API_KEY in the env"} }

  print "1/4 pulling OpenRouter models ..."
  let or_models = (yoke --provider openrouter | from json -o | select id name)
  print $"    ($or_models | length) OpenRouter models"

  print "2/4 pulling Artificial Analysis models (all pages) ..."
  let aa_models = (fetch-aa $aa_key)
  print $"    ($aa_models | length) AA models"

  print $"3/4 fuzzy-matching ..."
  let mapping = (generate-mapping $or_models $aa_models)
  $mapping | to json | save -f ($data_dir | path join "aa-map.json")
  let matched = ($mapping | values | where {|v| $v != null } | length)
  print $"    wrote aa-map.json \(($matched) of ($mapping | columns | length) ids matched\)"

  print "4/4 resolving intelligence scores ..."
  let aa_by_slug = ($aa_models | reduce -f {} {|m, acc| $acc | upsert $m.slug $m.intelligence })
  mut index = {}
  for pair in ($mapping | transpose id slug) {
    if $pair.slug != null {
      let score = ($aa_by_slug | get -o $pair.slug)
      if $score != null { $index = ($index | upsert $pair.id $score) }
    }
  }
  $index | to json | save -f ($data_dir | path join "aa-index.json")
  print $"    wrote aa-index.json \(($index | columns | length) ids with a score\)"
  print "done."
}
