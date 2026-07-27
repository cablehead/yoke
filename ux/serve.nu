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

source render.nu

const DEFAULT_PROVIDER = "gemini"
const DEFAULT_MODEL = "gemini-3-flash-preview"
const DEFAULT_SORT = "created"
const DEFAULT_SORT_DIR = "desc"
# Tools every run is given. One place, used both to run yoke and to render the context view.
const TOOLS_SPEC = "code,web_search"

# Columns shown in the model table. sortable columns get a clickable header.
const MODEL_COLS = [
  [key label sortable];
  [id id true]
  [intelligence AA true]
  [context_length context true]
  [price_in "in $/M" true]
  [price_out "out $/M" true]
  [created created true]
]

const ALL_PROVIDERS = [
  [name label key_var];
  [anthropic Anthropic ANTHROPIC_API_KEY]
  [openai OpenAI OPENAI_API_KEY]
  [gemini Gemini GEMINI_API_KEY]
  [openrouter OpenRouter OPENROUTER_API_KEY]
]

def available-providers [] {
  $ALL_PROVIDERS | where { $in.key_var in $env }
}

def styles [] {
  let theme_css = .highlight theme Dracula
  [
    (STYLE $theme_css)
    (STYLE "
      /* raw tags, styled once. layout stays inline on semantic tags (stacks.nu). */
      body { font-family: system-ui, sans-serif; margin: 0; height: 100vh; }
      a { color: #1a4b8c; text-decoration: none; }
      a:hover { text-decoration: underline; }
      button { font: inherit; cursor: pointer; }
      input, select { font: inherit; }
      input[type=text], select { padding: 0.5rem; border: 1px solid #ccc; border-radius: 0.25rem; }
      pre { border-radius: 0.5rem; padding: 1rem; overflow-x: auto; }
      code { font-size: 0.8125rem; }
      table { width: 100%; border-collapse: collapse; font-family: ui-monospace, monospace; font-size: 0.75rem; }
      th { text-align: left; padding: 0.3rem 0.5rem; border-bottom: 1px solid #ccc; position: sticky; top: 0; background: #fff; }
      td { padding: 0.3rem 0.5rem; }
      /* .scroll is the full-width scroll container (so you can scroll from anywhere, not only
         over the 48rem column); .col centers content inside it. */
      .scroll { flex: 1; overflow-y: auto; }
      #output { padding: 1rem 0 0; }
      #context { padding: 0 0 1rem; }
      .col { max-width: 48rem; margin: 0 auto; padding: 0 1rem; }
      /* tool cards (results and definitions): a status-bar header + body blocks. */
      .tool-head { display: flex; align-items: baseline; justify-content: space-between; gap: 0.5rem; font-weight: 600; font-size: 0.75rem; color: #555; margin-bottom: 0.35rem; padding-right: 1.75rem; }
      .tool-name { font-family: ui-monospace, monospace; }
      .tool-exit { font-family: ui-monospace, monospace; font-size: 0.6875rem; font-weight: 600; padding: 0.05rem 0.35rem; border-radius: 0.25rem; }
      .tool-exit.ok { color: #1a7f37; background: #e8f5ec; }
      .tool-exit.bad { color: #c0392b; background: #fdecea; }
      .tool-size { color: #aaa; font-size: 0.6875rem; font-weight: 400; }
      .tool-desc { color: #666; font-size: 0.8125rem; margin: 0 0 0.4rem; }
      .tool-args { margin: 0 0 0.4rem; padding: 0.4rem 0.6rem; background: rgba(0,0,0,0.05); border-radius: 0.25rem; font-size: 0.75rem; white-space: pre-wrap; overflow-x: auto; }
      .tool-out { margin: 0; white-space: pre-wrap; font-size: 0.75rem; max-height: 12rem; overflow: auto; }
      .card.tool.def { background: #f6f6fb; border-left-color: #8a8ad8; }
      /* per-node action row: fork (forkable turns) + raw toggle. subtle, above the next card. */
      .actions { display: flex; align-items: baseline; gap: 0.75rem; margin: -0.4rem 0 0.5rem; }
      .act-btn { border: 0; background: transparent; cursor: pointer; color: #999; font-size: 0.6875rem; padding: 0; }
      .act-btn:hover { color: #1a4b8c; }
      .raw-summary { cursor: pointer; color: #bbb; font-size: 0.6875rem; list-style: none; }
      .raw-summary::-webkit-details-marker { display: none; }
      details.raw pre { font-size: 0.6875rem; max-height: 18rem; overflow: auto; }
      /* collapsible tool card: peek by default, [+]/[-] toggle to expand. CSS-only. */
      .collapsible { position: relative; }
      .collapsible .card { max-height: 5rem; overflow: hidden; -webkit-mask-image: linear-gradient(#000 55%, transparent); mask-image: linear-gradient(#000 55%, transparent); }
      /* tools transclusion: one row summarizing the set; click to expand into the cards. */
      .tools-row { display: flex; align-items: baseline; gap: 0.5rem; cursor: pointer; padding: 0.6rem 0; color: #888; font-size: 0.8125rem; border-top: 1px solid #eee; }
      .tools-row:hover { color: #1a4b8c; }
      .tools-mark { font-family: ui-monospace, monospace; font-size: 0.6875rem; color: #aaa; }
      .tools-label { font-weight: 600; color: #555; }
      .tools-names { flex: 1; min-width: 0; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; font-family: ui-monospace, monospace; font-size: 0.75rem; }
      .tools-tok { color: #aaa; font-size: 0.6875rem; }
      /* tool-definition cards: full description; schema behind the header toggle. */
      .tool-meta { display: flex; align-items: baseline; gap: 0.6rem; }
      .schema-toggle { cursor: pointer; color: #999; font-size: 0.6875rem; }
      .schema-toggle:hover { color: #1a4b8c; }
      .tool-schema { display: none; margin: 0.4rem 0 0; white-space: pre-wrap; font-size: 0.6875rem; max-height: 16rem; overflow: auto; }
      .schema-cb:checked ~ .tool-schema { display: block; }
      .exp-cb:checked ~ .card { max-height: none; -webkit-mask-image: none; mask-image: none; }
      .exp-toggle { position: absolute; top: 0.3rem; right: 0.4rem; z-index: 2; cursor: pointer; color: #999; background: #fff; border-radius: 0.25rem; padding: 0.05rem 0.25rem; line-height: 1; font-family: ui-monospace, monospace; font-size: 0.75rem; user-select: none; }
      .exp-toggle .i-minus { display: none; }
      .exp-cb:checked ~ .exp-toggle .i-plus { display: none; }
      .exp-cb:checked ~ .exp-toggle .i-minus { display: inline; }
      @keyframes blink { 50% { opacity: 0; } }
      /* multi-lane view: .reading is the main view; pulling away ($_zoom -> .pulled) swaps in
         .tree, the whole conversation as an aligned node tree. Both stay in the DOM. */
      .lane-wrap { height: 100%; }
      .lane-wrap .reading { height: 100%; display: flex; flex-direction: column; min-height: 0; }
      .lane-wrap .tree { display: none; }
      .lane-wrap.pulled .reading { display: none; }
      .lane-wrap.pulled .tree { display: grid; gap: 0.5rem; grid-auto-rows: min-content; align-content: start; justify-content: start; padding: 1rem; height: 100%; overflow: auto; }
      /* skins: appearance only */
      .pane-header { padding: 0.5rem 0.75rem; font-size: 0.75rem; color: #888; text-transform: uppercase; letter-spacing: 0.05em; }
      .item { border: 0; border-bottom: 1px solid #f0f0f0; cursor: pointer; background: transparent; color: inherit; }
      .item:hover:not(.active) { background: #f4f4f4; }
      .item.active { background: #e8f0fe; color: #1a4b8c; }
      /* token-annotated outline: label + node tokens + cumulative. */
      .node { border-bottom: 1px solid #f0f0f0; padding: 0.35rem 0.75rem; font-size: 0.8125rem; }
      .node:hover { background: #f4f4f4; }
      .node-tok { color: #bbb; font-size: 0.6875rem; font-variant-numeric: tabular-nums; }
      .node-cum { color: #666; font-size: 0.75rem; font-variant-numeric: tabular-nums; min-width: 3rem; text-align: right; }
      .card { border: 1px solid #e0e0e0; border-radius: 0.5rem; padding: 0.75rem 1rem; margin-bottom: 0.75rem; background: #fff; overflow: hidden; }
      .card.user { background: #e8f0fe; border-color: #c4d8f0; }
      .card.tool { border: none; border-left: 3px solid #27ae60; border-radius: 0.25rem; background: #f0faf4; padding: 0.5rem 0.75rem; font-size: 0.8125rem; }
      .card.tool.error { border-left-color: #e74c3c; background: #fdf0ef; }
      .modal .backdrop { position: fixed; inset: 0; background: rgba(0,0,0,0.4); }
      .modal .dialog { position: fixed; top: 4vh; bottom: 4vh; left: 50%; transform: translateX(-50%); width: min(72rem, 96vw); background: #fff; border-radius: 0.5rem; box-shadow: 0 10px 40px rgba(0,0,0,0.25); display: flex; flex-direction: column; }
    ")
  ]
}

def nav-bar [...right] {
  NAV [
    (H1 (A {href: "/", style: "text-decoration: none; color: inherit;"} "yoke"))
    (DIV {style: "display: flex; gap: 1rem; align-items: center;"} ...$right)
  ]
}

# Format an integer with thousands separators for display (e.g. 1048576 -> 1,048,576).
def commafy [n] {
  $n | into string | split chars | reverse | chunks 3
    | each { reverse | str join } | reverse | str join ","
}

# Format a per-million-token price (float) as a compact dollar string.
# OpenRouter uses -1 to mean "no fixed price" (auto/router models).
def fmt-price [v] {
  if ($v < 0) { "auto" } else if ($v == 0) { "free" } else { "$" + ($v | math round --precision 3 | into string) }
}

# Filter by id/name substring, then sort by the given column and direction.
def sort-filter-models [models: list, filter: string, sort: string, dir: string] {
  let filtered = if ($filter | is-empty) {
    $models
  } else {
    $models | where {|m| ($m.id | str contains -i $filter) or ($m.name | str contains -i $filter) }
  }
  if ($filtered | is-empty) { return [] }
  let sorted = $filtered | sort-by -i {|row| $row | get $sort }
  if $dir == "desc" { $sorted | reverse } else { $sorted }
}

def render-model-select [models: list, sort: string, dir: string] {
  # Header cells: carry the sort arrow for the active column.
  let cols = $MODEL_COLS | each {|c|
    {
      key: $c.key,
      label: $c.label,
      sortable: $c.sortable,
      arrow: (if $c.key == $sort { (if $dir == "asc" { " ^" } else { " v" }) } else { "" })
    }
  }
  # Rows: format numbers/dates in nu so the template stays pure presentation.
  let rows = $models | each {|m|
    {
      id: $m.id,
      name: $m.name,
      intelligence: (if (($m.intelligence? | default (-1)) < 0) { "-" } else { $m.intelligence | into string }),
      context: (commafy $m.context_length),
      price_in: (fmt-price $m.price_in),
      price_out: (fmt-price $m.price_out),
      created: ($m.created | into string | str substring 0..9)
    }
  }
  let html = {cols: $cols, rows: $rows} | .mj ($script_dir | path join templates model-table.html)
  {__html: $html}
}

# The model picker modal. Open/close is a local $_pickerOpen signal; the model list
# inside #model-list is projected over the /ui connection.
def render-model-picker [models: list, sort: string, dir: string] {
  let providers = available-providers
  let default_provider = $providers | get -i 0 | get -i name | default $DEFAULT_PROVIDER
  DIV {id: "model-picker", class: "modal", "data-show": "$_pickerOpen", style: "display: none;"} [
    (DIV {class: "backdrop", "data-on:click": "$_pickerOpen = false"} "")
    (DIV {class: "dialog"} [
      (DIV {style: "display: flex; gap: 0.5rem; align-items: center; padding: 0.75rem 1rem; border-bottom: 1px solid #eee;"} [
        (SELECT {"data-bind": "provider", "data-on:change": "@post('/ui')"} {
          $providers | each {|p|
            if $p.name == $default_provider {
              OPTION {value: $p.name, selected: true} $p.label
            } else {
              OPTION {value: $p.name} $p.label
            }
          }
        })
        (BUTTON {style: "margin-left: auto;", "data-on:click": "$_pickerOpen = false"} "close")
      ])
      (DIV {style: "overflow: auto; padding: 0 1rem 1rem;"} (DIV {id: "model-list"} (render-model-select $models $sort $dir)))
    ])
  ]
}

# A turn's user question, for previews in the TOC and lanes.
def turn-label [frame: record] {
  let lines = try { .cas $frame.hash | lines | where {|l| $l != "" } | each { from json } } catch { [] }
  let user = $lines | where {|m| $m.role? == "user" } | first
  $user.content? | default [] | where {|c| $c.type? == "text" } | get -i 0.text | default "(turn)"
}

# A turn's final assistant response text, for the TOC's response pointer.
def resp-label [frame: record] {
  let lines = try { .cas $frame.hash | lines | where {|l| $l != "" } | each { from json } } catch { [] }
  let last = $lines | where {|m| $m.role? == "assistant" and (($m.content? | default [] | where {|c| $c.type? == "text" and (($c.text? | default "") | str length) > 0 } | length) > 0) } | last
  if ($last | is-empty) { return "(no response)" }
  $last.content? | default [] | where {|c| $c.type? == "text" } | get -i 0.text | default "(response)" | str trim
}

# All leaf tips (frames nobody `continues` from) for a session, in creation order.
# Each leaf is one lane -- a distinct branch of the conversation.
def leaves-for [session: any] {
  let frames = try { .cat -T chat.turn | where {|f| $f.meta?.session? == $session } } catch { [] }
  let parents = $frames | each {|f| $f.meta?.continues? } | compact
  $frames | where {|f| $f.id not-in $parents }
}

# The pulled-out overview: the whole conversation drawn as a tree. Every lane (leaf tip) is a
# column; each turn is a node placed at grid-row = its depth, so shared ancestors line up and
# The JSONL messages appended for a single turn (one chat.turn frame).
def turn-lines [frame: record] {
  try { .cas $frame.hash | lines | where {|l| $l != "" } | each { from json } } catch { [] }
}

# a trunk node spans the columns of all lanes that descend from it -- shared then branching.
# Every node renders its real cards (the same reading component), so a lane is literally the
# conversation, just aligned against its siblings. Clicking a node selects it as the head.
def lanes-tree [head: string] {
  let session = try { (.get $head).meta?.session? } catch { null }
  let leaves = if ($head | is-empty) { [] } else { leaves-for $session }
  if ($leaves | is-empty) { return (DIV {class: "tree"} "") }
  let current_ids = thread $head | get id
  # Stable lane order: leaves in tree (DFS) order by creation, independent of which lane is
  # current -- a lane keeps its column as you navigate, so you never get reshuffled. Each node
  # sits in the leftmost lane that has it, so the shared trunk runs down the left and peers
  # branch off where they diverge. The current path is highlighted and scrolled into view
  # wherever it falls (sometimes left, sometimes right, but always the same place for a lane).
  let ordered = $leaves | sort-by {|l| thread $l.id | get id | str join "/" } | each {|l| {leaf: $l, path: (thread $l.id)} }
  let ncols = $ordered | length
  # The current lane's column; nodes on the current path go here so the shared trunk runs down
  # under the current lane (not the leftmost). Other nodes stay in the leftmost lane that has
  # them, branching off to whichever side they fall on.
  let current_col = $ordered | enumerate | where {|x| $head in ($x.item.path | get id) } | get -i 0.index | default 0
  let placed = $ordered | enumerate | each {|col|
    $col.item.path | enumerate | each {|d| {id: $d.item.id, frame: $d.item, depth: $d.index, col: $col.index} }
  } | flatten | group-by id | items {|id grp|
    let col = if ($id in $current_ids) { $current_col } else { $grp | get col | math min }
    {id: $id, frame: ($grp | first | get frame), depth: ($grp | first | get depth), col: $col}
  }
  let cells = $placed | each {|nd|
    let is_current = ($nd.id in $current_ids)
    let skin = if $is_current { "outline: 2px solid #1a4b8c; outline-offset: 2px; border-radius: 0.5rem;" } else { "" }
    let place = "grid-row: " + (($nd.depth + 1) | into string) + "; grid-column: " + (($nd.col + 1) | into string) + ";"
    let attrs = {style: ("min-width: 0; cursor: pointer; " + $place + $skin), "data-on:click": ("$head = '" + $nd.id + "'; $_zoom = false; @get('/load')")}
    DIV (if $nd.id == $head { $attrs | merge {id: "lane-current"} } else { $attrs }) (render-run (turn-lines $nd.frame))
  }
  DIV {class: "tree", id: "lanes-tree", style: ("grid-template-columns: repeat(" + ($ncols | into string) + ", minmax(0, 24rem));")} $cells
}

# The multi-lane view IS the main view. The reading component (cards + composer) is the current
# lane; the overview is every lane rendered the same way, aligned by shared node. Pulling away
# ($_zoom, a client CSS class) crossfades the reading lane out and the aligned lanes in. Both
# stay in the DOM; the /ui bus re-broadcasts this whole view on every turn, so all visible lanes
# live-update.
def lanes-view [head: string] {
  DIV {class: "lane-wrap", "data-class": "{pulled: $_zoom}"} [
    (DIV {class: "reading"} (read-view $head))
    (lanes-tree $head)
  ]
}

# The tool schemas' token cost (bytes/4). The one context part the model never reports on its
# own -- it is bundled into the first call's input -- so it stays an estimate.
def tools-token-estimate [] {
  let bytes = try {
    ^yoke tools ...($TOOLS_SPEC | split row ",") | lines | where {|l| $l != "" } | each { $in | str length } | math sum
  } catch { 0 }
  ($bytes / 4) | math round
}

# The context window as an ordered list of nodes with real per-node and cumulative token counts
# derived from the model's usage. Chronological (oldest first): tools, then per turn the prompt,
# a node per tool-calling round, and the response. cum at a node = the context size once that
# node is in the window (the next call's input); node = cum minus the previous cum. Everything is
# from the LLM's usage except the tools node (estimate). Bad provider numbers surface as-is.
def context-outline [head: string] {
  let e_tools = tools-token-estimate
  mut cum = $e_tools
  mut out = [{kind: "tools", label: "tools", node: $e_tools, cum: $e_tools, anchor: "context", frame: null}]
  for fi in (thread $head | enumerate) {
    let f = $fi.item
    let idx = $fi.index | into string
    let msgs = turn-lines $f
    let assistants = $msgs | where {|m| $m.role? == "assistant" }
    if ($assistants | is-empty) { continue }
    let prompt = $msgs | where {|m| $m.role? == "user" } | first
    let ptext = $prompt.content? | default [] | where {|c| $c.type? == "text" } | get -i 0.text | default "(prompt)"
    let first_input = (try { $assistants | first | get usage.input } catch { null }) | default $cum
    $out = $out | append {kind: "prompt", label: $ptext, node: ($first_input - $cum), cum: $first_input, anchor: $"turn-($idx)", frame: $f.id}
    $cum = $first_input
    let n = $assistants | length
    for i in 0..<($n - 1) {
      let a = $assistants | get $i
      let ni = (try { $assistants | get ($i + 1) | get usage.input } catch { null }) | default $cum
      let calls = $a.content? | default [] | where {|c| $c.type? == "toolCall" }
      let names = $calls | get name? | compact | str join ", "
      let tc = $calls | get id? | compact | first
      let anchor = if ($tc | is-empty) { $"turn-($idx)" } else { $"tc-($tc)" }
      $out = $out | append {kind: "toolcall", label: (if ($names | is-empty) { "tool call" } else { $names }), node: ($ni - $cum), cum: $ni, anchor: $anchor, frame: $f.id}
      $cum = $ni
    }
    let last = $assistants | last
    let li = try { $last | get usage.input } catch { 0 }
    let lo = try { $last | get usage.output } catch { 0 }
    $out = $out | append {kind: "response", label: "response", node: $lo, cum: ($li + $lo), anchor: $"resp-($idx)", frame: $f.id}
    $cum = ($li + $lo)
  }
  $out
}

# Render one outline row: label (indented by kind), the node's own tokens, and the cumulative.
# Clicking jumps to the node's card/anchor; the tools row jumps to the transclusion row in the
# reading pane (which is where the expand lives).
def render-node-row [n: record] {
  let clip = {|s: string, m: int| if ($s | str length) > $m { ($s | str substring 0..$m) + "..." } else { $s } }
  let indent = if ($n.kind in ["prompt" "tools"]) { "0.75rem" } else { "1.75rem" }
  let color = if $n.kind == "prompt" { "#222" } else if $n.kind == "toolcall" { "#888" } else { "#555" }
  let label = if $n.kind == "toolcall" { $n.label } else { (do $clip $n.label 30) }
  let onclick = ("document.getElementById('" + $n.anchor + "')?.scrollIntoView({behavior: 'smooth', block: 'start'})")
  DIV {class: "node", style: "display: flex; align-items: baseline; gap: 0.4rem;", "data-on:click": $onclick} [
    (SPAN {style: ("flex: 1; min-width: 0; padding-left: " + $indent + "; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; color: " + $color + ";")} $label)
    (SPAN {class: "node-tok"} ("+" + (commafy $n.node)))
    (SPAN {class: "node-cum"} (commafy $n.cum))
  ]
}

# Left pane: the context window as a token-annotated outline. Fully reversed -- the newest node
# (largest cumulative) is on top, counting straight down to the tools node at the base. Strictly
# monotonic, so the number never appears to drop; within a turn the response leads and the prompt
# is the root at the bottom of its group. The tools row is always present (even on a fresh thread),
# so the tool set lives in the sidebar and stays out of the reading pane until you open it.
def thread-toc [head: string] {
  context-outline $head | reverse | each {|n| render-node-row $n }
}

# The composer: model button, prompt input, send. Belongs to the reading view only. Full-width
# bar (so its top border spans the pane) with the controls centered in a .col.
def composer [] {
  DIV {style: "background: #fff; border-top: 1px solid #eee;"} [
    (DIV {class: "col", style: "display: flex; gap: 0.5rem; align-items: center; padding: 0.75rem 1rem;"} [
      (BUTTON {style: "max-width: 14rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;", "data-on:click": "$_pickerOpen = true", "data-text": "'model: ' + $model"} "model")
      (INPUT {id: "prompt-input", type: "text", placeholder: "ask something...", "data-bind": "prompt", style: "flex: 1;"})
      (BUTTON {"data-indicator": "_sending", "data-attr:disabled": "$_sending", "data-on:click": "!$_sending && $prompt && @get('/sse'); $prompt = ''"} "send")
    ])
  ]
}

# A byte count and its ~token estimate (bytes/4), the same heuristic yoke budgets with.
def size-label [bytes: int] {
  $"($bytes) B  ~(($bytes / 4) | math round) tok"
}

# The tool definitions (and system prompt) as context-node cards -- the same card family as a
# tool result, collapsible like the other tool cards. These are the "what is this?" tools: each
# is a node in the context. Tools come from `yoke tools` (the same spec the run uses); the system
# prompt comes from the thread. Byte length is the raw wire size, matching the nav's tools node.
def render-context [head: string] {
  let sys = if ($head | is-empty) { "" } else {
    let m = thread-lines $head | where {|m| $m.role? == "system" } | get -i 0
    if $m == null { "" } else {
      let c = $m.content?
      if (($c | describe) | str starts-with "list") {
        $c | where {|b| $b.type? == "text" } | get -i 0.text | default ""
      } else {
        $c | default "" | into string
      }
    }
  }
  let tool_lines = try {
    ^yoke tools ...($TOOLS_SPEC | split row ",") | lines | where {|l| $l != "" }
  } catch { [] }
  let sys_cards = if ($sys | is-empty) { [] } else {
    [(render-tool-def "system prompt" ($sys | str length) "" $sys)]
  }
  let tools = $tool_lines | each { from json }
  let tool_cards = $tools | zip $tool_lines | each {|pair|
    let t = $pair.0
    render-tool-def $t.name ($pair.1 | str length) ($t.description? | default "") ($t.parameters? | default {} | to json --indent 2)
  }
  let cards = $sys_cards ++ $tool_cards
  if ($cards | is-empty) { return [] }
  # A single transclusion row summarizing the tools; click it to expand into the cards.
  let names = $tools | get name | str join ", "
  let total = ($sys | str length) + ($tool_lines | each { str length } | math sum)
  [
    (DIV {class: "tools-row", "data-on:click": "$_toolsOpen = !$_toolsOpen"} [
      (SPAN {class: "tools-mark", "data-text": "$_toolsOpen ? '[-]' : '[+]'"} "[+]")
      (SPAN {class: "tools-label"} "tools")
      (SPAN {class: "tools-names"} $names)
      (SPAN {class: "tools-tok"} (size-label $total))
    ])
    (DIV {"data-show": "$_toolsOpen"} $cards)
  ]
}

# The reading pane for a head: the card stack (newest first) with the context parts inline at
# the chronological start (the bottom), then the composer. #output holds the streamed messages;
# #context holds the static parts -- both scroll together in .scroll, but streaming only patches
# #output, so the context stays put. Cards center in a .col so the gutters scroll too.
def read-view [head: string] {
  let cards = if ($head | is-empty) { [] } else { render-run (thread-lines $head) --forks (thread $head | get id) }
  [
    (DIV {class: "scroll"} [
      (DIV {id: "output"} (DIV {class: "col"} ...$cards))
      (DIV {id: "context"} (DIV {class: "col"} ...(render-context $head)))
    ])
    (composer)
  ]
}

def page [resume: string] {
  let providers = available-providers
  let default_provider = $providers | get -i 0 | get -i name | default $DEFAULT_PROVIDER
  let models = sort-filter-models (with-aa (fetch-models $default_provider)) "" $DEFAULT_SORT $DEFAULT_SORT_DIR
  let default_model = $models | get -i 0.id | default $DEFAULT_MODEL

  # /session/<id> resumes an existing thread; / starts a fresh conversation.
  # $head is the current turn we continue from; a fork just points it at an earlier turn.
  let session = if ($resume | is-not-empty) { $resume } else { random uuid }
  let head = if ($resume | is-empty) { "" } else {
    (try { .cat -T chat.turn | where {|f| $f.meta?.session? == $session } | last | get -i id } catch { null }) | default ""
  }

  HTML (
    HEAD
      (META {charset: "utf-8"})
      (META {name: "viewport", content: "width=device-width, initial-scale=1"})
      (TITLE "yoke")
      (SCRIPT-DATASTAR)
      ...(styles)
  ) (
    BODY {
      "data-signals": ("{ model: '" + $default_model + "', provider: '" + $default_provider + "', model_filter: '', model_sort: '" + $DEFAULT_SORT + "', model_sort_dir: '" + $DEFAULT_SORT_DIR + "', model_sort_click: '', _pickerOpen: false, _zoom: false, _toolsOpen: false, session: '" + $session + "', head: '" + $head + "' }")
      "data-init": "@get('/ui')"
    } [
      (DIV {style: "display: grid; grid-template-columns: 16rem 1fr; height: 100vh;"} [
        (ASIDE {style: "display: flex; flex-direction: column; border-right: 1px solid #eee; background: #fafafa; overflow: hidden;"} [
          (DIV {style: "display: flex; gap: 1rem; align-items: baseline; padding: 0.75rem;"} [
            (H1 {style: "font-size: 1rem; margin: 0;"} "yoke")
            (A {href: "/"} "new")
            (A {href: "/runs"} "history")
            (BUTTON {style: "border: 0; background: transparent; padding: 0; color: #1a4b8c; cursor: pointer;", "data-on:click": "$_zoom = !$_zoom; $_zoom && setTimeout(() => document.getElementById('lane-current')?.scrollIntoView({inline: 'center', block: 'center'}), 60)"} "lanes")
          ])
          (HEADER {class: "pane-header"} "turns")
          (DIV {id: "thread-toc", style: "overflow-y: auto; flex: 1;"} (thread-toc $head))
        ])
        (SECTION {id: "view", style: "display: flex; flex-direction: column; min-width: 0; min-height: 0; overflow: hidden;"} (lanes-view $head))
      ])
      (render-model-picker $models $DEFAULT_SORT $DEFAULT_SORT_DIR)
    ]
  )
}

# Merge the current Artificial Analysis intelligence index onto the models. Loaded fresh
# per request (not baked into the cache) so regenerating data/aa-index.json shows up
# immediately without busting the model-list cache. -1 = unmapped.
def with-aa [models: list] {
  let aa = try { open ($script_dir | path join data aa-index.json) } catch { {} }
  $models | each {|m| $m | upsert intelligence ($aa | get -o $m.id | default (-1)) }
}

def fetch-models [provider: string] {
  let topic = $"models.($provider).v5"
  let cached = try { .last $topic } catch { null }
  if $cached != null {
    try { .cas $cached.hash | from json } catch { [] }
  } else {
    # Collect yoke's output with `complete` (not `try`): wrapping a streaming
    # external command in `try` and piping it into `.append` deadlocks in nu.
    let result = yoke --provider $provider | complete
    let models = if $result.exit_code == 0 {
      $result.stdout | from json -o | each {|m|
        # pricing is USD per token; surface as USD per million tokens for display/sort.
        let pr = $m.pricing? | default {}
        let id = ($m.id? | default "")
        {
          id: $id,
          name: ($m.name? | default $id),
          context_length: ($m.context_length? | default 0),
          price_in: ((try { $pr.prompt | into float } catch { 0.0 }) * 1000000),
          price_out: ((try { $pr.completion | into float } catch { 0.0 }) * 1000000),
          created: ($m.created? | default "")
        }
      }
    } else { [] }
    $models | to json | .append $topic --ttl time:21600000
    $models
  }
}

# Write side: a picker interaction (provider/filter/sort) publishes the new query
# to the bus. The /ui connection projects the result. Returns 204 (no direct patch).
def handle-ui [req: record] {
  let signals = $in | from datastar-signals $req
  let click = $signals.model_sort_click? | default ""
  let cur_sort = $signals.model_sort? | default $DEFAULT_SORT
  let cur_dir = $signals.model_sort_dir? | default $DEFAULT_SORT_DIR

  # A header click sorts by that column, toggling direction if it is already active.
  let sort = if ($click | is-not-empty) { $click } else { $cur_sort }
  let dir = if ($click | is-empty) {
    $cur_dir
  } else if $click == $cur_sort {
    if $cur_dir == "asc" { "desc" } else { "asc" }
  } else {
    "asc"
  }

  {
    provider: ($signals.provider? | default $DEFAULT_PROVIDER)
    filter: ($signals.model_filter? | default "")
    sort: $sort
    dir: $dir
    model: ($signals.model? | default "")
  } | .bus pub "model-picker"

  null | metadata set { merge {'http.response': {status: 204}} }
}

# Read side: one long-lived connection projecting the model list into #model-list
# whenever the picker query changes.
# The single home-page connection: projects the model list (on picker changes) and the
# thread index (when a turn is saved), both driven off the bus.
def stream-ui [] {
  .bus sub | each {|e|
    if $e.topic == "model-picker" {
      let s = $e.value
      let models = sort-filter-models (with-aa (fetch-models $s.provider)) $s.filter $s.sort $s.dir
      let selected = if (($s.model | default "") in ($models | get id)) { $s.model } else { $models | get -i 0.id | default "" }
      [
        (render-model-select $models $s.sort $s.dir | to datastar-patch-elements --selector "#model-list" --mode inner)
        ({model: $selected, model_sort: $s.sort, model_sort_dir: $s.dir, model_sort_click: ""} | to datastar-patch-signals)
      ]
    } else if $e.topic == "chat-turn-saved" {
      # A turn landed in some lane. The reading lane already streamed it into #output; here we
      # re-broadcast the aligned overview (#lanes-tree) so every visible lane reflects it too.
      let head = $e.value.head? | default ""
      [
        ({head: $head} | to datastar-patch-signals)
        (lanes-tree $head | get __html | to datastar-patch-elements)
        (toc-patch $head)
      ]
    } else { [] }
  } | flatten | to sse
}

# The turn TOC patch for a head. Shared by the bus projection (after a turn) and /load.
def toc-patch [head: string] {
  thread-toc $head | each {|b| $b.__html } | str join "" | to datastar-patch-elements --selector "#thread-toc" --mode inner
}

# Re-render the multi-lane view for a head (selecting a lane, forking, or jumping to a turn).
def handle-load [req: record] {
  let signals = $in | from datastar-signals $req
  let head = $signals.head? | default ""
  [
    (lanes-view $head | get __html | to datastar-patch-elements --selector "#view" --mode inner)
    (toc-patch $head)
  ] | to sse
}

# Walk the `continues` linked list back to the root, returning frames oldest -> newest.
def thread [id: any] {
  if ($id | is-empty) { return [] }
  let f = .get $id
  (thread ($f.meta?.continues?)) | append $f
}

# Rebuild a thread's full message list from its head frame id.
def thread-lines [id: string] {
  thread $id | each {|f| .cas $f.hash } | str join "\n" | lines | where {|l| $l != "" } | each { from json }
}

def runs-page [] {
  # One entry per conversation (session); clicking resumes it on the home page.
  let runs = try { .cat -T chat.turn } catch { [] }
    | group-by {|f| $f.meta?.session? | default $f.id }
    | transpose sid frames
    | each {|s|
        let head = $s.frames | last
        let root_lines = try { .cas ($s.frames | first | get hash) | lines | where {|l| $l != "" } | each { from json } } catch { [] }
        let user = $root_lines | where {|m| $m.role? == "user" } | first
        let prompt = $user.content? | default [] | where {|c| $c.type? == "text" } | get -i 0.text | default "(no prompt)"
        let preview = if ($prompt | str length) > 80 { ($prompt | str substring 0..80) + "..." } else { $prompt }
        {sid: $s.sid, head: $head.id, prompt: $preview, model: ($head.meta?.model? | default ""), turns: ($s.frames | length)}
      }
    | sort-by head | reverse

  HTML (
    HEAD
      (META {charset: "utf-8"})
      (META {name: "viewport", content: "width=device-width, initial-scale=1"})
      (TITLE "yoke - history")
      ...(styles)
  ) (
    BODY
      (DIV {style: "max-width: 48rem; margin: 2rem auto; padding: 0 1rem;"} [
        (nav-bar (A {href: "/"} "new"))
        (DIV
          ($runs | each {|run|
            A {href: $"/session/($run.sid)", class: "item", style: "display: block; padding: 0.75rem; color: inherit;"} [
              (DIV $run.prompt)
              (DIV {style: "font-size: 0.75rem; color: #888; margin-top: 0.25rem;"} $"($run.model) · ($run.turns) turns")
            ]
          })
        )
      ])
  )
}

def run-page [id: string] {
  let lines = thread-lines $id

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
  let session = $signals.session? | default "adhoc"
  let head = $signals.head? | default ""

  if ($prompt | is-empty) {
    {data: "no prompt"} | to sse
    return
  }

  # Continue from the current position ($head): the path root..head is the context, and this
  # turn is saved as a child of $head. A fork is just $head pointing at an earlier turn.
  let parent = if ($head | is-empty) { null } else { $head }
  let prior = if ($head | is-empty) { "" } else { thread $head | each {|f| .cas $f.hash } | str join "\n" }
  let prior_roles = if ($prior | str trim | is-empty) { 0 } else {
    $prior | lines | where {|l| (try { $l | from json | get -i role } catch { null }) != null } | length
  }

  # yoke echoes the prior context verbatim then the new turn; skip the echoed prior so each
  # frame stores just this turn, linked to its parent via `continues` (the xs thread model).
  $prior
    | yoke --provider $provider --model $model --tools $TOOLS_SPEC $prompt
    | lines
    | tee {
        let all = $in
        let saved = ($all | where { ($in | from json).role? != null } | skip $prior_roles | str join "\n" | .append chat.turn --meta {session: $session, continues: $parent, model: $model})
        {session: $session, head: $saved.id} | .bus pub "chat-turn-saved"
      }
    | render yoke-stream -m $model
    | to sse
}

{|req|
  dispatch $req [
    (route {path: "/"} {|req ctx| page ""})
    (route {path-matches: "/session/:id"} {|req ctx| page $ctx.id})
    (route {method: GET path: "/ui"} {|req ctx| stream-ui})
    (route {method: POST path: "/ui"} {|req ctx| handle-ui $req})
    (route {method: GET path: "/load"} {|req ctx| handle-load $req})
    (route {path: "/runs"} {|req ctx| runs-page})
    (route {path-matches: "/run/:id"} {|req ctx| run-page $ctx.id})
    (route {path: "/code"} {|req ctx| code-page})
    (route {path-matches: "/design/screenshots/:name"} {|req ctx|
      let f = $script_dir | path join .. design screenshots $ctx.name | path expand
      if ($f | path exists) {
        open --raw $f | metadata set { merge {'http.response': {headers: {'content-type': 'image/png'}}} }
      } else {
        "not found" | metadata set { merge {'http.response': {status: 404}} }
      }
    })
    (route {path: "/sse"} {|req ctx| handle-sse $req})
    (route true {|req ctx|
      "not found" | metadata set { merge {'http.response': {status: 404}} }
    })
  ]
}
