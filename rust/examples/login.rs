//! Inspect provider auth state and run an interactive login.
//!
//! ```text
//! cargo run --example login -- anthropic
//! ```

use makai::{AuthEvent, AuthHandlers, AuthStatus, Client};

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let provider_id = std::env::args()
        .nth(1)
        .unwrap_or_else(|| "anthropic".into());
    let client = Client::connect().await?;

    let providers = client.auth().list_providers().await?;
    for provider in &providers {
        println!("{:<16} {:?}", provider.id, provider.auth_status);
    }

    let needs_login = providers
        .iter()
        .find(|provider| provider.id == provider_id)
        .is_none_or(|provider| provider.auth_status != AuthStatus::Authenticated);

    if needs_login {
        let handlers = AuthHandlers::new()
            .on_event(|event| match event {
                AuthEvent::AuthUrl {
                    url, instructions, ..
                } => {
                    println!("Open {url}");
                    if let Some(instructions) = instructions {
                        println!("{instructions}");
                    }
                }
                AuthEvent::Progress { message, .. } => println!("{message}"),
                _ => {}
            })
            .on_prompt(|prompt| async move {
                println!("{}", prompt.message);
                let mut answer = String::new();
                std::io::stdin()
                    .read_line(&mut answer)
                    .map_err(|err| err.to_string())?;
                Ok(answer.trim().to_owned())
            });

        client.auth().login(&provider_id, Some(&handlers)).await?;
        println!("{provider_id} is authenticated");
    }

    client.close().await;
    Ok(())
}
