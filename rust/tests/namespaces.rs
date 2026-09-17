//! `models`, `auth`, and `provider` behaviour against the protocol fake.

#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use futures::StreamExt;
use makai::{
    AuthEvent, AuthHandlers, AuthRetryPolicy, AuthStatus, Error, ExecutionRequest,
    ListModelsRequest, ModelCapability, ModelSource, ProviderEvent, RunOptions,
};

#[tokio::test]
async fn models_list_parses_the_typed_descriptor() {
    let client = common::fake_client("ok").await;
    let response = client
        .models()
        .list(ListModelsRequest::default())
        .await
        .expect("lists");

    assert_eq!(response.models.len(), 1);
    let model = &response.models[0];
    assert_eq!(
        model.model_ref,
        "anthropic/anthropic-messages@claude-sonnet-4-5"
    );
    assert_eq!(model.auth_status, AuthStatus::Authenticated);
    assert_eq!(model.source, ModelSource::StaticFallback);
    assert!(model.capabilities.contains(&ModelCapability::Tools));
    assert_eq!(response.fetched_at_ms, 1_760_000_000_198);
    assert_eq!(response.cache_max_age_ms, 300_000);
    client.close().await;
}

#[tokio::test]
async fn models_list_sends_only_the_filters_it_was_given() {
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("ok")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    client
        .models()
        .list(ListModelsRequest {
            provider_id: Some("anthropic".into()),
            include_login_required: Some(true),
            ..Default::default()
        })
        .await
        .expect("lists");
    client.close().await;

    let frames = common::read_request_log(log.path());
    let request = frames
        .iter()
        .find(|frame| frame["type"] == serde_json::json!("models_request"))
        .expect("models_request was sent");
    assert_eq!(
        request["payload"]["provider_id"],
        serde_json::json!("anthropic")
    );
    assert_eq!(
        request["payload"]["include_login_required"],
        serde_json::json!(true)
    );
    assert!(request["payload"].get("api").is_none());
    assert!(request["payload"].get("model_id").is_none());
    assert_eq!(request["sequence"], serde_json::json!(1));
}

#[tokio::test]
async fn resolve_needs_exactly_one_match() {
    let client = common::fake_client("ok").await;
    let models = client.models();

    let model = models
        .resolve("anthropic", Some("anthropic-messages"), "claude-sonnet-4-5")
        .await
        .expect("resolves");
    assert_eq!(model.model_id, "claude-sonnet-4-5");
    assert_eq!(model.api, "anthropic-messages");

    // Two APIs serve the same model id, so an unqualified resolve is ambiguous.
    let error = models
        .resolve("anthropic", None, "claude-sonnet-4-5")
        .await
        .unwrap_err();
    assert_eq!(error.code(), Some("invalid_request"));
    assert!(error.to_string().contains("expected exactly 1"), "{error}");

    let error = models
        .resolve("anthropic", Some("anthropic-messages"), "missing")
        .await
        .unwrap_err();
    assert_eq!(error.code(), Some("invalid_request"));
    assert!(error.to_string().contains("model not found"), "{error}");

    client.close().await;
}

#[tokio::test]
async fn resolve_validates_its_arguments_before_the_wire() {
    let client = common::fake_client("ok").await;
    let models = client.models();

    assert!(models.resolve("", None, "m").await.is_err());
    assert!(models.resolve("p", None, "").await.is_err());
    assert!(models
        .list(ListModelsRequest {
            provider_id: Some("x".repeat(300)),
            ..Default::default()
        })
        .await
        .is_err());
    client.close().await;
}

#[tokio::test]
async fn a_malformed_models_response_is_rejected() {
    let client = common::fake_client("malformed").await;
    let error = client
        .models()
        .list(ListModelsRequest::default())
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Protocol { .. }), "{error:?}");
    assert_eq!(error.code(), Some("malformed_response"));
    client.close().await;
}

#[tokio::test]
async fn a_models_nack_surfaces_its_code() {
    let client = common::fake_client("auth_required").await;
    let error = client
        .models()
        .list(ListModelsRequest::default())
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Protocol { .. }), "{error:?}");
    assert_eq!(error.code(), Some("auth_required"));
    client.close().await;
}

#[tokio::test]
async fn agent_models_reaches_the_same_api() {
    let client = common::fake_client("ok").await;
    let direct = client
        .models()
        .list(ListModelsRequest::default())
        .await
        .expect("lists");
    let via_agent = client
        .agent()
        .models()
        .list(ListModelsRequest::default())
        .await
        .expect("lists");
    assert_eq!(direct, via_agent);
    client.close().await;
}

