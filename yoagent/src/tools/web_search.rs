//! Web search server tool marker.
//!
//! This is not a locally executed tool. It signals to providers that support
//! server-side web search (Anthropic, OpenAI, Gemini) to include their native
//! search capability. The provider handles execution; `execute()` should never
//! be called.

use crate::types::*;
use async_trait::async_trait;

pub struct WebSearchTool;

#[async_trait]
impl AgentTool for WebSearchTool {
    fn name(&self) -> &str {
        "web_search"
    }

    fn label(&self) -> &str {
        "Web Search"
    }

    fn description(&self) -> &str {
        "server_tool"
    }

    fn parameters_schema(&self) -> serde_json::Value {
        serde_json::json!({})
    }

    async fn execute(
        &self,
        _params: serde_json::Value,
        _ctx: ToolContext,
    ) -> Result<ToolResult, ToolError> {
        // Server-side tool: execution is handled by the provider
        Err(ToolError::Failed(
            "web_search is a server-side tool and should not be executed locally".into(),
        ))
    }
}
