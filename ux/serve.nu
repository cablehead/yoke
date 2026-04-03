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

const PROVIDERS = [
  [name label];
  [anthropic Anthropic]
  [openai OpenAI]
  [gemini Gemini]
]

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
    ")
  ]
}

def nav-bar [...right] {
  NAV [
    (H1 (A {href: "/", style: "text-decoration: none; color: inherit;"} "yoke"))
    (DIV {style: "display: flex; gap: 1rem; align-items: center;"} ...$right)
  ]
}

def render-model-select [models: list, selected: string] {
  let size = [($models | length) 8] | math min
  let size = [1 $size] | math max
  SELECT {id: "model-select", "data-bind": "model", size: $size, style: "width: 100%; font-family: ui-monospace, monospace; font-size: 0.75rem;"} {
    $models | each {|m|
      if $m == $selected {
        OPTION {value: $m, selected: true} $m
      } else {
        OPTION {value: $m} $m
      }
    }
  }
}

def page [] {
  let models = try { yoke --provider $DEFAULT_PROVIDER | from json -o | get id } catch { [$DEFAULT_MODEL] }

  HTML (
    HEAD
      (META {charset: "utf-8"})
      (META {name: "viewport", content: "width=device-width, initial-scale=1"})
      (TITLE "yoke")
      (SCRIPT-DATASTAR)
      ...(styles)
  ) (
    BODY
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
          "data-on:click": "$prompt && @get('/sse')"
        } "send")
      )
      (DIV {class: "config-row"}
        (SELECT {
          "data-bind": "provider",
          "data-on:change": "@get('/models')"
        } {
          $PROVIDERS | each {|p|
            if $p.name == $DEFAULT_PROVIDER {
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
          "data-on:input__debounce.200ms": "@get('/models')",
          value: "",
          style: "flex: 1;"
        })
      )
      (DIV {id: "model-select-wrapper", style: "margin-bottom: 0.75rem;"} (render-model-select $models $DEFAULT_MODEL))
      (DIV {id: "output"} "")
  )
}

def handle-models [req: record] {
  let signals = $in | from datastar-signals $req
  let provider = $signals.provider? | default $DEFAULT_PROVIDER
  let filter = $signals.model_filter? | default ""

  let all_models = try { yoke --provider $provider | from json -o | get id } catch { [] }
  let models = if ($filter | is-empty) {
    $all_models
  } else {
    $all_models | where { $in | str contains -i $filter }
  }
  let selected = $models | get -i 0 | default ""

  [
    (render-model-select $models $selected
      | to datastar-patch-elements --selector "#model-select-wrapper" --mode inner)
    ({model: $selected} | to datastar-patch-signals)
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

  yoke --provider $provider --model $model --tools web_search $prompt
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