#[tokio::test]
async fn auth_list_providers_degrades_unknown_statuses() {
    let client = common::fake_client("ok").await;
    let providers = client.auth().list_providers().await.expect("lists");
    assert_eq!(providers.len(), 3);
    assert_eq!(providers[0].auth_status, AuthStatus::LoginRequired);
    assert_eq!(providers[1].auth_status, AuthStatus::Authenticated);
    // A status this SDK version does not know must not fail the whole listing.
    assert_eq!(providers[2].auth_status, AuthStatus::Unknown);
    client.close().await;
}

#[tokio::test]
async fn a_malformed_providers_response_is_an_auth_error() {
    let client = common::fake_client("malformed").await;
    let error = client.auth().list_providers().await.unwrap_err();
    assert!(matches!(error, Error::Auth { .. }), "{error:?}");
    client.close().await;
}

#[tokio::test]
async fn login_drives_the_prompt_and_event_callbacks() {
    let client = common::fake_client("login_success").await;
    let events = Arc::new(Mutex::new(Vec::new()));
    let seen = Arc::clone(&events);

    let handlers = AuthHandlers::new()
        .on_event(move |event| {
            seen.lock().expect("lock").push(event);
        })
        .on_prompt(|prompt| async move {
            assert_eq!(prompt.prompt_id, "prompt-1");
            assert!(!prompt.allow_empty);
            Ok("ok".to_owned())
        });

    client
        .auth()
        .login("anthropic", Some(&handlers))
        .await
        .expect("login succeeds");

    let events = events.lock().expect("lock").clone();
    assert!(
        matches!(events[0], AuthEvent::Progress { .. }),
        "{events:?}"
    );
    assert!(matches!(events[1], AuthEvent::AuthUrl { .. }), "{events:?}");
    assert!(matches!(events[2], AuthEvent::Prompt(_)), "{events:?}");
    assert!(
        events
            .iter()
            .any(|event| matches!(event, AuthEvent::Success { .. })),
        "{events:?}"
    );
    client.close().await;
}

#[tokio::test]
async fn a_login_with_no_prompt_handler_cancels_rather_than_hanging() {
    let client = common::fake_client("login_success").await;
    let error = client.auth().login("anthropic", None).await.unwrap_err();
    assert!(error.is_cancelled(), "{error:?}");
    assert!(error.to_string().contains("no prompt handler"), "{error}");
    client.close().await;
}

#[tokio::test]
async fn a_rejected_prompt_answer_fails_the_login() {
    let client = common::fake_client("login_success").await;
    let handlers = AuthHandlers::new().on_prompt(|_| async move { Ok("wrong-code".to_owned()) });
    let error = client
        .auth()
        .login("anthropic", Some(&handlers))
        .await
        .unwrap_err();
    assert_eq!(error.code(), Some("invalid_code"));
    assert_eq!(error.to_string(), "wrong code");
    client.close().await;
}

#[tokio::test]
async fn a_prompt_handler_that_errors_aborts_the_flow() {
    let client = common::fake_client("login_success").await;
    let handlers =
        AuthHandlers::new().on_prompt(|_| async move { Err("user walked away".to_owned()) });
    let error = client
        .auth()
        .login("anthropic", Some(&handlers))
        .await
        .unwrap_err();
    assert_eq!(error.to_string(), "user walked away");
    client.close().await;
}

#[tokio::test]
async fn a_cancelled_login_maps_to_the_cancelled_kind() {
    let client = common::fake_client("login_cancelled").await;
    let error = client.auth().login("anthropic", None).await.unwrap_err();
    assert!(error.is_cancelled(), "{error:?}");
    client.close().await;
}

#[tokio::test]
async fn a_failed_login_carries_the_terminal_error_event() {
    // Spec §8: capture the terminal `auth_event.error` and propagate it into the
    // failure rather than reporting a generic message.
    let client = common::fake_client("login_failed").await;
    let error = client.auth().login("anthropic", None).await.unwrap_err();
    assert_eq!(error.code(), Some("auth_refresh_failed"));
    assert_eq!(error.to_string(), "refresh token rejected");
    client.close().await;
}

