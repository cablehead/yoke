# render-gemini.nu - render yoke JSONL into HTML views
#
# Processes a stream of yoke events and produces Datastar-compatible
# patch-elements records. Two views:
#
# 1. Streaming: accumulated markdown rendered as it arrives, with cursor
# 2. Finished: polished card with rendered markdown, model info, token usage,
#    and grounding sources

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

# Render grounding sources as a list of links
def render-sources [metadata: record] {
  let chunks = $metadata.groundingChunks? | default []
  let queries = $metadata.webSearchQueries? | default [] | where { $in != "" }

  if ($chunks | is-empty) and ($queries | is-empty) {
    return null
  }

  let source_links = $chunks | each {|chunk|
    let web = $chunk.web? | default {}
    let title = $web.title? | default "source"
    let uri = $web.uri? | default ""
    if ($uri | is-empty) { null } else {
      A {href: $uri, target: "_blank", style: "color: #4a7bbd; text-decoration: none;"} $title
    }
  } | compact

  let query_text = if ($queries | is-empty) { null } else {
    SPAN {style: "color: #999; font-style: italic;"} $"searched: ($queries | str join ', ')"
  }

  DIV {style: "padding: 0.5rem 1rem; background: #f0f4f8; border-top: 1px solid #e0e0e0; font-size: 0.75rem; display: flex; flex-wrap: wrap; gap: 0.25rem 0.75rem; align-items: center;"} [
    (SPAN {style: "color: #888; margin-right: 0.25rem;"} "sources:")
    ...$source_links
    ...( if $query_text != null { [$query_text] } else { [] } )
  ]
}

# Render token usage as a compact display
def render-usage [usage: record] {
  let dim = "color: #aaa; font-size: 0.6875rem;"
  let val = "color: #666;"

  let fields = [
    [($usage.input? | default 0) "in"]
    [($usage.search_tokens? | default 0) "search"]
    [($usage.thinking_tokens? | default 0) "think"]
    [($usage.output? | default 0) "out"]
    [($usage.cache_read? | default 0) "cached"]
    [($usage.total_tokens? | default 0) "total"]
  ]

  $fields
    | where { $in.0 > 0 }
    | each {|f| [(SPAN {style: $val} $"($f.0)") (SPAN {style: $dim} $" ($f.1) ")]}
    | flatten
}

# Render the finished response card
export def render-finished [
  text: string
  model: string
  usage: record
  --metadata: record
] {
  let rendered = $text | .md

  let sources = if $metadata != null {
    render-sources $metadata
  } else {
    null
  }

  DIV {id: "output"} (
    DIV {style: "background: #fff; border: 1px solid #e0e0e0; border-radius: 0.5rem; overflow: hidden;"} [
      (DIV {style: "padding: 1rem;"} $rendered)
      ...( if $sources != null { [$sources] } else { [] } )
      (DIV {style: "padding: 0.5rem 1rem; background: #f8f8f8; border-top: 1px solid #e0e0e0; font-size: 0.75rem; display: flex; justify-content: space-between; align-items: center;"} [
        (SPAN {style: "color: #888;"} $model)
        (SPAN ...(render-usage $usage))
      ])
    ]
  )
}

# Render a user message card
export def render-user [text: string] {
  DIV {style: "background: #e8f0fe; border: 1px solid #c4d8f0; border-radius: 0.5rem; padding: 0.75rem 1rem; margin-bottom: 0.75rem; font-size: 0.9375rem;"} $text
}

# Render a tool result card
export def render-tool-result [tool_name: string, content: string, --is-error] {
  let border = if $is_error { "border-left: 3px solid #e74c3c;" } else { "border-left: 3px solid #27ae60;" }
  let bg = if $is_error { "background: #fdf0ef;" } else { "background: #f0faf4;" }
  DIV {style: $"($bg) ($border) border-radius: 0.25rem; padding: 0.5rem 0.75rem; margin-bottom: 0.75rem; font-size: 0.8125rem;"} [
    (DIV {style: "font-weight: 600; font-size: 0.75rem; color: #555; margin-bottom: 0.25rem;"} $tool_name)
    (PRE {style: "margin: 0; white-space: pre-wrap; font-size: 0.75rem; max-height: 12rem; overflow-y: auto;"} $content)
  ]
}

# Render an assistant message card (without the outer #output div)
export def render-assistant [msg: record] {
  let text = $msg.content?
    | default []
    | where { $in.type? == "text" }
    | get text?
    | compact
    | str join ""
  let usage = $msg.usage? | default {}
  let model = $msg.model? | default ""
  let meta = $msg.metadata? | default null
  let rendered = $text | .md

  let sources = if $meta != null {
    render-sources $meta
  } else {
    null
  }

  DIV {style: "background: #fff; border: 1px solid #e0e0e0; border-radius: 0.5rem; overflow: hidden; margin-bottom: 0.75rem;"} [
    (DIV {style: "padding: 1rem;"} $rendered)
    ...( if $sources != null { [$sources] } else { [] } )
    (DIV {style: "padding: 0.5rem 1rem; background: #f8f8f8; border-top: 1px solid #e0e0e0; font-size: 0.75rem; display: flex; justify-content: space-between; align-items: center;"} [
      (SPAN {style: "color: #888;"} $model)
      (SPAN ...(render-usage $usage))
    ])
  ]
}

