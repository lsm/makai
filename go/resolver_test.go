package makai

import (
	"context"
	"crypto/sha256"
	"encoding/hex"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// writeFakeBinary creates an executable file and returns its path.
func writeFakeBinary(t *testing.T, dir, name, content string) string {
	t.Helper()
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(content), 0o755); err != nil {
		t.Fatal(err)
	}
	return path
}

// chdir moves the process into dir for the duration of the test.
//
// testing.T.Chdir would do this, but it needs Go 1.24 and the module targets
// 1.23 so consumers on the older toolchain can still build the SDK.
func chdir(t *testing.T, dir string) {
	t.Helper()
	previous, err := os.Getwd()
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chdir(dir); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() {
		if err := os.Chdir(previous); err != nil {
			t.Fatal(err)
		}
	})
}

// isolateResolverEnv clears every resolver variable so a developer's own
// MAKAI_BINARY_PATH cannot leak into these tests.
func isolateResolverEnv(t *testing.T) {
	t.Helper()
	t.Setenv(EnvBinaryPath, "")
	t.Setenv(EnvBinaryURL, "")
	t.Setenv(EnvBinarySHA256, "")
}

func TestResolveBinaryUsesTheExplicitPath(t *testing.T) {
	isolateResolverEnv(t)
	path := writeFakeBinary(t, t.TempDir(), "makai", "#!/bin/sh\n")

	resolved, err := ResolveBinary(context.Background(), &Options{BinaryPath: path})
	if err != nil {
		t.Fatalf("ResolveBinary: %v", err)
	}
	if resolved != path {
		t.Errorf("resolved = %q, want %q", resolved, path)
	}
}

func TestResolveBinaryEnvironmentOverridesTheOption(t *testing.T) {
	// The environment deliberately wins, so one MAKAI_BINARY_PATH steers
	// this SDK and the TypeScript SDK identically.
	isolateResolverEnv(t)
	dir := t.TempDir()
	fromEnv := writeFakeBinary(t, dir, "from-env", "#!/bin/sh\n")
	fromOption := writeFakeBinary(t, dir, "from-option", "#!/bin/sh\n")
	t.Setenv(EnvBinaryPath, fromEnv)

	resolved, err := ResolveBinary(context.Background(), &Options{BinaryPath: fromOption})
	if err != nil {
		t.Fatalf("ResolveBinary: %v", err)
	}
	if resolved != fromEnv {
		t.Errorf("resolved = %q, want the environment's %q", resolved, fromEnv)
	}
}

func TestResolveBinaryRejectsAMissingExplicitPath(t *testing.T) {
	isolateResolverEnv(t)

	_, err := ResolveBinary(context.Background(), &Options{
		BinaryPath: filepath.Join(t.TempDir(), "absent"),
	})
	if !errors.Is(err, ErrBinaryNotFound) {
		t.Fatalf("expected ErrBinaryNotFound, got %v", err)
	}
}

func TestResolveBinaryRejectsADirectory(t *testing.T) {
	isolateResolverEnv(t)

	_, err := ResolveBinary(context.Background(), &Options{BinaryPath: t.TempDir()})
	if !errors.Is(err, ErrBinaryNotFound) {
		t.Fatalf("expected ErrBinaryNotFound, got %v", err)
	}
}

func TestResolveBinaryRequiresAChecksumForURLs(t *testing.T) {
	isolateResolverEnv(t)

	_, err := ResolveBinary(context.Background(), &Options{
		BinaryURL: "https://example.invalid/makai",
	})
	if !errors.Is(err, ErrChecksumRequired) {
		t.Fatalf("expected ErrChecksumRequired, got %v", err)
	}
}

func TestResolveBinaryDownloadsAndVerifies(t *testing.T) {
	isolateResolverEnv(t)
	payload := []byte("#!/bin/sh\necho makai\n")
	digest := sha256.Sum256(payload)
	checksum := hex.EncodeToString(digest[:])

	var requests int
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		requests++
		w.Write(payload)
	}))
	defer server.Close()

	cacheDir := t.TempDir()
	opts := &Options{
		BinaryURL:      server.URL + "/dist/makai",
		ChecksumSHA256: strings.ToUpper(checksum),
		CacheDir:       cacheDir,
	}

	resolved, err := ResolveBinary(context.Background(), opts)
	if err != nil {
		t.Fatalf("ResolveBinary: %v", err)
	}
	if want := filepath.Join(cacheDir, "makai"); resolved != want {
		t.Errorf("resolved = %q, want %q", resolved, want)
	}
	if runtime.GOOS != "windows" {
		info, err := os.Stat(resolved)
		if err != nil {
			t.Fatal(err)
		}
		if info.Mode().Perm()&0o111 == 0 {
			t.Errorf("downloaded binary is not executable: %s", info.Mode())
		}
	}

	// A second resolution verifies the cache instead of downloading again.
	if _, err := ResolveBinary(context.Background(), opts); err != nil {
		t.Fatalf("second ResolveBinary: %v", err)
	}
	if requests != 1 {
		t.Errorf("made %d requests, want 1: the cache was not reused", requests)
	}

	// No partial files are left behind.
	entries, err := os.ReadDir(cacheDir)
	if err != nil {
		t.Fatal(err)
	}
	for _, entry := range entries {
		if strings.Contains(entry.Name(), "partial") {
			t.Errorf("temporary download file %q was left behind", entry.Name())
		}
	}
}

