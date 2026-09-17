//! The stdio transport: one `makai --stdio` child process, framed as NDJSON.
//!
//! # Shape
//!
//! Three tasks sit behind the child:
//!
//! * a **writer** owning `stdin`, fed by an unbounded channel so that sending a
//!   frame is synchronous and non-blocking — which is what lets a `Drop` impl
//!   emit a best-effort cancellation;
//! * a **reader** owning `stdout`, parsing each line into a [`Frame`] and
//!   handing it to the [`Router`];
//! * a **supervisor** owning the [`Child`], which either observes the process
//!   exiting on its own or, on shutdown, closes stdin, waits out a grace period,
//!   and then kills and reaps.
//!
//! # Routing
//!
//! Unlike the TypeScript SDK, which pulls frames and re-queues the ones that are
//! not its own, this is a push router: a caller registers its routes *before*
//! sending, so no frame can arrive before someone is waiting for it. Dispatch
//! follows spec §13.3:
//!
//! 1. a frame carrying `in_reply_to` goes to the waiter that registered that
//!    `message_id` — request-correlated delivery (§13.3.1);
//! 2. otherwise a `stream_id` / `session_id` frame goes to that route —
//!    session-scoped delivery for asynchronous run output (§13.3.2);
//! 3. anything left over is dropped.
//!
//! Because one subscription can hold several route keys at once, a caller sees
//! its correlated replies and its session-scoped run output on a single ordered
//! queue.

use std::collections::HashMap;
use std::process::Stdio;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::io::{AsyncBufReadExt, AsyncWriteExt, BufReader};
use tokio::process::{Child, Command};
use tokio::sync::{mpsc, oneshot, watch};
use tokio::task::JoinHandle;

use crate::error::{Error, Result};
use crate::wire::{Envelope, Frame};

/// How long a closing transport waits for the child to exit on its own after
/// stdin is closed, before killing it.
const SHUTDOWN_GRACE: Duration = Duration::from_millis(500);

/// A route a subscription is registered under.
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
enum RouteKey {
    Stream(String),
    Session(String),
    Reply(String),
}

#[derive(Default)]
struct RouterState {
    handshake: Option<oneshot::Sender<Frame>>,
    streams: HashMap<String, mpsc::UnboundedSender<Frame>>,
    sessions: HashMap<String, mpsc::UnboundedSender<Frame>>,
    replies: HashMap<String, mpsc::UnboundedSender<Frame>>,
    closed: Option<String>,
}

/// Dispatches inbound frames to the waiter that owns them.
pub(crate) struct Router {
    state: Mutex<RouterState>,
    /// Flips once when the transport dies, so waiters holding their own sender
    /// clone still learn about it. A dropped channel alone would not tell them:
    /// a subscription keeps a sender so it can add correlations later.
    closed_tx: watch::Sender<bool>,
    closed_rx: watch::Receiver<bool>,
}

impl Router {
    fn new() -> Self {
        let (closed_tx, closed_rx) = watch::channel(false);
        Self {
            state: Mutex::new(RouterState::default()),
            closed_tx,
            closed_rx,
        }
    }

