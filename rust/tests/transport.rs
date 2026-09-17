//! Transport, handshake, framing, and process-lifecycle coverage.

#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]

mod common;

use std::time::Duration;

use futures::StreamExt;
use makai::{Client, ClientBuilder, Error, ExecutionRequest, ListModelsRequest};

#[tokio::test]
async fn connects_and_completes_the_handshake() {
    let client = common::fake_client("ok").await;
    assert!(!client.is_closed());
    client.close().await;
    assert!(client.is_closed());
}

#[tokio::test]
async fn a_missing_handshake_times_out_rather_than_hanging() {
    let started = tokio::time::Instant::now();
    let error = common::fake_builder("no_handshake")
        .handshake_timeout(Duration::from_millis(300))
        .connect()
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Transport { .. }), "{error:?}");
    assert!(error.to_string().contains("handshake timed out"), "{error}");
    assert!(started.elapsed() < Duration::from_secs(3));
}

#[tokio::test]
async fn a_version_mismatch_fails_fast_with_a_typed_code() {
    let error = common::fake_builder("bad_version")
        .connect()
        .await
        .unwrap_err();
    assert_eq!(error.code(), Some("version_mismatch"));
    assert!(
        error.to_string().contains("protocol version mismatch"),
        "{error}"
    );
}

#[tokio::test]
async fn an_expected_version_can_be_overridden() {
    let client = common::fake_builder("bad_version")
        .expected_protocol_version("99")
        .connect()
        .await
        .expect("the fake advertises 99");
    client.close().await;
}

#[tokio::test]
async fn an_error_frame_in_place_of_the_handshake_is_a_protocol_error() {
    let error = common::fake_builder("handshake_error")
        .connect()
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Protocol { .. }), "{error:?}");
    assert_eq!(error.code(), Some("startup_failed"));
}

#[tokio::test]
async fn garbage_lines_are_discarded_without_breaking_the_stream() {
    // The reader must skip an unparseable line rather than treating it as the
    // handshake or tearing the transport down.
    let client = common::fake_client("garbage_then_ready").await;
    let models = client
        .models()
        .list(ListModelsRequest::default())
        .await
        .expect("models still work after a garbage line");
    assert_eq!(models.models.len(), 1);
    client.close().await;
}

#[tokio::test]
async fn a_missing_binary_is_a_clear_transport_error() {
    // `command` bypasses resolution, so this is the spawn failing rather than
    // the resolver refusing; both must be a typed transport error naming the
    // path, not a panic or a hang.
    let error = ClientBuilder::new()
        .command("/definitely/not/here/makai")
        .connect()
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Transport { .. }), "{error:?}");
    assert!(
        error.to_string().contains("/definitely/not/here/makai"),
        "{error}"
    );
}

#[tokio::test]
async fn a_child_that_dies_mid_request_fails_the_call_rather_than_hanging() {
    let client = common::fake_client("die_on_request").await;
    let started = tokio::time::Instant::now();
    let error = client
        .models()
        .list(ListModelsRequest::default())
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Protocol { .. }), "{error:?}");
    assert!(
        error.to_string().contains("exit") || error.to_string().contains("stdio stream ended"),
        "{error}"
    );
    assert!(started.elapsed() < Duration::from_secs(2));
    assert!(client.is_closed());
    client.close().await;
}

#[tokio::test]
async fn a_dead_child_fails_later_calls_immediately() {
    let client = common::fake_client("die_on_request").await;
    let _ = client.models().list(ListModelsRequest::default()).await;

    // Give the supervisor a moment to observe the exit.
    tokio::time::sleep(Duration::from_millis(100)).await;
    let started = tokio::time::Instant::now();
    let error = client
        .models()
        .list(ListModelsRequest::default())
        .await
        .unwrap_err();
    assert!(started.elapsed() < Duration::from_millis(500), "{error}");
    client.close().await;
}

#[tokio::test]
async fn a_silent_runtime_times_out_per_call() {
    let client = common::fake_builder("silent")
        .response_timeout(Duration::from_millis(200))
        .connect()
        .await
        .expect("connects");
    let error = client
        .models()
        .list(ListModelsRequest::default())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("timed out"), "{error}");

    // The transport is still usable: a timeout is per-call, not fatal.
    assert!(!client.is_closed());
    client.close().await;
}

