//! Agent-loop coverage: sequencing, tool execution, teardown, cancellation.

#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]

mod common;

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Arc;
use std::time::Duration;

use futures::StreamExt;
use makai::{AgentEvent, Error, ExecutionRequest, ProviderEvent, RunOptions, Tool};

const MODEL: &str = "anthropic/anthropic-messages@claude-sonnet-4-5";

fn kinds(frames: &[serde_json::Value]) -> Vec<String> {
    common::frame_kinds(frames)
}

#[tokio::test]
async fn run_walks_start_message_result_and_stop_in_order() {
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("ok")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    let response = client
        .agent()
        .run(ExecutionRequest::prompt(MODEL, "hi"))
        .await
        .expect("runs");
    assert_eq!(response.text(), "agent done");
    assert_eq!(response.stop_reason.as_deref(), Some("end_turn"));

    let frames = common::wait_for_logged(log.path(), |frames| {
        kinds(frames).iter().any(|kind| kind == "agent_stop")
    })
    .await;
    assert_eq!(
        kinds(&frames),
        vec!["agent_start", "agent_message", "agent_stop"]
    );
    client.close().await;
}

#[tokio::test]
async fn inbound_sequences_are_per_session_and_start_at_one() {
    // Spec §13.1: `agent_start` carries 1, an accepted `agent_message` advances
    // to 2, and the stop carries the next expected value.
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("ok")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    client
        .agent()
        .run(ExecutionRequest::prompt(MODEL, "hi"))
        .await
        .expect("runs");
    let frames = common::wait_for_logged(log.path(), |frames| {
        kinds(frames).iter().any(|kind| kind == "agent_stop")
    })
    .await;

    assert_eq!(frames[0]["sequence"], serde_json::json!(1));
    assert_eq!(frames[1]["sequence"], serde_json::json!(2));
    assert_eq!(frames[2]["sequence"], serde_json::json!(3));

    // One session throughout.
    let sessions: std::collections::BTreeSet<_> = frames
        .iter()
        .filter_map(|frame| frame["session_id"].as_str())
        .collect();
    assert_eq!(sessions.len(), 1);
    client.close().await;
}

#[tokio::test]
async fn each_run_gets_a_fresh_session_and_restarts_at_one() {
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("ok")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    for _ in 0..2 {
        client
            .agent()
            .run(ExecutionRequest::prompt(MODEL, "hi"))
            .await
            .expect("runs");
    }
    let frames = common::wait_for_logged(log.path(), |frames| {
        kinds(frames)
            .iter()
            .filter(|kind| *kind == "agent_stop")
            .count()
            == 2
    })
    .await;

    let starts: Vec<_> = frames
        .iter()
        .filter(|frame| frame["type"] == serde_json::json!("agent_start"))
        .collect();
    assert_eq!(starts.len(), 2);
    assert_ne!(starts[0]["session_id"], starts[1]["session_id"]);
    assert_eq!(starts[0]["sequence"], serde_json::json!(1));
    assert_eq!(starts[1]["sequence"], serde_json::json!(1));
    client.close().await;
}

#[tokio::test]
async fn a_caller_supplied_session_id_is_used_verbatim() {
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("ok")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    let session_id = "abcdefghijklmnopqrstu";
    client
        .agent()
        .run(
            ExecutionRequest::prompt(MODEL, "hi").with_options(RunOptions {
                session_id: Some(session_id.to_owned()),
                ..Default::default()
            }),
        )
        .await
        .expect("runs");
    let frames = common::wait_for_logged(log.path(), |frames| {
        kinds(frames).iter().any(|kind| kind == "agent_stop")
    })
    .await;

    assert_eq!(frames[0]["session_id"], serde_json::json!(session_id));
    // Spec §9 / §13.1: the canonical key plus the permanent legacy alias.
    assert_eq!(
        frames[0]["payload"]["session_id"],
        serde_json::json!(session_id)
    );
    assert_eq!(
        frames[0]["payload"]["resume_session_id"],
        serde_json::json!(session_id)
    );
    client.close().await;
}

