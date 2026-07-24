# test-render.nu - test the render module against fixtures
#
# Run with:
#   http-nu eval ux/tests/test-render.nu

use std/assert

const script_dir = path self | path dirname
source ($script_dir | path join ../render.nu)

# Test full fixture pipeline (laptops)
let fixture = open --raw ($script_dir | path join ../../fixtures/gemini-web-search-laptops.jsonl)
let frames = $fixture | lines | render yoke-stream -m "gemini-3-flash-preview"

let frame_count = $frames | length
assert ($frame_count > 3) $"expected >3 frames, got ($frame_count)"
print $"PASS: laptops fixture produced ($frame_count) frames"

# First frame should be the "thinking" view
let first = $frames | first
assert ($first.data | any { $in | str contains "thinking..." })
print "PASS: first frame is thinking view"

# Test tokyo fixture with grounding metadata
let tokyo_fixture = open --raw ($script_dir | path join ../../fixtures/gemini-web-search-tokyo.jsonl)
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

# Test render-run with multi-tool fixture
let multi_lines = open --raw ($script_dir | path join ../../fixtures/anthropic-multi-tool.jsonl)
  | lines | where { $in != "" }
  | each { from json }
  | where { $in.role? != null }

let cards = render-run $multi_lines
assert (($cards | length) == 6) $"expected 6 cards, got ($cards | length)"
print $"PASS: multi-tool fixture produced ($cards | length) cards"

# First card should be user message
let first_card = $cards | first
assert ($first_card.__html | str contains "card user")
print "PASS: first card is user message"

# Should have tool result cards with green border
let tool_cards = $cards | where { $in.__html | str contains "card tool" }
assert (($tool_cards | length) == 2) $"expected 2 tool result cards, got ($tool_cards | length)"
print "PASS: two tool result cards with green border"

# Should have assistant cards with model info
let assistant_cards = $cards | where { $in.__html | str contains "claude-sonnet" }
assert (($assistant_cards | length) > 0) "expected assistant cards with model info"
print "PASS: assistant cards have model info"

# Tool result cards should show tool names
let all_html = $cards | each { $in.__html } | str join "\n"
assert ($all_html | str contains "list_files")
assert ($all_html | str contains "read_file")
print "PASS: tool result cards show tool names"

# Test render-run with simple search fixture (no tools)
let search_lines = open --raw ($script_dir | path join ../../fixtures/gemini-web-search-tokyo.jsonl)
  | lines | where { $in != "" }
  | each { from json }
  | where { $in.role? != null }

let search_cards = render-run $search_lines
assert (($search_cards | length) == 2) $"expected 2 cards, got ($search_cards | length)"
print "PASS: search fixture produces 2 cards"

print "\nAll tests passed."