func TestResolveBinaryRejectsAChecksumMismatch(t *testing.T) {
	isolateResolverEnv(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("not what you asked for"))
	}))
	defer server.Close()

	_, err := ResolveBinary(context.Background(), &Options{
		BinaryURL:      server.URL + "/makai",
		ChecksumSHA256: strings.Repeat("ab", 32),
		CacheDir:       t.TempDir(),
	})
	if !errors.Is(err, ErrChecksumMismatch) {
		t.Fatalf("expected ErrChecksumMismatch, got %v", err)
	}
}

func TestResolveBinaryRedownloadsAfterACacheMismatch(t *testing.T) {
	isolateResolverEnv(t)
	payload := []byte("#!/bin/sh\n")
	digest := sha256.Sum256(payload)
	checksum := hex.EncodeToString(digest[:])

	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Write(payload)
	}))
	defer server.Close()

	cacheDir := t.TempDir()
	// A stale or tampered cache entry is evicted rather than trusted.
	writeFakeBinary(t, cacheDir, "makai", "tampered")

	resolved, err := ResolveBinary(context.Background(), &Options{
		BinaryURL:      server.URL + "/makai",
		ChecksumSHA256: checksum,
		CacheDir:       cacheDir,
	})
	if err != nil {
		t.Fatalf("ResolveBinary: %v", err)
	}
	content, err := os.ReadFile(resolved)
	if err != nil {
		t.Fatal(err)
	}
	if string(content) != string(payload) {
		t.Errorf("cached content = %q, want the re-downloaded payload", content)
	}
}

func TestResolveBinaryRejectsAFailedDownload(t *testing.T) {
	isolateResolverEnv(t)
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "gone", http.StatusNotFound)
	}))
	defer server.Close()

	_, err := ResolveBinary(context.Background(), &Options{
		BinaryURL:      server.URL + "/makai",
		ChecksumSHA256: strings.Repeat("ab", 32),
		CacheDir:       t.TempDir(),
	})
	if err == nil || !strings.Contains(err.Error(), "404") {
		t.Fatalf("expected the HTTP status to be reported, got %v", err)
	}
}

func TestResolveBinaryPrefersLocalZigBuilds(t *testing.T) {
	isolateResolverEnv(t)
	workdir := t.TempDir()
	// Both local candidates exist; the first one wins.
	first := writeFakeBinary(t, filepath.Join(workdir, "zig-out", "bin"), binaryName(), "#!/bin/sh\n")
	writeFakeBinary(t, filepath.Join(workdir, "zig", "zig-out", "bin"), binaryName(), "#!/bin/sh\n")

	chdir(t, workdir)
	resolved, err := ResolveBinary(context.Background(), &Options{})
	if err != nil {
		t.Fatalf("ResolveBinary: %v", err)
	}
	// Compare resolved paths: macOS temp dirs are symlinked through /private.
	wantReal, _ := filepath.EvalSymlinks(first)
	gotReal, _ := filepath.EvalSymlinks(resolved)
	if gotReal != wantReal {
		t.Errorf("resolved = %q, want %q", gotReal, wantReal)
	}
}

func TestResolveBinaryFallsBackToTheNestedZigBuild(t *testing.T) {
	isolateResolverEnv(t)
	workdir := t.TempDir()
	nested := writeFakeBinary(t, filepath.Join(workdir, "zig", "zig-out", "bin"), binaryName(), "#!/bin/sh\n")

	chdir(t, workdir)
	resolved, err := ResolveBinary(context.Background(), &Options{})
	if err != nil {
		t.Fatalf("ResolveBinary: %v", err)
	}
	wantReal, _ := filepath.EvalSymlinks(nested)
	gotReal, _ := filepath.EvalSymlinks(resolved)
	if gotReal != wantReal {
		t.Errorf("resolved = %q, want %q", gotReal, wantReal)
	}
}

func TestResolveBinaryFallsBackToPath(t *testing.T) {
	if runtime.GOOS == "windows" {
		t.Skip("the PATH fallback uses a shell script stub")
	}
	isolateResolverEnv(t)
	pathDir := t.TempDir()
	onPath := writeFakeBinary(t, pathDir, "makai", "#!/bin/sh\n")

	// An empty working directory means no local build to prefer.
	chdir(t, t.TempDir())
	t.Setenv("PATH", pathDir)

	resolved, err := ResolveBinary(context.Background(), &Options{})
	if err != nil {
		t.Fatalf("ResolveBinary: %v", err)
	}
	wantReal, _ := filepath.EvalSymlinks(onPath)
	gotReal, _ := filepath.EvalSymlinks(resolved)
	if gotReal != wantReal {
		t.Errorf("resolved = %q, want %q", gotReal, wantReal)
	}
}

func TestResolveBinaryReportsWhenNothingIsFound(t *testing.T) {
	isolateResolverEnv(t)
	chdir(t, t.TempDir())
	t.Setenv("PATH", t.TempDir())

	_, err := ResolveBinary(context.Background(), &Options{})
	if !errors.Is(err, ErrBinaryNotFound) {
		t.Fatalf("expected ErrBinaryNotFound, got %v", err)
	}
	// The message names the candidates that were tried.
	if !strings.Contains(err.Error(), "zig-out") {
		t.Errorf("message = %q; it should name the local build candidates", err)
	}
}

func TestBinaryNameMatchesThePlatform(t *testing.T) {
	want := "makai"
	if runtime.GOOS == "windows" {
		want = "makai.exe"
	}
	if got := binaryName(); got != want {
		t.Errorf("binaryName() = %q, want %q", got, want)
	}
}
