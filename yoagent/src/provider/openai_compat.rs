//! OpenAI Chat Completions compatible provider.
//!
//! One implementation covers OpenAI, xAI, Groq, Cerebras, OpenRouter,
//! Mistral, DeepSeek, MiniMax, HuggingFace, Kimi, and any other provider
//! that implements the OpenAI Chat Completions API.
//!
//! Behavioral differences are handled via `OpenAiCompat` flags in ModelConfig.

use super::model::{MaxTokensField, ModelConfig, OpenAiCompat, ThinkingFormat};
use super::traits::*;
use crate::types::*;
use async_trait::async_trait;
use futures::StreamExt;
use reqwest_eventsource::EventSource;
use serde::Deserialize;
use tokio::sync::mpsc;
use tracing::{debug, warn};

pub struct OpenAiCompatProvider;

#[async_trait]
impl StreamProvider for OpenAiCompatProvider {
    async fn stream(
        &self,
        config: StreamConfig,
        tx: mpsc::UnboundedSender<StreamEvent>,
        cancel: tokio_util::sync::CancellationToken,
    ) -> Result<Message, ProviderError> {
        let model_config = config.model_config.as_ref().ok_or_else(|| {
            ProviderError::Other("ModelConfig required for OpenAI provider".into())
        })?;
        let compat = model_config.compat.as_ref().cloned().unwrap_or_default();

        let base_url = &model_config.base_url;
        let url = format!("{}/chat/completions", base_url);

        let body = build_request_body(&config, model_config, &compat);
        debug!("OpenAI compat request: model={} url={}", config.model, url);

        let client = reqwest::Client::new();
        let mut request = client
            .post(&url)
            .header("content-type", "application/json")
            .header("authorization", format!("Bearer {}", config.api_key));

        // Add any extra headers from model config
        for (k, v) in &model_config.headers {
            request = request.header(k, v);
        }

        let request = request.json(&body);

        let mut es =
            EventSource::new(request).map_err(|e| ProviderError::Network(e.to_string()))?;

        let mut content: Vec<Content> = Vec::new();
        let mut usage = Usage::default();
        let mut stop_reason = StopReason::Stop;
        let mut tool_call_buffers: Vec<ToolCallBuffer> = Vec::new();

        let _ = tx.send(StreamEvent::Start);

        loop {
            tokio::select! {
                _ = cancel.cancelled() => {
                    es.close();
                    return Err(ProviderError::Cancelled);
                }
                event = es.next() => {
                    match event {
                        None => break,
                        Some(Ok(reqwest_eventsource::Event::Open)) => {}
                        Some(Ok(reqwest_eventsource::Event::Message(msg))) => {
                            if msg.data == "[DONE]" {
                                break;
                            }

                            let chunk: OpenAiChunk = match serde_json::from_str(&msg.data) {
                                Ok(c) => c,
                                Err(e) => {
                                    debug!("Failed to parse OpenAI chunk: {} data={}", e, &msg.data);
                                    continue;
                                }
                            };

                            // Process usage
                            if let Some(u) = &chunk.usage {
                                usage.input = u.prompt_tokens;
                                usage.output = u.completion_tokens;
                                usage.total_tokens = u.total_tokens;
                                if let Some(details) = &u.prompt_tokens_details {
                                    usage.cache_read = details.cached_tokens;
                                }
                            }

                            for choice in &chunk.choices {
                                let delta = &choice.delta;

                                // Handle reasoning/thinking content
                                let reasoning = match compat.thinking_format {
                                    ThinkingFormat::Xai => delta.reasoning.as_deref(),
                                    _ => delta.reasoning_content.as_deref(),
                                };
                                if let Some(reasoning_text) = reasoning {
                                    // Find or create thinking block
                                    let thinking_idx = content.iter().position(|c| matches!(c, Content::Thinking { .. }));
                                    let idx = match thinking_idx {
                                        Some(i) => i,
                                        None => {
                                            content.push(Content::Thinking { thinking: String::new(), signature: None });
                                            content.len() - 1
                                        }
                                    };
                                    if let Some(Content::Thinking { thinking, .. }) = content.get_mut(idx) {
                                        thinking.push_str(reasoning_text);
                                    }
                                    let _ = tx.send(StreamEvent::ThinkingDelta {
                                        content_index: idx,
                                        delta: reasoning_text.to_string(),
                                    });
                                }

                                // Handle text content
                                if let Some(text) = &delta.content {
                                    let text_idx = content.iter().position(|c| matches!(c, Content::Text { .. }));
                                    let idx = match text_idx {
                                        Some(i) => i,
                                        None => {
                                            content.push(Content::Text { text: String::new() });
                                            content.len() - 1
                                        }
                                    };
                                    if let Some(Content::Text { text: t }) = content.get_mut(idx) {
                                        t.push_str(text);
                                    }
                                    let _ = tx.send(StreamEvent::TextDelta {
                                        content_index: idx,
                                        delta: text.clone(),
                                    });
                                }

                                // Handle tool calls
                                if let Some(tool_calls) = &delta.tool_calls {
                                    for tc in tool_calls {
                                        let tc_index = tc.index as usize;
                                        while tool_call_buffers.len() <= tc_index {
                                            tool_call_buffers.push(ToolCallBuffer::default());
                                        }
                                        let buf = &mut tool_call_buffers[tc_index];
                                        if let Some(id) = &tc.id {
                                            buf.id = id.clone();
                                        }
                                        if let Some(f) = &tc.function {
                                            if let Some(name) = &f.name {
                                                buf.name.clone_from(name);
                                                let _ = tx.send(StreamEvent::ToolCallStart {
                                                    content_index: content.len() + tc_index,
                                                    id: buf.id.clone(),
                                                    name: name.clone(),
                                                });
                                            }
                                            if let Some(args) = &f.arguments {
                                                buf.arguments.push_str(args);
                                                let _ = tx.send(StreamEvent::ToolCallDelta {
                                                    content_index: content.len() + tc_index,
                                                    delta: args.clone(),
                                                });
                                            }
                                        }
                                    }
                                }

                                // Handle finish reason
                                if let Some(reason) = &choice.finish_reason {
                                    stop_reason = match reason.as_str() {
                                        "stop" => StopReason::Stop,
                                        "length" => StopReason::Length,
                                        "tool_calls" => StopReason::ToolUse,
                                        _ => StopReason::Stop,
                                    };
                                }
                            }
                        }
                        Some(Err(e)) => {
                            let provider_err = classify_eventsource_error(e).await;
                            warn!("OpenAI SSE error: {}", provider_err);
                            return Err(provider_err);
                        }
                    }
                }
            }
        }

        // Some models (e.g. Moonshot Kimi) stream tool calls as inline
        // special-token text in the content field instead of the structured
        // `tool_calls` field. When the structured path yielded nothing, try to
        // recover them from the accumulated text.
        if tool_call_buffers.is_empty() {
            let mut recovered = false;
            for c in content.iter_mut() {
                if let Content::Text { text } = c {
                    if let Some((cleaned, buffers)) = parse_inline_tool_calls(text) {
                        *text = cleaned;
                        tool_call_buffers = buffers;
                        recovered = true;
                        break;
                    }
                }
            }
            if recovered {
                content.retain(|c| !matches!(c, Content::Text { text } if text.is_empty()));
            }
        }

        // Finalize tool calls
        for buf in &tool_call_buffers {
            let args = serde_json::from_str(&buf.arguments)
                .unwrap_or(serde_json::Value::Object(Default::default()));
            content.push(Content::ToolCall {
                id: buf.id.clone(),
                name: buf.name.clone(),
                arguments: args,
            });
            let _ = tx.send(StreamEvent::ToolCallEnd {
                content_index: content.len() - 1,
            });
        }

        if !tool_call_buffers.is_empty() {
            stop_reason = StopReason::ToolUse;
        }

        let message = Message::Assistant {
            content,
            stop_reason,
            model: config.model.clone(),
            provider: model_config.provider.clone(),
            usage,
            timestamp: now_ms(),
            error_message: None,
            metadata: None,
        };

        let _ = tx.send(StreamEvent::Done {
            message: message.clone(),
        });
        Ok(message)
    }
}