# Render a complete run as a stack of cards from stored JSONL lines
export def render-run [lines: list] {
  $lines | each {|msg|
    match $msg.role? {
      "user" => {
        let text = $msg.content?
          | default []
          | where { $in.type? == "text" }
          | get text?
          | compact
          | str join ""
        render-user $text
      }
      "assistant" => {
        # Skip assistant messages that only have tool calls (no text)
        let has_text = $msg.content?
          | default []
          | where { $in.type? == "text" and ($in.text? | default "" | str length) > 0 }
          | length
        if $has_text > 0 {
          render-assistant $msg
        } else {
          null
        }
      }
      "toolResult" => {
        let tool_name = $msg.toolName? | default "tool"
        let content = $msg.content?
          | default []
          | where { $in.type? == "text" }
          | get text?
          | compact
          | str join "\n"
        let is_error = $msg.isError? | default false
        if $is_error {
          render-tool-result $tool_name $content --is-error
        } else {
          render-tool-result $tool_name $content
        }
      }
      _ => null
    }
  } | compact
}

# Render the full state: completed cards + streaming placeholder at bottom
def render-frame [cards: list, streaming_text: string] {
  let streaming = render-streaming-card $streaming_text
  DIV {id: "output"} [...$cards $streaming]
}

# Streaming card without the #output wrapper (for embedding in the stack)
def render-streaming-card [text: string] {
  let rendered = if ($text | is-empty) {
    SPAN {style: "color: #999;"} "thinking..."
  } else {
    $text | .md
  }
  DIV {style: "padding: 1rem; background: #f5f5f5; border-radius: 0.5rem; min-height: 4rem; margin-bottom: 0.75rem;"} [
    $rendered
    (SPAN {style: "display: inline-block; width: 0.5rem; height: 1rem; background: #333; animation: blink 1s step-end infinite;"} "")
  ]
}

# Process a stream of yoke JSONL lines into Datastar patch-elements records.
# Renders completed cards immediately, with a streaming placeholder at the bottom.
export def "render yoke-stream" [--model (-m): string = ""] {
  generate {|line, state = {acc: "", cards: [], messages: []}|
    let event = try { $line | from json } catch { null }
    if $event == null {
      {next: $state}
    } else if ($event.type? == "delta" and $event.kind? == "text") {
      let acc = $state.acc + $event.delta
      let frame = render-frame $state.cards $acc
      {out: ($frame | to datastar-patch-elements), next: ($state | merge {acc: $acc})}
    } else if ($event.type? == "agent_start") {
      let frame = render-frame [] ""
      {out: ($frame | to datastar-patch-elements), next: {acc: "", cards: [], messages: []}}
    } else if ($event.role? == "user") {
      # User message: render card immediately
      let text = $event.content?
        | default []
        | where { $in.type? == "text" }
        | get text?
        | compact
        | str join ""
      let cards = $state.cards | append (render-user $text)
      let messages = $state.messages | append $event
      let frame = render-frame $cards ""
      {out: ($frame | to datastar-patch-elements), next: ($state | merge {acc: "", cards: $cards, messages: $messages})}
    } else if ($event.role? == "toolResult") {
      # Tool result: render card immediately
      let tool_name = $event.toolName? | default "tool"
      let content = $event.content?
        | default []
        | where { $in.type? == "text" }
        | get text?
        | compact
        | str join "\n"
      let is_error = $event.isError? | default false
      let card = if $is_error {
        render-tool-result $tool_name $content --is-error
      } else {
        render-tool-result $tool_name $content
      }
      let cards = $state.cards | append $card
      let messages = $state.messages | append $event
      let frame = render-frame $cards ""
      {out: ($frame | to datastar-patch-elements), next: ($state | merge {acc: "", cards: $cards, messages: $messages})}
    } else if ($event.role? == "assistant") {
      # Assistant message: render as completed card, reset streaming text
      let messages = $state.messages | append $event
      let cards = $state.cards | append (render-assistant $event)
      {next: ($state | merge {acc: "", cards: $cards, messages: $messages})}
    } else if ($event.type? == "agent_end") {
      # Final frame: just the completed cards, no streaming placeholder
      let final_cards = render-run $state.messages
      let frame = DIV {id: "output"} ...$final_cards
      {out: ($frame | to datastar-patch-elements), next: $state}
    } else {
      {next: $state}
    }
  }
}