#[tokio::test]
async fn concurrent_calls_multiplex_over_one_transport() {
    let client = common::fake_client("ok").await;
    let models = client.models();

    let calls = (0..8).map(|_| {
        let models = models.clone();
        async move { models.list(ListModelsRequest::default()).await }
    });
    let results = futures::future::join_all(calls).await;

    for result in results {
        assert_eq!(result.expect("each call settles").models.len(), 1);
    }
    client.close().await;
}

#[cfg(unix)]
#[tokio::test]
async fn closing_the_client_reaps_the_child() {
    let pid_file = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("ok")
        .env("MAKAI_FAKE_PID_FILE", pid_file.path().display().to_string())
        .connect()
        .await
        .expect("connects");
    let pid = wait_for_pid(pid_file.path()).await;
    assert!(process_is_alive(pid), "the fake should be running");

    client.close().await;
    assert!(client.is_closed());

    // `close` returns only after the child has been waited on.
    assert!(!process_is_alive(pid), "the child should be reaped");
}

#[cfg(unix)]
#[tokio::test]
async fn dropping_the_client_terminates_the_child() {
    let pid_file = tempfile::NamedTempFile::new().expect("temp file");
    let pid = {
        let _client = common::fake_builder("ok")
            .env("MAKAI_FAKE_PID_FILE", pid_file.path().display().to_string())
            .connect()
            .await
            .expect("connects");
        let pid = wait_for_pid(pid_file.path()).await;
        assert!(process_is_alive(pid));
        pid
    };

    // `Drop` cannot await the reaper, so give it a moment to run.
    for _ in 0..40 {
        if !process_is_alive(pid) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("dropping the client left the child {pid} running");
}

#[cfg(unix)]
#[tokio::test]
async fn dropping_a_client_mid_stream_terminates_the_child() {
    let pid_file = tempfile::NamedTempFile::new().expect("temp file");
    let pid = {
        let client = common::fake_builder("provider_slow")
            .env("MAKAI_FAKE_PID_FILE", pid_file.path().display().to_string())
            .connect()
            .await
            .expect("connects");
        let pid = wait_for_pid(pid_file.path()).await;

        let mut events = Box::pin(client.provider().stream(ExecutionRequest::prompt(
            "anthropic/anthropic-messages@claude-sonnet-4-5",
            "hi",
        )));
        events.next().await.expect("an event").expect("no failure");
        // Both the stream and the client go out of scope here, in that order.
        pid
    };

    for _ in 0..40 {
        if !process_is_alive(pid) {
            return;
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
    }
    panic!("dropping a client mid-stream left the child {pid} running");
}

#[cfg(unix)]
async fn wait_for_pid(path: &std::path::Path) -> u32 {
    for _ in 0..100 {
        if let Ok(text) = std::fs::read_to_string(path) {
            if let Ok(pid) = text.trim().parse() {
                return pid;
            }
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    panic!("the fake never reported its pid");
}

#[cfg(unix)]
fn process_is_alive(pid: u32) -> bool {
    // A zombie the parent has not reaped still answers `kill -0`, so this also
    // catches a child that was killed but never waited on.
    std::process::Command::new("ps")
        .args(["-o", "stat=", "-p", &pid.to_string()])
        .output()
        .map(|output| {
            let stat = String::from_utf8_lossy(&output.stdout);
            let stat = stat.trim();
            !stat.is_empty() && !stat.starts_with('Z')
        })
        .unwrap_or(false)
}

#[tokio::test]
async fn calls_after_close_fail_instead_of_hanging() {
    let client = common::fake_client("ok").await;
    client.close().await;

    let error = client
        .models()
        .list(ListModelsRequest::default())
        .await
        .unwrap_err();
    assert!(error.to_string().contains("closed"), "{error}");

    let error = client
        .provider()
        .complete(ExecutionRequest::prompt("p/a@m", "hi"))
        .await
        .unwrap_err();
    assert!(error.to_string().contains("closed"), "{error}");
}

#[tokio::test]
async fn close_is_idempotent() {
    let client = common::fake_client("ok").await;
    client.close().await;
    client.close().await;
    assert!(client.is_closed());
}

#[tokio::test]
async fn namespace_handles_outlive_the_client_value() {
    let provider = {
        let client = common::fake_client("ok").await;
        client.provider()
    };
    // The namespace holds the transport alive, so the call still works.
    let response = provider
        .complete(ExecutionRequest::prompt(
            "anthropic/anthropic-messages@claude-sonnet-4-5",
            "hi",
        ))
        .await
        .expect("the transport outlives the client value");
    assert_eq!(response.text(), "hello");
}

#[tokio::test]
async fn every_outbound_frame_is_one_ndjson_line_with_the_v1_envelope() {
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("ok")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    client
        .models()
        .list(ListModelsRequest::default())
        .await
        .expect("lists");
    client
        .provider()
        .complete(ExecutionRequest::prompt(
            "anthropic/anthropic-messages@claude-sonnet-4-5",
            "hi",
        ))
        .await
        .expect("completes");
    client.close().await;

    let frames = common::read_request_log(log.path());
    assert!(frames.len() >= 2);
    for frame in &frames {
        assert_eq!(frame["version"], serde_json::json!(1), "{frame}");
        assert!(frame["message_id"].is_string(), "{frame}");
        assert!(frame["sequence"].is_u64(), "{frame}");
        assert!(frame["timestamp"].is_i64(), "{frame}");
        // A frame carries exactly one route key, which is how the stdio host
        // decides which protocol server to hand it to.
        let has_stream = frame.get("stream_id").is_some();
        let has_session = frame.get("session_id").is_some();
        assert!(has_stream ^ has_session, "{frame}");
    }
}

#[tokio::test]
async fn generated_ids_match_the_wire_formats() {
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("ok")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");
    client
        .models()
        .list(ListModelsRequest::default())
        .await
        .expect("lists");
    client
        .agent()
        .run(ExecutionRequest::prompt(
            "anthropic/anthropic-messages@claude-sonnet-4-5",
            "hi",
        ))
        .await
        .expect("runs");
    client.close().await;

    let frames = common::read_request_log(log.path());
    for frame in &frames {
        let message_id = frame["message_id"].as_str().expect("message_id");
        assert_eq!(message_id.len(), 26, "message_id is a ULID: {message_id}");
        assert!(
            message_id
                .bytes()
                .all(|b| b.is_ascii_digit() || b.is_ascii_uppercase()),
            "message_id is Crockford Base32: {message_id}"
        );
        // The runtime rejects a ULID whose 48-bit timestamp segment overflows.
        assert!(
            message_id.as_bytes()[0] <= b'7',
            "ULID timestamp segment overflows: {message_id}"
        );

        if let Some(stream_id) = frame.get("stream_id").and_then(|id| id.as_str()) {
            assert_eq!(stream_id.len(), 26, "stream_id is a ULID: {stream_id}");
        }
        if let Some(session_id) = frame.get("session_id").and_then(|id| id.as_str()) {
            assert_eq!(session_id.len(), 21, "session_id is a NanoID: {session_id}");
            assert!(session_id.bytes().all(|b| b.is_ascii_alphanumeric()));
        }
    }
}

#[tokio::test]
async fn the_builder_controls_the_child_environment() {
    // `env_clear` plus one variable is what the fake sees; if the builder leaked
    // the parent environment, an ambient MAKAI_FAKE_SCENARIO would win.
    let client = ClientBuilder::new()
        .command(common::fake_binary())
        .args(Vec::<String>::new())
        .env_clear()
        .env("MAKAI_FAKE_SCENARIO", "auth_required")
        .handshake_timeout(Duration::from_millis(2_000))
        .response_timeout(Duration::from_millis(2_000))
        .connect()
        .await
        .expect("connects");

    let error = client
        .models()
        .list(ListModelsRequest::default())
        .await
        .unwrap_err();
    assert_eq!(error.code(), Some("auth_required"));
    client.close().await;
}

#[tokio::test]
async fn the_client_is_debuggable_without_leaking_internals() {
    let client: Client = common::fake_client("ok").await;
    let rendered = format!("{client:?}");
    assert!(rendered.contains("Client"), "{rendered}");
    client.close().await;
}