#[derive(Default)]
struct ToolCallBuffer {
    id: String,
    name: String,
    arguments: String,
}

/// Recover tool calls that a model emitted as inline special-token text rather
/// than in the structured `tool_calls` field. Moonshot Kimi models do this over
/// providers (e.g. OpenRouter) that pass the raw token stream through as content.
///
/// Expected shape:
/// ```text
/// <|tool_calls_section_begin|>
///   <|tool_call_begin|>functions.NAME:IDX<|tool_call_argument_begin|>{JSON}<|tool_call_end|>
///   ...
/// <|tool_calls_section_end|>
/// ```
///
/// The id (`functions.NAME:IDX`) is preserved verbatim so tool results correlate;
/// the tool name is the segment between the last `.` and `:`. Returns the text
/// with the token section removed, plus the parsed buffers, or `None` if no
/// section is present.
fn parse_inline_tool_calls(text: &str) -> Option<(String, Vec<ToolCallBuffer>)> {
    const SECTION_BEGIN: &str = "<|tool_calls_section_begin|>";
    const SECTION_END: &str = "<|tool_calls_section_end|>";
    const CALL_BEGIN: &str = "<|tool_call_begin|>";
    const ARG_BEGIN: &str = "<|tool_call_argument_begin|>";
    const CALL_END: &str = "<|tool_call_end|>";

    let sec_start = text.find(SECTION_BEGIN)?;
    // The closing token may be absent if the stream was truncated mid-section;
    // in that case treat everything after the opener as the section body.
    let (section, after) = match text[sec_start..].find(SECTION_END) {
        Some(rel) => {
            let end = sec_start + rel + SECTION_END.len();
            (&text[sec_start..end], &text[end..])
        }
        None => (&text[sec_start..], ""),
    };

    let mut buffers = Vec::new();
    let mut rest = section;
    while let Some(cb) = rest.find(CALL_BEGIN) {
        let seg = &rest[cb + CALL_BEGIN.len()..];
        let Some(ab) = seg.find(ARG_BEGIN) else { break };
        let id_raw = seg[..ab].trim();
        let args_seg = &seg[ab + ARG_BEGIN.len()..];
        let (args, next) = match args_seg.find(CALL_END) {
            Some(ce) => (args_seg[..ce].trim(), &args_seg[ce + CALL_END.len()..]),
            None => (args_seg.trim(), ""),
        };
        let id_head = id_raw.rsplit_once(':').map(|(h, _)| h).unwrap_or(id_raw);
        let name = id_head
            .rsplit_once('.')
            .map(|(_, n)| n)
            .unwrap_or(id_head)
            .to_string();
        buffers.push(ToolCallBuffer {
            id: id_raw.to_string(),
            name,
            arguments: args.to_string(),
        });
        rest = next;
    }

    if buffers.is_empty() {
        return None;
    }

    let cleaned = format!("{}{}", &text[..sec_start], after);
    Some((cleaned.trim().to_string(), buffers))
}

