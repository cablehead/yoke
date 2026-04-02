# Yoke

Headless agent harness. JSONL in, JSONL out.

## Usage

```nu
$env.ANTHROPIC_API_KEY = "your_key_here"
yoke --model claude-3-5-sonnet-20241022 "Hello, what can you do?"
```

## Input Format

Feed JSONL via stdin:

```nu
'{"role":"system","content":"You are a helpful assistant"}' | yoke --model claude-3-5-sonnet-20241022
'{"role":"user","content":"List files in current directory"}' | yoke --model claude-3-5-sonnet-20241022
```

## Output Format

Returns JSONL with two types of lines:

- **Context**: Messages with `role` field (system/user/assistant/toolResult)
- **Events**: Observations with `type` field (agent_start, delta, tool_execution_start, etc.)

## Tools

Includes default coding tools: bash, read_file, write_file, edit_file, list_files, search.

## Build

```nu
cargo build --release
```