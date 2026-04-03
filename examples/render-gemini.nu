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
  let dim = "color: #aaa;"
  let val = "color: #666;"

  mut parts = []
  let input = $usage.input? | default 0
  let output = $usage.output? | default 0
  let thinking = $usage.thinking_tokens? | default 0
  let cache_read = $usage.cache_read? | default 0

  $parts = ($parts | append (SPAN {style: $val} $"($input)"))
  $parts = ($parts | append (SPAN {style: $dim} " in "))

  if $thinking > 0 {
    $parts = ($parts | append (SPAN {style: $val} $"($thinking)"))
    $parts = ($parts | append (SPAN {style: $dim} " think "))
  }

  $parts = ($parts | append (SPAN {style: $val} $"($output)"))
  $parts = ($parts | append (SPAN {style: $dim} " out"))

  if $cache_read > 0 {
    $parts = ($parts | append (SPAN {style: $dim} " / "))
    $parts = ($parts | append (SPAN {style: $val} $"($cache_read)"))
    $parts = ($parts | append (SPAN {style: $dim} " cached"))
  }

  $parts
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
      let meta = $event.metadata? | default null
      let frame = if $meta != null {
        render-finished $text ($event.model? | default $model) $usage --metadata $meta
      } else {
        render-finished $text ($event.model? | default $model) $usage
      }
      {out: ($frame | to datastar-patch-elements), next: $acc}
    } else {
      {next: $acc}
    }
  }
}