#[tokio::test]
async fn tools_execute_in_the_callers_process() {
    let calls = Arc::new(AtomicUsize::new(0));
    let counter = Arc::clone(&calls);

    let client = common::fake_client("agent_tools").await;
    let response = client
        .agent()
        .run(ExecutionRequest::prompt(MODEL, "hi").with_tool(
            Tool::new("lookup", "look it up", r#"{"type":"object"}"#).on_call(move |invocation| {
                let counter = Arc::clone(&counter);
                async move {
                    counter.fetch_add(1, Ordering::SeqCst);
                    let args: serde_json::Value =
                        invocation.args().map_err(|err| err.to_string())?;
                    Ok(format!(
                        "weather in {}",
                        args["city"].as_str().unwrap_or_default()
                    ))
                }
            }),
        ))
        .await
        .expect("runs");

    assert_eq!(calls.load(Ordering::SeqCst), 1);
    assert_eq!(response.text(), "tool said: weather in SF");
    client.close().await;
}

#[tokio::test]
async fn tool_results_correlate_to_the_request_and_skip_the_inbound_counter() {
    // Spec §13.1: a `tool_result` replies to its `tool_execute` and does not
    // consume an inbound sequence number, so the stop still carries 3.
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("agent_tools")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    client
        .agent()
        .run(
            ExecutionRequest::prompt(MODEL, "hi").with_tool(
                Tool::new("lookup", "look it up", "{}")
                    .on_call(|_| async move { Ok("sunny".to_owned()) }),
            ),
        )
        .await
        .expect("runs");

    let frames = common::wait_for_logged(log.path(), |frames| {
        kinds(frames).iter().any(|kind| kind == "agent_stop")
    })
    .await;
    assert_eq!(
        kinds(&frames),
        vec!["agent_start", "agent_message", "tool_result", "agent_stop"]
    );

    let tool_result = &frames[2];
    assert!(tool_result["in_reply_to"].is_string());
    assert_eq!(
        tool_result["payload"]["tool_call_id"],
        serde_json::json!("call-1")
    );
    assert_eq!(tool_result["payload"]["is_error"], serde_json::json!(false));

    let stop = &frames[3];
    assert_eq!(stop["sequence"], serde_json::json!(3));
    client.close().await;
}

#[tokio::test]
async fn an_unhandled_tool_answers_with_an_error_result() {
    let client = common::fake_client("agent_tools").await;
    let response = client
        .agent()
        .run(ExecutionRequest::prompt(MODEL, "hi"))
        .await
        .expect("the loop settles even with no handler");
    assert!(
        response.text().contains("not executable by this client"),
        "{}",
        response.text()
    );
    client.close().await;
}

#[tokio::test]
async fn stream_yields_the_lifecycle_then_exactly_one_terminal_event() {
    let client = common::fake_client("ok").await;
    let mut events = Box::pin(client.agent().stream(ExecutionRequest::prompt(MODEL, "hi")));

    let mut seen = Vec::new();
    while let Some(event) = events.next().await {
        seen.push(event.expect("no failures"));
    }

    assert!(matches!(seen.first(), Some(AgentEvent::AgentStart { .. })));
    assert!(seen
        .iter()
        .any(|event| matches!(event, AgentEvent::TurnStart)));
    assert!(seen
        .iter()
        .any(|event| matches!(event, AgentEvent::TurnEnd { .. })));
    assert!(seen.iter().any(|event| matches!(
        event,
        AgentEvent::Provider(ProviderEvent::MessageStart { .. })
    )));
    let text: String = seen.iter().filter_map(AgentEvent::text).collect();
    assert_eq!(text, "agent done");

    assert_eq!(
        seen.iter().filter(|event| event.is_terminal()).count(),
        1,
        "exactly one terminal event: {seen:?}"
    );
    assert!(matches!(seen.last(), Some(AgentEvent::AgentEnd { .. })));

    drop(events);
    client.close().await;
}