fn build_request_body(
    config: &StreamConfig,
    model_config: &ModelConfig,
    compat: &OpenAiCompat,
) -> serde_json::Value {
    let mut messages: Vec<serde_json::Value> = Vec::new();

    // System prompt
    if !config.system_prompt.is_empty() {
        let role = if compat.supports_developer_role {
            "developer"
        } else {
            "system"
        };
        messages.push(serde_json::json!({
            "role": role,
            "content": config.system_prompt,
        }));
    }

    for msg in &config.messages {
        match msg {
            Message::User { content, .. } => {
                messages.push(serde_json::json!({
                    "role": "user",
                    "content": content_to_openai(content),
                }));
            }
            Message::Assistant { content, .. } => {
                let mut parts: Vec<serde_json::Value> = Vec::new();
                let mut tool_calls: Vec<serde_json::Value> = Vec::new();

                for c in content {
                    match c {
                        Content::Text { text } if text.is_empty() => {}
                        Content::Text { text } => {
                            parts.push(serde_json::json!({"type": "text", "text": text}));
                        }
                        Content::ToolCall {
                            id,
                            name,
                            arguments,
                        } => {
                            tool_calls.push(serde_json::json!({
                                "id": id,
                                "type": "function",
                                "function": {"name": name, "arguments": arguments.to_string()},
                            }));
                        }
                        _ => {}
                    }
                }

                let mut msg_obj = serde_json::json!({"role": "assistant"});
                if !parts.is_empty() {
                    msg_obj["content"] = serde_json::json!(parts);
                }
                if !tool_calls.is_empty() {
                    msg_obj["tool_calls"] = serde_json::json!(tool_calls);
                }
                messages.push(msg_obj);
            }
            Message::ToolResult {
                tool_call_id,
                tool_name,
                content,
                ..
            } => {
                let content_val = if content.iter().any(|c| matches!(c, Content::Image { .. })) {
                    // Images present: use array format for multimodal tool results
                    content_to_openai(content)
                } else {
                    // Text-only: use plain string for maximum compat
                    let text = content
                        .iter()
                        .find_map(|c| match c {
                            Content::Text { text } => Some(text.clone()),
                            _ => None,
                        })
                        .unwrap_or_default();
                    serde_json::json!(text)
                };

                let mut msg_obj = serde_json::json!({
                    "role": "tool",
                    "tool_call_id": tool_call_id,
                    "content": content_val,
                });
                if compat.requires_tool_result_name {
                    msg_obj["name"] = serde_json::json!(tool_name);
                }
                messages.push(msg_obj);
            }
        }
    }

    let max_tokens_val = config.max_tokens.unwrap_or(model_config.max_tokens);
    let mut body = serde_json::json!({
        "model": config.model,
        "stream": true,
        "stream_options": {"include_usage": true},
        "messages": messages,
    });

    match compat.max_tokens_field {
        MaxTokensField::MaxCompletionTokens => {
            body["max_completion_tokens"] = serde_json::json!(max_tokens_val);
        }
        MaxTokensField::MaxTokens => {
            body["max_tokens"] = serde_json::json!(max_tokens_val);
        }
    }

    if !config.tools.is_empty() {
        // Filter out server-side tools (e.g. web_search) -- OpenAI handles
        // search via dedicated models, not tool definitions.
        let tools: Vec<serde_json::Value> = config
            .tools
            .iter()
            .filter(|t| !(t.name == "web_search" && t.description == "server_tool"))
            .map(|t| {
                serde_json::json!({
                    "type": "function",
                    "function": {
                        "name": t.name,
                        "description": t.description,
                        "parameters": t.parameters,
                    }
                })
            })
            .collect();
        if !tools.is_empty() {
            body["tools"] = serde_json::json!(tools);
        }
    }

    if config.thinking_level != ThinkingLevel::Off && compat.supports_reasoning_effort {
        let effort = match config.thinking_level {
            ThinkingLevel::Minimal | ThinkingLevel::Low => "low",
            ThinkingLevel::Medium => "medium",
            ThinkingLevel::High => "high",
            ThinkingLevel::Off => unreachable!(),
        };
        body["reasoning_effort"] = serde_json::json!(effort);
    }

    if let Some(temp) = config.temperature {
        body["temperature"] = serde_json::json!(temp);
    }

    body
}

