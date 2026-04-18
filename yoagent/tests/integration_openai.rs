//! Integration tests against the real OpenAI API.
//! Run with: OPENAI_API_KEY=... cargo test --test integration_openai -- --ignored

use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use yoagent::agent_loop::{agent_loop, AgentLoopConfig};
use yoagent::provider::{ModelConfig, OpenAiCompatProvider};
use yoagent::tools::{self, WebSearchTool};
use yoagent::types::*;

fn api_key() -> String {
    std::env::var("OPENAI_API_KEY").expect("OPENAI_API_KEY must be set")
}

fn make_config(model: &str) -> AgentLoopConfig {
    let model_config = ModelConfig::openai(model, model);
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

/// Search model with web_search tool only -- searches automatically.
#[tokio::test]
#[ignore]
async fn test_openai_search_model_web_search_only() {
    let config = make_config("gpt-5-search-api");
    let (tx, _rx) = mpsc::unbounded_channel();
    let cancel = CancellationToken::new();

    let mut context = AgentContext {
        system_prompt: String::new(),
        messages: Vec::new(),
        tools: vec![Box::new(WebSearchTool)],
    };

    let prompt = AgentMessage::Llm(Message::user("What is the current population of Toronto?"));
    let new_messages = agent_loop(vec![prompt], &mut context, &config, tx, cancel).await;

    let text = extract_assistant_text(&new_messages);
    assert!(!text.is_empty(), "Expected non-empty response");
    assert!(
        text.contains("Toronto") || text.contains("population") || text.contains("million"),
        "Expected response about Toronto's population, got: {}",
        text
    );
    println!("Response: {}", text);
}

/// Search model with no tools at all -- still searches automatically.
#[tokio::test]
#[ignore]
async fn test_openai_search_model_no_tools() {
    let config = make_config("gpt-5-search-api");
    let (tx, _rx) = mpsc::unbounded_channel();
    let cancel = CancellationToken::new();

    let mut context = AgentContext {
        system_prompt: String::new(),
        messages: Vec::new(),
        tools: Vec::new(),
    };

    let prompt = AgentMessage::Llm(Message::user("What is the current population of Toronto?"));
    let new_messages = agent_loop(vec![prompt], &mut context, &config, tx, cancel).await;

    let text = extract_assistant_text(&new_messages);
    assert!(!text.is_empty(), "Expected non-empty response");
    println!("Response: {}", text);
}

/// Regular model with function tools -- tool execution works.
#[tokio::test]
#[ignore]
async fn test_openai_regular_model_with_tools() {
    let config = make_config("gpt-5.4-mini");
    let (tx, mut rx) = mpsc::unbounded_channel();
    let cancel = CancellationToken::new();

    let mut context = AgentContext {
        system_prompt: "Use the bash tool to answer. Be concise.".into(),
        messages: Vec::new(),
        tools: tools::default_tools(),
    };

    let prompt = AgentMessage::Llm(Message::user(
        "What is the output of `echo hello_openai`? Use bash.",
    ));
    let new_messages = agent_loop(vec![prompt], &mut context, &config, tx, cancel).await;

    let text = extract_assistant_text(&new_messages);
    assert!(
        text.contains("hello_openai"),
        "Expected response with tool output, got: {}",
        text
    );
    assert!(has_tool_execution(&mut rx), "Expected tool execution");
    println!("Response: {}", text);
}

/// Regular model with code tools + web_search -- web_search is filtered out,
/// function tools work normally.
#[tokio::test]
#[ignore]
async fn test_openai_regular_model_code_plus_websearch() {
    let config = make_config("gpt-5.4-mini");
    let (tx, mut rx) = mpsc::unbounded_channel();
    let cancel = CancellationToken::new();

    let mut tools = tools::default_tools();
    tools.push(Box::new(WebSearchTool));

    let mut context = AgentContext {
        system_prompt: "Use the bash tool to answer. Be concise.".into(),
        messages: Vec::new(),
        tools,
    };

    let prompt = AgentMessage::Llm(Message::user(
        "What is the output of `echo hello_mixed`? Use bash.",
    ));
    let new_messages = agent_loop(vec![prompt], &mut context, &config, tx, cancel).await;

    let text = extract_assistant_text(&new_messages);
    assert!(
        text.contains("hello_mixed"),
        "Expected response with tool output, got: {}",
        text
    );
    assert!(has_tool_execution(&mut rx), "Expected tool execution");
    println!("Response: {}", text);
}

/// Search model rejects function tools -- should error gracefully.
#[tokio::test]
#[ignore]
async fn test_openai_search_model_rejects_function_tools() {
    let config = make_config("gpt-5-search-api");
    let (tx, _rx) = mpsc::unbounded_channel();
    let cancel = CancellationToken::new();

    // Send function tools to a search model -- should get an error
    let mut context = AgentContext {
        system_prompt: String::new(),
        messages: Vec::new(),
        tools: tools::default_tools(),
    };

    let prompt = AgentMessage::Llm(Message::user("Hello"));
    let new_messages = agent_loop(vec![prompt], &mut context, &config, tx, cancel).await;

    // Should have an assistant message with an error
    let has_error = new_messages.iter().any(|m| {
        matches!(
            m,
            AgentMessage::Llm(Message::Assistant {
                stop_reason: StopReason::Error,
                ..
            })
        )
    });
    assert!(
        has_error,
        "Expected error when sending function tools to search model"
    );
}
