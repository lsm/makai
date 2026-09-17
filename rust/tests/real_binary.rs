//! End-to-end coverage against a real `makai --stdio` build.
//!
//! These need a runtime binary and skip when `MAKAI_BINARY_PATH` is unset, which
//! mirrors `typescript/test/makai_binary_smoke.test.ts`. Build one with:
//!
//! ```text
//! zig build install --prefix /tmp/makai-rs
//! MAKAI_BINARY_PATH=/tmp/makai-rs/bin/makai cargo test --test real_binary
//! ```
//!
//! Nothing here needs provider credentials. The paths that would are exercised
//! through their unauthenticated failure, which is itself the behaviour worth
//! pinning: an `auth_required` rejection must reach the typed auth error. The
//! runtime's built-in `test-fixture` auth provider gives a real, deterministic
//! interactive login with no network.

#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]

mod common;

use std::time::Duration;

use futures::StreamExt;
use makai::{AuthEvent, AuthHandlers, Error, ExecutionRequest, ListModelsRequest};

#[tokio::test]
async fn connects_to_the_real_runtime() {
    let binary = require_real_binary!();
    let client = common::real_builder(&binary)
        .connect()
        .await
        .expect("the runtime connects");
    assert!(!client.is_closed());
    client.close().await;
    assert!(client.is_closed());
}

#[tokio::test]
async fn a_version_mismatch_against_the_real_runtime_fails_fast() {
    let binary = require_real_binary!();
    let error = common::real_builder(&binary)
        .expected_protocol_version("2")
        .connect()
        .await
        .unwrap_err();
    assert_eq!(error.code(), Some("version_mismatch"));
}

#[tokio::test]
async fn the_real_runtime_serves_the_model_catalog() {
    let binary = require_real_binary!();
    let client = common::real_builder(&binary)
        .connect()
        .await
        .expect("connects");

    let response = client
        .models()
        .list(ListModelsRequest {
            include_login_required: Some(true),
            ..Default::default()
        })
        .await
        .expect("lists models");
    assert!(
        !response.models.is_empty(),
        "the static catalog is non-empty"
    );
    assert!(response.fetched_at_ms > 0);

    for model in &response.models {
        assert!(!model.model_ref.is_empty());
        assert!(!model.model_id.is_empty());
        assert!(!model.provider_id.is_empty());
    }
    client.close().await;
}

#[tokio::test]
async fn the_real_runtime_resolves_one_model() {
    let binary = require_real_binary!();
    let client = common::real_builder(&binary)
        .connect()
        .await
        .expect("connects");

    let listed = client
        .models()
        .list(ListModelsRequest {
            include_login_required: Some(true),
            ..Default::default()
        })
        .await
        .expect("lists models");
    let first = listed.models.first().expect("at least one model").clone();

    let resolved = client
        .models()
        .resolve(&first.provider_id, Some(&first.api), &first.model_id)
        .await
        .expect("resolves");
    assert_eq!(resolved.model_ref, first.model_ref);
    client.close().await;
}

#[tokio::test]
async fn resolving_a_model_that_does_not_exist_is_an_invalid_request() {
    let binary = require_real_binary!();
    let client = common::real_builder(&binary)
        .connect()
        .await
        .expect("connects");
    let error = client
        .models()
        .resolve("anthropic", Some("anthropic-messages"), "no-such-model")
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Protocol { .. }), "{error:?}");
    assert_eq!(error.code(), Some("invalid_request"));
    client.close().await;
}

#[tokio::test]
async fn the_real_runtime_lists_auth_providers() {
    let binary = require_real_binary!();
    let client = common::real_builder(&binary)
        .connect()
        .await
        .expect("connects");

    let providers = client
        .auth()
        .list_providers()
        .await
        .expect("lists providers");
    assert!(!providers.is_empty());
    assert!(
        providers.iter().any(|provider| provider.id == "anthropic"),
        "{providers:?}"
    );
    assert!(
        providers
            .iter()
            .any(|provider| provider.id == "test-fixture"),
        "the CI fixture provider should be present: {providers:?}"
    );
    client.close().await;
}

