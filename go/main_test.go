package makai

import (
	"context"
	"encoding/json"
	"os"
	"runtime"
	"strings"
	"testing"
	"time"
)

// TestMain routes a re-executed test binary into the fake protocol host when
// the scenario variable is set, and otherwise runs the suite normally.
func TestMain(m *testing.M) {
	if scenario := os.Getenv(envFakeHost); scenario != "" {
		runFakeHost(scenario)
		return
	}
	os.Exit(m.Run())
}

// newTestClient starts a client whose runtime is a fake host running the
// given scenario, and registers its shutdown with the test.
func newTestClient(t *testing.T, scenario string, knobs ...string) *Client {
	t.Helper()
	client, err := newTestClientWithOptions(t, &Options{
		BinaryPath: os.Args[0],
		Args:       nil,
		Env:        fakeHostEnv(scenario, knobs...),
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	return client
}

// newTestClientWithOptions starts a client and returns New's error, for tests
// that assert on startup failures.
func newTestClientWithOptions(t *testing.T, opts *Options) (*Client, error) {
	t.Helper()
	// The fake host is the test binary itself, so it takes no runtime flags.
	if opts.Args == nil {
		opts.Args = []string{}
	}
	if opts.HandshakeTimeout == 0 {
		opts.HandshakeTimeout = 5 * time.Second
	}
	if opts.RequestTimeout == 0 {
		opts.RequestTimeout = 5 * time.Second
	}
	// MAKAI_BINARY_PATH would otherwise override the explicit path, since
	// the resolver gives the environment precedence.
	t.Setenv(EnvBinaryPath, "")
	t.Setenv(EnvBinaryURL, "")

	client, err := New(context.Background(), opts)
	if err != nil {
		return nil, err
	}
	t.Cleanup(func() {
		if err := client.Close(); err != nil {
			t.Errorf("Close: %v", err)
		}
	})
	return client, nil
}

// osArgsZero is the test binary's own path, which doubles as the fake
// runtime's command.
func osArgsZero() string { return os.Args[0] }

// testContext returns a context that is cancelled when the test ends.
func testContext(t *testing.T) context.Context {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	t.Cleanup(cancel)
	return ctx
}

// requestLogPath returns a fresh path for the fake host's request log and the
// reader that parses it.
func requestLogPath(t *testing.T) (string, func() []*frame) {
	t.Helper()
	path := t.TempDir() + "/requests.jsonl"
	return path, func() []*frame {
		raw, err := os.ReadFile(path)
		if err != nil {
			return nil
		}
		var frames []*frame
		for _, line := range strings.Split(strings.TrimSpace(string(raw)), "\n") {
			if line == "" {
				continue
			}
			var f frame
			if err := json.Unmarshal([]byte(line), &f); err != nil {
				t.Fatalf("request log line did not decode: %v", err)
			}
			f.raw = json.RawMessage(line)
			frames = append(frames, &f)
		}
		return frames
	}
}

// waitForFrameType polls the request log until at least one frame of the
// given type appears.
//
// Cancellation and teardown frames are best-effort: the call returns as soon
// as it has decided its outcome, so the frame can still be in flight or
// unlogged when the assertion runs.
func waitForFrameType(t *testing.T, readLog func() []*frame, frameType string) []*frame {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		if found := framesOfType(readLog(), frameType); len(found) > 0 {
			return found
		}
		if time.Now().After(deadline) {
			t.Fatalf("no %s frame was sent within the deadline", frameType)
		}
		time.Sleep(10 * time.Millisecond)
	}
}

// framesOfType filters a request log to one envelope type.
func framesOfType(frames []*frame, frameType string) []*frame {
	var out []*frame
	for _, f := range frames {
		if f.Type == frameType {
			out = append(out, f)
		}
	}
	return out
}

// waitForGoroutines waits for the goroutine count to fall back to baseline,
// so a leak check does not race a goroutine that is still unwinding.
func waitForGoroutines(t *testing.T, baseline int) {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		if runtime.NumGoroutine() <= baseline {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	buf := make([]byte, 1<<16)
	buf = buf[:runtime.Stack(buf, true)]
	t.Fatalf("goroutines did not settle: have %d, baseline %d\n%s", runtime.NumGoroutine(), baseline, buf)
}
