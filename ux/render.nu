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

# Render a user message card. An id anchors the turn so a TOC can scroll to it.
export def render-user [text: string, --id: string = ""] {
  if ($id | is-empty) {
    DIV {class: "card user"} $text
  } else {
    DIV {class: "card user", id: $id} $text
  }
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

# Render an assistant message card (without the outer #output div). An id anchors the turn's
# final response so a TOC can scroll to it.
export def render-assistant [msg: record, --id: string = ""] {
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

  let attrs = if ($id | is-empty) { {class: "card"} } else { {class: "card", id: $id} }
  DIV $attrs [
    $rendered
    ...( if $sources != null { [$sources] } else { [] } )
    (DIV {style: "display: flex; justify-content: space-between; align-items: center; margin-top: 0.5rem; padding-top: 0.5rem; border-top: 1px solid #eee; font-size: 0.75rem; color: #888;"} [
      (SPAN $model)
      (SPAN {title: "in: full context sent this step (system prompt + tool schemas + conversation so far), not just your message. out: tokens generated. cached: input reused from cache. total: in + out. Each step is a fresh call, so in grows as history accumulates.", style: "cursor: help;"} ...(render-usage $usage))
    ])
  ]
}

# Compact one-line rendering of a tool call's arguments, e.g. "path: Cargo.toml".
def fmt-args [args: any] {
  $args | default {} | items {|k v| $"($k): ($v)" } | str join ", "
}

# A collapsed "raw" toggle shown under a card -- the message's stored JSONL, every byte.
def raw-details [msg: record] {
  DETAILS {class: "raw"} [
    (SUMMARY {class: "raw-summary"} "raw")
    (PRE ($msg | to json --indent 2))
  ]
}

# Render a complete run as a stack of cards from stored JSONL lines
export def render-run [lines: list] {
  # Map each tool call id -> its compact args, sourced from the assistant messages.
  let call_args = $lines
    | where {|m| $m.role? == "assistant" }
    | each {|m| $m.content? | default [] | where {|c| $c.type? == "toolCall" } }
    | flatten
    | reduce --fold {} {|c, acc| $acc | upsert $c.id (fmt-args $c.arguments?) }

  # Turn number for each user message, so its card can be anchored as #turn-N.
  let user_positions = $lines | enumerate | where {|x| ($x.item.role?) == "user" } | get index

  # The last assistant text message of each turn, anchored #resp-N (line index -> turn number),
  # so a TOC can jump to a turn's final response, not just its question.
  let resp_by_idx = $lines | enumerate
    | where {|x| $x.item.role? == "assistant" and (($x.item.content? | default [] | where {|c| $c.type? == "text" and (($c.text? | default "") | str length) > 0 } | length) > 0) }
    | each {|x| {idx: $x.index, turn: (($user_positions | where {|u| $u <= $x.index } | length) - 1)} }
    | group-by {|r| $r.turn | into string }
    | values
    | each {|grp| $grp | sort-by idx | last }
    | reduce --fold {} {|it, acc| $acc | insert ($it.idx | into string) $it.turn }

  let items = $lines | enumerate | each {|x|
    let msg = $x.item
    let card = match $msg.role? {
      "user" => {
        let text = $msg.content?
          | default []
          | where { $in.type? == "text" }
          | get text?
          | compact
          | str join ""
        let turn = $user_positions | enumerate | where {|u| $u.item == $x.index } | get -i 0.index | default 0
        render-user $text --id $"turn-($turn)"
      }
      "assistant" => {
        # Skip assistant messages that only have tool calls (no text)
        let has_text = $msg.content?
          | default []
          | where { $in.type? == "text" and ($in.text? | default "" | str length) > 0 }
          | length
        if $has_text > 0 {
          let rid = $resp_by_idx | get -o ($x.index | into string)
          if $rid != null { render-assistant $msg --id $"resp-($rid)" } else { render-assistant $msg }
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
    if $card == null { null } else { {card: $card, msg: $msg, tool: ($msg.role? == "toolResult"), id: ($msg.toolCallId? | default ($x.index | into string))} }
  } | compact
  # Newest first. The top item stays full; older tool cards collapse to a peek you can expand.
  $items | reverse | enumerate | each {|y|
    let it = $y.item
    let body = if ($y.index != 0 and $it.tool) { collapsible-tool $it.card $it.id } else { $it.card }
    DIV {class: "msg"} [$body (raw-details $it.msg)]
  }
}

# Wrap a tool card so it collapses to a peek by default, with a [+]/[-] toggle to expand. Pure
# CSS (a hidden checkbox + label), so expand state survives Datastar morphs on each stream tick.
def collapsible-tool [card: any, id: string] {
  DIV {class: "collapsible"} [
    (INPUT {type: "checkbox", id: $"exp-($id)", class: "exp-cb", style: "display: none;"})
    $card
    (LABEL {for: $"exp-($id)", class: "exp-toggle"} [
      (SPAN {class: "i-plus"} "[+]")
      (SPAN {class: "i-minus"} "[-]")
    ])
  ]
}

# The live card at the top of the stack: the model's in-progress text (or "thinking..."). Its
# own #streaming id lets a text delta patch just this card, leaving the completed stack alone.
def render-streaming-card [text: string] {
  let rendered = if ($text | is-empty) {
    SPAN {style: "color: #999;"} "thinking..."
  } else {
    $text | .md
  }
  DIV {id: "streaming", style: "padding: 1rem; background: #f5f5f5; border-radius: 0.5rem; min-height: 4rem; margin-bottom: 0.75rem;"} [
    $rendered
    (SPAN {style: "display: inline-block; width: 0.5rem; height: 1rem; background: #333; animation: blink 1s step-end infinite;"} "")
  ]
}

# The whole #output: the live streaming card on top (while a turn is active), then the completed
# stack newest-first. One render path for streaming and rest -- render-run does the ordering.
def stream-frame [messages: list, acc: string, active: bool] {
  let top = if $active { [(render-streaming-card $acc)] } else { [] }
  DIV {id: "output"} (DIV {class: "col"} [...$top ...(render-run $messages)])
}

# Process a stream of yoke JSONL lines into Datastar patch-elements records. Text deltas patch
# only the streaming card; message/lifecycle events re-render the whole stack.
export def "render yoke-stream" [--model (-m): string = ""] {
  generate {|line, state = {acc: "", messages: []}|
    let event = try { $line | from json } catch { null }
    if $event == null {
      {next: $state}
    } else if ($event.type? == "delta" and $event.kind? == "text") {
      let acc = $state.acc + $event.delta
      {out: (render-streaming-card $acc | to datastar-patch-elements), next: ($state | merge {acc: $acc})}
    } else if ($event.type? == "agent_start") {
      {out: (stream-frame [] "" true | to datastar-patch-elements), next: {acc: "", messages: []}}
    } else if ($event.role? in ["user" "toolResult" "assistant"]) {
      let messages = $state.messages | append $event
      {out: (stream-frame $messages "" true | to datastar-patch-elements), next: ($state | merge {acc: "", messages: $messages})}
    } else if ($event.type? == "agent_end") {
      {out: (stream-frame $state.messages "" false | to datastar-patch-elements), next: $state}
    } else {
      {next: $state}
    }
  }
}
