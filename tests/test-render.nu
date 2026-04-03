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
let finished_html = render-finished "Hello **world**" "gemini-3-flash-preview" 136 347
assert ($finished_html.__html | str contains "<strong>world</strong>")
assert ($finished_html.__html | str contains "gemini-3-flash-preview")
assert ($finished_html.__html | str contains "136 in / 347 out")
assert (not ($finished_html.__html | str contains "animation: blink"))
print "PASS: finished card renders markdown with metadata"

# Test full fixture pipeline
let fixture = open --raw ($script_dir | path join ../fixtures/gemini-web-search-laptops.jsonl)
let frames = $fixture | lines | render yoke-stream -m "gemini-3-flash-preview"

# Should have multiple frames
let frame_count = $frames | length
assert ($frame_count > 3) $"expected >3 frames, got ($frame_count)"
print $"PASS: fixture produced ($frame_count) frames"

# First frame should be the "thinking" view
let first = $frames | first
assert ($first.data | any { $in | str contains "thinking..." })
print "PASS: first frame is thinking view"

# Last frame should be the finished card (no cursor, has metadata)
let last = $frames | last
let last_data = $last.data | str join "\n"
assert ($last_data | str contains "gemini-3-flash-preview")
assert ($last_data | str contains "136 in / 347 out")
assert (not ($last_data | str contains "animation: blink"))
print "PASS: last frame is finished card with metadata"

# Middle frames should have table content
let mid = $frames | skip 1 | drop 1 | last
let mid_data = $mid.data | str join "\n"
assert ($mid_data | str contains "MacBook Pro")
print "PASS: middle frames contain table content"

print "\nAll tests passed."
