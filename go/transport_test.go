package makai

import (
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"runtime"
	"strings"
	"testing"
	"time"
)

func TestHandshakeSucceeds(t *testing.T) {
	client := newTestClient(t, scenarioProtocol)
	if client.Auth == nil || client.Models == nil || client.Provider == nil || client.Agent == nil {
		t.Fatal("expected every namespace to be wired up")
	}
}

func TestHandshakeRejectsUnexpectedProtocolVersion(t *testing.T) {
	_, err := newTestClientWithOptions(t, &Options{
		BinaryPath: os.Args[0],
		Env:        fakeHostEnv(scenarioBadVersion),
	})
	if !errors.Is(err, ErrProtocolVersion) {
		t.Fatalf("expected ErrProtocolVersion, got %v", err)
	}
	if !strings.Contains(err.Error(), `got "2"`) {
		t.Errorf("expected the announced version in the message, got %q", err)
	}
}

func TestHandshakeSurfacesRuntimeErrorFrame(t *testing.T) {
	_, err := newTestClientWithOptions(t, &Options{
		BinaryPath: os.Args[0],
		Env:        fakeHostEnv(scenarioHandshakeError),
	})
	var protocolErr *ProtocolError
	if !errors.As(err, &protocolErr) {
		t.Fatalf("expected *ProtocolError, got %T: %v", err, err)
	}
	if protocolErr.Code != "startup_failed" {
		t.Errorf("Code = %q, want startup_failed", protocolErr.Code)
	}
}

func TestHandshakeTimesOut(t *testing.T) {
	_, err := newTestClientWithOptions(t, &Options{
		BinaryPath:       os.Args[0],
		Env:              fakeHostEnv(scenarioSilent),
		HandshakeTimeout: 150 * time.Millisecond,
	})
	var streamErr *StreamError
	if !errors.As(err, &streamErr) {
		t.Fatalf("expected *StreamError, got %T: %v", err, err)
	}
	if streamErr.Kind != KindTransportError {
		t.Errorf("Kind = %q, want %q", streamErr.Kind, KindTransportError)
	}
	if !strings.Contains(streamErr.Message, "timed out waiting for the runtime handshake") {
		t.Errorf("expected a handshake timeout, got %q", streamErr.Message)
	}
	if errors.Is(err, ErrClosed) {
		t.Error("a silent but living runtime should time out, not report an exit")
	}
}

func TestHandshakeFailsWhenRuntimeExits(t *testing.T) {
	_, err := newTestClientWithOptions(t, &Options{
		BinaryPath: os.Args[0],
		Env:        fakeHostEnv(scenarioExitAfterReady),
		// The runtime exits right after the handshake, so a models call is
		// what actually observes the death; startup itself may succeed.
		HandshakeTimeout: time.Second,
	})
	if err == nil {
		return
	}
	if !errors.Is(err, ErrClosed) {
		t.Fatalf("expected an ErrClosed-wrapped failure, got %v", err)
	}
}

func TestHandshakeIgnoresMalformedLines(t *testing.T) {
	// The fake host writes junk before and after its ready frame; neither
	// should stop the handshake or the request that follows it.
	client := newTestClient(t, scenarioGarbage)
	if _, err := client.Models.List(testContext(t), ListModelsRequest{}); err != nil {
		t.Fatalf("List after malformed lines: %v", err)
	}
}

func TestRequestFailsWhenRuntimeDiesMidRequest(t *testing.T) {
	client := newTestClient(t, scenarioExitMidRequest)

	_, err := client.Models.List(testContext(t), ListModelsRequest{})
	if err == nil {
		t.Fatal("expected the dead runtime to fail the request")
	}
	if !errors.Is(err, ErrClosed) {
		t.Fatalf("expected an ErrClosed-wrapped failure, got %v", err)
	}
}