fn content_to_openai(content: &[Content]) -> serde_json::Value {
    if content.len() == 1 {
        if let Content::Text { text } = &content[0] {
            if !text.is_empty() {
                return serde_json::json!(text);
            }
        }
    }
    let parts: Vec<serde_json::Value> = content
        .iter()
        .filter(|c| !matches!(c, Content::Text { text } if text.is_empty()))
        .filter_map(|c| match c {
            Content::Text { text } => Some(serde_json::json!({"type": "text", "text": text})),
            Content::Image { data, mime_type } => Some(serde_json::json!({
                "type": "image_url",
                "image_url": {"url": format!("data:{};base64,{}", mime_type, data)},
            })),
            _ => None,
        })
        .collect();
    serde_json::json!(parts)
}

// OpenAI streaming response types
#[derive(Deserialize)]
struct OpenAiChunk {
    #[serde(default)]
    choices: Vec<OpenAiChoice>,
    #[serde(default)]
    usage: Option<OpenAiUsage>,
}

#[derive(Deserialize)]
struct OpenAiChoice {
    delta: OpenAiDelta,
    #[serde(default)]
    finish_reason: Option<String>,
}

#[derive(Deserialize, Default)]
struct OpenAiDelta {
    #[serde(default)]
    content: Option<String>,
    #[serde(default)]
    reasoning_content: Option<String>,
    #[serde(default)]
    reasoning: Option<String>,
    #[serde(default)]
    tool_calls: Option<Vec<OpenAiToolCallDelta>>,
}

