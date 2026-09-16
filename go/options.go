package makai

import (
	"io"
	"log/slog"
	"time"
)

// Default timeouts and grace periods. Override them through [Options].
const (
	// defaultHandshakeTimeout bounds the wait for the runtime's ready frame.
	defaultHandshakeTimeout = 5 * time.Second
	// defaultRequestTimeout bounds the wait for each individual frame of a
	// response. A long provider turn is not a timeout as long as the runtime
	// keeps emitting frames.
	defaultRequestTimeout = 30 * time.Second
	// defaultShutdownGrace is how long Close waits for the runtime to exit
	// after its stdin is closed, before killing it.
	defaultShutdownGrace = 2 * time.Second
)

// Options configures a [Client]. The zero value is valid: it resolves the
// runtime binary automatically, runs it as `makai --stdio`, and uses the
// default timeouts.
type Options struct {
	// BinaryPath runs a specific runtime binary. The MAKAI_BINARY_PATH
	// environment variable takes precedence over this field, matching the
	// TypeScript SDK's resolution order.
	BinaryPath string

	// BinaryURL downloads the runtime from a URL when no explicit path is
	// configured. ChecksumSHA256 is required alongside it. The
	// MAKAI_BINARY_URL and MAKAI_BINARY_SHA256 environment variables take
	// precedence over these fields.
	BinaryURL string
	// ChecksumSHA256 is the lowercase hex SHA-256 of the binary at
	// BinaryURL. Downloads without it are refused with [ErrChecksumRequired].
	ChecksumSHA256 string
	// CacheDir is where a downloaded binary is cached. It defaults to
	// $XDG_CACHE_HOME/makai/bin, or ~/.cache/makai/bin.
	CacheDir string

	// Args are the runtime's arguments. Defaults to ["--stdio"].
	Args []string
	// Dir is the runtime's working directory. Defaults to the caller's.
	Dir string
	// Env is the runtime's environment. A nil Env inherits the caller's;
	// a non-nil Env replaces it entirely, as in [os/exec.Cmd].
	Env []string

	// ExpectedProtocolVersion is the envelope protocol version the runtime
	// must announce in its handshake. Defaults to "1".
	ExpectedProtocolVersion string

	// HandshakeTimeout bounds the wait for the ready frame. Defaults to 5s.
	HandshakeTimeout time.Duration
	// RequestTimeout bounds the wait for each frame of a response.
	// Defaults to 30s.
	RequestTimeout time.Duration
	// ShutdownGrace is how long Close waits for a clean exit before killing
	// the runtime. Defaults to 2s.
	ShutdownGrace time.Duration

	// Logger receives debug and error records about frames, routing and
	// process lifecycle. Defaults to a logger that discards everything.
	Logger *slog.Logger
}

func (o *Options) args() []string {
	if o == nil || o.Args == nil {
		return []string{"--stdio"}
	}
	return o.Args
}

func (o *Options) protocolVersion() string {
	if o == nil || o.ExpectedProtocolVersion == "" {
		return "1"
	}
	return o.ExpectedProtocolVersion
}

func (o *Options) handshakeTimeout() time.Duration {
	if o == nil || o.HandshakeTimeout <= 0 {
		return defaultHandshakeTimeout
	}
	return o.HandshakeTimeout
}

func (o *Options) requestTimeout() time.Duration {
	if o == nil || o.RequestTimeout <= 0 {
		return defaultRequestTimeout
	}
	return o.RequestTimeout
}

func (o *Options) shutdownGraceOrDefault() time.Duration {
	if o == nil || o.ShutdownGrace <= 0 {
		return defaultShutdownGrace
	}
	return o.ShutdownGrace
}

func (o *Options) logger() *slog.Logger {
	if o == nil || o.Logger == nil {
		return discardLogger
	}
	return o.Logger
}

// discardLogger drops every record, so the SDK logs nothing unless the caller
// supplies a logger.
var discardLogger = slog.New(slog.NewTextHandler(io.Discard, &slog.HandlerOptions{Level: slog.LevelError + 1}))