#[tokio::test]
async fn client_level_handlers_are_used_when_a_call_supplies_none() {
    let client = common::fake_builder("login_success")
        .auth_handlers(AuthHandlers::new().on_prompt(|_| async move { Ok("ok".to_owned()) }))
        .connect()
        .await
        .expect("connects");
    client
        .auth()
        .login("anthropic", None)
        .await
        .expect("client handlers answer the prompt");
    client.close().await;
}

#[tokio::test]
async fn provider_complete_parses_the_result_frame() {
    let client = common::fake_client("ok").await;
    let response = client
        .provider()
        .complete(
            ExecutionRequest::prompt("anthropic/anthropic-messages@claude-sonnet-4-5", "hi")
                .with_max_tokens(64),
        )
        .await
        .expect("completes");

    assert_eq!(response.text(), "hello");
    assert_eq!(response.provider_id, "anthropic");
    assert_eq!(response.api, "anthropic-messages");
    assert_eq!(response.model_id, "claude-sonnet-4-5");
    assert_eq!(response.stop_reason.as_deref(), Some("end_turn"));
    let usage = response.usage.expect("usage");
    assert_eq!((usage.input, usage.output), (3, 5));
    assert_eq!(usage.cache_read, Some(1));
    client.close().await;
}

#[tokio::test]
async fn provider_stream_normalizes_the_whole_event_sequence() {
    let client = common::fake_client("ok").await;
    let mut events = Box::pin(client.provider().stream(ExecutionRequest::prompt(
        "anthropic/anthropic-messages@claude-sonnet-4-5",
        "hi",
    )));

    let mut seen = Vec::new();
    while let Some(event) = events.next().await {
        seen.push(event.expect("no failures"));
    }

    assert!(matches!(
        seen.first(),
        Some(ProviderEvent::MessageStart { .. })
    ));
    let text: String = seen.iter().filter_map(ProviderEvent::text).collect();
    assert_eq!(text, "hello");
    assert!(seen.iter().any(|event| matches!(
        event,
        ProviderEvent::ThinkingDelta { delta } if delta == "thinking"
    )));
    // `reasoning` is normalized to a thinking delta (spec §3.5).
    assert!(seen.iter().any(|event| matches!(
        event,
        ProviderEvent::ToolCall { name, arguments_json, .. }
            if name == "lookup" && arguments_json == r#"{"city":"SF"}"#
    )));
    assert!(matches!(
        seen.last(),
        Some(ProviderEvent::MessageEnd { .. })
    ));
    assert_eq!(
        seen.iter().filter(|event| event.is_terminal()).count(),
        1,
        "exactly one terminal event"
    );

    drop(events);
    client.close().await;
}

#[tokio::test]
async fn dropping_a_provider_stream_sends_an_abort() {
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("provider_slow")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    {
        let mut events = Box::pin(client.provider().stream(ExecutionRequest::prompt(
            "anthropic/anthropic-messages@claude-sonnet-4-5",
            "hi",
        )));
        // Take one event, then walk away mid-stream.
        let first = events.next().await.expect("an event").expect("no failure");
        assert!(matches!(first, ProviderEvent::MessageStart { .. }));
    }

    let frames = common::wait_for_logged(log.path(), |frames| {
        common::frame_kinds(frames)
            .iter()
            .any(|kind| kind == "abort_request")
    })
    .await;
    let abort = frames
        .iter()
        .find(|frame| frame["type"] == serde_json::json!("abort_request"))
        .expect("abort_request was sent on drop");
    assert_eq!(
        abort["payload"]["reason"],
        serde_json::json!("client aborted")
    );
    assert_eq!(abort["stream_id"], abort["payload"]["target_stream_id"]);

    client.close().await;
}

#[tokio::test]
async fn a_completed_provider_stream_does_not_abort() {
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("ok")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    {
        let mut events = Box::pin(client.provider().stream(ExecutionRequest::prompt(
            "anthropic/anthropic-messages@claude-sonnet-4-5",
            "hi",
        )));
        while let Some(event) = events.next().await {
            event.expect("no failures");
        }
    }
    tokio::time::sleep(Duration::from_millis(150)).await;

    let frames = common::read_request_log(log.path());
    assert!(
        !common::frame_kinds(&frames)
            .iter()
            .any(|kind| kind == "abort_request"),
        "a settled stream must not abort: {:?}",
        common::frame_kinds(&frames)
    );
    client.close().await;
}