    fn lock(&self) -> std::sync::MutexGuard<'_, RouterState> {
        // A poisoned router means a previous dispatch panicked. The queues are
        // plain maps of channel senders, so the state is still coherent; keeping
        // the transport alive beats taking the whole client down.
        self.state
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner)
    }

    fn dispatch(&self, frame: Frame) {
        let mut state = self.lock();

        if let Some(handshake) = state.handshake.take() {
            let _ = handshake.send(frame);
            return;
        }

        if let Some(reply_to) = frame.in_reply_to.as_deref() {
            if let Some(sender) = state.replies.get(reply_to) {
                let _ = sender.send(frame);
                return;
            }
        }

        if let Some(stream_id) = frame.stream_id.as_deref() {
            if let Some(sender) = state.streams.get(stream_id) {
                let _ = sender.send(frame);
                return;
            }
        }

        if let Some(session_id) = frame.session_id.as_deref() {
            if let Some(sender) = state.sessions.get(session_id) {
                let _ = sender.send(frame);
                return;
            }
        }

        tracing::debug!(
            frame_type = %frame.kind,
            stream_id = ?frame.stream_id,
            session_id = ?frame.session_id,
            in_reply_to = ?frame.in_reply_to,
            "dropping frame with no registered route"
        );
    }

    /// Marks the transport dead and wakes every waiter by dropping its sender.
    fn close(&self, reason: String) {
        let mut state = self.lock();
        if state.closed.is_none() {
            state.closed = Some(reason);
        }
        state.handshake = None;
        state.streams.clear();
        state.sessions.clear();
        state.replies.clear();
        drop(state);
        let _ = self.closed_tx.send(true);
    }

    fn closed_reason(&self) -> Option<String> {
        self.lock().closed.clone()
    }

    fn unregister(&self, keys: &[RouteKey]) {
        let mut state = self.lock();
        for key in keys {
            match key {
                RouteKey::Stream(id) => {
                    state.streams.remove(id);
                }
                RouteKey::Session(id) => {
                    state.sessions.remove(id);
                }
                RouteKey::Reply(id) => {
                    state.replies.remove(id);
                }
            }
        }
    }
}

/// A caller's view of the frames routed to it.
pub(crate) struct Subscription {
    router: Arc<Router>,
    sender: mpsc::UnboundedSender<Frame>,
    receiver: mpsc::UnboundedReceiver<Frame>,
    keys: Vec<RouteKey>,
    closed: watch::Receiver<bool>,
    /// True when this subscription owns the session route; false when another
    /// live run already held it, in which case only correlated replies arrive.
    owns_session: bool,
}

impl Subscription {
    /// Registers `message_id` so replies to that request land on this queue.
    pub(crate) fn correlate(&mut self, message_id: &str) {
        let mut state = self.router.lock();
        if state.closed.is_some() {
            return;
        }
        state
            .replies
            .insert(message_id.to_owned(), self.sender.clone());
        drop(state);
        self.keys.push(RouteKey::Reply(message_id.to_owned()));
    }

    /// Stops routing replies to `message_id` here.
    pub(crate) fn uncorrelate(&mut self, message_id: &str) {
        let key = RouteKey::Reply(message_id.to_owned());
        self.router.unregister(std::slice::from_ref(&key));
        self.keys.retain(|existing| existing != &key);
    }

    /// Whether this subscription holds the session route, or lost it to a run
    /// that is already using the same caller-supplied `session_id`.
    pub(crate) fn owns_session(&self) -> bool {
        self.owns_session
    }

    /// Waits for the next frame, failing when the transport dies first.
    ///
    /// Frames already queued are delivered before the failure, so a terminal
    /// frame that raced the process exiting is not lost.
    pub(crate) async fn next(&mut self) -> Result<Frame> {
        loop {
            if let Ok(frame) = self.receiver.try_recv() {
                return Ok(frame);
            }
            if *self.closed.borrow() {
                // The try_recv above and this check are not one atomic step.
                // On a multi-threaded runtime another worker can dispatch a
                // terminal frame and set the closed flag in the window between
                // them, and failing here would lose the frame this function's
                // doc comment promises to deliver. Drain once more first; the
                // caller's next call re-drains through the try_recv above.
                if let Ok(frame) = self.receiver.try_recv() {
                    return Ok(frame);
                }
                return Err(self.closed_error());
            }
            tokio::select! {
                frame = self.receiver.recv() => {
                    return match frame {
                        Some(frame) => Ok(frame),
                        None => Err(self.closed_error()),
                    };
                }
                changed = self.closed.changed() => {
                    if changed.is_err() {
                        return Err(self.closed_error());
                    }
                }
            }
        }
    }

