//! Stream a provider turn, printing text as it arrives.
//!
//! ```text
//! cargo run --example stream
//! ```

use std::io::Write;

use futures::StreamExt;
use makai::{Client, ExecutionRequest, ProviderEvent};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let client = Client::connect().await?;

    let model = client
        .models()
        .resolve("anthropic", Some("anthropic-messages"), "claude-sonnet-4-5")
        .await?;

    let mut events = Box::pin(
        client.provider().stream(
            ExecutionRequest::prompt(
                &model.model_ref,
                "Explain lock-free queues in one paragraph.",
            )
            .with_max_tokens(256),
        ),
    );

    while let Some(event) = events.next().await {
        match event? {
            ProviderEvent::MessageStart { model_id, .. } => {
                eprintln!("streaming {}", model_id.unwrap_or_default());
            }
            ProviderEvent::TextDelta { delta } => {
                print!("{delta}");
                std::io::stdout().flush()?;
            }
            ProviderEvent::ToolCall { name, .. } => eprintln!("\ntool call: {name}"),
            ProviderEvent::MessageEnd { stop_reason, .. } => {
                println!();
                eprintln!("stop reason: {}", stop_reason.unwrap_or_default());
            }
            ProviderEvent::Error { message, .. } => eprintln!("\nstream error: {message}"),
            ProviderEvent::ThinkingDelta { .. } => {}
            _ => {}
        }
    }

    drop(events);
    client.close().await;
    Ok(())
}
