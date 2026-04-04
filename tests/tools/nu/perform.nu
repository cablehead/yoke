#!/usr/bin/env nu
#
# Usage: nu perform.nu case1.md
#
# Reads a test case markdown file, sends the prompt to yoke with the nu tool,
# and evaluates the output. Runs against each provider configured in .env.

use std/assert

const models = {
  gemini: "gemini-3-flash-preview"
  openai: "gpt-5.4-mini"
  anthropic: "claude-haiku-4-5-20251001"
}

def load-env [] {
  open ../../../.env
    | lines
    | where { $in | str trim | str length | $in > 0 }
    | each { |line|
      let parts = $line | split column "=" key value | get 0
      { name: $parts.key, value: $parts.value }
    }
}

def providers-from-env [] {
  let env_vars = load-env
  let mapping = {
    GEMINI_API_KEY: "gemini"
    OPENAI_API_KEY: "openai"
    ANTHROPIC_API_KEY: "anthropic"
  }
  $mapping
    | items { |key, provider|
      if ($env_vars | where name == $key | is-not-empty) {
        { provider: $provider, env_key: $key, env_value: ($env_vars | where name == $key | get value.0) }
      }
    }
    | compact
}

def run-yoke [prompt: string, provider: string, model: string, env_key: string, env_value: string] {
  let msg = { role: "user", content: $prompt } | to json -r
  with-env { ($env_key): $env_value } {
    $msg | yoke --tools nu --provider $provider --model $model
      | lines
      | where { $in | str starts-with '{' }
      | each { from json }
  }
}

def extract-nu-result [jsonl: list] {
  let tool_results = $jsonl
    | where { ($in | get -o type) == "tool_execution_end" and ($in | get -o tool_name) == "nu" }

  if ($tool_results | is-empty) {
    return { success: false, error: "no nu tool call was made", data: null }
  }

  let last = $tool_results | last
  let raw = $last | get result.content.0.text
  let ok = $last | get result.details.success

  if not $ok {
    return { success: false, error: $raw, data: null }
  }

  let data = try {
    $raw | from nuon
  } catch {
    return { success: false, error: $"not valid nuon: ($raw)", data: null }
  }

  { success: true, error: null, data: $data, raw: $raw }
}

def main [case_file: path] {
  let case = open $case_file
  let case_name = $case_file | path basename | str replace '.md' ''

  # extract the prompt
  let prompt = $case
    | parse --regex '(?s)## Prompt\n\n(.+?)\n\n##'
    | get capture0.0
    | str trim

  print $"(ansi cyan)case:(ansi reset) ($case_name)"
  print $"(ansi cyan)prompt:(ansi reset) ($prompt)..."
  print ""

  let providers = providers-from-env

  for p in $providers {
    let model = $models | get $p.provider
    print $"(ansi yellow)--- ($p.provider) / ($model) ---(ansi reset)"

    let jsonl = run-yoke $prompt $p.provider $model $p.env_key $p.env_value
    let result = extract-nu-result $jsonl

    if not $result.success {
      print $"  (ansi red)FAIL: ($result.error)(ansi reset)"
      continue
    }

    print $"  (ansi cyan)raw:(ansi reset) ($result.raw)"
    print ($result.data | table)

    evaluate $case_name $result.data
    print ""
  }
}

def evaluate [case_name: string, data: any] {
  match $case_name {
    "case1" => { eval-case1 $data },
    _ => { print $"  (ansi yellow)no eval defined for ($case_name)(ansi reset)" }
  }
}

def eval-case1 [data: any] {
  # 1. valid nuon (already passed if we got here)
  print $"  (ansi green)pass(ansi reset) valid nuon"

  # 2. 3 rows with product and total_value
  assert equal ($data | length) 3
  assert ("product" in ($data | columns))
  assert ("total_value" in ($data | columns))
  print $"  (ansi green)pass(ansi reset) 3 rows with product and total_value columns"

  # 3. multi-word value preserved
  assert ("Widget A" in ($data | get product))
  print $"  (ansi green)pass(ansi reset) multi-word \"Widget A\" preserved"

  # 4. descending order
  let values = $data | get total_value
  assert ($values.0 >= $values.1)
  assert ($values.1 >= $values.2)
  print $"  (ansi green)pass(ansi reset) sorted descending"

  # 5. numerically correct
  assert equal ($values.0 | into float) 2550.0
  assert equal ($values.1 | into float) 1074.75
  assert equal ($values.2 | into float) 750.0
  print $"  (ansi green)pass(ansi reset) values correct"
}