#[tokio::test]
async fn stream_aggregates_usage_across_turns() {
    let client = common::fake_client("ok").await;
    let mut events = Box::pin(client.agent().stream(ExecutionRequest::prompt(MODEL, "hi")));
    let mut last = None;
    while let Some(event) = events.next().await {
        last = Some(event.expect("no failures"));
    }
    match last {
        Some(AgentEvent::AgentEnd { usage, .. }) => {
            let usage = usage.expect("aggregate usage");
            assert_eq!((usage.input, usage.output), (3, 5));
        }
        other => panic!("unexpected terminal event: {other:?}"),
    }
    drop(events);
    client.close().await;
}

#[tokio::test]
async fn stream_tears_the_session_down_after_a_clean_finish() {
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("ok")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    {
        let mut events = Box::pin(client.agent().stream(ExecutionRequest::prompt(MODEL, "hi")));
        while let Some(event) = events.next().await {
            event.expect("no failures");
        }
    }

    let frames = common::wait_for_logged(log.path(), |frames| {
        kinds(frames).iter().any(|kind| kind == "agent_stop")
    })
    .await;
    let stops: Vec<_> = frames
        .iter()
        .filter(|frame| frame["type"] == serde_json::json!("agent_stop"))
        .collect();
    assert_eq!(stops.len(), 1, "exactly one stop: {:?}", kinds(&frames));
    assert_eq!(
        stops[0]["payload"]["reason"],
        serde_json::json!("completed")
    );
    client.close().await;
}

#[tokio::test]
async fn dropping_an_agent_stream_stops_the_session() {
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("agent_slow")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    {
        let mut events = Box::pin(client.agent().stream(ExecutionRequest::prompt(MODEL, "hi")));
        // Read past the start, then walk away mid-run.
        let first = events.next().await.expect("an event").expect("no failure");
        assert!(matches!(first, AgentEvent::AgentStart { .. }));
    }

    let frames = common::wait_for_logged(log.path(), |frames| {
        kinds(frames).iter().any(|kind| kind == "agent_stop")
    })
    .await;
    let stop = frames
        .iter()
        .find(|frame| frame["type"] == serde_json::json!("agent_stop"))
        .expect("agent_stop was sent on drop");
    assert_eq!(
        stop["payload"]["reason"],
        serde_json::json!("client aborted")
    );
    client.close().await;
}

#[tokio::test]
async fn a_cancelled_agent_stream_stops_yielding() {
    let client = common::fake_client("agent_slow").await;
    let events = client.agent().stream(ExecutionRequest::prompt(MODEL, "hi"));

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

    tokio::time::sleep(Duration::from_millis(200)).await;
    task.abort();
    let _ = task.await;

    let after_abort = count.load(Ordering::SeqCst);
    tokio::time::sleep(Duration::from_millis(250)).await;
    assert_eq!(count.load(Ordering::SeqCst), after_abort);
    client.close().await;
}

#[tokio::test]
async fn a_busy_session_is_never_stopped_by_the_attempt_that_lost_it() {
    // Spec §6.1 / §13.3.3: `agent_busy` means the id belongs to another live
    // run. Stopping it would remove and cancel that run.
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("agent_busy")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    let error = client
        .agent()
        .run(
            ExecutionRequest::prompt(MODEL, "hi").with_options(RunOptions {
                session_id: Some("abcdefghijklmnopqrstu".into()),
                ..Default::default()
            }),
        )
        .await
        .unwrap_err();
    assert_eq!(error.code(), Some("agent_busy"));

    tokio::time::sleep(Duration::from_millis(200)).await;
    let frames = common::read_request_log(log.path());
    assert!(
        !kinds(&frames).iter().any(|kind| kind == "agent_stop"),
        "a rejected attempt must not stop the session it lost: {:?}",
        kinds(&frames)
    );
    client.close().await;
}