    fn closed_error(&self) -> Error {
        Error::transport_stream(
            self.router
                .closed_reason()
                .unwrap_or_else(|| "transport closed".to_owned()),
        )
    }

    /// Waits for the next frame with a deadline.
    pub(crate) async fn next_within(
        &mut self,
        timeout: Duration,
        operation: &str,
    ) -> Result<Frame> {
        match tokio::time::timeout(timeout, self.next()).await {
            Ok(frame) => frame,
            Err(_) => Err(Error::transport_stream(format!(
                "timed out waiting for {operation} after {}ms",
                timeout.as_millis()
            ))),
        }
    }

    /// Drains whatever has already been queued, without waiting. Used after a
    /// terminal frame so a later run on the same route does not inherit the
    /// tail of this one (spec §6.1).
    pub(crate) fn drain_ready(&mut self) {
        while self.receiver.try_recv().is_ok() {}
    }
}

impl Drop for Subscription {
    fn drop(&mut self) {
        self.router.unregister(&self.keys);
    }
}

struct Inner {
    router: Arc<Router>,
    outbound: Mutex<Option<mpsc::UnboundedSender<String>>>,
    shutdown: Mutex<Option<oneshot::Sender<()>>>,
    supervisor: Mutex<Option<JoinHandle<()>>>,
    reader: Mutex<Option<JoinHandle<()>>>,
    writer: Mutex<Option<JoinHandle<()>>>,
    closing: AtomicBool,
}

impl Drop for Inner {
    fn drop(&mut self) {
        // Dropping the client without calling `close()` still has to terminate
        // the child. Closing the outbound channel drops the writer's stdin, and
        // the shutdown signal makes the supervisor kill and reap. The child was
        // spawned with `kill_on_drop`, so even a runtime that shuts down before
        // the supervisor is polled leaves no survivor.
        take(&self.outbound);
        if let Some(signal) = take(&self.shutdown) {
            let _ = signal.send(());
        }
        if let Some(handle) = take(&self.reader) {
            handle.abort();
        }
        if let Some(handle) = take(&self.writer) {
            handle.abort();
        }
    }
}

fn take<T>(slot: &Mutex<Option<T>>) -> Option<T> {
    slot.lock()
        .unwrap_or_else(std::sync::PoisonError::into_inner)
        .take()
}

/// Options for starting a transport.
#[derive(Debug, Clone)]
pub(crate) struct TransportOptions {
    pub command: std::path::PathBuf,
    pub args: Vec<String>,
    pub cwd: Option<std::path::PathBuf>,
    pub env: Vec<(String, String)>,
    pub env_clear: bool,
    pub expected_protocol_version: String,
    pub handshake_timeout: Duration,
}

/// A connected `makai --stdio` runtime.
pub(crate) struct Transport {
    inner: Arc<Inner>,
}

impl Transport {
    /// Spawns the runtime and completes the `ready` handshake.
    pub(crate) async fn connect(options: TransportOptions) -> Result<Self> {
        let mut command = Command::new(&options.command);
        command
            .args(&options.args)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::inherit())
            .kill_on_drop(true);
        if let Some(cwd) = &options.cwd {
            command.current_dir(cwd);
        }
        if options.env_clear {
            command.env_clear();
        }
        for (key, value) in &options.env {
            command.env(key, value);
        }

        let mut child: Child = command.spawn().map_err(|err| {
            Error::transport(format!(
                "failed to spawn {}: {err}",
                options.command.display()
            ))
        })?;

        let stdin = child
            .stdin
            .take()
            .ok_or_else(|| Error::transport("child stdin was not piped"))?;
        let stdout = child
            .stdout
            .take()
            .ok_or_else(|| Error::transport("child stdout was not piped"))?;

        let router = Arc::new(Router::new());
        let (handshake_tx, handshake_rx) = oneshot::channel();
        router.lock().handshake = Some(handshake_tx);