func TestSendAfterCloseFails(t *testing.T) {
	client, err := newTestClientWithOptions(t, &Options{
		BinaryPath: os.Args[0],
		Env:        fakeHostEnv(scenarioProtocol),
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	if err := client.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}

	if _, err := client.Models.List(testContext(t), ListModelsRequest{}); !errors.Is(err, ErrClosed) {
		t.Fatalf("expected ErrClosed after Close, got %v", err)
	}
}

func TestCloseIsIdempotent(t *testing.T) {
	client, err := newTestClientWithOptions(t, &Options{
		BinaryPath: os.Args[0],
		Env:        fakeHostEnv(scenarioProtocol),
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	for i := 0; i < 3; i++ {
		if err := client.Close(); err != nil {
			t.Fatalf("Close call %d: %v", i+1, err)
		}
	}
}

func TestCloseKillsRuntimeThatIgnoresStdin(t *testing.T) {
	client, err := newTestClientWithOptions(t, &Options{
		BinaryPath:    os.Args[0],
		Env:           fakeHostEnv(scenarioIgnoreStdin),
		ShutdownGrace: 100 * time.Millisecond,
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}
	pid := client.transport.cmd.Process.Pid

	start := time.Now()
	if err := client.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	if elapsed := time.Since(start); elapsed > 3*time.Second {
		t.Errorf("Close took %s; the grace period should have bounded it", elapsed)
	}
	if client.transport.cmd.ProcessState == nil {
		t.Fatal("expected the runtime to be reaped")
	}
	// Signal 0 on a reaped pid reports that it is gone.
	if process, err := os.FindProcess(pid); err == nil {
		if err := process.Signal(os.Signal(nil)); err == nil {
			t.Error("expected the killed runtime to be gone")
		}
	}
}

func TestCloseLeavesNoGoroutines(t *testing.T) {
	baseline := runtime.NumGoroutine()

	for i := 0; i < 3; i++ {
		client, err := newTestClientWithOptions(t, &Options{
			BinaryPath: os.Args[0],
			Env:        fakeHostEnv(scenarioProtocol),
		})
		if err != nil {
			t.Fatalf("New: %v", err)
		}
		if _, err := client.Models.List(testContext(t), ListModelsRequest{}); err != nil {
			t.Fatalf("List: %v", err)
		}
		if err := client.Close(); err != nil {
			t.Fatalf("Close: %v", err)
		}
	}
	waitForGoroutines(t, baseline)
}

func TestCancelledStreamLeavesNoGoroutines(t *testing.T) {
	baseline := runtime.NumGoroutine()

	client, err := newTestClientWithOptions(t, &Options{
		BinaryPath: os.Args[0],
		Env:        fakeHostEnv(scenarioProtocol, envSuppress+"=stream_request"),
	})
	if err != nil {
		t.Fatalf("New: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	stream, err := client.Provider.Stream(ctx, CompletionRequest{
		ModelRef: "anthropic/anthropic-messages@claude-sonnet-4-5",
		Messages: []Message{UserMessage("hi")},
	})
	if err != nil {
		t.Fatalf("Stream: %v", err)
	}

	go func() {
		time.Sleep(50 * time.Millisecond)
		cancel()
	}()
	if stream.Next() {
		t.Fatalf("expected no events from a suppressed stream, got %#v", stream.Event())
	}
	if !errors.Is(stream.Err(), context.Canceled) {
		t.Fatalf("expected a context.Canceled-wrapped error, got %v", stream.Err())
	}
	if err := stream.Close(); !errors.Is(err, context.Canceled) {
		t.Fatalf("Close should report the same failure, got %v", err)
	}

	pid := client.transport.cmd.Process.Pid
	if err := client.Close(); err != nil {
		t.Fatalf("Close: %v", err)
	}
	// Cancelling the stream stops the stream; closing the client reaps the
	// runtime. Neither leaves a process or a goroutine behind.
	if client.transport.cmd.ProcessState == nil {
		t.Fatal("expected the runtime to be reaped")
	}
	if process, err := os.FindProcess(pid); err == nil {
		if err := process.Signal(os.Signal(nil)); err == nil {
			t.Error("expected the runtime process to be gone")
		}
	}
	waitForGoroutines(t, baseline)
}

func TestConcurrentCallsAreMultiplexed(t *testing.T) {
	client := newTestClient(t, scenarioProtocol)
	ctx := testContext(t)

	const calls = 8
	errs := make(chan error, calls)
	for i := 0; i < calls; i++ {
		go func() {
			_, err := client.Models.List(ctx, ListModelsRequest{ProviderID: "anthropic"})
			errs <- err
		}()
	}
	for i := 0; i < calls; i++ {
		if err := <-errs; err != nil {
			t.Fatalf("concurrent List: %v", err)
		}
	}
}

func TestFrameReaderHandlesLongAndPartialLines(t *testing.T) {
	long := strings.Repeat("x", 300*1024)
	input := fmt.Sprintf("{\"type\":\"a\",\"payload\":{\"text\":%q}}\n{\"type\":\"b\"}", long)

	reader := newFrameReader(strings.NewReader(input))

	first, err := reader.next()
	if err != nil {
		t.Fatalf("first frame: %v", err)
	}
	if first.Type != "a" {
		t.Errorf("Type = %q, want a", first.Type)
	}
	if got := first.payload().str("text"); len(got) != len(long) {
		t.Errorf("payload text length = %d, want %d", len(got), len(long))
	}

	// The last line has no trailing newline; it must still be delivered.
	second, err := reader.next()
	if err != nil {
		t.Fatalf("second frame: %v", err)
	}
	if second.Type != "b" {
		t.Errorf("Type = %q, want b", second.Type)
	}
	if _, err := reader.next(); !errors.Is(err, io.EOF) {
		t.Fatalf("expected io.EOF at the end, got %v", err)
	}
}

func TestFrameReaderRejectsOversizedFrames(t *testing.T) {
	reader := newFrameReader(strings.NewReader(strings.Repeat("x", maxFrameBytes+1024)))
	if _, err := reader.next(); err == nil || !strings.Contains(err.Error(), "byte limit") {
		t.Fatalf("expected a size-limit error, got %v", err)
	}
}

func TestFrameReaderReportsMalformedLines(t *testing.T) {
	reader := newFrameReader(strings.NewReader("not json\n[]\n{\"type\":\"ok\"}\n"))

	for i := 0; i < 2; i++ {
		if _, err := reader.next(); !errors.Is(err, errMalformedFrame) {
			t.Fatalf("line %d: expected errMalformedFrame, got %v", i+1, err)
		}
	}
	f, err := reader.next()
	if err != nil {
		t.Fatalf("third line: %v", err)
	}
	if f.Type != "ok" {
		t.Errorf("Type = %q, want ok", f.Type)
	}
}

func TestDispatchRoutesByCorrelationThenRoute(t *testing.T) {
	tr := &transport{
		logger:     discardLogger,
		streams:    map[string][]*subscription{},
		sessions:   map[string][]*subscription{},
		correlates: map[string]*subscription{},
		done:       make(chan struct{}),
		exited:     make(chan struct{}),
	}
	streamSub := tr.subscribeStream("S1")
	sessionSub := tr.subscribeSession("N1")
	otherSession := tr.subscribeSession("N1")
	otherSession.correlate("MSG-OTHER")

	// A reply naming another waiter's request must reach that waiter, not
	// the first subscription on the shared route.
	tr.dispatch(&frame{Type: "agent_error", SessionID: "N1", InReplyTo: "MSG-OTHER"})
	// Run output with no in_reply_to stays on the session route.
	tr.dispatch(&frame{Type: "agent_event", SessionID: "N1"})
	// Stream-routed frames reach the stream subscription.
	tr.dispatch(&frame{Type: "models_response", StreamID: "S1"})
	// Unroutable frames are dropped rather than delivered anywhere.
	tr.dispatch(&frame{Type: "orphan", StreamID: "S-UNKNOWN"})

	ctx := testContext(t)
	if f, err := otherSession.next(ctx, time.Second, "correlated"); err != nil || f.Type != "agent_error" {
		t.Fatalf("correlated waiter got (%v, %v), want agent_error", f, err)
	}
	if f, err := sessionSub.next(ctx, time.Second, "session"); err != nil || f.Type != "agent_event" {
		t.Fatalf("session waiter got (%v, %v), want agent_event", f, err)
	}
	if f, err := streamSub.next(ctx, time.Second, "stream"); err != nil || f.Type != "models_response" {
		t.Fatalf("stream waiter got (%v, %v), want models_response", f, err)
	}

	// Nothing else was delivered anywhere.
	shortCtx, cancel := context.WithTimeout(ctx, 50*time.Millisecond)
	defer cancel()
	if _, err := sessionSub.next(shortCtx, 50*time.Millisecond, "session"); err == nil {
		t.Fatal("expected no further frames on the session route")
	}
}

func TestUnsubscribeDropsCorrelations(t *testing.T) {
	tr := &transport{
		logger:     discardLogger,
		streams:    map[string][]*subscription{},
		sessions:   map[string][]*subscription{},
		correlates: map[string]*subscription{},
		done:       make(chan struct{}),
		exited:     make(chan struct{}),
	}
	sub := tr.subscribeSession("N1")
	sub.correlate("MSG-1")
	sub.close()

	tr.mu.Lock()
	correlates, sessions := len(tr.correlates), len(tr.sessions)
	tr.mu.Unlock()
	if correlates != 0 || sessions != 0 {
		t.Fatalf("after close: %d correlations and %d session routes remain", correlates, sessions)
	}
}

func TestSubscriptionOverflowIsReported(t *testing.T) {
	tr := &transport{
		logger:     discardLogger,
		streams:    map[string][]*subscription{},
		sessions:   map[string][]*subscription{},
		correlates: map[string]*subscription{},
		done:       make(chan struct{}),
		exited:     make(chan struct{}),
	}
	sub := tr.subscribeStream("S1")
	for i := 0; i < routeQueueSize+8; i++ {
		sub.deliver(&frame{Type: "event", StreamID: "S1"})
	}

	// Buffered frames come back first, and the overflow surfaces once the
	// queue drains.
	ctx := testContext(t)
	for i := 0; i < routeQueueSize; i++ {
		if _, err := sub.next(ctx, time.Second, "event"); err != nil {
			t.Fatalf("frame %d: %v", i, err)
		}
	}
	_, err := sub.next(ctx, time.Second, "event")
	var streamErr *StreamError
	if !errors.As(err, &streamErr) || streamErr.Kind != KindTransportError {
		t.Fatalf("expected a transport error after overflow, got %v", err)
	}
	if !strings.Contains(streamErr.Message, "dropped") {
		t.Errorf("expected the message to mention dropped frames, got %q", streamErr.Message)
	}
}

func TestTailBufferKeepsLastBytes(t *testing.T) {
	buffer := newTailBuffer(8)
	buffer.Write([]byte("0123456789"))
	buffer.Write([]byte("abc"))
	if got := buffer.String(); got != "56789abc" {
		t.Errorf("String() = %q, want the last 8 bytes", got)
	}
}

func TestFrameReaderSkipsAnOversizedFrameAndResynchronizes(t *testing.T) {
	oversized := strings.Repeat("x", maxFrameBytes+1024)
	reader := newFrameReader(strings.NewReader(oversized + "\n" + `{"type":"after"}` + "\n"))

	_, err := reader.next()
	if !errors.Is(err, errMalformedFrame) {
		t.Fatalf("an oversized frame should be recoverable, got %v", err)
	}
	if !strings.Contains(err.Error(), "byte limit") {
		t.Errorf("error should name the limit, got %v", err)
	}

	f, err := reader.next()
	if err != nil {
		t.Fatalf("the frame after an oversized one should still be read: %v", err)
	}
	if f.Type != "after" {
		t.Errorf("Type = %q, want after", f.Type)
	}
}

func TestDispatchPromotesTheAcceptedSessionAttempt(t *testing.T) {
	tr := &transport{
		logger:     discardLogger,
		streams:    map[string][]*subscription{},
		sessions:   map[string][]*subscription{},
		correlates: map[string]*subscription{},
		done:       make(chan struct{}),
		exited:     make(chan struct{}),
	}
	const sessionID = "testNanoIdSess1234567"

	loser := tr.subscribeSession(sessionID)
	defer loser.close()
	winner := tr.subscribeSession(sessionID)
	defer winner.close()
	winner.correlate("WINNER")

	tr.dispatch(&frame{Type: "agent_started", SessionID: sessionID, InReplyTo: "WINNER",
		Payload: mustMarshal(map[string]any{"session_id": sessionID})})

	tr.dispatch(&frame{Type: "agent_event", SessionID: sessionID,
		Payload: mustMarshal(map[string]any{"event_json": `{"type":"text_delta","delta":"mine"}`})})

	select {
	case f := <-winner.queue:
		if f.Type != "agent_started" {
			t.Fatalf("first frame = %q, want agent_started", f.Type)
		}
	default:
		t.Fatal("the accepted attempt should have received its own agent_started")
	}
	select {
	case f := <-winner.queue:
		if f.Type != "agent_event" {
			t.Fatalf("second frame = %q, want agent_event", f.Type)
		}
	default:
		t.Fatal("uncorrelated session output should follow the accepted attempt")
	}
	select {
	case f := <-loser.queue:
		t.Fatalf("the losing attempt received %q", f.Type)
	default:
	}
}