#[derive(Deserialize)]
struct OpenAiToolCallDelta {
    #[serde(default)]
    index: u32,
    #[serde(default)]
    id: Option<String>,
    #[serde(default)]
    function: Option<OpenAiFunctionDelta>,
}

#[derive(Deserialize)]
struct OpenAiFunctionDelta {
    #[serde(default)]
    name: Option<String>,
    #[serde(default)]
    arguments: Option<String>,
}

#[derive(Deserialize)]
struct OpenAiUsage {
    #[serde(default)]
    prompt_tokens: u64,
    #[serde(default)]
    completion_tokens: u64,
    #[serde(default)]
    total_tokens: u64,
    #[serde(default)]
    prompt_tokens_details: Option<OpenAiPromptTokensDetails>,
}

#[derive(Deserialize)]
struct OpenAiPromptTokensDetails {
    #[serde(default)]
    cached_tokens: u64,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::provider::model::ModelConfig;

    #[test]
    fn test_build_request_body_basic() {
        let model_config = ModelConfig::openai("gpt-4o", "GPT-4o");
        let config = StreamConfig {
            model: "gpt-4o".into(),
            system_prompt: "You are helpful.".into(),
            messages: vec![Message::user("Hello")],
            tools: vec![],
            thinking_level: ThinkingLevel::Off,
            api_key: "test".into(),
            max_tokens: None,
            temperature: None,
            model_config: Some(model_config.clone()),
            cache_config: CacheConfig::default(),
        };

        let body = build_request_body(&config, &model_config, &OpenAiCompat::openai());
        assert_eq!(body["model"], "gpt-4o");
        assert!(body["stream"].as_bool().unwrap());
        // Developer role for OpenAI
        assert_eq!(body["messages"][0]["role"], "developer");
        assert_eq!(body["messages"][1]["role"], "user");
        // max_completion_tokens for OpenAI
        assert!(body["max_completion_tokens"].is_number());
    }