#[tokio::test]
async fn a_rejected_start_is_reported_without_a_stop() {
    // The fake rejects any `agent_start` that does not carry sequence 1, and
    // rejects `agent_stop` that is out of order, so a spurious stop would show
    // up as an extra frame here.
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("agent_busy")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .connect()
        .await
        .expect("connects");

    let mut events = Box::pin(client.agent().stream(ExecutionRequest::prompt(MODEL, "hi")));
    let error = events
        .next()
        .await
        .expect("one item")
        .expect_err("the start is rejected");
    assert_eq!(error.code(), Some("agent_busy"));
    assert!(events.next().await.is_none());
    drop(events);

    tokio::time::sleep(Duration::from_millis(150)).await;
    assert_eq!(
        kinds(&common::read_request_log(log.path())),
        vec!["agent_start"]
    );
    client.close().await;
}

#[tokio::test]
async fn an_unresolved_message_makes_the_stop_probe_both_sequences() {
    // Spec §6.1: the stop must carry the session's next expected inbound
    // sequence, and an out-of-order stop is rejected and leaves the session
    // registered. While the `agent_message` is unresolved the client cannot
    // know whether the server accepted it, so it probes: the pre-send value
    // first, then the post-send value once the server rejects that as
    // out-of-order. The fake here accepted the message — so it expects 3 — but
    // told the client nothing before the call timed out.
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("agent_silent_after_message")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .env("MAKAI_FAKE_EXPECTED_STOP_SEQUENCE", "3")
        .response_timeout(Duration::from_millis(300))
        .connect()
        .await
        .expect("connects");

    let error = client
        .agent()
        .run(ExecutionRequest::prompt(MODEL, "hi"))
        .await
        .unwrap_err();
    assert!(error.to_string().contains("timed out"), "{error}");

    let frames = common::wait_for_logged(log.path(), |frames| {
        kinds(frames)
            .iter()
            .filter(|kind| *kind == "agent_stop")
            .count()
            == 2
    })
    .await;
    let stops: Vec<u64> = frames
        .iter()
        .filter(|frame| frame["type"] == serde_json::json!("agent_stop"))
        .filter_map(|frame| frame["sequence"].as_u64())
        .collect();
    assert_eq!(
        stops,
        vec![2, 3],
        "expected a pre-send probe then the post-send retry: {:?}",
        kinds(&frames)
    );
    client.close().await;
}

#[tokio::test]
async fn an_aborted_stream_stops_an_unresolved_session_at_both_sequences() {
    // The stream-path mirror of the probe test above. A stream generator that
    // exits through `?` -- here a response timeout with no run output -- never
    // reaches `teardown`, and `Drop` cannot await the reply that would say
    // which sequence was right. The fake is told to expect 2, modelling a
    // server that never admitted the `agent_message`, so a lone post-send stop
    // is answered `invalid_request` and leaves the session registered until
    // idle eviction.
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("agent_silent_after_message")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .env("MAKAI_FAKE_EXPECTED_STOP_SEQUENCE", "2")
        .response_timeout(Duration::from_millis(300))
        .connect()
        .await
        .expect("connects");

    {
        let mut events = Box::pin(client.agent().stream(ExecutionRequest::prompt(MODEL, "hi")));
        let failure = events
            .next()
            .await
            .expect("an item")
            .expect_err("the run times out");
        assert!(failure.to_string().contains("timed out"), "{failure}");
    }

    let frames = common::wait_for_logged(log.path(), |frames| {
        kinds(frames)
            .iter()
            .filter(|kind| *kind == "agent_stop")
            .count()
            == 2
    })
    .await;
    let stops: Vec<u64> = frames
        .iter()
        .filter(|frame| frame["type"] == serde_json::json!("agent_stop"))
        .filter_map(|frame| frame["sequence"].as_u64())
        .collect();
    assert_eq!(
        stops,
        vec![2, 3],
        "expected the pre-send candidate then the post-send one: {:?}",
        kinds(&frames)
    );
    client.close().await;
}

