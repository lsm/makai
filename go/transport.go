package makai

import (
	"context"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"os"
	"os/exec"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// routeQueueSize bounds how many frames may sit undelivered on one route
// before the reader would have to block. Consumers read in a tight loop, so
// this is headroom for bursts rather than a steady-state buffer; overflowing
// it is reported as a transport failure rather than silently dropping frames.
const routeQueueSize = 1024

// stderrTailBytes caps how much of the runtime's stderr is retained to
// include in process-exit diagnostics.
const stderrTailBytes = 8 << 10

type routeKind int

const (
	routeStream routeKind = iota
	routeSession
)

func (k routeKind) String() string {
	if k == routeStream {
		return "stream"
	}
	return "session"
}

// transport owns the runtime child process and routes its frames to the
// calls waiting on them.
//
// One goroutine reads the child's stdout and dispatches each frame; a second
// waits for the process to exit. Calls never read the pipe themselves, so a
// slow or abandoned call cannot stall another call's frames.
type transport struct {
	cmd           *exec.Cmd
	stdin         io.WriteCloser
	logger        *slog.Logger
	shutdownGrace time.Duration

	writeMu sync.Mutex

	mu         sync.Mutex
	streams    map[string][]*subscription
	sessions   map[string][]*subscription
	correlates map[string]*subscription
	stderr     *tailBuffer

	// done closes when the reader goroutine stops, which happens when the
	// child's stdout reaches EOF or fails.
	done chan struct{}
	// exited closes after the child has been reaped.
	exited chan struct{}

	readErr atomic.Pointer[error]
	waitErr atomic.Pointer[error]

	closeOnce sync.Once
	closeErr  error
	closing   atomic.Bool
}

// startTransport spawns the runtime and completes the ready handshake.
//
// On any failure the child is killed and reaped before returning, so a failed
// New leaves no process and no goroutines behind.
func startTransport(ctx context.Context, command string, opts *Options) (*transport, error) {
	cmd := exec.Command(command, opts.args()...)
	cmd.Dir = opts.Dir
	if opts.Env != nil {
		cmd.Env = opts.Env
	}

	stdin, err := cmd.StdinPipe()
	if err != nil {
		return nil, transportErrorf(err, "cannot open runtime stdin: %v", err)
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		return nil, transportErrorf(err, "cannot open runtime stdout: %v", err)
	}
	stderrTail := newTailBuffer(stderrTailBytes)
	cmd.Stderr = stderrTail

	t := &transport{
		cmd:           cmd,
		stdin:         stdin,
		logger:        opts.logger(),
		shutdownGrace: opts.shutdownGraceOrDefault(),
		streams:       make(map[string][]*subscription),
		sessions:      make(map[string][]*subscription),
		correlates:    make(map[string]*subscription),
		stderr:        stderrTail,
		done:          make(chan struct{}),
		exited:        make(chan struct{}),
	}

	if err := cmd.Start(); err != nil {
		return nil, transportErrorf(err, "cannot start runtime %q: %v", command, err)
	}
	t.logger.Debug("makai: runtime started", "command", command, "args", opts.args(), "pid", cmd.Process.Pid)

	handshake := make(chan *frame, 1)
	go t.readLoop(stdout, handshake)

	if err := t.awaitHandshake(ctx, handshake, opts); err != nil {
		_ = t.close()
		return nil, err
	}
	return t, nil
}

// awaitHandshake consumes the runtime's first frame and validates it as the
// ready handshake.
func (t *transport) awaitHandshake(ctx context.Context, handshake <-chan *frame, opts *Options) error {
	timer := time.NewTimer(opts.handshakeTimeout())
	defer timer.Stop()

	select {
	case f, ok := <-handshake:
		if !ok {
			return t.terminalError("handshake")
		}
		switch f.Type {
		case "ready":
			expected := opts.protocolVersion()
			if f.ProtocolVersion != expected {
				return fmt.Errorf("%w: expected %q, got %q", ErrProtocolVersion, expected, f.ProtocolVersion)
			}
			t.logger.Debug("makai: handshake complete", "protocol_version", f.ProtocolVersion)
			return nil
		case "error":
			payload := f.payload()
			return &ProtocolError{
				Code:    payload.str("code", "error_code"),
				Message: payload.strOrDefault("runtime rejected the handshake", "message", "reason"),
			}
		default:
			return transportErrorf(nil, "unexpected handshake frame type %q", f.Type)
		}
	case <-timer.C:
		return transportErrorf(nil, "timed out waiting for the runtime handshake after %s", opts.handshakeTimeout())
	case <-ctx.Done():
		return abortError(ctx.Err(), "handshake")
	case <-t.done:
		return t.terminalError("handshake")
	}
}

// readLoop decodes frames until the child's stdout ends, delivering the first
// one to handshake and dispatching the rest to their routes.
func (t *transport) readLoop(stdout io.ReadCloser, handshake chan<- *frame) {
	reader := newFrameReader(stdout)
	delivered := false

	defer func() {
		if !delivered {
			close(handshake)
		}
		close(t.done)
		t.wakeAll()
		// Reading has finished, so the pipe is safe for Wait to close.
		err := t.cmd.Wait()
		t.waitErr.Store(&err)
		close(t.exited)
	}()

	for {
		f, err := reader.next()
		if errors.Is(err, errMalformedFrame) {
			t.logger.Warn("makai: discarding malformed frame from runtime")
			continue
		}
		if err != nil {
			if !errors.Is(err, io.EOF) && !errors.Is(err, os.ErrClosed) && !isPipeClosed(err) {
				t.readErr.Store(&err)
				t.logger.Error("makai: runtime read failed", "error", err)
			}
			return
		}
		if !delivered {
			delivered = true
			handshake <- f
			close(handshake)
			continue
		}
		t.dispatch(f)
	}
}

// dispatch routes one frame, following the spec's frame-routing rules:
// a reply goes to the waiter whose request it names, and everything else goes
// to its stream or session route. An unroutable frame is dropped.
func (t *transport) dispatch(f *frame) {
	t.logger.Debug("makai: frame received",
		"type", f.Type, "stream_id", f.StreamID, "session_id", f.SessionID,
		"sequence", f.Sequence, "in_reply_to", f.InReplyTo)

	t.mu.Lock()
	var target *subscription
	if f.InReplyTo != "" {
		target = t.correlates[f.InReplyTo]
	}
	if target == nil && f.StreamID != "" {
		if subs := t.streams[f.StreamID]; len(subs) > 0 {
			target = subs[0]
		}
	}
	if target == nil && f.SessionID != "" {
		if subs := t.sessions[f.SessionID]; len(subs) > 0 {
			target = subs[0]
		}
	}
	// A session id can carry more than one attempt: two runs may start with
	// the same caller-supplied id, and only one is accepted. Registration
	// order does not say which, so the acceptance itself promotes its own
	// subscription to receive the run's uncorrelated output.
	if target != nil && f.SessionID != "" && f.Type == "agent_started" {
		t.promoteSessionLocked(f.SessionID, target)
	}
	t.mu.Unlock()

	if target == nil {
		t.logger.Debug("makai: dropping unroutable frame", "type", f.Type,
			"stream_id", f.StreamID, "session_id", f.SessionID, "in_reply_to", f.InReplyTo)
		return
	}
	target.deliver(f)
}

// promoteSessionLocked moves sub to the front of its session route, so
// frames that name only the session are delivered to it. t.mu must be held.
func (t *transport) promoteSessionLocked(sessionID string, sub *subscription) {
	subs := t.sessions[sessionID]
	for i, candidate := range subs {
		if candidate != sub {
			continue
		}
		if i > 0 {
			copy(subs[1:i+1], subs[:i])
			subs[0] = sub
		}
		return
	}
}

// send writes one envelope to the runtime. Writes are serialized so frames
// never interleave on the pipe.
func (t *transport) send(f *frame) error {
	encoded := mustMarshal(f)
	line := make([]byte, 0, len(encoded)+1)
	line = append(line, encoded...)
	line = append(line, '\n')

	t.writeMu.Lock()
	defer t.writeMu.Unlock()

	select {
	case <-t.done:
		return t.terminalError("send")
	default:
	}
	if t.closing.Load() {
		return t.terminalError("send")
	}

	t.logger.Debug("makai: frame sent",
		"type", f.Type, "stream_id", f.StreamID, "session_id", f.SessionID, "sequence", f.Sequence)
	if _, err := t.stdin.Write(line); err != nil {
		if terminal := t.terminalErrorIfDown(); terminal != nil {
			return terminal
		}
		return transportErrorf(err, "cannot write %s frame to the runtime: %v", f.Type, err)
	}
	return nil
}

// sendBestEffort writes a frame whose delivery is not required for
// correctness, such as a cancellation or teardown frame.
func (t *transport) sendBestEffort(f *frame) {
	if err := t.send(f); err != nil {
		t.logger.Debug("makai: best-effort frame not sent", "type", f.Type, "error", err)
	}
}

func (t *transport) subscribeStream(id string) *subscription { return t.subscribe(routeStream, id) }

func (t *transport) subscribeSession(id string) *subscription { return t.subscribe(routeSession, id) }

func (t *transport) subscribe(kind routeKind, id string) *subscription {
	sub := &subscription{
		transport: t,
		kind:      kind,
		id:        id,
		queue:     make(chan *frame, routeQueueSize),
		wake:      make(chan struct{}, 1),
	}
	t.mu.Lock()
	if kind == routeStream {
		t.streams[id] = append(t.streams[id], sub)
	} else {
		t.sessions[id] = append(t.sessions[id], sub)
	}
	t.mu.Unlock()
	return sub
}

func (t *transport) unsubscribe(sub *subscription) {
	t.mu.Lock()
	defer t.mu.Unlock()

	table := t.sessions
	if sub.kind == routeStream {
		table = t.streams
	}
	subs := table[sub.id]
	for i, candidate := range subs {
		if candidate == sub {
			subs = append(subs[:i], subs[i+1:]...)
			break
		}
	}
	if len(subs) == 0 {
		delete(table, sub.id)
	} else {
		table[sub.id] = subs
	}
	for messageID, owner := range t.correlates {
		if owner == sub {
			delete(t.correlates, messageID)
		}
	}
}

// wakeAll nudges every live subscription so waiters notice the transport has
// gone down even when their queue is empty.
func (t *transport) wakeAll() {
	t.mu.Lock()
	subs := make([]*subscription, 0, len(t.streams)+len(t.sessions))
	for _, list := range t.streams {
		subs = append(subs, list...)
	}
	for _, list := range t.sessions {
		subs = append(subs, list...)
	}
	t.mu.Unlock()

	for _, sub := range subs {
		sub.signal()
	}
}

// terminalError describes why the transport is no longer usable.
func (t *transport) terminalError(operation string) error {
	<-t.done
	if err := t.readErr.Load(); err != nil && *err != nil {
		return transportErrorf(*err, "%s failed: runtime stream error: %v", operation, *err)
	}
	if t.closing.Load() {
		return transportErrorf(ErrClosed, "%s failed: %v", operation, ErrClosed)
	}

	// The reader has stopped; give the reaper a moment so the message can
	// name the exit status instead of just reporting EOF.
	select {
	case <-t.exited:
	case <-time.After(time.Second):
	}
	detail := "runtime process exited"
	if err := t.waitErr.Load(); err != nil && *err != nil {
		detail = "runtime process exited: " + (*err).Error()
	}
	if tail := strings.TrimSpace(t.stderr.String()); tail != "" {
		detail += ": " + lastLine(tail)
	}
	return transportErrorf(ErrClosed, "%s failed: %s", operation, detail)
}

// terminalErrorIfDown returns a terminal error when the transport is already
// down, and nil while it is still running.
func (t *transport) terminalErrorIfDown() error {
	select {
	case <-t.done:
		return t.terminalError("send")
	default:
		return nil
	}
}

// close shuts the runtime down: stdin is closed to request a clean exit, and
// the process is killed if it does not oblige within the shutdown grace
// period. It always reaps the child and joins the reader goroutine.
func (t *transport) close() error {
	t.closeOnce.Do(func() {
		t.closing.Store(true)
		t.logger.Debug("makai: closing transport")

		// Deliberately not under writeMu: a send blocked in Write on a full
		// pipe holds that mutex, and taking it here would stop Close from
		// ever reaching the grace timer that is meant to bound exactly this
		// case. Closing an *os.File under a concurrent Write is safe and is
		// what unblocks the wedged writer.
		closeErr := t.stdin.Close()

		grace := t.shutdownGrace
		if grace <= 0 {
			grace = defaultShutdownGrace
		}
		timer := time.NewTimer(grace)
		defer timer.Stop()

		killed := false
		select {
		case <-t.exited:
		case <-timer.C:
			t.logger.Debug("makai: runtime did not exit in time, killing")
			if t.cmd.Process != nil {
				killed = true
				_ = t.cmd.Process.Kill()
			}
			<-t.exited
		}

		// A runtime this Close killed is an expected outcome of the grace
		// period, not a failure to report.
		if err := t.waitErr.Load(); err != nil && *err != nil && !killed {
			t.closeErr = transportErrorf(*err, "runtime exited with an error: %v", *err)
			return
		}
		if closeErr != nil && !errors.Is(closeErr, os.ErrClosed) {
			t.closeErr = transportErrorf(closeErr, "cannot close runtime stdin: %v", closeErr)
		}
	})
	return t.closeErr
}

// subscription is one call's view of a frame route.
type subscription struct {
	transport *transport
	kind      routeKind
	id        string
	queue     chan *frame
	wake      chan struct{}
	overflow  atomic.Bool
	closed    atomic.Bool
}

// correlate registers messageID so that replies naming it are delivered to
// this subscription even when another subscription shares the route.
func (s *subscription) correlate(messageID string) {
	if messageID == "" {
		return
	}
	s.transport.mu.Lock()
	s.transport.correlates[messageID] = s
	s.transport.mu.Unlock()
}

// uncorrelate drops a previously registered correlation id.
func (s *subscription) uncorrelate(messageID string) {
	if messageID == "" {
		return
	}
	s.transport.mu.Lock()
	if s.transport.correlates[messageID] == s {
		delete(s.transport.correlates, messageID)
	}
	s.transport.mu.Unlock()
}

func (s *subscription) deliver(f *frame) {
	if s.closed.Load() {
		return
	}
	select {
	case s.queue <- f:
		s.signal()
	default:
		s.overflow.Store(true)
		s.signal()
		s.transport.logger.Error("makai: route queue overflowed, frame dropped",
			"route", s.kind.String(), "id", s.id, "type", f.Type)
	}
}

func (s *subscription) signal() {
	select {
	case s.wake <- struct{}{}:
	default:
	}
}

// next returns the subscription's next frame, waiting up to timeout.
//
// It fails with an aborted error when ctx ends, a transport error on timeout,
// on route overflow, or when the runtime process goes away.
func (s *subscription) next(ctx context.Context, timeout time.Duration, operation string) (*frame, error) {
	timer := time.NewTimer(timeout)
	defer timer.Stop()

	for {
		select {
		case f := <-s.queue:
			return f, nil
		default:
		}
		if s.overflow.Load() {
			return nil, &StreamError{
				Kind:      KindTransportError,
				Message:   fmt.Sprintf("%s failed: runtime produced frames faster than they could be consumed and some were dropped", operation),
				StreamID:  s.streamID(),
				SessionID: s.sessionID(),
			}
		}

		select {
		case f := <-s.queue:
			return f, nil
		case <-s.wake:
			continue
		case <-ctx.Done():
			return nil, abortError(ctx.Err(), operation)
		case <-timer.C:
			return nil, &StreamError{
				Kind:      KindTransportError,
				Message:   fmt.Sprintf("timed out waiting for %s after %s", operation, timeout),
				StreamID:  s.streamID(),
				SessionID: s.sessionID(),
			}
		case <-s.transport.done:
			// The runtime is gone, but frames it already sent are still
			// valid; hand those back before reporting the failure.
			select {
			case f := <-s.queue:
				return f, nil
			default:
			}
			return nil, s.transport.terminalError(operation)
		}
	}
}

// drain consumes frames the runtime is still emitting for this route, giving
// up once the route has been idle for idle or the budget elapses.
//
// Draining after a terminal frame matters because the runtime queues a
// trailing event behind an agent result, and a later call reusing the id
// would otherwise read that stale frame first.
func (s *subscription) drain(idle, budget time.Duration) {
	deadline := time.Now().Add(budget)
	for {
		remaining := time.Until(deadline)
		if remaining <= 0 {
			return
		}
		wait := idle
		if wait > remaining {
			wait = remaining
		}
		timer := time.NewTimer(wait)
		select {
		case <-s.queue:
			timer.Stop()
		case <-s.wake:
			timer.Stop()
		case <-timer.C:
			timer.Stop()
			return
		case <-s.transport.done:
			timer.Stop()
			return
		}
	}
}

func (s *subscription) close() {
	if s.closed.Swap(true) {
		return
	}
	s.transport.unsubscribe(s)
}

func (s *subscription) streamID() string {
	if s.kind == routeStream {
		return s.id
	}
	return ""
}

func (s *subscription) sessionID() string {
	if s.kind == routeSession {
		return s.id
	}
	return ""
}

// isPipeClosed backs up the errors.Is(err, os.ErrClosed) check at the read
// loop's exit. Closing the runtime's pipes is an ordinary part of shutdown,
// and a "file already closed" that reaches the loop through a wrapping this
// Go version or platform does not expose as os.ErrClosed would otherwise be
// logged and reported as a stream failure.
func isPipeClosed(err error) bool {
	return err != nil && strings.Contains(err.Error(), "file already closed")
}

func lastLine(text string) string {
	lines := strings.Split(strings.TrimSpace(text), "\n")
	return strings.TrimSpace(lines[len(lines)-1])
}

// tailBuffer keeps the last n bytes written to it, so process diagnostics can
// quote the runtime's most recent stderr without retaining everything.
type tailBuffer struct {
	mu   sync.Mutex
	buf  []byte
	size int
}

func newTailBuffer(size int) *tailBuffer { return &tailBuffer{size: size} }

func (b *tailBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.buf = append(b.buf, p...)
	if len(b.buf) > b.size {
		b.buf = append(b.buf[:0], b.buf[len(b.buf)-b.size:]...)
	}
	return len(p), nil
}

func (b *tailBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return string(b.buf)
}