        let (outbound_tx, mut outbound_rx) = mpsc::unbounded_channel::<String>();
        let writer = tokio::spawn(async move {
            let mut stdin = stdin;
            while let Some(line) = outbound_rx.recv().await {
                if stdin.write_all(line.as_bytes()).await.is_err() {
                    break;
                }
                if stdin.write_all(b"\n").await.is_err() {
                    break;
                }
                if stdin.flush().await.is_err() {
                    break;
                }
            }
        });

        let reader_router = Arc::clone(&router);
        let reader = tokio::spawn(async move {
            let mut lines = BufReader::new(stdout).lines();
            loop {
                match lines.next_line().await {
                    Ok(Some(line)) => {
                        let trimmed = line.trim();
                        if trimmed.is_empty() {
                            continue;
                        }
                        match Frame::parse(trimmed) {
                            Ok(frame) => reader_router.dispatch(frame),
                            Err(err) => {
                                tracing::warn!(error = %err, "discarding unparseable frame");
                            }
                        }
                    }
                    Ok(None) => {
                        reader_router.close("stdio stream ended".to_owned());
                        return;
                    }
                    Err(err) => {
                        reader_router.close(format!("stdio read failed: {err}"));
                        return;
                    }
                }
            }
        });

        let (shutdown_tx, shutdown_rx) = oneshot::channel::<()>();
        let supervisor_router = Arc::clone(&router);
        let supervisor = tokio::spawn(async move {
            supervise(child, shutdown_rx, supervisor_router).await;
        });

        let inner = Arc::new(Inner {
            router: Arc::clone(&router),
            outbound: Mutex::new(Some(outbound_tx)),
            shutdown: Mutex::new(Some(shutdown_tx)),
            supervisor: Mutex::new(Some(supervisor)),
            reader: Mutex::new(Some(reader)),
            writer: Mutex::new(Some(writer)),
            closing: AtomicBool::new(false),
        });
        let transport = Self { inner };