#[tokio::test]
async fn a_settled_run_stops_once_without_probing() {
    // The mirror of the probe test: any run output proves the message was
    // admitted, so the stop goes straight to the post-send value.
    let log = tempfile::NamedTempFile::new().expect("temp file");
    let client = common::fake_builder("ok")
        .env("MAKAI_FAKE_REQUEST_LOG", log.path().display().to_string())
        .env("MAKAI_FAKE_EXPECTED_STOP_SEQUENCE", "3")
        .connect()
        .await
        .expect("connects");

    client
        .agent()
        .run(ExecutionRequest::prompt(MODEL, "hi"))
        .await
        .expect("runs");

    let frames = common::wait_for_logged(log.path(), |frames| {
        kinds(frames).iter().any(|kind| kind == "agent_stop")
    })
    .await;
    let stops: Vec<u64> = frames
        .iter()
        .filter(|frame| frame["type"] == serde_json::json!("agent_stop"))
        .filter_map(|frame| frame["sequence"].as_u64())
        .collect();
    assert_eq!(stops, vec![3]);
    client.close().await;
}

#[tokio::test]
async fn an_errored_run_with_an_auth_message_takes_the_auth_path() {
    // Spec §3.5: a provider auth failure settles as a *successful* run whose
    // stop_reason is "error"; it must still reach the typed auth error.
    let client = common::fake_client("auth_required").await;
    let error = client
        .agent()
        .run(ExecutionRequest::prompt(MODEL, "hi"))
        .await
        .unwrap_err();
    assert!(matches!(error, Error::AuthRequired { .. }), "{error:?}");
    assert_eq!(error.provider_id(), Some("anthropic"));
    client.close().await;
}

#[tokio::test]
async fn an_errored_stream_with_an_auth_message_takes_the_auth_path() {
    let client = common::fake_client("auth_required").await;
    let mut events = Box::pin(client.agent().stream(ExecutionRequest::prompt(MODEL, "hi")));

    let mut error = None;
    while let Some(event) = events.next().await {
        match event {
            Ok(_) => {}
            Err(err) => {
                error = Some(err);
                break;
            }
        }
    }
    let error = error.expect("the run fails");
    assert!(matches!(error, Error::AuthRequired { .. }), "{error:?}");
    drop(events);
    client.close().await;
}

#[tokio::test]
async fn a_dead_child_fails_a_run_in_flight() {
    let client = common::fake_client("die_on_request").await;
    let started = tokio::time::Instant::now();
    let error = client
        .agent()
        .run(ExecutionRequest::prompt(MODEL, "hi"))
        .await
        .unwrap_err();
    assert!(matches!(error, Error::Stream { .. }), "{error:?}");
    assert!(started.elapsed() < Duration::from_secs(2));
    client.close().await;
}

#[tokio::test]
async fn concurrent_runs_do_not_cross_sessions() {
    let client = common::fake_client("ok").await;
    let agent = client.agent();

    let runs = (0..6).map(|index| {
        let agent = agent.clone();
        async move {
            agent
                .run(ExecutionRequest::prompt(MODEL, format!("hi {index}")))
                .await
        }
    });
    let results = futures::future::join_all(runs).await;
    for result in results {
        assert_eq!(result.expect("each run settles").text(), "agent done");
    }
    client.close().await;
}

#[tokio::test]
async fn the_session_tail_does_not_leak_into_the_next_run() {
    // The fake queues a terminal `agent_end` behind `agent_result`, exactly as
    // the runtime does (spec §6.1). A client that failed to drain would hand it
    // to the next run on the transport as that run's first event.
    let client = common::fake_client("ok").await;
    let agent = client.agent();

    for _ in 0..3 {
        let mut events = Box::pin(agent.stream(ExecutionRequest::prompt(MODEL, "hi")));
        let first = events.next().await.expect("an event").expect("no failure");
        assert!(
            matches!(first, AgentEvent::AgentStart { .. }),
            "stale tail leaked into a new run: {first:?}"
        );
        while let Some(event) = events.next().await {
            event.expect("no failures");
        }
    }
    client.close().await;
}
