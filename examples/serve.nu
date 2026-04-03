# serve.nu - stream yoke output to the browser via Datastar SSE
#
# Run with:
#   http-nu --datastar :3001 examples/serve.nu
#
# Then open http://localhost:3001 in your browser.

const script_dir = path self | path dirname

use http-nu/router *
use http-nu/datastar *
use http-nu/html *

source render-gemini.nu

const DEFAULT_MODEL = "gemini-3-flash-preview"

def page [] {
  let theme_css = .highlight theme Dracula
  HTML (
    HEAD
      (META {charset: "utf-8"})
      (META {name: "viewport", content: "width=device-width, initial-scale=1"})
      (TITLE "yoke")
      (SCRIPT-DATASTAR)
      (STYLE $theme_css)
      (STYLE "
        body { font-family: system-ui, sans-serif; max-width: 48rem; margin: 2rem auto; padding: 0 1rem; }
        input[type=text] { flex: 1; padding: 0.5rem; font-size: 1rem; border: 1px solid #ccc; border-radius: 0.25rem; }
        button { padding: 0.5rem 1rem; font-size: 1rem; cursor: pointer; border-radius: 0.25rem; border: 1px solid #ccc; }
        .meta { color: #888; font-size: 0.75rem; margin-top: 0.5rem; }
        nav { display: flex; justify-content: space-between; align-items: baseline; margin-bottom: 1rem; }
        nav a { font-size: 0.875rem; color: #666; text-decoration: none; }
        nav a:hover { color: #333; }
        @keyframes blink { 50% { opacity: 0; } }
        pre { border-radius: 0.5rem; padding: 1rem; overflow-x: auto; }
        code { font-size: 0.8125rem; }
      ")
  ) (
    BODY
      (NAV (H1 "yoke") (A {href: "/code"} "source"))
      (DIV {style: "display: flex; gap: 0.5rem; margin-bottom: 1rem;"}
        (INPUT {
          type: "text",
          placeholder: "ask something...",
          "data-bind": "prompt",
          value: ""
        })
        (BUTTON {
          "data-on:click": "$prompt && @get('/sse')"
        } "send")
      )
      (P {class: "meta"}
        (LABEL "model: ")
        (INPUT {
          type: "text",
          "data-bind": "model",
          value: $DEFAULT_MODEL,
          style: "width: 20rem; font-size: 0.75rem; padding: 0.25rem;"
        })
      )
      (DIV {id: "output"} "")
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
      (NAV (H1 "yoke") (A {href: "/"} "back"))
      (PRE {class: "code"} (CODE $highlighted))
  )
}

def handle-sse [req: record] {
  let signals = $in | from datastar-signals $req
  let prompt = $signals.prompt? | default ""
  let model = $signals.model? | default $DEFAULT_MODEL

  if ($prompt | is-empty) {
    {data: "no prompt"} | to sse
    return
  }

  yoke --provider gemini --model $model --tools web_search $prompt
    | lines
    | render yoke-stream -m $model
    | to sse
}

{|req|
  dispatch $req [
    (route {path: "/"} {|req ctx| page})
    (route {path: "/code"} {|req ctx| code-page})
    (route {path: "/sse"} {|req ctx| handle-sse $req})
    (route true {|req ctx|
      "not found" | metadata set { merge {'http.response': {status: 404}} }
    })
  ]
}
