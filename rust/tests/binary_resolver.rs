//! Binary resolution order, mirroring `typescript/src/binary_resolver.ts`.

#![allow(
    clippy::unwrap_used,
    clippy::expect_used,
    clippy::panic,
    clippy::indexing_slicing
)]

use std::path::PathBuf;

use makai::BinaryResolver;

/// `MAKAI_BINARY_PATH` and friends are process-global, so the tests that touch
/// them run one at a time.
static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

struct EnvGuard {
    keys: Vec<(&'static str, Option<String>)>,
    _lock: std::sync::MutexGuard<'static, ()>,
}

impl EnvGuard {
    fn set(pairs: &[(&'static str, Option<&str>)]) -> Self {
        let lock = ENV_LOCK
            .lock()
            .unwrap_or_else(std::sync::PoisonError::into_inner);
        let mut keys = Vec::new();
        for (key, value) in pairs {
            keys.push((*key, std::env::var(key).ok()));
            match value {
                Some(value) => std::env::set_var(key, value),
                None => std::env::remove_var(key),
            }
        }
        Self { keys, _lock: lock }
    }
}

impl Drop for EnvGuard {
    fn drop(&mut self) {
        for (key, value) in &self.keys {
            match value {
                Some(value) => std::env::set_var(key, value),
                None => std::env::remove_var(key),
            }
        }
    }
}

fn clear_env() -> Vec<(&'static str, Option<&'static str>)> {
    vec![
        ("MAKAI_BINARY_PATH", None),
        ("MAKAI_BINARY_URL", None),
        ("MAKAI_BINARY_SHA256", None),
    ]
}

fn write_fake_binary(dir: &std::path::Path, relative: &[&str]) -> PathBuf {
    let mut path = dir.to_path_buf();
    for segment in relative {
        path.push(segment);
    }
    std::fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
    std::fs::write(&path, b"#!/bin/sh\nexit 0\n").expect("write");
    path
}

#[tokio::test]
async fn an_explicit_path_wins_over_local_builds() {
    let _guard = EnvGuard::set(&clear_env());
    let temp = tempfile::tempdir().expect("tempdir");
    let explicit = write_fake_binary(temp.path(), &["custom", "makai"]);
    write_fake_binary(temp.path(), &["zig-out", "bin", "makai"]);

    let resolved = BinaryResolver {
        binary_path: Some(explicit.clone()),
        base_dir: Some(temp.path().to_path_buf()),
        ..Default::default()
    }
    .resolve()
    .await
    .expect("resolves");
    assert_eq!(resolved, explicit);
}

#[tokio::test]
async fn the_environment_variable_outranks_the_explicit_option() {
    let temp = tempfile::tempdir().expect("tempdir");
    let from_env = write_fake_binary(temp.path(), &["env", "makai"]);
    let from_option = write_fake_binary(temp.path(), &["option", "makai"]);
    let mut env = clear_env();
    env[0] = ("MAKAI_BINARY_PATH", Some(from_env.to_str().expect("utf8")));
    // Leak the path so it can live in the 'static tuple the guard takes.
    let leaked: &'static str = Box::leak(from_env.to_string_lossy().into_owned().into_boxed_str());
    env[0] = ("MAKAI_BINARY_PATH", Some(leaked));
    let _guard = EnvGuard::set(&env);

    let resolved = BinaryResolver {
        binary_path: Some(from_option),
        ..Default::default()
    }
    .resolve()
    .await
    .expect("resolves");
    assert_eq!(resolved, PathBuf::from(leaked));
}

#[tokio::test]
async fn a_missing_explicit_path_is_an_error_not_a_fallback() {
    let _guard = EnvGuard::set(&clear_env());
    let temp = tempfile::tempdir().expect("tempdir");
    write_fake_binary(temp.path(), &["zig-out", "bin", "makai"]);

    let error = BinaryResolver {
        binary_path: Some(temp.path().join("nope").join("makai")),
        base_dir: Some(temp.path().to_path_buf()),
        ..Default::default()
    }
    .resolve()
    .await
    .unwrap_err();
    assert!(error.to_string().contains("not found"), "{error}");
}

#[tokio::test]
async fn local_builds_are_checked_in_order() {
    let _guard = EnvGuard::set(&clear_env());

    let temp = tempfile::tempdir().expect("tempdir");
    let nested = write_fake_binary(temp.path(), &["zig", "zig-out", "bin", "makai"]);
    let resolved = BinaryResolver {
        base_dir: Some(temp.path().to_path_buf()),
        ..Default::default()
    }
    .resolve()
    .await
    .expect("resolves");
    assert_eq!(resolved, nested, "zig/zig-out is the second candidate");

    let top = write_fake_binary(temp.path(), &["zig-out", "bin", "makai"]);
    let resolved = BinaryResolver {
        base_dir: Some(temp.path().to_path_buf()),
        ..Default::default()
    }
    .resolve()
    .await
    .expect("resolves");
    assert_eq!(resolved, top, "zig-out is the first candidate");
}

#[tokio::test]
async fn with_nothing_to_find_the_bare_command_is_returned_for_path_lookup() {
    let _guard = EnvGuard::set(&clear_env());
    let temp = tempfile::tempdir().expect("tempdir");

    let resolved = BinaryResolver {
        base_dir: Some(temp.path().to_path_buf()),
        ..Default::default()
    }
    .resolve()
    .await
    .expect("resolves");
    let expected = if cfg!(windows) { "makai.exe" } else { "makai" };
    assert_eq!(resolved, PathBuf::from(expected));
}

#[tokio::test]
async fn a_url_without_a_checksum_is_rejected() {
    let _guard = EnvGuard::set(&clear_env());
    let error = BinaryResolver {
        binary_url: Some("https://example.invalid/makai".to_owned()),
        ..Default::default()
    }
    .resolve()
    .await
    .unwrap_err();
    assert!(
        error.to_string().contains("SHA-256 checksum is required"),
        "{error}"
    );
}

#[tokio::test]
async fn a_cached_download_is_used_when_its_checksum_matches() {
    let _guard = EnvGuard::set(&clear_env());
    let temp = tempfile::tempdir().expect("tempdir");
    let cache = temp.path().join("cache");
    std::fs::create_dir_all(&cache).expect("mkdir");
    std::fs::write(cache.join("makai-darwin-arm64"), b"makai").expect("write");

    let resolved = BinaryResolver {
        binary_url: Some("https://example.invalid/releases/makai-darwin-arm64".to_owned()),
        // `printf 'makai' | shasum -a 256`
        checksum_sha256: Some(
            "439a79bbe49c475f4732c0cf16ae14793df79123bfe09e53b1ed32e6d9f4d13c".to_owned(),
        ),
        cache_dir: Some(cache.clone()),
        ..Default::default()
    }
    .resolve()
    .await
    .expect("the cached file is verified and used");
    assert_eq!(resolved, cache.join("makai-darwin-arm64"));
}

#[tokio::test]
async fn the_builder_command_bypasses_the_environment_override() {
    // `MAKAI_BINARY_PATH` outranks the resolver's `binary_path`, matching the
    // TypeScript SDK. `ClientBuilder::command` is the escape hatch for callers
    // that must pin an exact executable — a test harness, or an application
    // shipping its own runtime.
    let mut env = clear_env();
    env[0] = ("MAKAI_BINARY_PATH", Some("/definitely/not/here/makai"));
    let _guard = EnvGuard::set(&env);

    let client = makai::ClientBuilder::new()
        .command(env!("CARGO_BIN_EXE_makai-protocol-fake"))
        .args(Vec::<String>::new())
        .env_clear()
        .env("MAKAI_FAKE_SCENARIO", "ok")
        .handshake_timeout(std::time::Duration::from_millis(2_000))
        .connect()
        .await
        .expect("the pinned command is used");
    client.close().await;
}

#[tokio::test]
async fn a_cached_download_with_the_wrong_checksum_is_discarded() {
    let _guard = EnvGuard::set(&clear_env());
    let temp = tempfile::tempdir().expect("tempdir");
    let cache = temp.path().join("cache");
    std::fs::create_dir_all(&cache).expect("mkdir");
    let cached = cache.join("makai");
    std::fs::write(&cached, b"tampered").expect("write");

    let result = BinaryResolver {
        binary_url: Some("https://example.invalid/makai".to_owned()),
        checksum_sha256: Some(
            "439a79bbe49c475f4732c0cf16ae14793df79123bfe09e53b1ed32e6d9f4d13c".to_owned(),
        ),
        cache_dir: Some(cache),
        ..Default::default()
    }
    .resolve()
    .await;

    // Without the `download` feature the resolver reports the miss instead of
    // silently falling through to a different binary than the caller pinned.
    assert!(result.is_err(), "a tampered cache must not be used");
    assert!(!cached.exists(), "the rejected file is removed");
}

#[cfg(not(feature = "download"))]
#[tokio::test]
async fn without_the_download_feature_a_cache_miss_is_a_clear_error() {
    let _guard = EnvGuard::set(&clear_env());
    let temp = tempfile::tempdir().expect("tempdir");

    let error = BinaryResolver {
        binary_url: Some("https://example.invalid/makai".to_owned()),
        checksum_sha256: Some("0".repeat(64)),
        cache_dir: Some(temp.path().join("cache")),
        ..Default::default()
    }
    .resolve()
    .await
    .unwrap_err();
    assert!(error.to_string().contains("`download` feature"), "{error}");
}