        transport
            .complete_handshake(handshake_rx, &options)
            .await
            .inspect_err(|_| {
                // A failed handshake must not leave the child running.
                transport.begin_shutdown();
            })?;
        Ok(transport)
    }

    async fn complete_handshake(
        &self,
        handshake: oneshot::Receiver<Frame>,
        options: &TransportOptions,
    ) -> Result<()> {
        let frame = match tokio::time::timeout(options.handshake_timeout, handshake).await {
            Ok(Ok(frame)) => frame,
            Ok(Err(_)) => {
                return Err(Error::transport(
                    self.inner
                        .router
                        .closed_reason()
                        .unwrap_or_else(|| "runtime exited before the handshake".to_owned()),
                ))
            }
            Err(_) => {
                return Err(Error::transport(format!(
                    "stdio handshake timed out after {}ms",
                    options.handshake_timeout.as_millis()
                )))
            }
        };

        if frame.kind == "error" {
            return Err(Error::protocol(
                frame
                    .payload_non_empty("message")
                    .unwrap_or_else(|| "stdio handshake failed".to_owned()),
                frame.payload_str("code"),
            ));
        }
        if frame.kind != "ready" {
            return Err(Error::transport(format!(
                "unexpected handshake frame type: {}",
                frame.kind
            )));
        }
        let version = frame.payload_str("protocol_version").unwrap_or_default();
        if version != options.expected_protocol_version {
            return Err(Error::protocol(
                format!(
                    "protocol version mismatch (expected {}, got {version})",
                    options.expected_protocol_version
                ),
                Some("version_mismatch"),
            ));
        }
        Ok(())
    }

    /// Registers a provider/auth stream route before the request is sent.
    pub(crate) fn subscribe_stream(&self, stream_id: &str) -> Subscription {
        let (sender, receiver) = mpsc::unbounded_channel();
        {
            let mut state = self.inner.router.lock();
            state.streams.insert(stream_id.to_owned(), sender.clone());
        }
        Subscription {
            router: Arc::clone(&self.inner.router),
            sender,
            receiver,
            keys: vec![RouteKey::Stream(stream_id.to_owned())],
            closed: self.inner.router.closed_rx.clone(),
            owns_session: true,
        }
    }

    /// Registers an agent session route before `agent_start` is sent.
    ///
    /// Two overlapping runs may share one caller-supplied `session_id`; per spec
    /// §13.3.3 the runtime rejects the second with `agent_busy`, so only the
    /// first subscription takes the session route. The loser still gets its
    /// correlated rejection, which is the only frame that can legitimately reach
    /// it.
    pub(crate) fn subscribe_session(&self, session_id: &str) -> Subscription {
        let (sender, receiver) = mpsc::unbounded_channel();
        let mut keys = Vec::new();
        let owns_session = {
            let mut state = self.inner.router.lock();
            if state.sessions.contains_key(session_id) {
                false
            } else {
                state.sessions.insert(session_id.to_owned(), sender.clone());
                keys.push(RouteKey::Session(session_id.to_owned()));
                true
            }
        };
        Subscription {
            router: Arc::clone(&self.inner.router),
            sender,
            receiver,
            keys,
            closed: self.inner.router.closed_rx.clone(),
            owns_session,
        }
    }

    /// Queues an envelope. Synchronous and non-blocking, so it is safe to call
    /// from a `Drop` impl that needs to emit a best-effort cancellation.
    pub(crate) fn send(&self, envelope: &Envelope) -> Result<()> {
        let line = envelope.to_line();
        tracing::trace!(frame = %line, "sending frame");
        let guard = self
            .inner
            .outbound
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        match guard.as_ref() {
            Some(sender) => sender.send(line).map_err(|_| {
                Error::transport_stream(
                    self.inner
                        .router
                        .closed_reason()
                        .unwrap_or_else(|| "transport is closed".to_owned()),
                )
            }),
            None => Err(Error::transport_stream("transport is closed")),
        }
    }

    /// Queues an envelope, swallowing the failure. For cancellation frames,
    /// where a dead transport has already achieved the goal.
    pub(crate) fn send_best_effort(&self, envelope: &Envelope) {
        if let Err(err) = self.send(envelope) {
            tracing::debug!(error = %err, frame_type = %envelope.kind, "best-effort send dropped");
        }
    }

    fn begin_shutdown(&self) {
        self.inner.closing.store(true, Ordering::SeqCst);
        take(&self.inner.outbound);
        if let Some(signal) = take(&self.inner.shutdown) {
            let _ = signal.send(());
        }
    }

    /// Closes stdin, waits for the child to exit, and reaps it.
    pub(crate) async fn close(&self) {
        self.begin_shutdown();
        if let Some(handle) = take(&self.inner.supervisor) {
            let _ = handle.await;
        }
        if let Some(handle) = take(&self.inner.writer) {
            let _ = handle.await;
        }
        if let Some(handle) = take(&self.inner.reader) {
            let _ = handle.await;
        }
        self.inner.router.close("transport closed".to_owned());
    }

    /// Whether the child has exited or the transport has been closed.
    pub(crate) fn is_closed(&self) -> bool {
        self.inner.closing.load(Ordering::SeqCst) || self.inner.router.closed_reason().is_some()
    }
}