    #[test]
    fn test_build_request_body_with_tools() {
        let model_config = ModelConfig::openai("gpt-4o", "GPT-4o");
        let compat = OpenAiCompat::openai();
        let config = StreamConfig {
            model: "gpt-4o".into(),
            system_prompt: String::new(),
            messages: vec![Message::user("List files")],
            tools: vec![ToolDefinition {
                name: "bash".into(),
                description: "Run a command".into(),
                parameters: serde_json::json!({"type": "object"}),
            }],
            thinking_level: ThinkingLevel::Off,
            api_key: "test".into(),
            max_tokens: Some(1024),
            temperature: Some(0.5),
            model_config: Some(model_config.clone()),
            cache_config: CacheConfig::default(),
        };

        let body = build_request_body(&config, &model_config, &compat);
        assert!(body["tools"].is_array());
        assert_eq!(body["tools"][0]["function"]["name"], "bash");
        assert_eq!(body["temperature"], 0.5);
    }

    #[test]
    fn test_content_to_openai_simple_text() {
        let content = vec![Content::Text {
            text: "hello".into(),
        }];
        let result = content_to_openai(&content);
        assert_eq!(result, "hello");
    }

    #[test]
    fn test_content_to_openai_filters_empty_text() {
        let content = vec![
            Content::Text { text: "".into() },
            Content::Text {
                text: "hello".into(),
            },
            Content::Text { text: "".into() },
        ];
        let result = content_to_openai(&content);
        let parts = result.as_array().unwrap();
        assert_eq!(parts.len(), 1);
        assert_eq!(parts[0]["text"], "hello");
    }

    #[test]
    fn test_content_to_openai_single_empty_text_filtered() {
        let content = vec![Content::Text { text: "".into() }];
        let result = content_to_openai(&content);
        let parts = result.as_array().unwrap();
        assert!(parts.is_empty());
    }

    #[test]
    fn test_content_to_openai_multipart() {
        let content = vec![
            Content::Text {
                text: "look at this".into(),
            },
            Content::Image {
                data: "abc".into(),
                mime_type: "image/png".into(),
            },
        ];
        let result = content_to_openai(&content);
        assert!(result.is_array());
        assert_eq!(result[0]["type"], "text");
        assert_eq!(result[1]["type"], "image_url");
    }

    #[test]
    fn test_tool_result_with_image() {
        let model_config = ModelConfig::openai("gpt-4o", "GPT-4o");
        let compat = OpenAiCompat::openai();
        let config = StreamConfig {
            model: "gpt-4o".into(),
            system_prompt: String::new(),
            messages: vec![
                Message::Assistant {
                    content: vec![Content::ToolCall {
                        id: "call-1".into(),
                        name: "read_file".into(),
                        arguments: serde_json::json!({"path": "img.png"}),
                    }],
                    stop_reason: StopReason::ToolUse,
                    model: "test".into(),
                    provider: "test".into(),
                    usage: Usage::default(),
                    timestamp: 0,
                    error_message: None,
                    metadata: None,
                },
                Message::ToolResult {
                    tool_call_id: "call-1".into(),
                    tool_name: "read_file".into(),
                    content: vec![Content::Image {
                        data: "aW1hZ2VkYXRh".into(),
                        mime_type: "image/png".into(),
                    }],
                    is_error: false,
                    timestamp: 0,
                },
            ],
            tools: vec![],
            thinking_level: ThinkingLevel::Off,
            api_key: "test".into(),
            max_tokens: None,
            temperature: None,
            model_config: Some(model_config.clone()),
            cache_config: CacheConfig::default(),
        };

        let body = build_request_body(&config, &model_config, &compat);
        let msgs = body["messages"].as_array().unwrap();
        // tool result is the last message (after system + assistant)
        let tool_msg = msgs.last().unwrap();
        assert_eq!(tool_msg["role"], "tool");
        // content should be an array with image_url
        let content = tool_msg["content"].as_array().unwrap();
        assert_eq!(content[0]["type"], "image_url");
        assert!(content[0]["image_url"]["url"]
            .as_str()
            .unwrap()
            .starts_with("data:image/png;base64,"));
    }

