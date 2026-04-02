# yoke

Headless agent harness. JSONL in, JSONL out.

Built on [yoagent](https://github.com/yologdev/yoagent).

## Quick start

```nushell
yoke --provider anthropic --model claude-sonnet-4-20250514 "what files are here?"
```

## Discovery

Run with no args to list providers:

```nushell
yoke
# available providers:
#
#   anthropic
#     env: ANTHROPIC_API_KEY
#     key: https://console.anthropic.com/settings/keys
#
#   openai
#     env: OPENAI_API_KEY
#     key: https://platform.openai.com/api-keys
#
#   gemini
#     env: GEMINI_API_KEY
#     key: https://aistudio.google.com/apikey
```

Run with just `--provider` to list available models:

```nushell
yoke --provider anthropic
# claude-3-5-haiku-20241022
# claude-3-5-sonnet-20241022
# claude-sonnet-4-20250514
# ...
```

## Providers

| Provider | Env var | API |
|----------|---------|-----|
| anthropic | `ANTHROPIC_API_KEY` | Anthropic Messages |
| openai | `OPENAI_API_KEY` | OpenAI Chat Completions |
| gemini | `GEMINI_API_KEY` | Google Generative AI |

## Input

JSONL on stdin. Lines with `role` are context messages. Everything else is
silently skipped (observation events, blank lines, etc).

Simple form -- string content for user and system messages:

```nushell
{"role":"user","content":"list files"} | to json -r | yoke --provider anthropic --model claude-sonnet-4-20250514
```

Multiple messages:

```nushell
[
  ({"role":"system","content":"You are a helpful assistant."} | to json -r)
  ({"role":"user","content":"list files in the current directory"} | to json -r)
] | str join "\n" | yoke --provider anthropic --model claude-sonnet-4-20250514
```

Structured form (round-tripped from a previous run's output) also works.

## Output

JSONL on stdout. Two kinds of lines, distinguished by shape:

**Context lines** have `role`. These are the conversation: user messages,
assistant responses, tool results. They round-trip as input.

**Observation lines** have `type`. Streaming deltas, tool execution events,
lifecycle markers. Skipped on input.

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

Save a run, then continue the conversation:

```nushell
yoke --provider anthropic --model claude-sonnet-4-20250514 "what files are here?" | tee { save -f session.jsonl }
```

Continue from saved context:

```nushell
open --raw session.jsonl | yoke --provider anthropic --model claude-sonnet-4-20250514 "now count them"
```

Pipe the same context to a different model:

```nushell
open --raw session.jsonl | yoke --provider openai --model gpt-4o "summarize what happened"
```

## Tools

All yoagent built-in tools: bash, read_file, write_file, edit_file,
list_files, search.

## Build

```nushell
cargo build --release
```
