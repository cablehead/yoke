use std::io::{self, BufRead, IsTerminal};

use clap::Parser;
use serde::Serialize;
use tokio::sync::mpsc;

use yoagent::provider::AnthropicProvider;
use yoagent::tools::default_tools;
use yoagent::types::*;
use yoagent::Agent;

#[derive(Parser)]
#[command(about = "Headless agent harness. JSONL in, JSONL out.")]
struct Cli {
    /// Model identifier (e.g. claude-sonnet-4-20250514)
    #[arg(long)]
    model: String,

    /// Optional trailing prompt appended as a final user message
    #[arg()]
    prompt: Option<String>,
}

// -- JSONL output types ------------------------------------------------------

#[derive(Serialize)]
#[serde(tag = "type")]
#[serde(rename_all = "snake_case")]
enum Event {
    AgentStart,
    AgentEnd,
    TurnStart,
    TurnEnd,
    MessageStart {
        message: AgentMessage,
    },
    #[serde(rename = "delta")]
    MessageUpdate {
        #[serde(flatten)]
        delta: Delta,
    },
    MessageEnd {
        message: AgentMessage,
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
enum Delta {
    Text { delta: String },
    Thinking { delta: String },
    ToolCall { delta: String },
}

// -- Input parsing -----------------------------------------------------------

#[derive(serde::Deserialize)]
struct InputMessage {
    role: String,
    #[serde(default)]
    content: serde_json::Value,
}

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

        let msg: InputMessage = match serde_json::from_str(line) {
            Ok(m) => m,
            Err(e) => {
                eprintln!("skipping invalid json: {}", e);
                continue;
            }
        };

        match msg.role.as_str() {
            "system" => {
                system = match msg.content {
                    serde_json::Value::String(s) => s,
                    other => other.to_string(),
                };
            }
            "user" => {
                let text = match msg.content {
                    serde_json::Value::String(s) => s,
                    other => other.to_string(),
                };
                messages.push(AgentMessage::Llm(Message::user(text)));
            }
            other => {
                eprintln!("skipping unsupported role: {}", other);
            }
        }
    }

    (system, messages)
}

// -- Event translation -------------------------------------------------------

fn translate(event: &AgentEvent) -> Option<Event> {
    match event {
        AgentEvent::AgentStart => Some(Event::AgentStart),
        AgentEvent::AgentEnd { .. } => Some(Event::AgentEnd),
        AgentEvent::TurnStart => Some(Event::TurnStart),
        AgentEvent::TurnEnd { .. } => Some(Event::TurnEnd),
        AgentEvent::MessageStart { message } => Some(Event::MessageStart {
            message: message.clone(),
        }),
        AgentEvent::MessageUpdate { delta, .. } => {
            let d = match delta {
                StreamDelta::Text { delta } => Delta::Text {
                    delta: delta.clone(),
                },
                StreamDelta::Thinking { delta } => Delta::Thinking {
                    delta: delta.clone(),
                },
                StreamDelta::ToolCallDelta { delta } => Delta::ToolCall {
                    delta: delta.clone(),
                },
            };
            Some(Event::MessageUpdate { delta: d })
        }
        AgentEvent::MessageEnd { message } => Some(Event::MessageEnd {
            message: message.clone(),
        }),
        AgentEvent::ToolExecutionStart {
            tool_call_id,
            tool_name,
            args,
        } => Some(Event::ToolExecutionStart {
            tool_call_id: tool_call_id.clone(),
            tool_name: tool_name.clone(),
            args: args.clone(),
        }),
        AgentEvent::ToolExecutionUpdate { .. } => None,
        AgentEvent::ToolExecutionEnd {
            tool_call_id,
            tool_name,
            result,
            is_error,
        } => Some(Event::ToolExecutionEnd {
            tool_call_id: tool_call_id.clone(),
            tool_name: tool_name.clone(),
            result: result.clone(),
            is_error: *is_error,
        }),
        AgentEvent::ProgressMessage {
            tool_call_id,
            tool_name,
            text,
        } => Some(Event::ProgressMessage {
            tool_call_id: tool_call_id.clone(),
            tool_name: tool_name.clone(),
            text: text.clone(),
        }),
        AgentEvent::InputRejected { reason } => Some(Event::InputRejected {
            reason: reason.clone(),
        }),
    }
}

fn emit(event: &Event) {
    match serde_json::to_string(event) {
        Ok(json) => println!("{}", json),
        Err(e) => eprintln!("error serializing event: {}", e),
    }
}

// -- Main --------------------------------------------------------------------

#[tokio::main]
async fn main() {
    let cli = Cli::parse();

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

    let api_key = std::env::var("ANTHROPIC_API_KEY").unwrap_or_default();

    let mut agent = Agent::new(AnthropicProvider)
        .with_model(&cli.model)
        .with_api_key(api_key)
        .with_tools(default_tools());

    if !system.is_empty() {
        agent = agent.with_system_prompt(system);
    }

    let (tx, mut rx) = mpsc::unbounded_channel();

    let printer = tokio::spawn(async move {
        while let Some(event) = rx.recv().await {
            if let Some(e) = translate(&event) {
                emit(&e);
            }
        }
    });

    agent.prompt_messages_with_sender(messages, tx).await;
    agent.finish().await;
    let _ = printer.await;
}
