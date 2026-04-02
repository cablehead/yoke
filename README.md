# yoke

Headless agent harness. JSONL in, JSONL out.

Built on [yoagent](https://github.com/yologdev/yoagent).

## Usage

```
yoke --provider anthropic --model claude-sonnet-4-20250514 "what files are here?"
```

Pipe in context, add a prompt on the CLI:

```
cat context.jsonl | yoke --provider anthropic --model claude-sonnet-4-20250514 "what do you think?"
```

List available models for a provider:

```
yoke --provider anthropic
yoke --provider openai
```

## Providers

| Provider | Env var |
|----------|---------|
| anthropic | `ANTHROPIC_API_KEY` |
| openai | `OPENAI_API_KEY` |
| gemini | `GEMINI_API_KEY` |

## Input

JSONL on stdin. Each line is either a context message (has `role`) or ignored.

```jsonl
{"role":"system","content":"You are a helpful assistant."}
{"role":"user","content":"list files in the current directory"}
```

Simple string content works for user and system messages. Structured content
from a previous run's output also works -- pipe it back in to continue a
conversation.

## Output

JSONL on stdout. Two kinds of lines:

**Context** -- messages with a `role` field. These are the conversation: user
messages, assistant responses, tool results. Pipe them back in as input to
continue.

```jsonl
{"role":"user","content":[{"type":"text","text":"list files"}],"timestamp":1234}
{"role":"assistant","content":[...],"stopReason":"stop","model":"...","usage":{...},"timestamp":1234}
{"role":"toolResult","toolCallId":"...","toolName":"...","content":[...],"isError":false,"timestamp":1234}
```

**Observation** -- events with a `type` field. Streaming deltas, tool
execution, lifecycle. Skipped on input.

```jsonl
{"type":"agent_start"}
{"type":"delta","kind":"text","delta":"I'll check"}
{"type":"tool_execution_start","tool_call_id":"...","tool_name":"list_files","args":{}}
{"type":"tool_execution_end","tool_call_id":"...","tool_name":"list_files","result":{...},"is_error":false}
{"type":"agent_end"}
```

## Tools

All yoagent built-in tools: bash, read_file, write_file, edit_file,
list_files, search.

## Build

```
cargo build --release
```
