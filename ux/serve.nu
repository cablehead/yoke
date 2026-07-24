# serve.nu - stream yoke output to the browser via Datastar SSE
#
# Run with:
#   http-nu --datastar --store ./store :3001 ux/serve.nu
#
# Then open http://localhost:3001 in your browser.

const script_dir = path self | path dirname

use http-nu/router *
use http-nu/datastar *
use http-nu/html *

source render-gemini.nu

const DEFAULT_PROVIDER = "gemini"
const DEFAULT_MODEL = "gemini-3-flash-preview"
const DEFAULT_SORT = "created"
const DEFAULT_SORT_DIR = "desc"

# Columns shown in the model table. sortable columns get a clickable header.
const MODEL_COLS = [
  [key label sortable];
  [id id true]
  [intelligence AA true]
  [context_length context true]
  [price_in "in $/M" true]
  [price_out "out $/M" true]
  [created created true]
]

const ALL_PROVIDERS = [
  [name label key_var];
  [anthropic Anthropic ANTHROPIC_API_KEY]
  [openai OpenAI OPENAI_API_KEY]
  [gemini Gemini GEMINI_API_KEY]
  [openrouter OpenRouter OPENROUTER_API_KEY]
]

def available-providers [] {
  $ALL_PROVIDERS | where { $in.key_var in $env }
}