#[tokio::test]
async fn an_interactive_login_runs_end_to_end_against_the_real_runtime() {
    let binary = require_real_binary!();
    require_unattended_credential_store!();
    // The fixture provider's credentials are written under HOME, so give it one
    // that the test owns.
    let home = tempfile::tempdir().expect("tempdir");
    let client = common::real_builder(&binary)
        .env("HOME", home.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    let saw_url = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let flag = std::sync::Arc::clone(&saw_url);
    let handlers = AuthHandlers::new()
        .on_event(move |event| {
            if matches!(event, AuthEvent::AuthUrl { .. }) {
                flag.store(true, std::sync::atomic::Ordering::SeqCst);
            }
        })
        .on_prompt(|prompt| async move {
            assert!(!prompt.prompt_id.is_empty());
            Ok("ok".to_owned())
        });

    client
        .auth()
        .login("test-fixture", Some(&handlers))
        .await
        .expect("the fixture login succeeds");
    assert!(saw_url.load(std::sync::atomic::Ordering::SeqCst));

    let auth_file = home.path().join(".makai").join("auth.json");
    assert!(
        auth_file.exists(),
        "credentials were persisted by the runtime"
    );

    let providers = client
        .auth()
        .list_providers()
        .await
        .expect("lists providers");
    let fixture = providers
        .iter()
        .find(|provider| provider.id == "test-fixture")
        .expect("fixture provider");
    assert_eq!(fixture.auth_status, makai::AuthStatus::Authenticated);

    client.close().await;
}

#[tokio::test]
async fn a_wrong_code_re_prompts_against_the_real_runtime() {
    // The fixture provider re-prompts until the answer is right, which exercises
    // the multi-round prompt loop: several `auth_prompt_response` envelopes on
    // one flow, each carrying the next outbound sequence.
    let binary = require_real_binary!();
    require_unattended_credential_store!();
    let home = tempfile::tempdir().expect("tempdir");
    let client = common::real_builder(&binary)
        .env("HOME", home.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    let prompts = std::sync::Arc::new(std::sync::atomic::AtomicUsize::new(0));
    let retried = std::sync::Arc::new(std::sync::atomic::AtomicBool::new(false));
    let counter = std::sync::Arc::clone(&prompts);
    let saw_retry = std::sync::Arc::clone(&retried);

    let handlers = AuthHandlers::new()
        .on_event(move |event| {
            if let AuthEvent::Progress { message, .. } = event {
                if message.contains("Invalid fixture code") {
                    saw_retry.store(true, std::sync::atomic::Ordering::SeqCst);
                }
            }
        })
        .on_prompt(move |_| {
            let counter = std::sync::Arc::clone(&counter);
            async move {
                let attempt = counter.fetch_add(1, std::sync::atomic::Ordering::SeqCst);
                Ok(if attempt == 0 { "wrong" } else { "ok" }.to_owned())
            }
        });

    client
        .auth()
        .login("test-fixture", Some(&handlers))
        .await
        .expect("the second answer succeeds");
    assert_eq!(prompts.load(std::sync::atomic::Ordering::SeqCst), 2);
    assert!(retried.load(std::sync::atomic::Ordering::SeqCst));
    client.close().await;
}

#[tokio::test]
async fn a_prompt_handler_that_gives_up_cancels_the_real_flow() {
    let binary = require_real_binary!();
    let home = tempfile::tempdir().expect("tempdir");
    let client = common::real_builder(&binary)
        .env("HOME", home.path().display().to_string())
        .frame_timeout(Duration::from_millis(3_000))
        .connect()
        .await
        .expect("connects");

    let handlers =
        AuthHandlers::new().on_prompt(|_| async move { Err("user walked away".to_owned()) });
    let started = tokio::time::Instant::now();
    let error = client
        .auth()
        .login("test-fixture", Some(&handlers))
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Auth { .. }), "{error:?}");
    assert!(
        started.elapsed() < Duration::from_secs(10),
        "abandoning a flow must not wait out a long timeout"
    );

    let auth_file = home.path().join(".makai").join("auth.json");
    assert!(
        !auth_file.exists(),
        "an abandoned flow must not persist credentials"
    );
    client.close().await;
}

#[tokio::test]
async fn a_login_with_no_prompt_handler_cancels_the_real_flow() {
    let binary = require_real_binary!();
    let home = tempfile::tempdir().expect("tempdir");
    let client = common::real_builder(&binary)
        .env("HOME", home.path().display().to_string())
        .frame_timeout(Duration::from_millis(3_000))
        .connect()
        .await
        .expect("connects");

    let error = client.auth().login("test-fixture", None).await.unwrap_err();
    assert!(error.is_cancelled(), "{error:?}");
    client.close().await;
}

