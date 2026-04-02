use std::io::{self, BufRead, IsTerminal};

use clap::Parser;
use serde::Serialize;
use tokio::sync::mpsc;

use yoagent::provider::{AnthropicProvider, GoogleProvider, ModelConfig, OpenAiCompatProvider};
use yoagent::tools::default_tools;
use yoagent::types::*;
use yoagent::Agent;

#[derive(Parser)]
#[command(about = "Headless agent harness. JSONL in, JSONL out.")]
struct Cli {
    /// Provider: anthropic, openai, gemini
    #[arg(long)]
    provider: Option<String>,

    /// Model identifier (e.g. claude-sonnet-4-20250514)
    #[arg(long)]
    model: Option<String>,

    /// Optional trailing prompt appended as a final user message
    #[arg()]
    prompt: Option<String>,
}

// -- JSONL output: observation events ----------------------------------------

#[derive(Serialize)]
#[serde(tag = "type")]
#[serde(rename_all = "snake_case")]
enum Observation {
    AgentStart,
    AgentEnd,
    TurnStart,
    TurnEnd,
    #[serde(rename = "delta")]
    Delta {
        #[serde(flatten)]
        delta: DeltaKind,
    },
    ToolExecutionStart {
        tool_call_id: String,
        tool_name: String,
        args: serde_json::Value,
    },
    ToolExecutionEnd {
        tool_call_id: String,
        tool_name: String,
        result: ToolResult,
        is_error: bool,
    },
    ProgressMessage {
        tool_call_id: String,
        tool_name: String,
        text: String,
    },
    InputRejected {
        reason: String,
    },
}

#[derive(Serialize)]
#[serde(tag = "kind")]
#[serde(rename_all = "snake_case")]
enum DeltaKind {
    Text { delta: String },
    Thinking { delta: String },
    ToolCall { delta: String },
}

// -- Input parsing -----------------------------------------------------------

fn parse_stdin() -> (String, Vec<AgentMessage>) {
    let mut system = String::new();
    let mut messages: Vec<AgentMessage> = Vec::new();

    let stdin = io::stdin().lock();
    for line in stdin.lines() {
        let line = match line {
            Ok(l) => l,
            Err(e) => {
                eprintln!("error reading stdin: {}", e);
                continue;
            }
        };
        let line = line.trim();
        if line.is_empty() {
            continue;
        }

        // Parse as generic JSON to inspect the shape
        let value: serde_json::Value = match serde_json::from_str(line) {
            Ok(v) => v,
            Err(e) => {
                eprintln!("skipping invalid json: {}", e);
                continue;
            }
        };

        // Lines with "role" are context messages; everything else is skipped
        let role = match value.get("role").and_then(|r| r.as_str()) {
            Some(r) => r,
            None => continue,
        };

        match role {
            "system" => {
                system = match value.get("content") {
                    Some(serde_json::Value::String(s)) => s.clone(),
                    Some(other) => other.to_string(),
                    None => String::new(),
                };
            }
            // Shorthand: {"role":"user","content":"some string"}
            "user" if value.get("content").is_some_and(|c| c.is_string()) => {
                let text = value["content"].as_str().unwrap();
                messages.push(AgentMessage::Llm(Message::user(text)));
            }
            // Full form: user, assistant, toolResult with structured content
            _ => match serde_json::from_value::<Message>(value.clone()) {
                Ok(msg) => messages.push(AgentMessage::Llm(msg)),
                Err(e) => eprintln!("skipping message: {}", e),
            },
        }
    }

    (system, messages)
}

// -- Event emission ----------------------------------------------------------

fn emit_context(message: &AgentMessage) {
    match serde_json::to_string(message) {
        Ok(json) => println!("{}", json),
        Err(e) => eprintln!("error serializing message: {}", e),
    }
}

fn emit_observation(obs: &Observation) {
    match serde_json::to_string(obs) {
        Ok(json) => println!("{}", json),
        Err(e) => eprintln!("error serializing event: {}", e),
    }
}

fn handle_event(event: &AgentEvent) {
    match event {
        // Context lines: bare messages with "role"
        AgentEvent::MessageEnd { message } => emit_context(message),

        // Observation lines: tagged with "type"
        AgentEvent::AgentStart => emit_observation(&Observation::AgentStart),
        AgentEvent::AgentEnd { .. } => emit_observation(&Observation::AgentEnd),
        AgentEvent::TurnStart => emit_observation(&Observation::TurnStart),
        AgentEvent::TurnEnd { .. } => emit_observation(&Observation::TurnEnd),
        AgentEvent::MessageUpdate { delta, .. } => {
            let d = match delta {
                StreamDelta::Text { delta } => DeltaKind::Text {
                    delta: delta.clone(),
                },
                StreamDelta::Thinking { delta } => DeltaKind::Thinking {
                    delta: delta.clone(),
                },
                StreamDelta::ToolCallDelta { delta } => DeltaKind::ToolCall {
                    delta: delta.clone(),
                },
            };
            emit_observation(&Observation::Delta { delta: d });
        }
        AgentEvent::ToolExecutionStart {
            tool_call_id,
            tool_name,
            args,
        } => emit_observation(&Observation::ToolExecutionStart {
            tool_call_id: tool_call_id.clone(),
            tool_name: tool_name.clone(),
            args: args.clone(),
        }),
        AgentEvent::ToolExecutionEnd {
            tool_call_id,
            tool_name,
            result,
            is_error,
        } => emit_observation(&Observation::ToolExecutionEnd {
            tool_call_id: tool_call_id.clone(),
            tool_name: tool_name.clone(),
            result: result.clone(),
            is_error: *is_error,
        }),
        AgentEvent::ProgressMessage {
            tool_call_id,
            tool_name,
            text,
        } => emit_observation(&Observation::ProgressMessage {
            tool_call_id: tool_call_id.clone(),
            tool_name: tool_name.clone(),
            text: text.clone(),
        }),
        AgentEvent::InputRejected { reason } => emit_observation(&Observation::InputRejected {
            reason: reason.clone(),
        }),

        // MessageStart and ToolExecutionUpdate are not emitted
        AgentEvent::MessageStart { .. } | AgentEvent::ToolExecutionUpdate { .. } => {}
    }
}

