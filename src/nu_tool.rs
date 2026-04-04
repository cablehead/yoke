//! Nushell tool -- execute nushell scripts with an embedded engine.

use std::sync::OnceLock;

use async_trait::async_trait;
use nu_cli::{add_cli_context, gather_parent_env_vars};
use nu_cmd_lang::create_default_context;
use nu_command::add_shell_command_context;
use nu_engine::eval_block_with_early_return;
use nu_parser::parse;
use nu_protocol::debugger::WithoutDebug;
use nu_protocol::engine::{EngineState, Redirection, Stack, StateWorkingSet};
use nu_protocol::{OutDest, PipelineData, Span};

use yoagent::types::*;

fn engine_state() -> &'static EngineState {
    static ENGINE: OnceLock<EngineState> = OnceLock::new();
    ENGINE.get_or_init(|| {
        let mut engine_state = create_default_context();
        engine_state = add_shell_command_context(engine_state);
        engine_state = add_cli_context(engine_state);
        if let Ok(cwd) = std::env::current_dir() {
            gather_parent_env_vars(&mut engine_state, cwd.as_ref());
        }
        engine_state
    })
}

pub struct NuTool;

#[async_trait]
impl AgentTool for NuTool {
    fn name(&self) -> &str {
        "nu"
    }

    fn label(&self) -> &str {
        "Execute Nushell"
    }

    fn description(&self) -> &str {
        "Execute a Nushell script. Output is automatically converted to nuon -- do not add '| to nuon' or '| to json'. Pass structured data via 'input' (JSON) to avoid quoting issues -- it becomes $in in the pipeline.\n\nExamples:\n  {command: \"$in | sort-by price -r\", input: [{name: \"Widget A\", price: 25.50}, {name: \"Gadget\", price: 15}]}\n  {command: \"seq 1 10 | each { |n| $n * $n }\"}"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({
            "type": "object",
            "properties": {
                "command": {
                    "type": "string",
                    "description": "The Nushell pipeline to execute. The result of the last expression is returned."
                },
                "input": {
                    "description": "Optional JSON data piped as $in to the command. Use this for structured data instead of embedding literals in the command string."
                }
            },
            "required": ["command"]
        })
    }

    async fn execute(
        &self,
        params: serde_json::Value,
        ctx: ToolContext,
    ) -> Result<ToolResult, ToolError> {
        let command = params["command"]
            .as_str()
            .ok_or_else(|| ToolError::InvalidArgs("missing 'command' parameter".into()))?
            .to_string();

        let input_json =
            if params.get("input").is_some_and(|v| !v.is_null()) {
                Some(serde_json::to_string(&params["input"]).map_err(|e| {
                    ToolError::InvalidArgs(format!("failed to serialize input: {e}"))
                })?)
            } else {
                None
            };

        let cancel = ctx.cancel;

        let handle = tokio::task::spawn_blocking(move || {
            let base = engine_state();
            let mut engine_state = base.clone();

            let script = match &input_json {
                Some(json) => {
                    format!("r#'{json}'# | from json | {command} | to nuon")
                }
                None => format!("{command} | to nuon"),
            };

            let mut working_set = StateWorkingSet::new(&engine_state);
            let block = parse(&mut working_set, None, script.as_bytes(), false);

            if let Some(err) = working_set.parse_errors.first() {
                return Err(format!("Parse error: {:?}", err));
            }

            engine_state
                .merge_delta(working_set.render())
                .map_err(|e| format!("Merge error: {e}"))?;

            let mut stack = Stack::new();
            let mut stack =
                stack.push_redirection(Some(Redirection::Pipe(OutDest::PipeSeparate)), None);

            let result = eval_block_with_early_return::<WithoutDebug>(
                &engine_state,
                &mut stack,
                &block,
                PipelineData::empty(),
            )
            .map_err(|e| format!("{e}"))?;

            let value = result
                .body
                .into_value(Span::unknown())
                .map_err(|e| format!("{e}"))?;

            Ok(value.to_expanded_string(" ", &engine_state.config))
        });

        tokio::select! {
            _ = cancel.cancelled() => {
                Err(ToolError::Cancelled)
            }
            result = handle => {
                match result {
                    Ok(Ok(output)) => Ok(ToolResult {
                        content: vec![Content::Text { text: output }],
                        details: serde_json::json!({ "success": true }),
                    }),
                    Ok(Err(e)) => Ok(ToolResult {
                        content: vec![Content::Text { text: format!("Error: {e}") }],
                        details: serde_json::json!({ "success": false }),
                    }),
                    Err(e) => Err(ToolError::Failed(format!("Task failed: {e}"))),
                }
            }
        }
    }
}