#[tokio::test]
async fn an_unauthenticated_provider_call_reaches_the_typed_auth_error() {
    let binary = require_real_binary!();
    let home = tempfile::tempdir().expect("tempdir");
    let client = common::real_builder(&binary)
        .env("HOME", home.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    let error = client
        .provider()
        .complete(ExecutionRequest::prompt(
            "anthropic/anthropic-messages@claude-sonnet-4-5",
            "hi",
        ))
        .await
        .unwrap_err();
    assert!(matches!(error, Error::AuthRequired { .. }), "{error:?}");
    assert_eq!(error.provider_id(), Some("anthropic"));
    client.close().await;
}

#[tokio::test]
async fn an_unauthenticated_provider_stream_reaches_the_typed_auth_error() {
    let binary = require_real_binary!();
    let home = tempfile::tempdir().expect("tempdir");
    let client = common::real_builder(&binary)
        .env("HOME", home.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    let mut events = Box::pin(client.provider().stream(ExecutionRequest::prompt(
        "anthropic/anthropic-messages@claude-sonnet-4-5",
        "hi",
    )));
    let error = events
        .next()
        .await
        .expect("one item")
        .expect_err("auth is required");
    assert!(matches!(error, Error::AuthRequired { .. }), "{error:?}");
    drop(events);
    client.close().await;
}

#[tokio::test]
async fn an_unauthenticated_agent_run_walks_the_whole_session_lifecycle() {
    // The run reaches the provider, fails there for lack of credentials, and
    // settles through `agent_result` — which exercises agent_start, the
    // correlated agent_started, agent_message, the event stream, and teardown.
    let binary = require_real_binary!();
    let home = tempfile::tempdir().expect("tempdir");
    let client = common::real_builder(&binary)
        .env("HOME", home.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    let error = client
        .agent()
        .run(ExecutionRequest::prompt(
            "anthropic/anthropic-messages@claude-sonnet-4-5",
            "hi",
        ))
        .await
        .unwrap_err();
    assert!(matches!(error, Error::AuthRequired { .. }), "{error:?}");
    assert_eq!(error.provider_id(), Some("anthropic"));
    client.close().await;
}

#[tokio::test]
async fn an_unauthenticated_agent_stream_emits_lifecycle_before_failing() {
    let binary = require_real_binary!();
    let home = tempfile::tempdir().expect("tempdir");
    let client = common::real_builder(&binary)
        .env("HOME", home.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    let mut events = Box::pin(client.agent().stream(ExecutionRequest::prompt(
        "anthropic/anthropic-messages@claude-sonnet-4-5",
        "hi",
    )));

    let mut seen = Vec::new();
    let mut failure = None;
    while let Some(event) = events.next().await {
        match event {
            Ok(event) => seen.push(event),
            Err(error) => {
                failure = Some(error);
                break;
            }
        }
    }

    assert!(
        seen.iter()
            .any(|event| matches!(event, makai::AgentEvent::TurnStart)),
        "the loop started a turn before failing: {seen:?}"
    );
    let failure = failure.expect("the run fails for lack of credentials");
    assert!(matches!(failure, Error::AuthRequired { .. }), "{failure:?}");
    drop(events);
    client.close().await;
}

#[tokio::test]
async fn several_calls_multiplex_over_one_real_runtime() {
    let binary = require_real_binary!();
    let client = common::real_builder(&binary)
        .connect()
        .await
        .expect("connects");

    let models = client.models();
    let auth = client.auth();
    let (listed, providers) = tokio::join!(
        models.list(ListModelsRequest::default()),
        auth.list_providers()
    );
    assert!(!listed.expect("lists").models.is_empty());
    assert!(!providers.expect("lists").is_empty());
    client.close().await;
}

#[tokio::test]
async fn closing_the_client_reaps_the_real_runtime() {
    let binary = require_real_binary!();
    let client = common::real_builder(&binary)
        .connect()
        .await
        .expect("connects");
    client
        .models()
        .list(ListModelsRequest::default())
        .await
        .expect("lists");

    let started = tokio::time::Instant::now();
    client.close().await;
    assert!(
        started.elapsed() < Duration::from_secs(3),
        "close should not wait out a timeout"
    );
    assert!(client.is_closed());
}