#[tokio::test]
async fn a_cancelled_provider_stream_stops_yielding() {
    let client = common::fake_client("provider_slow").await;
    let events = client.provider().stream(ExecutionRequest::prompt(
        "anthropic/anthropic-messages@claude-sonnet-4-5",
        "hi",
    ));

    let count = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&count);
    let task = tokio::spawn(async move {
        let mut events = Box::pin(events);
        while let Some(event) = events.next().await {
            if event.is_err() {
                break;
            }
            counter.fetch_add(1, Ordering::SeqCst);
        }
    });

    tokio::time::sleep(Duration::from_millis(150)).await;
    task.abort();
    let _ = task.await;

    let after_abort = count.load(Ordering::SeqCst);
    tokio::time::sleep(Duration::from_millis(200)).await;
    assert_eq!(
        count.load(Ordering::SeqCst),
        after_abort,
        "cancelling the task must stop the stream"
    );
    client.close().await;
}

#[tokio::test]
async fn auth_required_surfaces_as_the_typed_error_under_the_manual_policy() {
    let client = common::fake_client("auth_required").await;

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
    assert!(events.next().await.is_none(), "the stream ends there");

    drop(events);
    client.close().await;
}

#[tokio::test]
async fn auto_once_without_handlers_fails_fast_instead_of_hanging() {
    // Spec §3.7: `auto_once` with no configured handlers must fail fast with the
    // typed auth error, not stall on a prompt nobody can answer.
    let client = common::fake_builder("auth_required")
        .auth_retry_policy(AuthRetryPolicy::AutoOnce)
        .connect()
        .await
        .expect("connects");

    let started = tokio::time::Instant::now();
    let error = client
        .provider()
        .complete(ExecutionRequest::prompt(
            "anthropic/anthropic-messages@claude-sonnet-4-5",
            "hi",
        ))
        .await
        .unwrap_err();
    assert!(matches!(error, Error::AuthRequired { .. }), "{error:?}");
    assert!(started.elapsed() < Duration::from_secs(2));
    client.close().await;
}

#[tokio::test]
async fn a_per_request_policy_overrides_the_client_default() {
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("ok")
        .auth_retry_policy(AuthRetryPolicy::AutoOnce)
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    client
        .provider()
        .complete(
            ExecutionRequest::prompt("anthropic/anthropic-messages@claude-sonnet-4-5", "hi")
                .with_options(RunOptions {
                    auth_retry_policy: Some(AuthRetryPolicy::Manual),
                    ..Default::default()
                }),
        )
        .await
        .expect("completes");
    client.close().await;

    let frames = common::read_request_log(log.path());
    let request = frames
        .iter()
        .find(|frame| frame["type"] == serde_json::json!("complete_request"))
        .expect("complete_request was sent");
    assert_eq!(
        request["payload"]["options"]["auth_retry_policy"],
        serde_json::json!("manual")
    );
}

#[tokio::test]
async fn invalid_requests_are_rejected_without_touching_the_wire() {
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("ok")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    let error = client
        .provider()
        .complete(ExecutionRequest::prompt("", "hi"))
        .await
        .unwrap_err();
    assert!(matches!(error, Error::InvalidRequest { .. }), "{error:?}");

    let error = client
        .agent()
        .run(
            ExecutionRequest::prompt("p/a@m", "hi").with_options(RunOptions {
                session_id: Some("too-short".into()),
                ..Default::default()
            }),
        )
        .await
        .unwrap_err();
    assert!(matches!(error, Error::InvalidRequest { .. }), "{error:?}");

    client.close().await;
    assert!(
        common::read_request_log(log.path()).is_empty(),
        "nothing should have been sent"
    );
}

#[tokio::test]
async fn streams_report_invalid_requests_as_their_first_item() {
    // A stream cannot fail at call time, so validation surfaces on the first
    // poll rather than being silently deferred until a request is on the wire.
    let client = common::fake_client("ok").await;

    let mut events = Box::pin(client.provider().stream(ExecutionRequest::prompt("", "hi")));
    let error = events
        .next()
        .await
        .expect("one item")
        .expect_err("the request is invalid");
    assert!(matches!(error, Error::InvalidRequest { .. }), "{error:?}");
    assert!(events.next().await.is_none());
    drop(events);

    let mut events = Box::pin(client.agent().stream(ExecutionRequest::prompt("", "hi")));
    let error = events
        .next()
        .await
        .expect("one item")
        .expect_err("the request is invalid");
    assert!(matches!(error, Error::InvalidRequest { .. }), "{error:?}");
    drop(events);

    client.close().await;
}
