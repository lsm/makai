//! Rust SDK for [Makai](https://github.com/lsm/makai), a Zig-first streaming AI
//! runtime.
//!
//! The SDK starts a `makai --stdio` process and speaks its newline-delimited
//! JSON protocol, exposing four namespaces that mirror the TypeScript SDK:
//!
//! * [`Client::auth`] — list provider auth state, run interactive logins;
//! * [`Client::models`] — discover models and resolve one by id;
//! * [`Client::provider`] — one provider turn, complete or streamed;
//! * [`Client::agent`] — the agent loop, with tools executing in your process.
//!
//! # Quick start
//!
//! ```no_run
//! use makai::{Client, ExecutionRequest};
//!
//! # async fn run() -> makai::Result<()> {
//! let client = Client::connect().await?;
//!
//! let model = client
//!     .models()
//!     .resolve("anthropic", Some("anthropic-messages"), "claude-sonnet-4-5")
//!     .await?;
//!
//! let response = client
//!     .provider()
//!     .complete(
//!         ExecutionRequest::prompt(&model.model_ref, "Write a haiku about streams.")
//!             .with_max_tokens(128),
//!     )
//!     .await?;
//!
//! println!("{}", response.text());
//! client.close().await;
//! # Ok(())
//! # }
//! ```
//!
//! # Streaming
//!
//! Streams are [`futures_core::Stream`]s of `Result` items. Dropping one cancels
//! the underlying work: the SDK sends `abort_request` for a provider stream and
//! `agent_stop` for an agent run, so the runtime stops rather than finishing
//! into a queue nobody is reading.
//!
//! ```no_run
//! use futures::StreamExt;
//! use makai::{Client, ExecutionRequest, ProviderEvent};
//!
//! # async fn run() -> makai::Result<()> {
//! # let client = Client::connect().await?;
//! # let model_ref = String::new();
//! let mut events = Box::pin(
//!     client
//!         .provider()
//!         .stream(ExecutionRequest::prompt(model_ref, "Explain lock-free queues.")),
//! );
//!
//! while let Some(event) = events.next().await {
//!     if let ProviderEvent::TextDelta { delta } = event? {
//!         print!("{delta}");
//!     }
//! }
//! # Ok(())
//! # }
//! ```
//!
//! # Identifiers
//!
//! `model_ref` is an opaque, server-issued handle: read it off a
//! [`ModelDescriptor`] and pass it back unchanged. `session_id` is a correlation
//! key, not a resume handle — sessions are not resumable, and on interruption
//! the full context is resent under a fresh id.

#![cfg_attr(
    not(test),
    deny(
        clippy::unwrap_used,
        clippy::expect_used,
        clippy::panic,
        clippy::indexing_slicing
    )
)]
#![warn(missing_docs, missing_debug_implementations)]

mod agent;
mod auth;
mod binary;
mod client;
mod error;
mod events;
mod execution;
mod ids;
mod models;
mod provider;
mod transport;
mod types;
mod wire;

pub use agent::AgentApi;
pub use auth::{AuthApi, AuthEvent, AuthHandlers, AuthPrompt, ProviderAuthInfo};
pub use binary::BinaryResolver;
pub use client::{Client, ClientBuilder};
pub use error::{AuthErrorKind, Error, Result, StreamErrorKind};
pub use events::{AgentEvent, ProviderEvent};
pub use execution::ExecutionRequest;
pub use models::{
    AuthStatus, ListModelsRequest, ListModelsResponse, ModelCapability, ModelDescriptor,
    ModelLifecycle, ModelSource, ModelsApi, ReasoningLevel,
};
pub use provider::ProviderApi;
pub use types::{
    AuthRetryPolicy, ChatMessage, CompletionResponse, Content, ContentPart, ReasoningEffort, Role,
    RunOptions, Tool, ToolInvocation, ToolResult, Usage,
};
pub use wire::Frame;
