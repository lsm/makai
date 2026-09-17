//! Locating the `makai` runtime binary.
//!
//! The order mirrors `typescript/src/binary_resolver.ts`:
//!
//! 1. an explicit path, or `MAKAI_BINARY_PATH`;
//! 2. a URL (`binary_url` / `MAKAI_BINARY_URL`) with a **required** SHA-256
//!    checksum, cached on disk;
//! 3. *(TypeScript only)* the `@makai/cli-<platform>-<arch>` npm package;
//! 4. `./zig-out/bin/makai`;
//! 5. `./zig/zig-out/bin/makai`;
//! 6. `makai` on `PATH`.
//!
//! Step 3 has no Rust counterpart and is deliberately skipped. It resolves
//! through Node's module resolution against an optional npm dependency; Rust has
//! no equivalent channel that ships a platform-specific executable alongside a
//! library crate, and inventing one (a `build.rs` download, say) would put a
//! network fetch in the build with none of the checksum guarantees step 2
//! insists on. Consumers who install the binary through a package manager should
//! point `MAKAI_BINARY_PATH` at it, or let step 6 find it on `PATH`.
//!
//! Step 2 needs the `download` feature to *fetch*. Without it, an already-cached
//! file is still verified and used, and a cache miss is a clear error rather
//! than a silent fallback — falling through to a different binary than the one
//! the caller pinned would be worse than failing.

use std::path::{Path, PathBuf};

use sha2::{Digest, Sha256};

use crate::error::{Error, Result};

const ENV_BINARY_PATH: &str = "MAKAI_BINARY_PATH";
const ENV_BINARY_URL: &str = "MAKAI_BINARY_URL";
const ENV_BINARY_SHA256: &str = "MAKAI_BINARY_SHA256";

/// How to find the runtime binary.
#[derive(Debug, Clone, Default)]
pub struct BinaryResolver {
    /// An explicit path, taking precedence over everything but the environment.
    pub binary_path: Option<PathBuf>,
    /// A URL to download from. Requires [`BinaryResolver::checksum_sha256`].
    pub binary_url: Option<String>,
    /// The expected SHA-256 of the downloaded file, lowercase hex.
    pub checksum_sha256: Option<String>,
    /// Where downloads are cached. Defaults to `~/.cache/makai/bin`.
    pub cache_dir: Option<PathBuf>,
    /// The working directory the `zig-out` candidates are resolved against.
    /// Defaults to the process's current directory.
    pub base_dir: Option<PathBuf>,
}

/// The name of the runtime executable on this platform.
fn binary_name() -> &'static str {
    if cfg!(windows) {
        "makai.exe"
    } else {
        "makai"
    }
}

fn env_var(key: &str) -> Option<String> {
    std::env::var(key).ok().filter(|value| !value.is_empty())
}

