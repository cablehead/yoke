# yoke

Headless agent harness. JSONL in, JSONL out.

Context in, agent loop, JSONL out, done. No TUI, no REPL, no persistence.

Built on [yoagent](https://github.com/yologdev/yoagent).

- [Quick start](#quick-start)
- [Discovery](#discovery)
- [Tools](#tools)
- [Web search](#web-search)
- [Input](#input)
- [Output](#output)
- [Round-tripping](#round-tripping)
- [Providers](#providers)
- [Web UI](#web-ui)
- [Install](#install)

## Quick start

```nushell
yoke --provider anthropic --model claude-sonnet-4-20250514 "what files are here?"
```

## Discovery

List providers and where to get API keys:

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
```

List models for a provider:

```nushell
$ yoke --provider anthropic
claude-3-5-haiku-20241022
claude-3-5-sonnet-20241022
claude-sonnet-4-20250514
...
```

## Tools

Control which tools the agent has access to with `--tools`:

```nushell
# all tools including web search (default)
yoke --provider anthropic --model claude-sonnet-4-20250514 --tools all "find recent rust news"

# code tools only (bash, read_file, write_file, edit_file, list_files, search)
yoke --provider anthropic --model claude-sonnet-4-20250514 --tools code "refactor main.rs"

# web search only
yoke --provider openai --model gpt-5-search-api --tools web_search "latest news on Toronto"

# no tools
yoke --provider anthropic --model claude-sonnet-4-20250514 --tools none "explain ownership in rust"

# pick individual tools
yoke --provider anthropic --model claude-sonnet-4-20250514 --tools bash,read_file "check the logs"

# combine groups
yoke --provider anthropic --model claude-sonnet-4-20250514 --tools code,web_search "find and fix the bug"
```

Available tools:

| Tool | Description |
|------|-------------|
| `bash` | Shell command execution |
| `read_file` | Read files with line numbers |
| `write_file` | Create or overwrite files |
| `edit_file` | Search/replace editing |
| `list_files` | Directory listing |
| `search` | Grep/ripgrep pattern search |
| `web_search` | Provider-side web search |

## Web search

Web search is a provider-side capability. Each provider handles it differently:

| Provider | How it works | With function tools? |
|----------|-------------|---------------------|
| Anthropic | Server tool, model invokes mid-turn | Yes |
| OpenAI | Dedicated search models (e.g. `gpt-5-search-api`) | No -- separate model family |
| Gemini | Google Search grounding tool | Yes |

For OpenAI, use `--tools web_search` with a search model:

```nushell
yoke --provider openai --model gpt-5-search-api --tools web_search "population of toronto 2026"
```

For Anthropic and Gemini, web search works alongside code tools:

```nushell
yoke --provider anthropic --model claude-sonnet-4-20250514 "what is the latest rust release?"
```

## Input

JSONL on stdin. Lines with `role` are context messages. Everything else is
silently skipped.

```nushell
# simple prompt
{"role":"user","content":"list files"} | to json -r | yoke --provider anthropic --model claude-sonnet-4-20250514

# system prompt + user message
[
  ({"role":"system","content":"You are a helpful assistant."} | to json -r)
  ({"role":"user","content":"list files in the current directory"} | to json -r)
] | str join "\n" | yoke --provider anthropic --model claude-sonnet-4-20250514
```

Structured content from a previous run's output also round-trips as input.

## Output

JSONL on stdout. Two kinds of lines:

**Context lines** have `role`. User messages, assistant responses, tool
results. These round-trip as input.

**Observation lines** have `type`. Streaming deltas, tool execution, lifecycle.
Skipped on input.

```jsonl
{"type":"agent_start"}
{"type":"turn_start"}
{"role":"user","content":[{"type":"text","text":"what files are here?"}],"timestamp":1234}
{"type":"delta","kind":"text","delta":"I'll check"}
{"type":"tool_execution_start","tool_call_id":"...","tool_name":"list_files","args":{}}
{"type":"tool_execution_end","tool_call_id":"...","tool_name":"list_files","result":{...},"is_error":false}
{"role":"toolResult","toolCallId":"...","toolName":"list_files","content":[...],"isError":false,"timestamp":1234}
{"role":"assistant","content":[...],"stopReason":"stop","model":"...","usage":{...},"timestamp":1234}
{"type":"turn_end"}
{"type":"agent_end"}
```

## Round-tripping

Save a run:

```nushell
yoke --provider anthropic --model claude-sonnet-4-20250514 "what files are here?" | tee { save -f session.jsonl }
```

Continue the conversation:

```nushell
open --raw session.jsonl | yoke --provider anthropic --model claude-sonnet-4-20250514 "now count them"
```

Replay context against a different model:

```nushell
open --raw session.jsonl | yoke --provider openai --model gpt-5.4-mini "summarize what happened"
```

## Providers

| Provider | Env var | API |
|----------|---------|-----|
| anthropic | `ANTHROPIC_API_KEY` | Anthropic Messages |
| openai | `OPENAI_API_KEY` | OpenAI Chat Completions |
| gemini | `GEMINI_API_KEY` | Google Generative AI |

## Web UI

yoke includes a browser-based UI powered by
[http-nu](https://github.com/cablehead/http-nu) and
[Datastar](https://data-star.dev). It streams responses in real time with
rendered markdown, syntax highlighting, and grounding sources.

Requires [http-nu](https://github.com/cablehead/http-nu) (with embedded
[cross.stream](https://cross.stream) store for run history).

```nushell
http-nu --datastar --store ./store :3001 ux/serve.nu
```

Then open http://localhost:3001.

**Pages:**

- `/` -- prompt input, streams response as live-updating cards
- `/runs` -- history of past runs
- `/run/:id` -- replay a stored run as a card stack
- `/code` -- syntax-highlighted source of serve.nu

**How it works:**

Each yoke run streams JSONL through a render pipeline that produces
[Datastar](https://data-star.dev) SSE events. The browser morphs HTML into
place as cards complete:

- **User card** -- your prompt
- **Assistant card** -- rendered markdown, model info, token usage
- **Tool result card** -- tool name, output
- **Sources footer** -- grounding links from web search (Gemini)

Completed cards appear immediately. The current turn streams live at the bottom
with a blinking cursor. Runs are persisted to the cross.stream store for replay.

**Run the tests:**

```nushell
http-nu eval ux/tests/test-render.nu
```

## Install

```nushell
cargo install --git https://github.com/cablehead/yoke
```

Or build from source:

```nushell
git clone https://github.com/cablehead/yoke
cd yoke
cargo build --release
```
