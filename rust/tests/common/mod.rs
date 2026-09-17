//! Shared helpers for the integration tests.

#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing,
    dead_code
)]

use std::path::PathBuf;
use std::time::Duration;

use makai::{Client, ClientBuilder};

/// The protocol fake built alongside the crate.
pub fn fake_binary() -> PathBuf {
    PathBuf::from(env!("CARGO_BIN_EXE_makai-protocol-fake"))
}

/// A client wired to the protocol fake running `scenario`.
pub fn fake_builder(scenario: &str) -> ClientBuilder {
    // `env_clear` keeps an ambient `MAKAI_BINARY_PATH` or a stale scenario from
    // the developer's shell out of the child, so a test means exactly one thing.
    ClientBuilder::new()
        .command(fake_binary())
        .args(Vec::<String>::new())
        .env_clear()
        .env("MAKAI_FAKE_SCENARIO", scenario)
        .handshake_timeout(Duration::from_millis(2_000))
        .response_timeout(Duration::from_millis(2_000))
        .frame_timeout(Duration::from_millis(2_000))
}

/// Connects a client to the protocol fake running `scenario`.
pub async fn fake_client(scenario: &str) -> Client {
    fake_builder(scenario)
        .connect()
        .await
        .expect("fake server connects")
}

/// The real `makai --stdio` binary, when `MAKAI_BINARY_PATH` names one.
///
/// Mirrors the TypeScript SDK's smoke tests: without the variable the
/// binary-backed tests skip rather than fail, so `cargo test` is green on a
/// machine with no runtime build.
pub fn real_binary() -> Option<PathBuf> {
    let path = std::env::var("MAKAI_BINARY_PATH").ok()?;
    let path = PathBuf::from(path);
    path.exists().then_some(path)
}

/// A client wired to the real runtime.
pub fn real_builder(path: &std::path::Path) -> ClientBuilder {
    let mut builder = ClientBuilder::new()
        .command(path)
        .args(["--stdio"])
        .env_clear()
        .handshake_timeout(Duration::from_millis(5_000))
        .response_timeout(Duration::from_millis(20_000))
        .frame_timeout(Duration::from_millis(20_000));
    for key in ["HOME", "PATH", "TMPDIR", "USER"] {
        if let Ok(value) = std::env::var(key) {
            builder = builder.env(key, value);
        }
    }
    // On macOS the runtime reads credentials from the login Keychain before it
    // answers anything auth-aware, and an unsigned local build blocks there
    // waiting on a GUI prompt that a test runner can never satisfy. Naming a
    // service that holds no item makes the lookup miss immediately and fall
    // through to the file store, which is what CI (Linux) uses anyway.
    builder.env("MAKAI_KEYCHAIN_SERVICE", "com.makai.auth.rust-sdk-tests")
}

/// Skips the test body unless a real runtime is available.
#[macro_export]
macro_rules! require_real_binary {
    () => {
        match $crate::common::real_binary() {
            Some(path) => path,
            None => {
                eprintln!("skipping: MAKAI_BINARY_PATH is not set");
                return;
            }
        }
    };
}

/// Whether the runtime can persist credentials without a human at the keyboard.
///
/// On macOS `saveToPreferredStorage` writes to the login Keychain, and creating
/// that item from an unsigned local build blocks in `AuthorizationCopyRights`
/// waiting on a UI prompt no test runner can answer. Everywhere else — including
/// CI, which is Linux — the file store is used and the write is unattended.
/// Set `MAKAI_RUST_SDK_ALLOW_KEYCHAIN=1` to run these anyway on a Mac where the
/// item's ACL has already been approved.
pub fn credential_writes_are_unattended() -> bool {
    !cfg!(target_os = "macos")
        || std::env::var("MAKAI_RUST_SDK_ALLOW_KEYCHAIN").as_deref() == Ok("1")
}

/// Skips the test body when the runtime would block on a credential-store prompt.
#[macro_export]
macro_rules! require_unattended_credential_store {
    () => {
        if !$crate::common::credential_writes_are_unattended() {
            eprintln!(
                "skipping: the macOS login Keychain would prompt; \
                 set MAKAI_RUST_SDK_ALLOW_KEYCHAIN=1 to run anyway"
            );
            return;
        }
    };
}

/// Reads the frames the fake recorded, in order.
pub fn read_request_log(path: &std::path::Path) -> Vec<serde_json::Value> {
    let Ok(text) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    text.lines()
        .filter(|line| !line.trim().is_empty())
        .filter_map(|line| serde_json::from_str(line).ok())
        .collect()
}

/// Waits for `predicate` to hold over the recorded frames, or gives up.
pub async fn wait_for_logged<F>(path: &std::path::Path, predicate: F) -> Vec<serde_json::Value>
where
    F: Fn(&[serde_json::Value]) -> bool,
{
    let deadline = tokio::time::Instant::now() + Duration::from_secs(3);
    loop {
        let frames = read_request_log(path);
        if predicate(&frames) {
            return frames;
        }
        if tokio::time::Instant::now() >= deadline {
            return frames;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
}

/// The `type` of each recorded frame.
pub fn frame_kinds(frames: &[serde_json::Value]) -> Vec<String> {
    frames
        .iter()
        .filter_map(|frame| frame.get("type").and_then(|kind| kind.as_str()))
        .map(str::to_owned)
        .collect()
}