// -- Provider config ---------------------------------------------------------

struct ProviderConfig {
    key_var: &'static str,
    models_url: &'static str,
    dashboard: &'static str,
}

const PROVIDERS: &[(&str, ProviderConfig)] = &[
    (
        "anthropic",
        ProviderConfig {
            key_var: "ANTHROPIC_API_KEY",
            models_url: "https://api.anthropic.com/v1/models",
            dashboard: "https://console.anthropic.com/settings/keys",
        },
    ),
    (
        "openai",
        ProviderConfig {
            key_var: "OPENAI_API_KEY",
            models_url: "https://api.openai.com/v1/models",
            dashboard: "https://platform.openai.com/api-keys",
        },
    ),
    (
        "gemini",
        ProviderConfig {
            key_var: "GEMINI_API_KEY",
            models_url: "https://generativelanguage.googleapis.com/v1beta/models",
            dashboard: "https://aistudio.google.com/apikey",
        },
    ),
];

fn provider_config(provider: &str) -> &'static ProviderConfig {
    PROVIDERS
        .iter()
        .find(|(name, _)| *name == provider)
        .map(|(_, config)| config)
        .unwrap_or_else(|| {
            eprintln!("unknown provider: {}", provider);
            std::process::exit(1);
        })
}

fn list_providers() {
    println!("available providers:\n");
    for (name, config) in PROVIDERS {
        println!("  {}", name);
        println!("    env: {}", config.key_var);
        println!("    key: {}", config.dashboard);
        println!();
    }
}

fn get_api_key(config: &ProviderConfig) -> String {
    std::env::var(config.key_var).unwrap_or_else(|_| {
        eprintln!("{} not set", config.key_var);
        std::process::exit(1);
    })
}

async fn list_models(provider: &str, config: &ProviderConfig, api_key: &str) {
    let client = reqwest::Client::new();

    let (req, list_key, id_key) = match provider {
        "anthropic" => (
            client
                .get(config.models_url)
                .header("x-api-key", api_key)
                .header("anthropic-version", "2023-06-01"),
            "data",
            "id",
        ),
        "gemini" => (
            client.get(format!("{}?key={}", config.models_url, api_key)),
            "models",
            "name",
        ),
        _ => (
            client
                .get(config.models_url)
                .header("authorization", format!("Bearer {}", api_key)),
            "data",
            "id",
        ),
    };

    let resp = match req.send().await {
        Ok(r) => r,
        Err(e) => {
            eprintln!("error fetching models: {}", e);
            std::process::exit(1);
        }
    };

    let body: serde_json::Value = match resp.json().await {
        Ok(v) => v,
        Err(e) => {
            eprintln!("error parsing response: {}", e);
            std::process::exit(1);
        }
    };

    match body[list_key].as_array() {
        Some(list) => {
            let mut ids: Vec<String> = list
                .iter()
                .filter_map(|m| {
                    let raw = m[id_key].as_str()?;
                    // Google prefixes with "models/" -- strip it
                    Some(raw.strip_prefix("models/").unwrap_or(raw).to_string())
                })
                .collect();
            ids.sort();
            for id in ids {
                println!("{}", id);
            }
        }
        None => {
            eprintln!("unexpected response: {}", body);
            std::process::exit(1);
        }
    }
}

// -- Main --------------------------------------------------------------------

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

    // No provider: list available providers and exit
    let provider = match cli.provider {
        Some(p) => p,
        None => {
            list_providers();
            return;
        }
    };

    let prov = provider_config(&provider);
    let api_key = get_api_key(prov);

    // No model: list available models and exit
    let model = match cli.model {
        Some(m) => m,
        None => {
            list_models(&provider, prov, &api_key).await;
            return;
        }
    };

    let (system, mut messages) = if io::stdin().is_terminal() {
        (String::new(), Vec::<AgentMessage>::new())
    } else {
        parse_stdin()
    };

    if let Some(prompt) = cli.prompt {
        messages.push(AgentMessage::Llm(Message::user(prompt)));
    }

    if messages.is_empty() {
        eprintln!("no messages provided");
        std::process::exit(1);
    }

    let mut agent = match provider.as_str() {
        "anthropic" => Agent::new(AnthropicProvider),
        "openai" => {
            Agent::new(OpenAiCompatProvider).with_model_config(ModelConfig::openai(&model, &model))
        }
        "gemini" => {
            Agent::new(GoogleProvider).with_model_config(ModelConfig::google(&model, &model))
        }
        _ => unreachable!(),
    };

    agent = agent
        .with_model(&model)
        .with_api_key(api_key)
        .with_tools(default_tools())
        .on_error(|e| eprintln!("error: {}", e));

    if !system.is_empty() {
        agent = agent.with_system_prompt(system);
    }

    let (tx, mut rx) = mpsc::unbounded_channel();

    let printer = tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            handle_event(&event);
        }
    });

    agent.prompt_messages_with_sender(messages, tx).await;
    agent.finish().await;
    let _ = printer.await;
}
