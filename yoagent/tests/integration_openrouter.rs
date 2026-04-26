//! Integration tests against the real OpenRouter API.
//! Run with: OPENROUTER_API_KEY=... cargo test --test integration_openrouter -- --ignored

use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use yoagent::agent_loop::{agent_loop, AgentLoopConfig};
use yoagent::provider::{ModelConfig, OpenAiCompatProvider};
use yoagent::tools;
use yoagent::types::*;

fn api_key() -> String {
    std::env::var("OPENROUTER_API_KEY").expect("OPENROUTER_API_KEY must be set")
}

fn make_config(model: &str) -> AgentLoopConfig {
    let model_config = ModelConfig::openrouter(model, model);
    AgentLoopConfig {
        provider: std::sync::Arc::new(OpenAiCompatProvider),
        model: model.into(),
        api_key: api_key(),
        thinking_level: ThinkingLevel::Off,
        max_tokens: Some(1024),
        temperature: None,
        model_config: Some(model_config),
        convert_to_llm: None,
        transform_context: None,
        get_steering_messages: None,
        get_follow_up_messages: None,
        context_config: None,
        compaction_strategy: None,
        execution_limits: None,
        cache_config: CacheConfig {
            enabled: false,
            strategy: CacheStrategy::Disabled,
        },
        tool_execution: ToolExecutionStrategy::default(),
        retry_config: yoagent::RetryConfig::default(),
        before_turn: None,
        after_turn: None,
        on_error: None,
        input_filters: vec![],
    }
}

fn extract_assistant_text(messages: &[AgentMessage]) -> String {
    messages
        .iter()
        .filter_map(|m| {
            if let AgentMessage::Llm(Message::Assistant { content, .. }) = m {
                Some(
                    content
                        .iter()
                        .filter_map(|c| {
                            if let Content::Text { text } = c {
                                Some(text.as_str())
                            } else {
                                None
                            }
                        })
                        .collect::<Vec<_>>()
                        .join(""),
                )
            } else {
                None
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

fn has_tool_execution(rx: &mut mpsc::UnboundedReceiver<AgentEvent>) -> bool {
    let mut found = false;
    while let Ok(event) = rx.try_recv() {
        if matches!(event, AgentEvent::ToolExecutionStart { .. }) {
            found = true;
        }
    }
    found
}

/// Simple completion -- verifies streaming round-trip via OpenRouter.
#[tokio::test]
#[ignore]
async fn test_openrouter_simple_completion() {
    let config = make_config("openai/gpt-4o-mini");
    let (tx, _rx) = mpsc::unbounded_channel();
    let cancel = CancellationToken::new();

    let mut context = AgentContext {
        system_prompt: "Be concise.".into(),
        messages: Vec::new(),
        tools: Vec::new(),
    };

    let prompt = AgentMessage::Llm(Message::user("Reply with exactly the word: pong"));
    let new_messages = agent_loop(vec![prompt], &mut context, &config, tx, cancel).await;

    let text = extract_assistant_text(&new_messages);
    assert!(!text.is_empty(), "Expected non-empty response");
    assert!(
        text.to_lowercase().contains("pong"),
        "Expected 'pong' in response, got: {}",
        text
    );
    println!("Response: {}", text);
}

/// Tool use round-trip via OpenRouter.
#[tokio::test]
#[ignore]
async fn test_openrouter_with_tools() {
    let config = make_config("openai/gpt-4o-mini");
    let (tx, mut rx) = mpsc::unbounded_channel();
    let cancel = CancellationToken::new();

    let mut context = AgentContext {
        system_prompt: "Use the bash tool to answer. Be concise.".into(),
        messages: Vec::new(),
        tools: tools::default_tools(),
    };

    let prompt = AgentMessage::Llm(Message::user(
        "What is the output of `echo hello_openrouter`? Use bash.",
    ));
    let new_messages = agent_loop(vec![prompt], &mut context, &config, tx, cancel).await;

    let text = extract_assistant_text(&new_messages);
    assert!(
        text.contains("hello_openrouter"),
        "Expected response with tool output, got: {}",
        text
    );
    assert!(has_tool_execution(&mut rx), "Expected tool execution");
    println!("Response: {}", text);
}
