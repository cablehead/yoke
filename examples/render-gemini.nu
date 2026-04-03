# render-gemini.nu - render yoke JSONL into HTML views
#
# Processes a stream of yoke events and produces Datastar-compatible
# patch-elements records. Two views:
#
# 1. Streaming: accumulated markdown rendered as it arrives, with cursor
# 2. Finished: polished card with rendered markdown, model info, token usage

use http-nu/datastar *
use http-nu/html *

# Render the in-progress streaming view
export def render-streaming [text: string] {
  let rendered = if ($text | is-empty) {
    SPAN {style: "color: #999;"} "thinking..."
  } else {
    $text | .md
  }
  DIV {id: "output"} (
    DIV {style: "padding: 1rem; background: #f5f5f5; border-radius: 0.5rem; min-height: 4rem;"} [
      $rendered
      (SPAN {style: "display: inline-block; width: 0.5rem; height: 1rem; background: #333; animation: blink 1s step-end infinite;"} "")
    ]
  )
}

# Render the finished response card
export def render-finished [text: string, model: string, input_tokens: int, output_tokens: int] {
  let rendered = $text | .md
  DIV {id: "output"} (
    DIV {style: "background: #fff; border: 1px solid #e0e0e0; border-radius: 0.5rem; overflow: hidden;"} [
      (DIV {style: "padding: 1rem;"} $rendered)
      (DIV {style: "padding: 0.5rem 1rem; background: #f8f8f8; border-top: 1px solid #e0e0e0; font-size: 0.75rem; color: #888; display: flex; gap: 1rem;"} [
        (SPAN $model)
        (SPAN $"($input_tokens) in / ($output_tokens) out")
      ])
    ]
  )
}

# Process a stream of yoke JSONL lines into Datastar patch-elements records.
# Uses `generate` for streaming accumulation.
export def "render yoke-stream" [--model (-m): string = ""] {
  generate {|line, acc = ""|
    let event = try { $line | from json } catch { null }
    if $event == null {
      {next: $acc}
    } else if ($event.type? == "delta" and $event.kind? == "text") {
      let acc = $acc + $event.delta
      {out: (render-streaming $acc | to datastar-patch-elements), next: $acc}
    } else if ($event.type? == "agent_start") {
      {out: (render-streaming "" | to datastar-patch-elements), next: ""}
    } else if ($event.role? == "assistant") {
      let text = $event.content?
        | default []
        | where type? == "text"
        | get text?
        | compact
        | str join ""
      let usage = $event.usage? | default {}
      let frame = render-finished $text ($event.model? | default $model) ($usage.input? | default 0) ($usage.output? | default 0)
        | to datastar-patch-elements
      {out: $frame, next: $acc}
    } else {
      {next: $acc}
    }
  }
}
