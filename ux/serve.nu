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
      #output { flex: 1; overflow-y: auto; padding: 1rem 0; }
      @keyframes blink { 50% { opacity: 0; } }
      /* multi-lane view: .reading is the main view; pulling away ($_zoom -> .pulled) swaps in
         .tree, the whole conversation as an aligned node tree. Both stay in the DOM. */
      .lane-wrap { height: 100%; }
      .lane-wrap .reading { height: 100%; display: flex; flex-direction: column; max-width: 48rem; margin: 0 auto; padding: 0 1rem; min-height: 0; }
      .lane-wrap .tree { display: none; }
      .lane-wrap.pulled .reading { display: none; }
      .lane-wrap.pulled .tree { display: grid; gap: 0.5rem; grid-auto-rows: min-content; align-content: start; justify-content: start; padding: 1rem; height: 100%; overflow: auto; }
      /* skins: appearance only */
      .pane-header { padding: 0.5rem 0.75rem; font-size: 0.75rem; color: #888; text-transform: uppercase; letter-spacing: 0.05em; }
      .item { border: 0; border-bottom: 1px solid #f0f0f0; cursor: pointer; background: transparent; color: inherit; }
      .item:hover:not(.active) { background: #f4f4f4; }
      .item.active { background: #e8f0fe; color: #1a4b8c; }
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

# All leaf tips (frames nobody `continues` from) for a session, in creation order.
# Each leaf is one lane -- a distinct branch of the conversation.
def leaves-for [session: any] {
  let frames = try { .cat -T chat.turn | where {|f| $f.meta?.session? == $session } } catch { [] }
  let parents = $frames | each {|f| $f.meta?.continues? } | compact
  $frames | where {|f| $f.id not-in $parents }
}

# The pulled-out overview: the whole conversation drawn as a tree. Every lane (leaf tip) is a
# column; each turn is a node placed at grid-row = its depth, so shared ancestors line up and
# a trunk node spans the columns of all lanes that descend from it -- shared then branching.
# Nodes on the current thread are highlighted. Clicking a node selects it as the head.
def lanes-tree [head: string] {
  let session = try { (.get $head).meta?.session? } catch { null }
  let leaves = if ($head | is-empty) { [] } else { leaves-for $session }
  if ($leaves | is-empty) { return (DIV {class: "tree"} "") }
  let current_ids = thread $head | get id
  # Column order: sorting leaves by their root->tip id path groups shared prefixes (DFS order),
  # so a shared ancestor's descendant lanes are contiguous and its node can span them.
  let ordered = $leaves | each {|l| {leaf: $l, path: (thread $l.id)} } | sort-by {|x| $x.path | get id | str join "/" }
  let n = $ordered | length
  # Every (node, column) placement, then folded to one cell per node spanning its columns.
  let cells = $ordered | enumerate | each {|col|
    $col.item.path | enumerate | each {|d| {id: $d.item.id, frame: $d.item, depth: $d.index, col: $col.index} }
  } | flatten | group-by id | items {|id grp|
    {id: $id, frame: ($grp | first | get frame), depth: ($grp | first | get depth), min: ($grp | get col | math min), max: ($grp | get col | math max)}
  } | each {|nd|
    let is_current = ($nd.id in $current_ids)
    let skin = if $is_current { "background: #eef4fc; border-color: #1a4b8c; color: #1a4b8c; font-weight: 600;" } else { "background: #fff; border-color: #eee; color: #555;" }
    let place = "grid-row: " + (($nd.depth + 1) | into string) + "; grid-column: " + (($nd.min + 1) | into string) + " / span " + (($nd.max - $nd.min + 1) | into string) + ";"
    DIV {
      style: ("border: 1px solid; border-radius: 0.4rem; padding: 0.4rem 0.6rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; cursor: pointer; " + $place + $skin),
      "data-on:click": ("$head = '" + $nd.id + "'; $_zoom = false; @get('/load')")
    } (turn-label $nd.frame)
  }
  DIV {class: "tree", style: ("grid-template-columns: repeat(" + ($n | into string) + ", 12rem);")} $cells
}

# The multi-lane view IS the main view. The reading component (cards + composer) is the current
# lane; the tree overview is every lane aligned by shared node. Pulling away ($_zoom, a client
# CSS class) crossfades the reading lane out and the aligned tree in. Both stay in the DOM so
# streaming keeps targeting #output and the toggle needs no round trip.
def lanes-view [head: string] {
  DIV {class: "lane-wrap", "data-class": "{pulled: $_zoom}"} [
    (DIV {class: "reading"} (read-view $head))
    (lanes-tree $head)
  ]
}

# Left pane: a table of contents for the current thread -- one entry per turn,
# clicking scrolls the output to that turn (#turn-N).
def thread-toc [head: string] {
  if ($head | is-empty) { return [] }
  thread $head | enumerate | each {|t|
    let label = turn-label $t.item
    let preview = if ($label | str length) > 34 { ($label | str substring 0..34) + "..." } else { $label }
    DIV {class: "item", style: "display: flex; align-items: center;"} [
      (BUTTON {
        style: "flex: 1; min-width: 0; text-align: left; border: 0; background: transparent; cursor: pointer; padding: 0.5rem 0.75rem; color: inherit; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;",
        "data-on:click": ("document.getElementById('turn-" + ($t.index | into string) + "')?.scrollIntoView({behavior: 'smooth', block: 'start'})")
      } $preview)
      (BUTTON {
        title: "branch from here",
        style: "border: 0; background: transparent; cursor: pointer; padding: 0.5rem; color: #999;",
        "data-on:click": ("$head = '" + $t.item.id + "'; @get('/load')")
      } "fork")
    ]
  }
}

# The composer: model button, prompt input, send. Belongs to the reading view only.
def composer [] {
  DIV {style: "position: sticky; bottom: 0; background: #fff; display: flex; gap: 0.5rem; align-items: center; padding: 0.75rem 0; border-top: 1px solid #eee;"} [
    (BUTTON {style: "max-width: 14rem; overflow: hidden; text-overflow: ellipsis; white-space: nowrap;", "data-on:click": "$_pickerOpen = true", "data-text": "'model: ' + $model"} "model")
    (INPUT {id: "prompt-input", type: "text", placeholder: "ask something...", "data-bind": "prompt", style: "flex: 1;"})
    (BUTTON {"data-indicator": "_sending", "data-attr:disabled": "$_sending", "data-on:click": "!$_sending && $prompt && @get('/sse'); $prompt = ''"} "send")
  ]
}

# The reading pane for a head: the card stack plus the composer. This is the default mode
# of the #view region; /lanes swaps in lanes-view, and returning here restores it.
def read-view [head: string] {
  let cards = if ($head | is-empty) { [] } else { render-run (thread-lines $head) }
  [
    (DIV {id: "output"} ...$cards)
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
      "data-signals": ("{ model: '" + $default_model + "', provider: '" + $default_provider + "', model_filter: '', model_sort: '" + $DEFAULT_SORT + "', model_sort_dir: '" + $DEFAULT_SORT_DIR + "', model_sort_click: '', _pickerOpen: false, _zoom: false, session: '" + $session + "', head: '" + $head + "' }")
      "data-init": "@get('/ui')"
    } [
      (DIV {style: "display: grid; grid-template-columns: 16rem 1fr; height: 100vh;"} [
        (ASIDE {style: "display: flex; flex-direction: column; border-right: 1px solid #eee; background: #fafafa; overflow: hidden;"} [
          (DIV {style: "display: flex; gap: 1rem; align-items: baseline; padding: 0.75rem;"} [
            (H1 {style: "font-size: 1rem; margin: 0;"} "yoke")
            (A {href: "/"} "new")
            (A {href: "/runs"} "history")
            (BUTTON {style: "border: 0; background: transparent; padding: 0; color: #1a4b8c; cursor: pointer;", "data-on:click": "$_zoom = !$_zoom"} "lanes")
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
      let head = $e.value.head? | default ""
      [ ({head: $head} | to datastar-patch-signals) (toc-patch $head) ]
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
    | yoke --provider $provider --model $model --tools code,web_search $prompt
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
