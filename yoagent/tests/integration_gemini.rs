//! Integration tests against the real Google Gemini API.
//! Run with: GEMINI_API_KEY=... cargo test --test integration_gemini -- --ignored

use tokio::sync::mpsc;
use tokio_util::sync::CancellationToken;
use yoagent::agent_loop::{agent_loop, AgentLoopConfig};
use yoagent::provider::{GoogleProvider, ModelConfig};
use yoagent::tools::{self, WebSearchTool};
use yoagent::types::*;

fn api_key() -> String {
    std::env::var("GEMINI_API_KEY").expect("GEMINI_API_KEY must be set")
}

fn make_config(model: &str) -> AgentLoopConfig {
    let model_config = ModelConfig::google(model, model);
    AgentLoopConfig {
        provider: std::sync::Arc::new(GoogleProvider),
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

/// Simple text response.
#[tokio::test]
#[ignore]
async fn test_gemini_simple_text() {
    let config = make_config("gemini-3-flash-preview");
    let (tx, _rx) = mpsc::unbounded_channel();
    let cancel = CancellationToken::new();

    let mut context = AgentContext {
        system_prompt: "Reply with exactly one word.".into(),
        messages: Vec::new(),
        tools: Vec::new(),
    };

    let prompt = AgentMessage::Llm(Message::user("What color is the sky?"));
    let new_messages = agent_loop(vec![prompt], &mut context, &config, tx, cancel).await;

    let text = extract_assistant_text(&new_messages);
    assert!(!text.is_empty(), "Expected non-empty response");
    println!("Response: {}", text);
}

/// Web search with Gemini -- grounding via googleSearch tool.
#[tokio::test]
#[ignore]
async fn test_gemini_web_search() {
    let config = make_config("gemini-3-flash-preview");
    let (tx, mut rx) = mpsc::unbounded_channel();
    let cancel = CancellationToken::new();

    let mut context = AgentContext {
        system_prompt: "Be concise.".into(),
        messages: Vec::new(),
        tools: vec![Box::new(WebSearchTool)],
    };

    let prompt = AgentMessage::Llm(Message::user(
        "What is the current population of Toronto in 2026?",
    ));
    let new_messages = agent_loop(vec![prompt], &mut context, &config, tx, cancel).await;

    let text = extract_assistant_text(&new_messages);
    assert!(!text.is_empty(), "Expected non-empty response");
    assert!(
        text.contains("Toronto") || text.contains("population") || text.contains("million"),
        "Expected response about Toronto's population, got: {}",
        text
    );

    // No local tool execution (search is server-side)
    let mut got_tool_execution = false;
    while let Ok(event) = rx.try_recv() {
        if matches!(event, AgentEvent::ToolExecutionStart { .. }) {
            got_tool_execution = true;
        }
    }
    assert!(
        !got_tool_execution,
        "Web search should not trigger local tool execution"
    );

    println!("Response: {}", text);
}

/// Web search returns grounding metadata on the assistant message.
#[tokio::test]
#[ignore]
async fn test_gemini_web_search_has_grounding_metadata() {
    let config = make_config("gemini-3-flash-preview");
    let (tx, _rx) = mpsc::unbounded_channel();
    let cancel = CancellationToken::new();

    let mut context = AgentContext {
        system_prompt: "Be concise.".into(),
        messages: Vec::new(),
        tools: vec![Box::new(WebSearchTool)],
    };

    let prompt = AgentMessage::Llm(Message::user("What is the population of Tokyo?"));
    let new_messages = agent_loop(vec![prompt], &mut context, &config, tx, cancel).await;

    // Find the assistant message
    let assistant = new_messages.iter().find_map(|m| match m {
        AgentMessage::Llm(Message::Assistant { metadata, .. }) => Some(metadata),
        _ => None,
    });

    let metadata = assistant
        .expect("Expected an assistant message")
        .as_ref()
        .expect("Expected metadata on assistant message");

    // Should have webSearchQueries
    let queries = metadata["webSearchQueries"].as_array();
    assert!(
        queries.is_some_and(|q| !q.is_empty()),
        "Expected webSearchQueries in metadata, got: {}",
        metadata
    );

    // Should have groundingChunks with web sources
    let chunks = metadata["groundingChunks"].as_array();
    assert!(
        chunks.is_some_and(|c| !c.is_empty()),
        "Expected groundingChunks in metadata, got: {}",
        metadata
    );

    // Text should NOT contain raw grounding JSON
    let text = extract_assistant_text(&new_messages);
    assert!(
        !text.contains("groundingMetadata"),
        "Text should not contain raw grounding JSON"
    );

    println!("Metadata: {}", metadata);
}

/// Web search + function tools together.
#[tokio::test]
#[ignore]
async fn test_gemini_web_search_with_function_tools() {
    let config = make_config("gemini-3-flash-preview");
    let (tx, _rx) = mpsc::unbounded_channel();
    let cancel = CancellationToken::new();

    let mut tools: Vec<Box<dyn AgentTool>> = tools::default_tools();
    tools.push(Box::new(WebSearchTool));

    let mut context = AgentContext {
        system_prompt: "Be concise.".into(),
        messages: Vec::new(),
        tools,
    };

    let prompt = AgentMessage::Llm(Message::user(
        "What is the current population of Toronto in 2026?",
    ));
    let new_messages = agent_loop(vec![prompt], &mut context, &config, tx, cancel).await;

    let text = extract_assistant_text(&new_messages);
    assert!(!text.is_empty(), "Expected non-empty response");
    println!("Response: {}", text);
}

/// Function tool use with Gemini.
#[tokio::test]
#[ignore]
async fn test_gemini_tool_use() {
    let config = make_config("gemini-3-flash-preview");
    let (tx, mut rx) = mpsc::unbounded_channel();
    let cancel = CancellationToken::new();

    let mut context = AgentContext {
        system_prompt: "Use the bash tool to answer. Be concise.".into(),
        messages: Vec::new(),
        tools: tools::default_tools(),
    };

    let prompt = AgentMessage::Llm(Message::user(
        "What is the output of `echo hello_gemini`? Use bash to run it.",
    ));
    let new_messages = agent_loop(vec![prompt], &mut context, &config, tx, cancel).await;

    let text = extract_assistant_text(&new_messages);
    assert!(
        text.contains("hello_gemini"),
        "Expected response with tool output, got: {}",
        text
    );

    let mut got_tool_execution = false;
    while let Ok(event) = rx.try_recv() {
        if matches!(event, AgentEvent::ToolExecutionStart { .. }) {
            got_tool_execution = true;
        }
    }
    assert!(got_tool_execution, "Expected tool execution");
    println!("Response: {}", text);
}
