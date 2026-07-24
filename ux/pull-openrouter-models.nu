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
# A non-reasoning model streams the whole mapping in one shot; run with --thinking off so
# it never burns the budget on reasoning. (Reasoning models like kimi-k2.7-code balloon on
# the full list and its reasoning is mandatory / can't be disabled.) north-mini-code:free is
# a zero-cost swap with slightly lower recall.
const MAP_MODEL = "openai/gpt-4.1-mini"
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

# Pull the final assistant text out of a yoke JSONL stream and parse it as a JSON object.
def parse-mapping-json [stdout: string] {
  let text = ($stdout | lines | each {|l| try { $l | from json } catch { null }} | compact
    | where {|e| ($e.role? | default "") == "assistant" }
    | each {|e| $e.content? | default [] | where {|c| ($c.type? | default "") == "text" } | get text? | compact | str join "" }
    | str join "")
  let json_text = ($text | str replace -r '(?s)^[^{]*(\{.*\})[^}]*$' '$1')
  let parsed = try { $json_text | from json } catch { {} }
  # Always return a record so callers can merge safely (a bad batch parses to null/empty).
  if (($parsed | describe) | str starts-with "record") { $parsed } else { {} }
}

# Fuzzy-match OpenRouter ids to AA slugs in one shot. Returns a record id -> slug|null.
# A non-reasoning model run with --thinking off streams the whole mapping directly.
def generate-mapping [or_models: list, aa_models: list] {
  let or_list = ($or_models | each {|m| $"($m.id)\t($m.name)" } | str join "\n")
  let aa_list = ($aa_models | each {|m| $"($m.slug)\t($m.name)\t($m.creator)" } | str join "\n")
  let prompt = ("Match each OpenRouter model id to the single best-matching Artificial Analysis "
    + "(AA) slug, or null if there is no confident match. Match by model family, version, and "
    + "vendor; ignore suffixes like ':free'/':thinking' and vendor path prefixes. Use only slugs "
    + "from the AA list; never invent one.\n\n"
    + "Return ONLY one JSON object mapping every OpenRouter id (exact string) to an AA slug string "
    + "or null. No prose, no markdown fences.\n\n"
    + "# OpenRouter ids (id<TAB>name)\n" + $or_list + "\n\n"
    + "# AA slugs (slug<TAB>name<TAB>creator)\n" + $aa_list)
  print $"    ($MAP_MODEL): ($or_models | length) ids x ($aa_models | length) slugs, ($prompt | str length) chars ..."
  let raw = (yoke --provider openrouter --model $MAP_MODEL --tools none --thinking off --max-tokens 20000 $prompt | complete)
  if $raw.exit_code != 0 { error make {msg: $"yoke failed: ($raw.stderr)"} }
  parse-mapping-json $raw.stdout
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