fn default_cache_dir() -> PathBuf {
    let home = env_var("HOME")
        .or_else(|| env_var("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_else(std::env::temp_dir);
    home.join(".cache").join("makai").join("bin")
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    digest.iter().map(|byte| format!("{byte:02x}")).collect()
}

async fn verify_checksum(path: &Path, expected: &str) -> Result<()> {
    let bytes = tokio::fs::read(path)
        .await
        .map_err(|err| Error::transport(format!("failed to read {}: {err}", path.display())))?;
    let actual = sha256_hex(&bytes);
    if actual != expected.to_ascii_lowercase() {
        return Err(Error::transport(format!(
            "binary checksum mismatch: expected {expected}, got {actual}"
        )));
    }
    Ok(())
}

impl BinaryResolver {
    /// Resolves the binary, returning either an absolute path or the bare
    /// command name for `PATH` lookup.
    pub async fn resolve(&self) -> Result<PathBuf> {
        if let Some(path) = env_var(ENV_BINARY_PATH)
            .map(PathBuf::from)
            .or_else(|| self.binary_path.clone())
        {
            let resolved = absolutize(&path, self.base_dir.as_deref());
            if !tokio::fs::try_exists(&resolved).await.unwrap_or(false) {
                return Err(Error::transport(format!(
                    "makai binary not found at {}",
                    resolved.display()
                )));
            }
            tracing::debug!(path = %resolved.display(), "resolved binary from explicit path");
            return Ok(resolved);
        }

        let url = env_var(ENV_BINARY_URL).or_else(|| self.binary_url.clone());
        if let Some(url) = url {
            let checksum = env_var(ENV_BINARY_SHA256)
                .or_else(|| self.checksum_sha256.clone())
                .ok_or_else(|| {
                    Error::transport(format!(
                        "a SHA-256 checksum is required when downloading the makai binary from {url}"
                    ))
                })?;
            return self.resolve_from_url(&url, &checksum).await;
        }

        let base = match &self.base_dir {
            Some(base) => base.clone(),
            None => std::env::current_dir().unwrap_or_else(|_| PathBuf::from(".")),
        };
        for candidate in [
            base.join("zig-out").join("bin").join(binary_name()),
            base.join("zig")
                .join("zig-out")
                .join("bin")
                .join(binary_name()),
        ] {
            if tokio::fs::try_exists(&candidate).await.unwrap_or(false) {
                tracing::debug!(path = %candidate.display(), "resolved binary from local build");
                return Ok(candidate);
            }
        }

        tracing::debug!(binary = binary_name(), "falling back to PATH lookup");
        Ok(PathBuf::from(binary_name()))
    }

    async fn resolve_from_url(&self, url: &str, checksum: &str) -> Result<PathBuf> {
        let cache_dir = self.cache_dir.clone().unwrap_or_else(default_cache_dir);
        let file_name = url
            .rsplit('/')
            .next()
            .map(|segment| segment.split(['?', '#']).next().unwrap_or(segment))
            .filter(|segment| !segment.is_empty())
            .unwrap_or(binary_name());
        let cache_path = cache_dir.join(file_name);

        if tokio::fs::try_exists(&cache_path).await.unwrap_or(false) {
            match verify_checksum(&cache_path, checksum).await {
                Ok(()) => {
                    // A pre-populated entry — `curl -o`, a CI cache restore, a
                    // plain file write — commonly lands at 0644, so the
                    // checksum can pass and the spawn still fail with
                    // permission denied.
                    ensure_executable(&cache_path).await?;
                    tracing::debug!(path = %cache_path.display(), "cached binary checksum verified");
                    return Ok(cache_path);
                }
                Err(err) => {
                    tracing::warn!(error = %err, path = %cache_path.display(), "cached binary rejected");
                    let _ = tokio::fs::remove_file(&cache_path).await;
                }
            }
        }

        self.download(url, &cache_path, checksum).await
    }

    #[cfg(feature = "download")]
    async fn download(&self, url: &str, target: &Path, checksum: &str) -> Result<PathBuf> {
        let response = reqwest::get(url)
            .await
            .map_err(|err| Error::transport(format!("failed to download binary: {err}")))?;
        if !response.status().is_success() {
            return Err(Error::transport(format!(
                "failed to download binary: {}",
                response.status()
            )));
        }
        let bytes = response
            .bytes()
            .await
            .map_err(|err| Error::transport(format!("failed to read downloaded binary: {err}")))?;

        let actual = sha256_hex(&bytes);
        if actual != checksum.to_ascii_lowercase() {
            return Err(Error::transport(format!(
                "binary checksum mismatch: expected {checksum}, got {actual}"
            )));
        }

        write_executable(target, &bytes).await?;
        tracing::info!(path = %target.display(), "downloaded makai binary");
        Ok(target.to_path_buf())
    }

    #[cfg(not(feature = "download"))]
    async fn download(&self, url: &str, target: &Path, _checksum: &str) -> Result<PathBuf> {
        Err(Error::transport(format!(
            "{url} is not cached at {} and this build of the makai crate cannot download it; \
             enable the `download` feature or set {ENV_BINARY_PATH}",
            target.display()
        )))
    }
}

#[cfg_attr(not(feature = "download"), allow(dead_code))]
async fn write_executable(target: &Path, bytes: &[u8]) -> Result<()> {
    if let Some(parent) = target.parent() {
        tokio::fs::create_dir_all(parent).await.map_err(|err| {
            Error::transport(format!(
                "failed to create cache directory {}: {err}",
                parent.display()
            ))
        })?;
    }
    // Two clients resolving the same uncached url would otherwise write and
    // rename one shared `<target>.tmp`: the first rename removes it and the
    // second fails, after an otherwise successful download.
    let temp = unique_temp_path(target);
    let install = async {
        tokio::fs::write(&temp, bytes).await.map_err(|err| {
            Error::transport(format!("failed to write {}: {err}", temp.display()))
        })?;
        set_executable(&temp).await?;
        tokio::fs::rename(&temp, target).await.map_err(|err| {
            Error::transport(format!(
                "failed to install {} -> {}: {err}",
                temp.display(),
                target.display()
            ))
        })
    }
    .await;
    if install.is_err() {
        let _ = tokio::fs::remove_file(&temp).await;
    }
    install
}

/// Names one download's temporary file so concurrent installs of the same
/// cache entry cannot collide on it.
#[cfg_attr(not(feature = "download"), allow(dead_code))]
fn unique_temp_path(target: &Path) -> PathBuf {
    let suffix = format!(
        "tmp.{}.{}",
        std::process::id(),
        crate::ids::new_ulid().to_ascii_lowercase()
    );
    let mut name = target.file_name().unwrap_or_default().to_os_string();
    name.push(".");
    name.push(suffix);
    target.with_file_name(name)
}

#[cfg_attr(not(feature = "download"), allow(dead_code))]
async fn set_executable(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        tokio::fs::set_permissions(path, std::fs::Permissions::from_mode(0o755))
            .await
            .map_err(|err| {
                Error::transport(format!("failed to chmod {}: {err}", path.display()))
            })?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

/// Adds the owner execute bit to an existing file when it is missing.
async fn ensure_executable(path: &Path) -> Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let metadata = tokio::fs::metadata(path)
            .await
            .map_err(|err| Error::transport(format!("failed to stat {}: {err}", path.display())))?;
        let mode = metadata.permissions().mode();
        if mode & 0o111 == 0o111 {
            return Ok(());
        }
        tokio::fs::set_permissions(path, std::fs::Permissions::from_mode(mode | 0o755))
            .await
            .map_err(|err| {
                Error::transport(format!("failed to chmod {}: {err}", path.display()))
            })?;
    }
    #[cfg(not(unix))]
    let _ = path;
    Ok(())
}

fn absolutize(path: &Path, base: Option<&Path>) -> PathBuf {
    if path.is_absolute() {
        return path.to_path_buf();
    }
    let base = base
        .map(Path::to_path_buf)
        .or_else(|| std::env::current_dir().ok())
        .unwrap_or_else(|| PathBuf::from("."));
    base.join(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The resolver reads process-wide environment variables, so the tests that
    /// depend on their absence take them away for the duration — one at a time,
    /// and restoring whatever the developer or CI had set.
    struct WithoutEnvOverrides {
        saved: Vec<(&'static str, Option<String>)>,
        _lock: std::sync::MutexGuard<'static, ()>,
    }

    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    impl WithoutEnvOverrides {
        fn new() -> Self {
            let lock = ENV_LOCK
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let saved = [ENV_BINARY_PATH, ENV_BINARY_URL, ENV_BINARY_SHA256]
                .into_iter()
                .map(|key| {
                    let previous = std::env::var(key).ok();
                    std::env::remove_var(key);
                    (key, previous)
                })
                .collect();
            Self { saved, _lock: lock }
        }
    }

    impl Drop for WithoutEnvOverrides {
        fn drop(&mut self) {
            for (key, value) in &self.saved {
                match value {
                    Some(value) => std::env::set_var(key, value),
                    None => std::env::remove_var(key),
                }
            }
        }
    }

    #[test]
    fn checksums_are_lowercase_hex() {
        assert_eq!(
            sha256_hex(b"makai"),
            // `printf 'makai' | shasum -a 256`
            "439a79bbe49c475f4732c0cf16ae14793df79123bfe09e53b1ed32e6d9f4d13c"
        );
    }

    #[tokio::test]
    async fn explicit_paths_must_exist() {
        let _env = WithoutEnvOverrides::new();
        let resolver = BinaryResolver {
            binary_path: Some(PathBuf::from("/definitely/not/here/makai")),
            ..Default::default()
        };
        let err = resolver.resolve().await.unwrap_err();
        assert!(err.message().contains("not found"), "{err}");
    }

    #[tokio::test]
    async fn urls_require_a_checksum() {
        let _env = WithoutEnvOverrides::new();
        let resolver = BinaryResolver {
            binary_url: Some("https://example.invalid/makai".to_owned()),
            ..Default::default()
        };
        let err = resolver.resolve().await.unwrap_err();
        assert!(
            err.message().contains("SHA-256 checksum is required"),
            "{err}"
        );
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn a_verified_cache_entry_is_made_executable() {
        use std::os::unix::fs::PermissionsExt;

        let _guard = WithoutEnvOverrides::new();
        let dir = tempfile::tempdir().expect("tempdir");
        let cached = dir.path().join("makai");
        let bytes = b"#!/bin/sh\nexit 0\n";
        tokio::fs::write(&cached, bytes).await.expect("write");
        tokio::fs::set_permissions(&cached, std::fs::Permissions::from_mode(0o644))
            .await
            .expect("chmod");

        let resolver = BinaryResolver {
            binary_url: Some("https://example.invalid/makai".to_owned()),
            checksum_sha256: Some(sha256_hex(bytes)),
            cache_dir: Some(dir.path().to_path_buf()),
            ..Default::default()
        };
        let resolved = resolver.resolve().await.expect("cache hit resolves");
        assert_eq!(resolved, cached);

        let mode = tokio::fs::metadata(&cached)
            .await
            .expect("stat")
            .permissions()
            .mode();
        assert_eq!(mode & 0o111, 0o111, "resolved binary must be executable");
    }

    #[test]
    fn concurrent_downloads_do_not_share_a_temporary_path() {
        let target = Path::new("/tmp/cache/makai");
        let first = unique_temp_path(target);
        let second = unique_temp_path(target);

        assert_ne!(first, second);
        assert_eq!(first.parent(), target.parent());
        assert_ne!(first, target.to_path_buf());
        assert!(
            first
                .file_name()
                .and_then(|name| name.to_str())
                .is_some_and(|name| name.starts_with("makai.tmp.")),
            "{first:?}"
        );
    }

    #[test]
    fn the_binary_name_matches_the_platform() {
        if cfg!(windows) {
            assert_eq!(binary_name(), "makai.exe");
        } else {
            assert_eq!(binary_name(), "makai");
        }
    }
}
