<h1>
<p align="center">
  yoke
  <br><br>
  <sup>A single agent turn as a unix pipe.</sup>
</p>
</h1>

<p align="center">
  <a href="https://github.com/cablehead/yoke/actions/workflows/release-binaries.yml">
    <img src="https://github.com/cablehead/yoke/actions/workflows/release-binaries.yml/badge.svg" alt="CI">
  </a>
  <a href="https://discord.com/invite/YNbScHBHrh">
    <img src="https://img.shields.io/discord/1182364431435436042?logo=discord" alt="Discord">
  </a>
</p>

---

yoke is a static binary that drives one LLM agent turn to completion. It runs
tool calls in a loop until the model is satisfied, then exits. Context window
in as JSONL on stdin, new context + live stream out as JSONL on stdout.

```
context.jsonl ──> yoke ──> tee ──> store context for follow-ups
                               └─> real-time view
```

No TUI, no REPL, no daemon, no persistence. Just a JSONL-in / JSONL-out
primitive you compose with shell tools. Particularly
[Nushell](https://www.nushell.sh), which is purpose-built for orchestrating
structured data streams.

```nushell
# one-shot
yoke --provider gemini --model gemini-2.5-flash "what files are here?"

# pipe context in, tee the stream to a file for follow-ups
yoke --provider anthropic --model claude-sonnet-4-20250514 "refactor main.rs"
  | tee { save -f session.jsonl }

# continue the conversation
cat session.jsonl
  | yoke --provider anthropic --model claude-sonnet-4-20250514 "now add tests"

# replay the same context against a different model
cat session.jsonl
  | yoke --provider openai --model gpt-5.4-mini "summarize what happened"
```

Built on [yoagent](https://github.com/yologdev/yoagent).

- [Install](#install)
- [Providers](#providers)
- [Tools](#tools)
- [Input / Output](#input--output)
- [Round-tripping](#round-tripping)
- [Skills](#skills)
- [Web UI](#web-ui)

## Install

### [eget](https://github.com/zyedidia/eget)

```nushell
eget cablehead/yoke
```

### Homebrew (macOS)

```nushell
brew install cablehead/tap/yoke
```

### cargo

```nushell
cargo install --git https://github.com/cablehead/yoke
```

### Build from source

```nushell
git clone https://github.com/cablehead/yoke
cd yoke
cargo build --release
```

## Providers

Run with no arguments to see available providers:

```nushell
$ yoke
available providers:

  anthropic
    env: ANTHROPIC_API_KEY
    key: https://console.anthropic.com/settings/keys

  openai
    env: OPENAI_API_KEY
    key: https://platform.openai.com/api-keys

  gemini
    env: GEMINI_API_KEY
    key: https://aistudio.google.com/apikey

  ollama
    local, no API key required
    default: http://localhost:11434
```

Run with a provider and no model to list available models:

```nushell
$ yoke --provider anthropic
claude-3-5-haiku-20241022
claude-3-5-sonnet-20241022
claude-sonnet-4-20250514
...
```

| Provider | Env var | API |
|----------|---------|-----|
| anthropic | `ANTHROPIC_API_KEY` | Anthropic Messages |
| openai | `OPENAI_API_KEY` | OpenAI Chat Completions |
| gemini | `GEMINI_API_KEY` | Google Generative AI |
| ollama | -- | Local, OpenAI-compatible |

### Ollama

Run models locally with [Ollama](https://ollama.com). No API key required.

```nushell
yoke --provider ollama
yoke --provider ollama --model gemma4 "hello"
yoke --provider ollama --base_url http://192.168.1.100:11434 --model llama3 "hello"
```

## Tools

Control which tools the agent has access to with `--tools`:

```nushell
# all tools including web search (default)
yoke --provider gemini --model gemini-2.5-flash --tools all "find recent rust news"

# code tools only
yoke --provider anthropic --model claude-sonnet-4-20250514 --tools code "refactor main.rs"

# nushell instead of bash
yoke --provider gemini --model gemini-2.5-flash --tools nu,read_file "check the logs"

# no tools
yoke --provider anthropic --model claude-sonnet-4-20250514 --tools none "explain ownership in rust"
```

| Tool | Description |
|------|-------------|
| `bash` | Shell command execution |
| `nu` | Nushell script execution (embedded engine) |
| `read_file` | Read files with line numbers |
| `write_file` | Create or overwrite files |
| `edit_file` | Search/replace editing |
| `list_files` | Directory listing |
| `search` | Grep/ripgrep pattern search |
| `web_search` | Provider-side web search |

### The nu tool

The builtin `nu` tool runs Nushell scripts in an embedded engine -- no
subprocess, no shell. Output is automatically converted to
[nuon](https://www.nushell.sh/lang-guide/chapters/types/nuon.html) so
structured data round-trips cleanly.

An optional `input` parameter accepts JSON data that gets piped as `$in` to
the command. This lets the LLM pass structured data as native JSON without
worrying about string quoting:

```json
{"command": "$in | sort-by price -r", "input": [{"name": "Widget A", "price": 25.50}]}
```

#### Plugins and modules

Load Nushell plugins with `--plugin` and module search paths with `-I`:

```nushell
# load the polars plugin
yoke --provider gemini --model gemini-2.5-flash --tools nu \
  --plugin /usr/local/bin/nu_plugin_polars \
  "open data.csv and find the top 5 rows by price"

# multiple plugins and an include path
yoke --provider gemini --model gemini-2.5-flash --tools nu \
  --plugin /usr/local/bin/nu_plugin_polars \
  --plugin /usr/local/bin/nu_plugin_formats \
  -I ./lib \
  "use mymod.nu; analyze the data"
```

Plugin names are included in the tool description so the LLM knows
they're available and can discover subcommands via `help`.

### Web search

Web search is a provider-side capability:

| Provider | How it works | With function tools? |
|----------|-------------|---------------------|
| Anthropic | Server tool, model invokes mid-turn | Yes |
| OpenAI | Dedicated search models (e.g. `gpt-5-search-api`) | No |
| Gemini | Google Search grounding tool | Yes |

## Input / Output

### Input

JSONL on stdin. Lines with `role` are context messages. Everything else is
silently skipped.

```nushell
# simple prompt
{role: "user", content: "list files"} | to json -r
  | yoke --provider anthropic --model claude-sonnet-4-20250514

# system prompt + user message
[
  ({role: "system", content: "You are a helpful assistant."} | to json -r)
  ({role: "user", content: "list files"} | to json -r)
] | str join "\n"
  | yoke --provider anthropic --model claude-sonnet-4-20250514
```

### Output

JSONL on stdout. Two kinds of lines:

**Context lines** have `role`. User messages, assistant responses, tool
results. These round-trip as input to the next turn.

**Observation lines** have `type`. Streaming deltas, tool execution, lifecycle
events. Skipped on input.

```jsonl
{"type":"agent_start"}
{"role":"system","content":"..."}
{"type":"turn_start"}
{"role":"user","content":[{"type":"text","text":"what files are here?"}],"timestamp":1234}
{"type":"delta","kind":"text","delta":"I'll check"}
{"type":"tool_execution_start","tool_call_id":"...","tool_name":"list_files","args":{}}
{"type":"tool_execution_end","tool_call_id":"...","tool_name":"list_files","result":{...}}
{"role":"toolResult","toolCallId":"...","toolName":"list_files","content":[...]}
{"role":"assistant","content":[...],"stopReason":"stop","model":"...","usage":{...}}
{"type":"turn_end"}
{"type":"agent_end"}
```

The observation lines are the live stream -- tee them to a renderer for
real-time display. The context lines are the durable state -- save them for
follow-ups.

## Round-tripping

Save a run:

```nushell
yoke --provider anthropic --model claude-sonnet-4-20250514 "what files are here?"
  | tee { save -f session.jsonl }
```

Continue the conversation:

```nushell
cat session.jsonl
  | yoke --provider anthropic --model claude-sonnet-4-20250514 "now count them"
```

Replay context against a different model:

```nushell
cat session.jsonl
  | yoke --provider openai --model gpt-5.4-mini "summarize what happened"
```

## Skills

Load [AgentSkills](https://agentskills.io)-compatible skill directories with
`--skills`. Skill metadata is injected into the system prompt. The agent reads
full SKILL.md instructions via `read_file` when it activates a skill.

```nushell
yoke --provider gemini --model gemini-2.5-flash --skills ./skills --tools read_file "use the greet skill"
```

A skill directory:

```
skills/
  greet/
    SKILL.md
  weather/
    SKILL.md
    scripts/
```

SKILL.md uses YAML frontmatter with `name` and `description` fields. The body
contains full instructions the agent reads on demand.

## Web UI

yoke includes a browser-based UI powered by
[http-nu](https://github.com/cablehead/http-nu) and
[Datastar](https://data-star.dev). It streams responses in real time with
rendered markdown, syntax highlighting, and grounding sources.

```nushell
http-nu --datastar --store ./store :3001 ux/serve.nu
```

Each yoke run streams JSONL through a render pipeline. The browser morphs HTML
into place as the turn progresses. Completed runs are persisted to the
[cross.stream](https://cross.stream) store for replay.

## Tool eval

`tests/tools/` contains eval cases for iterating on builtin tool descriptions
and behavior. Each case is a markdown file with a prompt and evaluation
criteria. `perform.nu` runs the case through yoke and checks the output.

```nushell
cd tests/tools/nu
$env.GEMINI_API_KEY = "your-key-here"
nu perform.nu case1.md
```
