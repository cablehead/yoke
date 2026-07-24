# render.nu - render yoke JSONL event stream into HTML cards
#
# Processes a stream of yoke events and produces Datastar-compatible
# patch-elements records. Two views:
#
# 1. Streaming: accumulated markdown rendered as it arrives, with cursor
# 2. Finished: polished card with rendered markdown, model info, token usage,
#    and grounding sources

use http-nu/datastar *
use http-nu/html *

# Render sources from metadata (handles both Gemini grounding and Anthropic citations)
def render-sources [metadata: record] {
  # Gemini: groundingChunks with web.title/web.uri
  let gemini_links = $metadata.groundingChunks? | default [] | each {|chunk|
    let web = $chunk.web? | default {}
    let title = $web.title? | default "source"
    let uri = $web.uri? | default ""
    if ($uri | is-empty) { null } else { {title: $title, url: $uri} }
  } | compact

  # Anthropic: citations with title/url
  let anthropic_links = $metadata.citations? | default [] | each {|c|
    let title = $c.title? | default "source"
    let url = $c.url? | default ""
    if ($url | is-empty) { null } else { {title: $title, url: $url} }
  } | compact

  # Deduplicate by url
  let all_links = $gemini_links | append $anthropic_links | uniq-by url

  let queries = $metadata.webSearchQueries? | default [] | where { $in != "" }

  if ($all_links | is-empty) and ($queries | is-empty) {
    return null
  }

  let source_els = $all_links | each {|link|
    A {href: $link.url, target: "_blank", style: "color: #4a7bbd; text-decoration: none;"} $link.title
  }

  let query_text = if ($queries | is-empty) { null } else {
    SPAN {style: "color: #999; font-style: italic;"} $"searched: ($queries | str join ', ')"
  }

  DIV {style: "padding: 0.5rem 1rem; background: #f0f4f8; border-top: 1px solid #e0e0e0; font-size: 0.75rem; display: flex; flex-wrap: wrap; gap: 0.25rem 0.75rem; align-items: center;"} [
    (SPAN {style: "color: #888; margin-right: 0.25rem;"} "sources:")
    ...$source_els
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

# Render a user message card
export def render-user [text: string] {
  DIV {class: "card user"} $text
}

# Render a tool result card. `args` is a compact rendering of the call's arguments
# (e.g. "path: README.md") so you can see what the tool was invoked with.
export def render-tool-result [tool_name: string, content: string, --args: string = "", --is-error] {
  let cls = if $is_error { "card tool error" } else { "card tool" }
  DIV {class: $cls} [
    (DIV {style: "font-weight: 600; font-size: 0.75rem; color: #555; margin-bottom: 0.25rem;"} [
      (SPAN $tool_name)
      ...(if ($args | is-not-empty) { [(SPAN {style: "font-weight: 400; color: #999; margin-left: 0.5rem; font-family: ui-monospace, monospace;"} $args)] } else { [] })
    ])
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

  DIV {class: "card"} [
    $rendered
    ...( if $sources != null { [$sources] } else { [] } )
    (DIV {style: "display: flex; justify-content: space-between; align-items: center; margin-top: 0.5rem; padding-top: 0.5rem; border-top: 1px solid #eee; font-size: 0.75rem; color: #888;"} [
      (SPAN $model)
      (SPAN ...(render-usage $usage))
    ])
  ]
}

# Compact one-line rendering of a tool call's arguments, e.g. "path: Cargo.toml".
def fmt-args [args: any] {
  $args | default {} | items {|k v| $"($k): ($v)" } | str join ", "
}

# Render a complete run as a stack of cards from stored JSONL lines
export def render-run [lines: list] {
  # Map each tool call id -> its compact args, sourced from the assistant messages.
  let call_args = $lines
    | where {|m| $m.role? == "assistant" }
    | each {|m| $m.content? | default [] | where {|c| $c.type? == "toolCall" } }
    | flatten
    | reduce --fold {} {|c, acc| $acc | upsert $c.id (fmt-args $c.arguments?) }

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
        let args = $call_args | get -o ($msg.toolCallId? | default "") | default ""
        let content = $msg.content?
          | default []
          | where { $in.type? == "text" }
          | get text?
          | compact
          | str join "\n"
        let is_error = $msg.isError? | default false
        if $is_error {
          render-tool-result $tool_name $content --args $args --is-error
        } else {
          render-tool-result $tool_name $content --args $args
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
