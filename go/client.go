package makai

import (
	"context"
	"time"
)

// Client is a connected Makai runtime. It owns the child process and the
// frame routing for every call made through its namespaces.
//
// A Client is safe for concurrent use: calls on different streams and
// sessions are multiplexed over the one transport, and ordering is guaranteed
// within a stream or session but not between them.
//
// Always call [Client.Close] when finished; it terminates the runtime and
// releases the SDK's goroutines.
type Client struct {
	// Auth lists auth providers and runs interactive login flows.
	Auth *AuthService
	// Models lists and resolves the models the runtime can serve.
	Models *ModelsService
	// Provider runs direct provider completions, buffered or streamed.
	Provider *ProviderService
	// Agent runs the agent loop, executing tools in client code.
	Agent *AgentService

	transport *transport
}

// New resolves the makai runtime, starts it as a stdio protocol host, and
// completes the protocol handshake.
//
// A nil opts uses the defaults: automatic binary resolution, `makai --stdio`,
// and the default timeouts. See [ResolveBinary] for the resolution order.
//
// ctx bounds startup and the handshake only. It does not bound the client's
// lifetime: once New returns, cancelling ctx does not close the client.
func New(ctx context.Context, opts *Options) (*Client, error) {
	if opts == nil {
		opts = &Options{}
	}
	command, err := ResolveBinary(ctx, opts)
	if err != nil {
		return nil, err
	}
	transport, err := startTransport(ctx, command, opts)
	if err != nil {
		return nil, err
	}
	return newClient(transport, opts.requestTimeout()), nil
}

func newClient(transport *transport, timeout time.Duration) *Client {
	client := &Client{transport: transport}
	client.Auth = &AuthService{transport: transport, timeout: timeout}
	client.Models = &ModelsService{transport: transport, timeout: timeout}
	client.Provider = &ProviderService{transport: transport, timeout: timeout}
	client.Agent = &AgentService{transport: transport, timeout: timeout}
	return client
}

// Close terminates the runtime and releases the client's resources.
//
// It closes the runtime's stdin to ask for a clean exit, waits out the
// configured shutdown grace period, then kills the process. It always reaps
// the child and joins the SDK's goroutines before returning, and is safe to
// call more than once: later calls return the first call's result.
//
// In-flight calls fail with a transport error wrapping [ErrClosed].
func (c *Client) Close() error { return c.transport.close() }
