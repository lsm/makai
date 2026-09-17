package makai

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"log/slog"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
)

// Environment variables that steer binary resolution. Each takes precedence
// over the equivalent [Options] field, matching the TypeScript SDK.
const (
	// EnvBinaryPath points at a specific runtime binary.
	EnvBinaryPath = "MAKAI_BINARY_PATH"
	// EnvBinaryURL downloads the runtime from a URL.
	EnvBinaryURL = "MAKAI_BINARY_URL"
	// EnvBinarySHA256 is the required checksum for EnvBinaryURL.
	EnvBinarySHA256 = "MAKAI_BINARY_SHA256"
)

// ResolveBinary locates the makai runtime, in this order:
//
//  1. MAKAI_BINARY_PATH, else [Options].BinaryPath.
//  2. MAKAI_BINARY_URL (else [Options].BinaryURL), which requires a SHA-256
//     checksum from MAKAI_BINARY_SHA256 or [Options].ChecksumSHA256. The
//     binary is cached and its checksum verified on every use.
//  3. ./zig-out/bin/makai
//  4. ./zig/zig-out/bin/makai
//  5. makai on PATH.
//
// The TypeScript SDK has one more step between 2 and 3: an optional
// @makai/cli-<platform>-<arch> npm package. That step is npm-specific and has
// no Go equivalent, so it is deliberately absent here. The practical effect
// is that a local build under ./zig-out is picked up in Go where npm would
// have preferred the packaged binary.
//
// Note that the environment variables win over the equivalent Options fields
// rather than the other way around. This mirrors the TypeScript resolver, so
// the same MAKAI_BINARY_PATH override steers both SDKs identically.
func ResolveBinary(ctx context.Context, opts *Options) (string, error) {
	if opts == nil {
		opts = &Options{}
	}
	logger := opts.logger()

	if explicit := firstNonEmpty(os.Getenv(EnvBinaryPath), opts.BinaryPath); explicit != "" {
		resolved, err := filepath.Abs(explicit)
		if err != nil {
			return "", fmt.Errorf("makai: cannot resolve binary path %q: %w", explicit, err)
		}
		if err := checkExecutable(resolved); err != nil {
			return "", err
		}
		logger.Debug("makai: binary resolved from explicit path", "path", resolved)
		return resolved, nil
	}

	binaryURL := firstNonEmpty(os.Getenv(EnvBinaryURL), opts.BinaryURL)
	if binaryURL != "" {
		checksum := firstNonEmpty(os.Getenv(EnvBinarySHA256), opts.ChecksumSHA256)
		if checksum == "" {
			return "", fmt.Errorf("%w: %s", ErrChecksumRequired, binaryURL)
		}
		return resolveFromURL(ctx, binaryURL, strings.ToLower(checksum), opts.CacheDir, logger)
	}

	for _, candidate := range localCandidates() {
		if err := checkExecutable(candidate); err == nil {
			logger.Debug("makai: binary resolved from local build", "path", candidate)
			return candidate, nil
		}
	}

	name := binaryName()
	found, err := exec.LookPath(name)
	if err != nil {
		return "", fmt.Errorf("%w: no %s on PATH and no local build under %s",
			ErrBinaryNotFound, name, strings.Join(localCandidates(), " or "))
	}
	logger.Debug("makai: binary resolved from PATH", "path", found)
	return found, nil
}

func localCandidates() []string {
	name := binaryName()
	cwd, err := os.Getwd()
	if err != nil {
		return nil
	}
	return []string{
		filepath.Join(cwd, "zig-out", "bin", name),
		filepath.Join(cwd, "zig", "zig-out", "bin", name),
	}
}

func binaryName() string {
	if runtime.GOOS == "windows" {
		return "makai.exe"
	}
	return "makai"
}

