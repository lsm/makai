package makai_test

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log"
	"os"

	makai "github.com/lsm/makai/go"
)

func ExampleNew() {
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

func ExampleProviderService_Stream() {
	ctx := context.Background()
	client, err := makai.New(ctx, nil)
	if err != nil {
		log.Fatal(err)
	}
	defer client.Close()

	stream, err := client.Provider.Stream(ctx, makai.CompletionRequest{
		ModelRef: "anthropic/anthropic-messages@claude-sonnet-4-5",
		Messages: []makai.Message{makai.UserMessage("Explain lock-free queues in one paragraph.")},
		Options:  &makai.RunOptions{MaxTokens: makai.MaxTokens(256)},
	})
	if err != nil {
		log.Fatal(err)
	}
	defer stream.Close()

	for stream.Next() {
		switch event := stream.Event().(type) {
		case *makai.MessageStart:
			fmt.Fprintf(os.Stderr, "streaming %s/%s\n", event.ProviderID, event.ModelID)
		case *makai.TextDelta:
			fmt.Print(event.Delta)
		case *makai.ToolCallEvent:
			fmt.Fprintf(os.Stderr, "\ntool call: %s(%s)\n", event.Name, event.ArgumentsJSON)
		case *makai.MessageEnd:
			fmt.Fprintf(os.Stderr, "\nstop reason: %s\n", event.StopReason)
		}
	}
	if err := stream.Err(); err != nil {
		log.Fatal(err)
	}
}

func ExampleAgentService_Run() {
	ctx := context.Background()
	client, err := makai.New(ctx, nil)
	if err != nil {
		log.Fatal(err)
	}
	defer client.Close()

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
		ModelRef: "anthropic/anthropic-messages@claude-sonnet-4-5",
		Messages: []makai.Message{makai.UserMessage("Should I bring an umbrella in San Francisco?")},
		Tools:    []makai.Tool{weather},
	})
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(response.Message.Text)
}

func ExampleAuthService_Login() {
	ctx := context.Background()
	client, err := makai.New(ctx, nil)
	if err != nil {
		log.Fatal(err)
	}
	defer client.Close()

	providers, err := client.Auth.ListProviders(ctx)
	if err != nil {
		log.Fatal(err)
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
			log.Fatal(err)
		}
	}
}

// Recovering from a missing login: the SDK reports which provider needs one,
// and the caller decides whether to run the interactive flow and retry.
func ExampleAuthRequiredError() {
	ctx := context.Background()
	client, err := makai.New(ctx, nil)
	if err != nil {
		log.Fatal(err)
	}
	defer client.Close()

	request := makai.CompletionRequest{
		ModelRef: "anthropic/anthropic-messages@claude-sonnet-4-5",
		Messages: []makai.Message{makai.UserMessage("Hello")},
	}

	response, err := client.Provider.Complete(ctx, request)

	var authRequired *makai.AuthRequiredError
	if errors.As(err, &authRequired) {
		if err := client.Auth.Login(ctx, authRequired.ProviderID, makai.LoginHandlers{}); err != nil {
			log.Fatal(err)
		}
		response, err = client.Provider.Complete(ctx, request)
	}
	if err != nil {
		log.Fatal(err)
	}
	fmt.Println(response.Message.Text)
}