def styles [] {
  let theme_css = .highlight theme Dracula
  [
    (STYLE $theme_css)
    (STYLE "
      body { font-family: system-ui, sans-serif; max-width: 48rem; margin: 2rem auto; padding: 0 1rem; }
      input[type=text], select { padding: 0.5rem; font-size: 0.8125rem; border: 1px solid #ccc; border-radius: 0.25rem; }
      button { padding: 0.5rem 1rem; font-size: 1rem; cursor: pointer; border-radius: 0.25rem; border: 1px solid #ccc; }
      nav { display: flex; justify-content: space-between; align-items: center; margin-bottom: 1rem; }
      nav a { font-size: 0.875rem; color: #666; text-decoration: none; }
      nav a:hover { color: #333; }
      @keyframes blink { 50% { opacity: 0; } }
      pre { border-radius: 0.5rem; padding: 1rem; overflow-x: auto; }
      code { font-size: 0.8125rem; }
      .run-item { padding: 0.75rem; border-bottom: 1px solid #eee; cursor: pointer; }
      .run-item:hover { background: #f8f8f8; }
      .run-item .prompt { font-size: 0.875rem; }
      .run-item .meta { font-size: 0.75rem; color: #888; margin-top: 0.25rem; }
      .config-row { display: flex; gap: 0.5rem; align-items: center; font-size: 0.75rem; color: #888; margin-bottom: 0.75rem; }
      .model-row { cursor: pointer; border-bottom: 1px solid #f0f0f0; }
      .model-row:hover:not(.selected) { background: #f8f8f8; }
      .model-row.selected { background: #e8f0fe; color: #1a4b8c; }
    ")
  ]
}

def nav-bar [...right] {
  NAV [
    (H1 (A {href: "/", style: "text-decoration: none; color: inherit;"} "yoke"))
    (DIV {style: "display: flex; gap: 1rem; align-items: center;"} ...$right)
  ]
}

# Format an integer with thousands separators for display (e.g. 1048576 -> 1,048,576).
def commafy [n] {
  $n | into string | split chars | reverse | chunks 3
    | each { reverse | str join } | reverse | str join ","
}

# Format a per-million-token price (float) as a compact dollar string.
# OpenRouter uses -1 to mean "no fixed price" (auto/router models).
def fmt-price [v] {
  if ($v < 0) { "auto" } else if ($v == 0) { "free" } else { "$" + ($v | math round --precision 3 | into string) }
}

# Filter by id/name substring, then sort by the given column and direction.
def sort-filter-models [models: list, filter: string, sort: string, dir: string] {
  let filtered = if ($filter | is-empty) {
    $models
  } else {
    $models | where {|m| ($m.id | str contains -i $filter) or ($m.name | str contains -i $filter) }
  }
  if ($filtered | is-empty) { return [] }
  let sorted = $filtered | sort-by -i {|row| $row | get $sort }
  if $dir == "desc" { $sorted | reverse } else { $sorted }
}

def render-model-select [models: list, sort: string, dir: string] {
  # Header cells: carry the sort arrow for the active column.
  let cols = $MODEL_COLS | each {|c|
    {
      key: $c.key,
      label: $c.label,
      sortable: $c.sortable,
      arrow: (if $c.key == $sort { (if $dir == "asc" { " ^" } else { " v" }) } else { "" })
    }
  }
  # Rows: format numbers/dates in nu so the template stays pure presentation.
  let rows = $models | each {|m|
    {
      id: $m.id,
      name: $m.name,
      intelligence: (if (($m.intelligence? | default (-1)) < 0) { "-" } else { $m.intelligence | into string }),
      context: (commafy $m.context_length),
      price_in: (fmt-price $m.price_in),
      price_out: (fmt-price $m.price_out),
      created: ($m.created | into string | str substring 0..9)
    }
  }
  let html = {cols: $cols, rows: $rows} | .mj ($script_dir | path join templates model-table.html)
  {__html: $html}
}

def page [] {
  let providers = available-providers
  let default_provider = $providers | get -i 0 | get -i name | default $DEFAULT_PROVIDER
  let models = sort-filter-models (fetch-models $default_provider) "" $DEFAULT_SORT $DEFAULT_SORT_DIR
  let default_model = $models | get -i 0.id | default $DEFAULT_MODEL

  HTML (
    HEAD
      (META {charset: "utf-8"})
      (META {name: "viewport", content: "width=device-width, initial-scale=1"})
      (TITLE "yoke")
      (SCRIPT-DATASTAR)
      ...(styles)
  ) (
    BODY {
      "data-signals": ("{ model: '" + $default_model + "', model_sort: '" + $DEFAULT_SORT + "', model_sort_dir: '" + $DEFAULT_SORT_DIR + "', model_sort_click: '' }")
    }
      (nav-bar (A {href: "/runs"} "history") (A {href: "/code"} "source"))
      (DIV {style: "display: flex; gap: 0.5rem; margin-bottom: 0.75rem;"}
        (INPUT {
          type: "text",
          placeholder: "ask something...",
          "data-bind": "prompt",
          value: "",
          style: "flex: 1; font-size: 1rem;"
        })
        (BUTTON {
          "data-indicator": "_sending",
          "data-attr:disabled": "$_sending",
          "data-on:click": "!$_sending && $prompt && @get('/sse')"
        } "send")
      )
      (DIV {class: "config-row"}
        (SELECT {
          "data-bind": "provider",
          "data-on:change": "@get('/models')"
        } {
          $providers | each {|p|
            if $p.name == $default_provider {
              OPTION {value: $p.name, selected: true} $p.label
            } else {
              OPTION {value: $p.name} $p.label
            }
          }
        })
        (INPUT {
          type: "text",
          placeholder: "filter models...",
          "data-bind": "model_filter",
          "data-on:input__debounce.60ms": "@get('/models')",
          value: "",
          style: "flex: 1;"
        })
      )
      (DIV {id: "model-select-wrapper", style: "margin-bottom: 0.75rem; overflow-x: auto;"} (render-model-select $models $DEFAULT_SORT $DEFAULT_SORT_DIR))
      (DIV {id: "output"} "")
  )
}

def fetch-models [provider: string] {
  let topic = $"models.($provider).v4"
  let cached = try { .last $topic } catch { null }
  if $cached != null {
    try { .cas $cached.hash | from json } catch { [] }
  } else {
    # Artificial Analysis intelligence index per OpenRouter id (generated by
    # pull-openrouter-models.nu). -1 is the sentinel for "no score / unmapped".
    let aa = try { open ($script_dir | path join data aa-index.json) } catch { {} }
    # Collect yoke's output with `complete` (not `try`): wrapping a streaming
    # external command in `try` and piping it into `.append` deadlocks in nu.
    let result = yoke --provider $provider | complete
    let models = if $result.exit_code == 0 {
      $result.stdout | from json -o | each {|m|
        # pricing is USD per token; surface as USD per million tokens for display/sort.
        let pr = $m.pricing? | default {}
        let id = ($m.id? | default "")
        {
          id: $id,
          name: ($m.name? | default $id),
          context_length: ($m.context_length? | default 0),
          price_in: ((try { $pr.prompt | into float } catch { 0.0 }) * 1000000),
          price_out: ((try { $pr.completion | into float } catch { 0.0 }) * 1000000),
          intelligence: ($aa | get -o $id | default (-1)),
          created: ($m.created? | default "")
        }
      }
    } else { [] }
    $models | to json | .append $topic --ttl time:21600000
    $models
  }
}

def handle-models [req: record] {
  let signals = $in | from datastar-signals $req
  let provider = $signals.provider? | default $DEFAULT_PROVIDER
  let filter = $signals.model_filter? | default ""
  let click = $signals.model_sort_click? | default ""
  let cur_sort = $signals.model_sort? | default $DEFAULT_SORT
  let cur_dir = $signals.model_sort_dir? | default $DEFAULT_SORT_DIR

  # A header click sorts by that column, toggling direction if it is already active.
  let sort = if ($click | is-not-empty) { $click } else { $cur_sort }
  let dir = if ($click | is-empty) {
    $cur_dir
  } else if $click == $cur_sort {
    if $cur_dir == "asc" { "desc" } else { "asc" }
  } else {
    "asc"
  }

  let models = sort-filter-models (fetch-models $provider) $filter $sort $dir
  let current = $signals.model? | default ""
  let selected = if ($current != "") and ($current in ($models | get id)) {
    $current
  } else {
    $models | get -i 0.id | default ""
  }

  [
    (render-model-select $models $sort $dir
      | to datastar-patch-elements --selector "#model-select-wrapper" --mode inner)
    ({model: $selected, model_sort: $sort, model_sort_dir: $dir, model_sort_click: ""} | to datastar-patch-signals)
  ] | to sse
}

def runs-page [] {
  let runs = .cat -T run | reverse | each {|frame|
    let content = .cas $frame.hash
    let lines = $content | lines | each { from json }
    let user_msg = $lines | where { $in.role? == "user" } | first
    let assistant_msg = $lines | where { $in.role? == "assistant" } | get -i 0
    let prompt = $user_msg.content?
      | default []
      | where { $in.type? == "text" }
      | get -i 0
      | get -i text
      | default "(no prompt)"
    let model = $assistant_msg.model? | default ""
    let preview = if ($prompt | str length) > 80 {
      ($prompt | str substring 0..80) + "..."
    } else {
      $prompt
    }
    {id: $frame.id, prompt: $preview, model: $model}
  }

  HTML (
    HEAD
      (META {charset: "utf-8"})
      (META {name: "viewport", content: "width=device-width, initial-scale=1"})
      (TITLE "yoke - history")
      (SCRIPT-DATASTAR)
      ...(styles)
  ) (
    BODY
      (nav-bar (A {href: "/"} "new"))
      (DIV {
        $runs | each {|run|
          A {href: $"/run/($run.id)", class: "run-item", style: "display: block; text-decoration: none; color: inherit;"} [
            (DIV {class: "prompt"} $run.prompt)
            (DIV {class: "meta"} $run.model)
          ]
        }
      })
  )
}

def run-page [id: string] {
  let frame = .get $id
  let content = .cas $frame.hash
  let lines = $content | lines | each { from json }

  let cards = render-run $lines

  HTML (
    HEAD
      (META {charset: "utf-8"})
      (META {name: "viewport", content: "width=device-width, initial-scale=1"})
      (TITLE $"yoke - ($id)")
      ...(styles)
  ) (
    BODY
      (nav-bar (A {href: "/runs"} "history") (A {href: "/"} "new"))
      (DIV ...$cards)
  )
}

def code-page [] {
  let source = open ($script_dir | path join serve.nu)
  let highlighted = $source | .highlight nu
  let theme_css = .highlight theme Dracula

  HTML (
    HEAD
      (META {charset: "utf-8"})
      (META {name: "viewport", content: "width=device-width, initial-scale=1"})
      (TITLE "yoke - source")
      (STYLE "
        body { font-family: system-ui, sans-serif; max-width: 48rem; margin: 2rem auto; padding: 0 1rem; }
        nav { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 1rem; }
        nav a { font-size: 0.875rem; color: #666; text-decoration: none; }
        nav a:hover { color: #333; }
        pre { padding: 1rem; border-radius: 0.5rem; overflow-x: auto; font-size: 0.8125rem; line-height: 1.6; }
      ")
      (STYLE $theme_css)
  ) (
    BODY
      (nav-bar (A {href: "/"} "back"))
      (PRE {class: "code"} (CODE $highlighted))
  )
}

def handle-sse [req: record] {
  let signals = $in | from datastar-signals $req
  let prompt = $signals.prompt? | default ""
  let provider = $signals.provider? | default $DEFAULT_PROVIDER
  let model = $signals.model? | default $DEFAULT_MODEL

  if ($prompt | is-empty) {
    {data: "no prompt"} | to sse
    return
  }

  yoke --provider $provider --model $model --tools code,web_search $prompt
    | lines
    | tee {
        where { ($in | from json).role? != null }
        | str join "\n"
        | .append run
      }
    | render yoke-stream -m $model
    | to sse
}

{|req|
  dispatch $req [
    (route {path: "/"} {|req ctx| page})
    (route {path: "/models"} {|req ctx| handle-models $req})
    (route {path: "/runs"} {|req ctx| runs-page})
    (route {path-matches: "/run/:id"} {|req ctx| run-page $ctx.id})
    (route {path: "/code"} {|req ctx| code-page})
    (route {path: "/sse"} {|req ctx| handle-sse $req})
    (route true {|req ctx|
      "not found" | metadata set { merge {'http.response': {status: 404}} }
    })
  ]
}