// resolveFromURL returns a cached copy of the binary at rawURL, downloading
// it when the cache is empty and re-downloading when a cached copy fails its
// checksum.
func resolveFromURL(ctx context.Context, rawURL, checksum, cacheDir string, logger *slog.Logger) (string, error) {
	parsed, err := url.Parse(rawURL)
	if err != nil {
		return "", fmt.Errorf("makai: invalid binary URL %q: %w", rawURL, err)
	}
	if cacheDir == "" {
		cacheDir, err = defaultCacheDir()
		if err != nil {
			return "", err
		}
	}
	fileName := filepath.Base(parsed.Path)
	if fileName == "" || fileName == "." || fileName == string(filepath.Separator) {
		fileName = binaryName()
	}
	cachePath := filepath.Join(cacheDir, fileName)

	if _, err := os.Stat(cachePath); err == nil {
		if verifyErr := verifyChecksum(cachePath, checksum); verifyErr == nil {
			logger.Debug("makai: cached binary checksum verified", "path", cachePath)
			return cachePath, nil
		} else if !errors.Is(verifyErr, ErrChecksumMismatch) {
			return "", verifyErr
		}
		logger.Warn("makai: cached binary checksum mismatch, re-downloading", "path", cachePath)
		if err := os.Remove(cachePath); err != nil && !errors.Is(err, fs.ErrNotExist) {
			return "", fmt.Errorf("makai: cannot evict cached binary %q: %w", cachePath, err)
		}
	} else if !errors.Is(err, fs.ErrNotExist) {
		return "", fmt.Errorf("makai: cannot inspect cached binary %q: %w", cachePath, err)
	}

	logger.Debug("makai: downloading binary", "url", rawURL, "target", cachePath)
	if err := downloadToCache(ctx, rawURL, cachePath, checksum); err != nil {
		return "", err
	}
	logger.Info("makai: binary download complete", "path", cachePath, "sha256", checksum)
	return cachePath, nil
}

func downloadToCache(ctx context.Context, rawURL, targetPath, checksum string) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, rawURL, nil)
	if err != nil {
		return fmt.Errorf("makai: cannot build binary download request: %w", err)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return fmt.Errorf("makai: cannot download binary from %s: %w", rawURL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("makai: cannot download binary from %s: %s", rawURL, resp.Status)
	}

	if err := os.MkdirAll(filepath.Dir(targetPath), 0o755); err != nil {
		return fmt.Errorf("makai: cannot create binary cache directory: %w", err)
	}
	temp, err := os.CreateTemp(filepath.Dir(targetPath), filepath.Base(targetPath)+".*.partial")
	if err != nil {
		return fmt.Errorf("makai: cannot create temporary download file: %w", err)
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)

	digest := sha256.New()
	if _, err := io.Copy(io.MultiWriter(temp, digest), resp.Body); err != nil {
		temp.Close()
		return fmt.Errorf("makai: binary download failed: %w", err)
	}
	if err := temp.Close(); err != nil {
		return fmt.Errorf("makai: binary download failed: %w", err)
	}

	actual := hex.EncodeToString(digest.Sum(nil))
	if actual != checksum {
		return fmt.Errorf("%w: expected %s, got %s", ErrChecksumMismatch, checksum, actual)
	}
	if runtime.GOOS != "windows" {
		if err := os.Chmod(tempPath, 0o755); err != nil {
			return fmt.Errorf("makai: cannot make downloaded binary executable: %w", err)
		}
	}
	if err := os.Rename(tempPath, targetPath); err != nil {
		return fmt.Errorf("makai: cannot install downloaded binary: %w", err)
	}
	return nil
}

func verifyChecksum(path, checksum string) error {
	file, err := os.Open(path)
	if err != nil {
		return fmt.Errorf("makai: cannot read binary %q: %w", path, err)
	}
	defer file.Close()

	digest := sha256.New()
	if _, err := io.Copy(digest, file); err != nil {
		return fmt.Errorf("makai: cannot read binary %q: %w", path, err)
	}
	actual := hex.EncodeToString(digest.Sum(nil))
	if actual != checksum {
		return fmt.Errorf("%w: expected %s, got %s", ErrChecksumMismatch, checksum, actual)
	}
	return nil
}

func checkExecutable(path string) error {
	info, err := os.Stat(path)
	if err != nil {
		if errors.Is(err, fs.ErrNotExist) {
			return fmt.Errorf("%w: %s", ErrBinaryNotFound, path)
		}
		return fmt.Errorf("makai: cannot inspect binary %q: %w", path, err)
	}
	if info.IsDir() {
		return fmt.Errorf("%w: %s is a directory", ErrBinaryNotFound, path)
	}
	return nil
}

func defaultCacheDir() (string, error) {
	base, err := os.UserCacheDir()
	if err != nil {
		return "", fmt.Errorf("makai: cannot determine a binary cache directory: %w", err)
	}
	return filepath.Join(base, "makai", "bin"), nil
}

func firstNonEmpty(values ...string) string {
	for _, value := range values {
		if value != "" {
			return value
		}
	}
	return ""
}
