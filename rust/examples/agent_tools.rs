//! Run the agent loop with a tool that executes in this process.
//!
//! ```text
//! cargo run --example agent_tools
//! ```

use futures::StreamExt;
use makai::{AgentEvent, Client, ExecutionRequest, Tool};
use serde::Deserialize;

#[derive(Deserialize)]
struct WeatherArgs {
    city: String,
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let client = Client::connect().await?;

    let model = client
        .models()
        .resolve("anthropic", Some("anthropic-messages"), "claude-sonnet-4-5")
        .await?;

    let weather = Tool::new(
        "get_weather",
        "Get the current weather for a city.",
        serde_json::json!({
            "type": "object",
            "properties": { "city": { "type": "string" } },
            "required": ["city"],
            "additionalProperties": false,
        })
        .to_string(),
    )
    .on_call(|invocation| async move {
        let args: WeatherArgs = invocation.args().map_err(|err| err.to_string())?;
        Ok(format!("It is 18°C and raining in {}.", args.city))
    });

    let request = ExecutionRequest::prompt(
        &model.model_ref,
        "Should I bring an umbrella in San Francisco today?",
    )
    .with_tool(weather)
    .with_max_tokens(512);

    let mut events = Box::pin(client.agent().stream(request));
    while let Some(event) = events.next().await {
        match event? {
            AgentEvent::TurnStart => eprintln!("-- turn start"),
            AgentEvent::ToolExecutionStart { tool_name, .. } => eprintln!("-- calling {tool_name}"),
            AgentEvent::ToolExecutionEnd { is_error, .. } => {
                eprintln!("-- tool done (error: {})", is_error.unwrap_or(false));
            }
            AgentEvent::AgentEnd { usage, .. } => {
                if let Some(usage) = usage {
                    eprintln!("-- {} in, {} out", usage.input, usage.output);
                }
            }
            other => {
                if let Some(text) = other.text() {
                    print!("{text}");
                }
            }
        }
    }
    println!();

    drop(events);
    client.close().await;
    Ok(())
}
