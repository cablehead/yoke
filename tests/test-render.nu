# test-render.nu - test the render-gemini module against fixtures
#
# Run with:
#   http-nu eval tests/test-render.nu

use std/assert

const script_dir = path self | path dirname
source ($script_dir | path join ../examples/render-gemini.nu)

# Test streaming view renders markdown
let streaming_html = render-streaming "## Hello\n\n**bold** text"
assert ($streaming_html.__html | str contains "<h2>Hello</h2>")
assert ($streaming_html.__html | str contains "<strong>bold</strong>")
assert ($streaming_html.__html | str contains "animation: blink")
print "PASS: streaming view renders markdown with cursor"

# Test streaming view shows thinking for empty text
let thinking_html = render-streaming ""
assert ($thinking_html.__html | str contains "thinking...")
print "PASS: streaming view shows thinking for empty text"

# Test finished card renders markdown with metadata
let finished_html = render-finished "Hello **world**" "gemini-3-flash-preview" {input: 136, output: 347}
assert ($finished_html.__html | str contains "<strong>world</strong>")
assert ($finished_html.__html | str contains "gemini-3-flash-preview")
assert ($finished_html.__html | str contains ">136<")
assert ($finished_html.__html | str contains ">347<")
assert ($finished_html.__html | str contains " in ")
assert ($finished_html.__html | str contains " out")
assert (not ($finished_html.__html | str contains "animation: blink"))
print "PASS: finished card renders markdown with metadata"

# Test finished card with thinking and search tokens
let finished_full = render-finished "Hello" "gemini-3-flash-preview" {input: 145, output: 524, thinking_tokens: 943, search_tokens: 1404}
assert ($finished_full.__html | str contains ">943<")
assert ($finished_full.__html | str contains " think ")
assert ($finished_full.__html | str contains ">1404<")
assert ($finished_full.__html | str contains " search ")
print "PASS: finished card shows thinking and search tokens"

# Zero-value tokens are omitted
let finished_minimal = render-finished "Hello" "gemini-3-flash-preview" {input: 10, output: 20, thinking_tokens: 0, search_tokens: 0}
assert (not ($finished_minimal.__html | str contains " think "))
assert (not ($finished_minimal.__html | str contains " search "))
print "PASS: zero-value tokens are omitted"

# Test finished card with grounding sources
let finished_with_sources = render-finished "Hello" "gemini-3-flash-preview" {input: 10, output: 20} --metadata {
  webSearchQueries: ["population of Tokyo 2026"]
  groundingChunks: [
    {web: {title: "wikipedia.org" uri: "https://en.wikipedia.org/wiki/Tokyo"}}
    {web: {title: "macrotrends.net" uri: "https://macrotrends.net/tokyo"}}
  ]
}
assert ($finished_with_sources.__html | str contains "sources:")
assert ($finished_with_sources.__html | str contains "wikipedia.org")
assert ($finished_with_sources.__html | str contains "macrotrends.net")
assert ($finished_with_sources.__html | str contains "searched: population of Tokyo 2026")
print "PASS: finished card with grounding sources"

# Test finished card without metadata shows no sources
let finished_no_meta = render-finished "Hello" "gemini-3-flash-preview" {input: 10, output: 20}
assert (not ($finished_no_meta.__html | str contains "sources:"))
print "PASS: finished card without metadata has no sources"

# Test full fixture pipeline (laptops)
let fixture = open --raw ($script_dir | path join ../fixtures/gemini-web-search-laptops.jsonl)
let frames = $fixture | lines | render yoke-stream -m "gemini-3-flash-preview"

let frame_count = $frames | length
assert ($frame_count > 3) $"expected >3 frames, got ($frame_count)"
print $"PASS: laptops fixture produced ($frame_count) frames"

# First frame should be the "thinking" view
let first = $frames | first
assert ($first.data | any { $in | str contains "thinking..." })
print "PASS: first frame is thinking view"

# Test tokyo fixture with grounding metadata
let tokyo_fixture = open --raw ($script_dir | path join ../fixtures/gemini-web-search-tokyo.jsonl)
let tokyo_frames = $tokyo_fixture | lines | render yoke-stream -m "gemini-3-flash-preview"

let tokyo_count = $tokyo_frames | length
assert ($tokyo_count > 3) $"expected >3 frames, got ($tokyo_count)"
print $"PASS: tokyo fixture produced ($tokyo_count) frames"

# Last frame should have sources from grounding metadata
let last = $tokyo_frames | last
let last_data = $last.data | str join "\n"
assert ($last_data | str contains "sources:")
assert ($last_data | str contains "wikipedia.org")
print "PASS: tokyo last frame has grounding sources"

# Last frame should have model and usage
assert ($last_data | str contains "gemini-3-flash-preview")
assert ($last_data | str contains " in ")
assert ($last_data | str contains " out")
print "PASS: tokyo last frame has model and usage"

print "\nAll tests passed."
