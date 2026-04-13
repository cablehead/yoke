//! Nushell tool -- execute nushell scripts with an embedded engine.

use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use async_trait::async_trait;
use nu_cli::{add_cli_context, gather_parent_env_vars};
use nu_cmd_lang::create_default_context;
use nu_command::add_shell_command_context;
use nu_engine::eval_block_with_early_return;
use nu_parser::parse;
use nu_plugin_engine::{GetPlugin, PluginDeclaration};
use nu_protocol::debugger::WithoutDebug;
use nu_protocol::engine::{EngineState, Redirection, Stack, StateWorkingSet};
use nu_protocol::{OutDest, PipelineData, PluginIdentity, RegisteredPlugin, Span, Type, Value};

use yoagent::types::*;

/// Configuration for the Nu engine, set once before first use.
static NU_CONFIG: OnceLock<NuConfig> = OnceLock::new();

struct NuConfig {
    plugins: Vec<PathBuf>,
    include_paths: Vec<PathBuf>,
}

/// Call once at startup (before any tool execution) to register plugin
/// paths and include paths for the embedded Nushell engine.
pub fn configure(plugins: Vec<PathBuf>, include_paths: Vec<PathBuf>) {
    let _ = NU_CONFIG.set(NuConfig {
        plugins,
        include_paths,
    });
}

fn load_plugin(engine_state: &mut EngineState, path: &Path) -> Result<(), String> {
    let path = path
        .canonicalize()
        .map_err(|e| format!("Failed to canonicalize plugin path {path:?}: {e}"))?;

    let identity = PluginIdentity::new(&path, None)
        .map_err(|_| format!("Invalid plugin path {path:?}: must be named nu_plugin_*"))?;

    let mut working_set = StateWorkingSet::new(engine_state);
    let plugin = nu_plugin_engine::add_plugin_to_working_set(&mut working_set, &identity)
        .map_err(|e| format!("Failed to add plugin to working set: {e}"))?;

    engine_state
        .merge_delta(working_set.render())
        .map_err(|e| format!("Failed to merge plugin delta: {e}"))?;

    let interface = plugin
        .clone()
        .get_plugin(None)
        .map_err(|e| format!("Failed to spawn plugin {path:?}: {e}"))?;

    plugin.set_metadata(Some(
        interface
            .get_metadata()
            .map_err(|e| format!("Failed to get plugin metadata: {e}"))?,
    ));

    let mut working_set = StateWorkingSet::new(engine_state);
    for signature in interface
        .get_signature()
        .map_err(|e| format!("Failed to get plugin signatures: {e}"))?
    {
        let decl = PluginDeclaration::new(plugin.clone(), signature);
        working_set.add_decl(Box::new(decl));
    }
    engine_state
        .merge_delta(working_set.render())
        .map_err(|e| format!("Failed to merge plugin commands: {e}"))?;

    Ok(())
}

fn set_lib_dirs(engine_state: &mut EngineState, paths: &[PathBuf]) -> Result<(), String> {
    if paths.is_empty() {
        return Ok(());
    }
    let span = Span::unknown();
    let vals: Vec<Value> = paths
        .iter()
        .map(|p| Value::string(p.to_string_lossy(), span))
        .collect();

    let mut working_set = StateWorkingSet::new(engine_state);
    let var_id = working_set.add_variable(
        b"$NU_LIB_DIRS".into(),
        span,
        Type::List(Box::new(Type::String)),
        false,
    );
    working_set.set_variable_const_val(var_id, Value::list(vals, span));
    engine_state
        .merge_delta(working_set.render())
        .map_err(|e| format!("Failed to set NU_LIB_DIRS: {e}"))?;
    Ok(())
}

fn engine_state() -> &'static EngineState {
    static ENGINE: OnceLock<EngineState> = OnceLock::new();
    ENGINE.get_or_init(|| {
        nu_command::tls::CRYPTO_PROVIDER.default();

        let mut engine_state = create_default_context();
        engine_state = add_shell_command_context(engine_state);
        engine_state = add_cli_context(engine_state);
        if let Ok(cwd) = std::env::current_dir() {
            gather_parent_env_vars(&mut engine_state, cwd.as_ref());
        }

        let config = NU_CONFIG.get();

        // Load plugins
        if let Some(cfg) = config {
            for path in &cfg.plugins {
                if let Err(e) = load_plugin(&mut engine_state, path) {
                    eprintln!("warning: failed to load plugin: {e}");
                }
            }
        }

        // Set include paths
        if let Some(cfg) = config {
            if let Err(e) = set_lib_dirs(&mut engine_state, &cfg.include_paths) {
                eprintln!("warning: failed to set include paths: {e}");
            }
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
