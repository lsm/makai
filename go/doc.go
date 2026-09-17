// Package makai is a Go SDK for the Makai stdio protocol.
//
// The SDK spawns (or connects to) a `makai --stdio` runtime and exposes four
// namespaces over its newline-delimited JSON framing:
//
//   - [Client.Auth] lists auth providers and drives interactive login flows.
//   - [Client.Models] lists and resolves models.
//   - [Client.Provider] runs direct provider completions, buffered or streamed.
//   - [Client.Agent] runs the agent loop, with tools executed in client code.
//
// Every call that performs I/O takes a [context.Context] as its first
// argument. Cancelling that context stops the call promptly, sends a
// best-effort cancellation frame to the runtime, and releases the call's frame
// route. It does not tear down the client: [Client.Close] owns the child
// process lifetime.
//
// A minimal session looks like this:
//
//	client, err := makai.New(ctx, nil)
//	if err != nil {
//		return err
//	}
//	defer client.Close()
//
//	model, err := client.Models.Resolve(ctx, makai.ResolveModelRequest{
//		ProviderID: "anthropic",
//		API:        "anthropic-messages",
//		ModelID:    "claude-sonnet-4-5",
//	})
//	if err != nil {
//		return err
//	}
//
//	resp, err := client.Provider.Complete(ctx, makai.CompletionRequest{
//		ModelRef: model.ModelRef,
//		Messages: []makai.Message{makai.UserMessage("Write a haiku about streams.")},
//	})
//
// # Opaque model refs
//
// ModelRef values are server-issued handles. Application code must treat them
// as opaque: do not parse them, do not build them by hand, and do not derive
// provider or model identity from their text. Obtain them from
// [ModelsService.List] or [ModelsService.Resolve].
//
// # Sessions are not resumable
//
// An agent run's session id is a correlation key for one run's frames. It is
// not a resume handle: a finished or interrupted run cannot be continued by
// reusing its id, and reusing a live id is rejected by the runtime. Callers
// that need to continue a conversation resend the full message history.
//
// # Errors
//
// Failures are returned as typed errors reachable through [errors.As]:
// [StreamError] for provider, transport and abort failures on provider/agent
// calls, [AuthRequiredError] (which unwraps to [StreamError]) when a provider
// needs a login, [ProtocolError] for model-discovery protocol failures, and
// [AuthError] for auth listing and login-flow failures. Errors caused by a
// cancelled context wrap the context error, so [errors.Is] against
// [context.Canceled] and [context.DeadlineExceeded] works.
package makai
