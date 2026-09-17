# Makai Go SDK

Go SDK for Makai's stdio protocol. The SDK starts or connects to a `makai --stdio` runtime and exposes high-level namespaces for provider completions, streaming, agent runs, auth flows, and model discovery.

## Installation

```bash
go get github.com/lsm/makai/go
```

The module lives in the `go/` subdirectory of the Makai repository, so its import path ends in `/go` while the package itself is named `makai`:

```go
import makai "github.com/lsm/makai/go"
```

You also need access to the Makai runtime binary. By default the SDK looks for a local build under `zig-out/bin/makai` or `zig/zig-out/bin/makai`, then falls back to `makai` on `PATH`. See [Configuration](#configuration) for explicit binary resolver options.

## Quick start

Create a client, resolve a model, send one chat message, and print the assistant response.

```go
package main

import (
	"context"
	"fmt"
	"log"

	makai "github.com/lsm/makai/go"
)

func main() {
	ctx := context.Background()

	client, err := makai.New(ctx, nil)
	if err != nil {
		log.Fatal(err)
	}
	defer client.Close()

	model, err := client.Models.Resolve(ctx, makai.ResolveModelRequest{
		ProviderID: "anthropic",
		API:        "anthropic-messages",
		ModelID:    "claude-sonnet-4-5",
	})
	if err != nil {
		log.Fatal(err)
	}

	response, err := client.Provider.Complete(ctx, makai.CompletionRequest{
		ModelRef: model.ModelRef,
		Messages: []makai.Message{makai.UserMessage("Write a haiku about streams.")},
		Options:  &makai.RunOptions{MaxTokens: makai.MaxTokens(128)},
	})
	if err != nil {
		log.Fatal(err)
	}

	fmt.Println(response.Message.Text)
}
```

Every call that performs I/O takes a `context.Context` first. Cancelling it stops the call promptly, sends a best-effort cancellation frame to the runtime, and releases the call's frame route — it does not close the client. `client.Close()` owns the child process lifetime, and always reaps it.

## Streaming completions

`client.Provider.Stream(...)` is the streaming form of `Complete`. Each `*TextDelta` carries newly generated text.

```go
stream, err := client.Provider.Stream(ctx, makai.CompletionRequest{
	ModelRef: model.ModelRef,
	Messages: []makai.Message{makai.UserMessage("Explain lock-free queues in one paragraph.")},
	Options:  &makai.RunOptions{MaxTokens: makai.MaxTokens(256)},
})
if err != nil {
	return err
}
defer stream.Close()

for stream.Next() {
	switch event := stream.Event().(type) {
	case *makai.MessageStart:
		fmt.Fprintf(os.Stderr, "streaming %s/%s\n", event.ProviderID, event.ModelID)
	case *makai.TextDelta:
		fmt.Print(event.Delta)
	case *makai.ThinkingDelta:
		// Reasoning output is surfaced separately from normal text.
	case *makai.ToolCallEvent:
		fmt.Fprintf(os.Stderr, "\ntool call: %s(%s)\n", event.Name, event.ArgumentsJSON)
	case *makai.MessageEnd:
		fmt.Fprintf(os.Stderr, "\nstop reason: %s\n", event.StopReason)
	}
}
return stream.Err()
```

The iterator follows the `bufio.Scanner` shape: `Next` advances, `Event` returns the current event, `Err` reports why the loop ended, and `Close` releases the stream. `Next` returning false means either the end of the stream or a failure — check `Err` to tell them apart. Always `Close`: closing an unfinished stream tells the runtime to abandon it.

A provider stream emits exactly one terminal event, either `*MessageEnd` or `*ErrorEvent`.

## Agent loop with tools

Use `client.Agent.Run(...)` when you want the Makai agent loop to manage provider turns and the tool lifecycle. Tool definitions carry a JSON Schema string; the tool itself runs in your process, through `Execute`.

```go
weather := makai.Tool{
	Name:        "get_weather",
	Description: "Get the current weather for a city.",
	ParametersSchemaJSON: `{
		"type": "object",
		"properties": {"city": {"type": "string"}},
		"required": ["city"],
		"additionalProperties": false
	}`,
	Execute: func(ctx context.Context, call makai.ToolInvocation) (string, error) {
		var args struct {
			City string `json:"city"`
		}
		if err := json.Unmarshal([]byte(call.ArgumentsJSON), &args); err != nil {
			return "", fmt.Errorf("bad arguments: %w", err)
		}
		return "It is raining in " + args.City + ".", nil
	},
}

response, err := client.Agent.Run(ctx, makai.AgentRequest{
	ModelRef: model.ModelRef,
	Messages: []makai.Message{makai.UserMessage("Should I bring an umbrella in San Francisco?")},
	Tools:    []makai.Tool{weather},
	Options:  &makai.RunOptions{MaxTokens: makai.MaxTokens(512)},
})
```

An error returned from `Execute` is reported to the model as a failed tool result rather than aborting the run, so a tool can surface a recoverable problem and let the model react. A tool the model calls but that has no `Execute` is reported back as not executable by this client.

For agent streaming, iterate `client.Agent.Stream(request)` and handle `*AgentStart`, `*TurnStart`, `*ToolExecutionStart`, `*ToolExecutionEnd`, the provider deltas, and the terminal `*AgentEnd`.

```go
stream, err := client.Agent.Stream(ctx, request)
if err != nil {
	return err
}
defer stream.Close()

for stream.Next() {
	switch event := stream.Event().(type) {
	case *makai.TextDelta:
		fmt.Print(event.Delta)
	case *makai.ToolExecutionStart:
		log.Printf("running %s", event.ToolName)
	case *makai.AgentEnd:
		log.Printf("stop reason: %s", event.StopReason)
	}
}
return stream.Err()
```

A run ends in one of two ways, and a type switch only sees one of them. A run that completes emits `*AgentEnd` as its last event; a run that fails ends the loop instead, with the failure available from `stream.Err()` — `*ErrorEvent` is converted there and is never delivered as an event, so a `case *makai.ErrorEvent` is dead code. Always check `stream.Err()` after the loop.

Reaching `*AgentEnd` is not by itself proof of success either: a failed provider turn still settles that way, with `StopReason` `"error"` and the detail in `ErrorMessage`.

### Sessions are not resumable

`RunOptions.SessionID` is a correlation key for one run's frames, not a resume handle. A finished or interrupted run cannot be continued by reusing its id, and reusing the id of a live run is rejected with `CodeAgentBusy`. Leave it empty and the SDK generates one; supply one only to make a run's frames easier to match against runtime logs. To continue a conversation, resend the full message history.

## Auth

Use `client.Auth.ListProviders(ctx)` to inspect auth state, and `client.Auth.Login(ctx, providerID, handlers)` to run an interactive login. Token material is owned by the runtime and is never returned by the SDK.

```go
providers, err := client.Auth.ListProviders(ctx)
if err != nil {
	return err
}

for _, provider := range providers {
	if provider.ID != "anthropic" || provider.Status == makai.AuthAuthenticated {
		continue
	}
	err := client.Auth.Login(ctx, provider.ID, makai.LoginHandlers{
		OnEvent: func(event makai.AuthEvent) {
			switch event.Type {
			case makai.AuthEventURL:
				fmt.Println("open", event.URL)
			case makai.AuthEventProgress:
				fmt.Println(event.Message)
			}
		},
		OnPrompt: func(ctx context.Context, prompt makai.AuthPrompt) (string, error) {
			fmt.Println(prompt.Message)
			var answer string
			_, err := fmt.Scanln(&answer)
			return answer, err
		},
	})
	if err != nil {
		return err
	}
}
```

A flow that asks for input with no `OnPrompt` configured is cancelled, because it cannot be completed; the login then fails with an `*AuthError` of kind `AuthKindCancelled`.

There is no automatic auth retry. When a call fails because a provider needs a login, the SDK returns an `*AuthRequiredError` naming the provider, and recovering is a login plus a retry:

```go
response, err := client.Provider.Complete(ctx, request)

var authRequired *makai.AuthRequiredError
if errors.As(err, &authRequired) {
	if err := client.Auth.Login(ctx, authRequired.ProviderID, handlers); err != nil {
		return err
	}
	response, err = client.Provider.Complete(ctx, request)
}
```

## Models

Models are discovered through `client.Models`. Use `ModelRef` from the returned descriptor in provider and agent calls. **Treat `ModelRef` as opaque**: do not parse it, do not build one by hand, and do not derive provider or model identity from its text.

```go
models, err := client.Models.List(ctx, makai.ListModelsRequest{
	ProviderID:           "anthropic",
	IncludeLoginRequired: makai.Bool(true),
})
if err != nil {
	return err
}

fmt.Printf("fetched %d models at %s\n", len(models.Models), models.FetchedAt.Format(time.RFC3339))
fmt.Printf("cache max age: %s\n", models.CacheMaxAge)

for _, model := range models.Models {
	fmt.Printf("%s: %s [%s]\n", model.DisplayName, model.ModelRef, model.AuthStatus)
}

resolved, err := client.Models.Resolve(ctx, makai.ResolveModelRequest{
	ProviderID: "anthropic",
	API:        "anthropic-messages",
	ModelID:    "claude-sonnet-4-5",
})
```

`Resolve` asks the runtime for exactly one model. Matching none or more than one is an error, not a silently-picked first result.

## Configuration

`makai.New(ctx, opts)` takes transport settings and binary resolver options in one `*Options`. A nil `Options` uses the defaults.

### Explicit binary path

```go
client, err := makai.New(ctx, &makai.Options{
	BinaryPath: "/opt/makai/bin/makai",
})
```

You can also set `MAKAI_BINARY_PATH=/opt/makai/bin/makai`. Note that the environment variable **takes precedence over** `Options.BinaryPath`; this mirrors the TypeScript SDK, so one override steers both.

### Download from URL with checksum

```go
client, err := makai.New(ctx, &makai.Options{
	BinaryURL:      "https://example.com/releases/makai-darwin-arm64",
	ChecksumSHA256: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef",
	CacheDir:       "/tmp/makai-bin-cache",
})
```

The checksum is required; a download without one is refused with `ErrChecksumRequired`. A cached copy is re-verified on every use and re-downloaded if it does not match. Environment variable equivalents are `MAKAI_BINARY_URL` and `MAKAI_BINARY_SHA256`.

### PATH lookup and local builds

With no resolver options, the SDK checks:

1. `./zig-out/bin/makai` (or `makai.exe` on Windows)
2. `./zig/zig-out/bin/makai`
3. `makai` on `PATH`

The TypeScript resolver has one more step, an optional `@makai/cli-<platform>-<arch>` npm package, between the URL step and the local builds. That step is npm-specific and has no Go equivalent, so it is deliberately absent here. The practical difference: where npm would prefer a packaged binary, Go picks up your local `./zig-out` build.

### Transport settings

```go
client, err := makai.New(ctx, &makai.Options{
	Args:             []string{"--stdio"},
	Dir:              workingDirectory,
	Env:              append(os.Environ(), "MAKAI_LOG=info"),
	HandshakeTimeout: 5 * time.Second,
	RequestTimeout:   30 * time.Second,
	ShutdownGrace:    2 * time.Second,
	Logger:           slog.Default(),
})
```

`RequestTimeout` bounds the wait for each individual response frame, not the whole call: a long provider turn is not a timeout as long as the runtime keeps emitting frames. `Logger` receives debug records about frames, routing and process lifecycle; without one the SDK logs nothing.

`Close` closes the runtime's stdin to ask for a clean exit, waits out `ShutdownGrace`, then kills the process. It always reaps the child and joins the SDK's goroutines before returning, and is safe to call more than once.

## Error handling

Failures are typed and reachable through `errors.As`:

- `*StreamError` — provider, transport and abort failures on `Provider` and `Agent` calls. Carries `Kind`, `Code`, `ProviderID`, and the correlation ids.
- `*AuthRequiredError` — a specialized `*StreamError` for `auth_required`. It names the `ProviderID` to log in to, and unwraps to `*StreamError` so code handling only the general case still matches.
- `*ProtocolError` — model-discovery failures: invalid requests, rejections, and malformed responses.
- `*AuthError` — auth listing and login failures. `Kind` is one of `provider_error`, `cancelled`, `transport_error`, `unknown`.

Errors caused by a cancelled context wrap the context error, so `errors.Is(err, context.Canceled)` and `errors.Is(err, context.DeadlineExceeded)` work. Failures caused by a closed or dead runtime wrap `ErrClosed`.

```go
switch {
case errors.As(err, &authRequired):
	log.Printf("login required for %s", authRequired.ProviderID)
case errors.As(err, &streamErr):
	log.Printf("stream failed (%s/%s): %s", streamErr.Kind, streamErr.Code, streamErr.Message)
case errors.As(err, &protocolErr):
	log.Printf("protocol failed (%s): %s", protocolErr.Code, protocolErr.Message)
case errors.As(err, &authErr):
	log.Printf("auth failed (%s/%s): %s", authErr.Kind, authErr.Code, authErr.Message)
}
```

## Development

```bash
cd go
go vet ./...
go test -race ./...
```

Protocol-level tests run against a fake host built into the test binary, so they need no runtime and no API keys. To additionally exercise the real runtime:

```bash
zig build install --prefix /tmp/makai-go       # from the repository root
MAKAI_BINARY_PATH=/tmp/makai-go/bin/makai go test -race ./...
```

The real-runtime tests skip themselves when `MAKAI_BINARY_PATH` is unset. They isolate `HOME` (and, on macOS, `MAKAI_KEYCHAIN_SERVICE`) so a test run cannot read or write your own credentials.
