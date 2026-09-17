//! Resolve a model, send one message, print the reply.
//!
//! ```text
//! cargo run --example complete
//! ```

use makai::{Client, ExecutionRequest};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let client = Client::connect().await?;

    let model = client
        .models()
        .resolve("anthropic", Some("anthropic-messages"), "claude-sonnet-4-5")
        .await?;

    let response = client
        .provider()
        .complete(
            ExecutionRequest::prompt(&model.model_ref, "Write a haiku about streams.")
                .with_max_tokens(128),
        )
        .await?;

    println!("{}", response.text());
    if let Some(usage) = response.usage {
        eprintln!("tokens: {} in, {} out", usage.input, usage.output);
    }

    client.close().await;
    Ok(())
}