    #[test]
    fn test_tool_result_text_only_uses_string() {
        let model_config = ModelConfig::openai("gpt-4o", "GPT-4o");
        let compat = OpenAiCompat::openai();
        let config = StreamConfig {
            model: "gpt-4o".into(),
            system_prompt: String::new(),
            messages: vec![Message::ToolResult {
                tool_call_id: "call-1".into(),
                tool_name: "bash".into(),
                content: vec![Content::Text {
                    text: "hello".into(),
                }],
                is_error: false,
                timestamp: 0,
            }],
            tools: vec![],
            thinking_level: ThinkingLevel::Off,
            api_key: "test".into(),
            max_tokens: None,
            temperature: None,
            model_config: Some(model_config.clone()),
            cache_config: CacheConfig::default(),
        };

        let body = build_request_body(&config, &model_config, &compat);
        let msgs = body["messages"].as_array().unwrap();
        let tool_msg = msgs.last().unwrap();
        // Text-only: content should be a plain string
        assert_eq!(tool_msg["content"], "hello");
    }

    #[test]
    fn test_parse_inline_tool_calls_kimi() {
        let text = "Summary of progress.\n\n\
            <|tool_calls_section_begin|>\
            <|tool_call_begin|>functions.bash:16<|tool_call_argument_begin|>{\"command\": \"ls -la\"}<|tool_call_end|>\
            <|tool_call_begin|>functions.read_file:17<|tool_call_argument_begin|>{\"path\": \"a.txt\"}<|tool_call_end|>\
            <|tool_calls_section_end|>";
        let (cleaned, buffers) = parse_inline_tool_calls(text).expect("should parse");
        assert_eq!(cleaned, "Summary of progress.");
        assert_eq!(buffers.len(), 2);
        assert_eq!(buffers[0].id, "functions.bash:16");
        assert_eq!(buffers[0].name, "bash");
        assert_eq!(buffers[0].arguments, "{\"command\": \"ls -la\"}");
        assert_eq!(buffers[1].id, "functions.read_file:17");
        assert_eq!(buffers[1].name, "read_file");
        assert_eq!(buffers[1].arguments, "{\"path\": \"a.txt\"}");
    }

    #[test]
    fn test_parse_inline_tool_calls_truncated_section() {
        // Stream cut off before the closing section token.
        let text = "doing work\
            <|tool_calls_section_begin|>\
            <|tool_call_begin|>functions.bash:1<|tool_call_argument_begin|>{\"command\": \"pwd\"}<|tool_call_end|>";
        let (cleaned, buffers) = parse_inline_tool_calls(text).expect("should parse");
        assert_eq!(cleaned, "doing work");
        assert_eq!(buffers.len(), 1);
        assert_eq!(buffers[0].name, "bash");
    }

    #[test]
    fn test_parse_inline_tool_calls_none_for_plain_text() {
        assert!(parse_inline_tool_calls("just a normal answer, no tools").is_none());
    }

    #[test]
    fn test_parse_inline_tool_calls_real_kimi_capture() {
        // Verbatim assistant text captured from a live moonshotai/kimi-k2.7-code
        // turn over OpenRouter, where the tool calls leaked as inline tokens.
        let text = include_str!("testdata/kimi_inline_tool_calls.txt");
        let (cleaned, buffers) = parse_inline_tool_calls(text).expect("should parse");
        // Prose preamble survives, token section is stripped.
        assert!(cleaned.starts_with("Summary so far:"));
        assert!(!cleaned.contains("<|tool_call"));
        assert_eq!(buffers.len(), 2);
        assert_eq!(buffers[0].id, "functions.bash:16");
        assert_eq!(buffers[0].name, "bash");
        assert_eq!(buffers[1].id, "functions.bash:17");
        assert_eq!(buffers[1].name, "bash");
        // Arguments round-trip as valid JSON with the expected command key.
        for buf in &buffers {
            let v: serde_json::Value = serde_json::from_str(&buf.arguments).unwrap();
            assert!(v.get("command").and_then(|c| c.as_str()).is_some());
        }
    }
}