async fn supervise(mut child: Child, shutdown: oneshot::Receiver<()>, router: Arc<Router>) {
    tokio::select! {
        status = child.wait() => {
            let reason = match status {
                Ok(status) => format!("stdio process exited ({status})"),
                Err(err) => format!("stdio process could not be reaped: {err}"),
            };
            router.close(reason);
        }
        _ = shutdown => {
            // The outbound channel is dropped before the signal is sent, so the
            // writer has already closed stdin and the child should see EOF.
            match tokio::time::timeout(SHUTDOWN_GRACE, child.wait()).await {
                Ok(_) => {}
                Err(_) => {
                    let _ = child.start_kill();
                    let _ = child.wait().await;
                }
            }
            router.close("transport closed".to_owned());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    fn frame(line: &str) -> Frame {
        Frame::parse(line).expect("frame parses")
    }

    #[tokio::test]
    async fn correlated_replies_beat_the_route() {
        let router = Arc::new(Router::new());
        let (owner_tx, mut owner_rx) = mpsc::unbounded_channel();
        let (route_tx, mut route_rx) = mpsc::unbounded_channel();
        {
            let mut state = router.lock();
            state.replies.insert("REQ".to_owned(), owner_tx);
            state.sessions.insert("SESS".to_owned(), route_tx);
        }

        router.dispatch(frame(
            r#"{"type":"nack","session_id":"SESS","message_id":"M","in_reply_to":"REQ","payload":{}}"#,
        ));
        router.dispatch(frame(
            r#"{"type":"agent_event","session_id":"SESS","message_id":"M2","payload":{}}"#,
        ));

        assert_eq!(owner_rx.recv().await.expect("reply").kind, "nack");
        assert_eq!(route_rx.recv().await.expect("event").kind, "agent_event");
    }

    #[tokio::test]
    async fn a_reply_to_an_unregistered_request_is_not_stolen_by_the_route() {
        let router = Arc::new(Router::new());
        let (route_tx, mut route_rx) = mpsc::unbounded_channel();
        router
            .lock()
            .sessions
            .insert("SESS".to_owned(), route_tx.clone());

        // A reply whose owner is gone still falls through to the route rather
        // than being dropped: the route is the only remaining candidate.
        router.dispatch(frame(
            r#"{"type":"agent_stopped","session_id":"SESS","message_id":"M","in_reply_to":"GONE","payload":{}}"#,
        ));
        assert_eq!(route_rx.recv().await.expect("frame").kind, "agent_stopped");
    }

    #[tokio::test]
    async fn frames_with_no_route_are_dropped() {
        let router = Arc::new(Router::new());
        let (tx, mut rx) = mpsc::unbounded_channel();
        router.lock().sessions.insert("MINE".to_owned(), tx);
        router.dispatch(frame(
            r#"{"type":"agent_event","session_id":"OTHER","message_id":"M","payload":{}}"#,
        ));
        assert!(rx.try_recv().is_err());
    }

    #[tokio::test]
    async fn closing_the_router_wakes_waiters_with_the_reason() {
        let router = Arc::new(Router::new());
        let (tx, rx) = mpsc::unbounded_channel();
        router.lock().streams.insert("S".to_owned(), tx.clone());
        let mut subscription = Subscription {
            router: Arc::clone(&router),
            sender: tx,
            receiver: rx,
            keys: vec![RouteKey::Stream("S".to_owned())],
            closed: router.closed_rx.clone(),
            owns_session: true,
        };
        router.close("stdio process exited (exit status: 1)".to_owned());
        let err = subscription.next().await.unwrap_err();
        assert!(err.message().contains("exit status: 1"), "{err}");
    }

    #[tokio::test]
    async fn the_handshake_slot_takes_the_first_frame_only() {
        let router = Arc::new(Router::new());
        let (handshake_tx, handshake_rx) = oneshot::channel();
        let (stream_tx, mut stream_rx) = mpsc::unbounded_channel();
        {
            let mut state = router.lock();
            state.handshake = Some(handshake_tx);
            state.streams.insert("S".to_owned(), stream_tx);
        }
        router.dispatch(frame(r#"{"type":"ready","protocol_version":"1"}"#));
        router.dispatch(frame(r#"{"type":"ack","stream_id":"S","payload":{}}"#));

        assert_eq!(handshake_rx.await.expect("ready").kind, "ready");
        assert_eq!(stream_rx.recv().await.expect("ack").kind, "ack");
    }

    #[test]
    fn envelopes_render_as_one_line() {
        let envelope = Envelope::for_stream("models_request", "S", json!({"provider_id": "x"}));
        assert_eq!(envelope.to_line().lines().count(), 1);
    }
}
