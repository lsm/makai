package makai

import (
	"context"
	"encoding/json"
	"fmt"
	"time"
)

// AgentService runs the runtime's agent loop: it manages provider turns and
// the tool-execution lifecycle, and asks this client to run the tools the
// model calls.
type AgentService struct {
	transport *transport
	timeout   time.Duration
}

// Run executes an agent run to completion and returns the final assistant
// response.
//
// Tools with an Execute function are invoked as the model calls them. A tool
// the model calls but that has no Execute is reported back to the model as
// not executable by this client.
//
// Failures are [*StreamError], or [*AuthRequiredError] when a provider turn
// failed for lack of credentials. Note that a provider failure can also
// settle normally: check [CompletionResponse].StopReason for "error" and
// ErrorMessage for the detail.
//
// Cancelling ctx aborts the run, asks the runtime to stop the session, and
// returns an error wrapping ctx.Err().
func (s *AgentService) Run(ctx context.Context, req AgentRequest) (*CompletionResponse, error) {
	run, err := s.begin(ctx, req)
	if err != nil {
		return nil, err
	}
	defer run.close()

	var events []AgentEvent
	for {
		batch, err := run.pump()
		if err != nil {
			run.teardownAfter(err)
			return nil, withSessionID(err, run.sessionID)
		}
		if run.result != nil {
			run.teardown("completed", true)
			return responseOrAuthError(run.result, run.fallbackProvider)
		}
		for _, event := range batch {
			if errEvent, ok := event.(*ErrorEvent); ok {
				failure := streamErrorFromEvent(errEvent, run.fallbackProvider, run.sessionID)
				run.teardown("completed", true)
				return nil, failure
			}
			events = append(events, event)
			if _, ok := event.(*AgentEnd); ok {
				run.teardown("completed", true)
				return responseOrAuthError(buildResponseFromEvents(events), run.fallbackProvider)
			}
		}
	}
}

// Stream executes an agent run and reports its events as they arrive.
//
// The returned [*AgentStream] must be closed when the caller is done with it:
//
//	stream, err := client.Agent.Stream(ctx, req)
//	if err != nil {
//		return err
//	}
//	defer stream.Close()
//	for stream.Next() {
//		switch event := stream.Event().(type) {
//		case *makai.TextDelta:
//			fmt.Print(event.Delta)
//		case *makai.ToolExecutionStart:
//			log.Printf("running %s", event.ToolName)
//		}
//	}
//	return stream.Err()
//
// Closing before the run finishes stops the session, so an abandoned stream
// does not leave a run holding its session id.
func (s *AgentService) Stream(ctx context.Context, req AgentRequest) (*AgentStream, error) {
	run, err := s.begin(ctx, req)
	if err != nil {
		return nil, err
	}
	return &AgentStream{run: run}, nil
}

func (s *AgentService) begin(ctx context.Context, req AgentRequest) (*agentRun, error) {
	if err := validateExecutionRequest(req.ModelRef, req.Messages); err != nil {
		return nil, err
	}
	sessionID := req.sessionID()
	if sessionID == "" {
		return nil, &ProtocolError{
			Code:    CodeInvalidRequest,
			Message: "options.session_id must be a 21-character alphanumeric NanoID",
		}
	}
	if err := ctx.Err(); err != nil {
		return nil, abortError(err, "agent run")
	}

	run := &agentRun{
		ctx:               ctx,
		transport:         s.transport,
		timeout:           s.timeout,
		request:           req,
		sessionID:         sessionID,
		idClientGenerated: req.Options == nil || req.Options.SessionID == "",
		fallbackProvider:  providerIDFromRef(req.ModelRef),
		toolBuf:           newToolBuffer(),
		nextSequence:      1,
	}
	run.sub = s.transport.subscribeSession(sessionID)

	start := newSessionEnvelope("agent_start", sessionID, 1, map[string]any{
		"session_id": sessionID,
		// resume_session_id is the pre-rename alias for the same value.
		// Emitting both keeps pre-rename runtimes binding the caller's id.
		"resume_session_id": sessionID,
		"config_json":       string(mustMarshal(map[string]any{"model_ref": req.ModelRef, "tools": serializeTools(req.Tools)})),
	})
	run.startMessageID = start.MessageID
	run.sub.correlate(start.MessageID)

	if err := s.transport.send(start); err != nil {
		run.sub.close()
		return nil, err
	}
	run.nextSequence = 2
	return run, nil
}

// sessionID returns the run's session id, generating one when the caller did
// not supply it, and "" when the caller supplied an invalid one.
func (r AgentRequest) sessionID() string {
	if r.Options == nil || r.Options.SessionID == "" {
		return newNanoID()
	}
	if !isNanoID(r.Options.SessionID) {
		return ""
	}
	return r.Options.SessionID
}

// AgentStream iterates the events of one agent run.
//
// It is not safe for concurrent use: drive it from one goroutine.
type AgentStream struct {
	run     *agentRun
	pending []AgentEvent
	current AgentEvent
	err     error
	done    bool
	started bool
}

// Next advances to the next event, reporting whether one is available.
// It returns false at the end of the run and on failure; check
// [AgentStream.Err] to tell the two apart.
func (s *AgentStream) Next() bool {
	if s.done {
		return false
	}
	for {
		if len(s.pending) > 0 {
			event := s.pending[0]
			s.pending = s.pending[1:]

			switch value := event.(type) {
			case *ErrorEvent:
				s.fail(streamErrorFromEvent(value, s.run.fallbackProvider, s.run.sessionID))
				return false
			case *AgentEnd:
				// Aggregate usage across every provider turn, since the
				// runtime's agent_end reports only the last one.
				if s.run.aggregateUsage != nil {
					value.Usage = s.run.aggregateUsage
				}
				s.done = true
				if value.StopReason == "error" && isAuthFailureMessage(value.ErrorMessage, value.API) {
					s.fail(newAuthRequiredError(firstNonEmpty(value.ProviderID, s.run.fallbackProvider), value.ErrorMessage))
					return false
				}
			case *MessageEnd:
				s.run.aggregateUsage = s.run.aggregateUsage.add(value.Usage)
			}

			// The runtime does not always open a run with agent_start;
			// synthesize one so every stream starts the same way.
			if !s.started {
				s.started = true
				if _, ok := event.(*AgentStart); !ok {
					s.pending = append([]AgentEvent{event}, s.pending...)
					s.current = &AgentStart{SessionID: s.run.sessionID}
					s.done = false
					return true
				}
			}
			s.current = event
			return true
		}

		batch, err := s.run.pump()
		if err != nil {
			s.fail(withSessionID(err, s.run.sessionID))
			return false
		}
		if s.run.result != nil {
			// The run settled through a result frame rather than an
			// agent_end event; project it as the terminal event.
			s.pending = append(s.pending, agentEndFromResponse(s.run.result))
			s.run.result = nil
			continue
		}
		s.pending = append(s.pending, batch...)
	}
}

// Event returns the event [AgentStream.Next] just advanced to.
func (s *AgentStream) Event() AgentEvent { return s.current }

// Err returns the failure that ended the run, or nil if it ended normally.
func (s *AgentStream) Err() error { return s.err }

// Close stops the run's session and releases its frame route. It is
// idempotent and returns the same error as [AgentStream.Err].
func (s *AgentStream) Close() error {
	if s.run == nil {
		return s.err
	}
	if s.err != nil && isAbort(s.err) {
		s.run.teardown("client aborted", false)
	} else {
		s.run.teardown("completed", true)
	}
	s.run.close()
	s.run = nil
	s.done = true
	return s.err
}

func (s *AgentStream) fail(err error) {
	s.err = err
	s.done = true
	s.current = nil
}

func agentEndFromResponse(response *CompletionResponse) *AgentEnd {
	return &AgentEnd{
		StopReason:   response.StopReason,
		Usage:        response.Usage,
		ErrorMessage: response.ErrorMessage,
		ProviderID:   response.ProviderID,
		API:          response.API,
	}
}

// agentRun is the state machine shared by Run and Stream: it owns the
// session's frame route, the outbound sequence, and the tool side channel.
type agentRun struct {
	ctx       context.Context
	transport *transport
	sub       *subscription
	timeout   time.Duration
	request   AgentRequest

	sessionID         string
	idClientGenerated bool
	fallbackProvider  string
	toolBuf           *toolBuffer

	startMessageID   string
	messageMessageID string
	startAccepted    bool
	messageSent      bool

	// nextSequence is the session's next expected inbound sequence:
	// 1 for agent_start, 2 for the first agent_message, then one per
	// follow-up. Tool replies do not consume a sequence number.
	nextSequence int64
	// unresolvedMessageSequence records the sequence an agent_message was
	// sent with while its acceptance is still unknown, so teardown can probe
	// both the pre-send and post-send values.
	unresolvedMessageSequence int64

	startReplyObserved bool
	foreignSession     bool
	stopped            bool

	aggregateUsage *Usage
	result         *CompletionResponse
}

// pump reads frames until it produces agent events, settles the run into
// result, or fails. An empty batch with a nil error means the caller should
// call pump again.
func (r *agentRun) pump() ([]AgentEvent, error) {
	for {
		f, err := r.sub.next(r.ctx, r.timeout, "agent stream event")
		if err != nil {
			return nil, err
		}
		if f.Type == "ack" || f.Type == "agent_stopped" {
			continue
		}
		// Before the start is accepted, this attempt owns nothing
		// uncorrelated on the session route: park anything that is not a
		// reply to its own agent_start.
		if !r.startAccepted && f.Type != "agent_started" && f.Type != "nack" && f.Type != "agent_error" {
			continue
		}

		switch f.Type {
		case "nack", "agent_error":
			if !r.startAccepted && f.InReplyTo != "" && f.InReplyTo != r.startMessageID {
				continue
			}
			r.startReplyObserved = true
			if r.messageSent && f.InReplyTo == r.messageMessageID {
				r.rollbackMessage()
			}
			var failure error
			if f.Type == "nack" {
				failure = nackToError(f, r.fallbackProvider, "", r.sessionID)
			} else {
				failure = errorFrameToError(f, r.fallbackProvider, "", r.sessionID)
			}
			r.noteForeignSession(failure)
			return nil, failure

		case "agent_started":
			if f.InReplyTo != "" && f.InReplyTo != r.startMessageID {
				continue
			}
			r.startAccepted = true
			r.startReplyObserved = true
			if !r.messageSent {
				if err := r.sendMessage(); err != nil {
					return nil, err
				}
			}
			continue

		case "tool_execute":
			r.unresolvedMessageSequence = 0
			if err := r.executeTool(f); err != nil {
				return nil, err
			}
			continue

		case "agent_result":
			r.unresolvedMessageSequence = 0
			payload, err := f.jsonPayload("result_json")
			if err != nil {
				return nil, err
			}
			r.result = parseAgentRunResponse(payload)
			return nil, nil

		case "result", "complete_response":
			r.unresolvedMessageSequence = 0
			r.result = parseCompletionResponse(f.payload())
			return nil, nil
		}

		events, err := normalizeAgentFrame(f, r.toolBuf)
		if err != nil {
			return nil, err
		}
		if len(events) == 0 {
			// A known event frame that projects no SDK-visible event, such
			// as a tool_execution_update, is not a protocol failure.
			if f.Type == "agent_event" || f.Type == "event" {
				continue
			}
			return nil, &StreamError{
				Kind:      KindTransportError,
				Message:   fmt.Sprintf("unexpected frame type %q while awaiting an agent result", f.Type),
				SessionID: r.sessionID,
			}
		}
		r.unresolvedMessageSequence = 0
		return events, nil
	}
}

func (r *agentRun) sendMessage() error {
	messageJSON := map[string]any{
		"model_ref": r.request.ModelRef,
		"messages":  agentMessages(r.request.Messages),
		"tools":     serializeTools(r.request.Tools),
	}
	payload := map[string]any{
		"session_id":   r.sessionID,
		"message_json": string(mustMarshal(messageJSON)),
	}
	if options := serializeOptions(r.request.Options); len(options) > 0 {
		payload["options_json"] = string(mustMarshal(options))
	}

	envelope := newSessionEnvelope("agent_message", r.sessionID, 2, payload)
	r.messageMessageID = envelope.MessageID
	r.sub.correlate(envelope.MessageID)
	if err := r.transport.send(envelope); err != nil {
		return err
	}
	r.messageSent = true
	r.nextSequence = 3
	r.unresolvedMessageSequence = 2
	return nil
}

// rollbackMessage restores the session's expected sequence after the runtime
// rejected an agent_message: a rejected submission admits nothing, so the
// runtime's counter did not advance.
func (r *agentRun) rollbackMessage() {
	if r.unresolvedMessageSequence == 0 {
		return
	}
	r.nextSequence = r.unresolvedMessageSequence
	r.unresolvedMessageSequence = 0
}

// noteForeignSession records that the session id belongs to another live run,
// which makes it not this attempt's to stop.
func (r *agentRun) noteForeignSession(err error) {
	var streamErr *StreamError
	if asStreamError(err, &streamErr) && streamErr.Code == CodeAgentBusy && !r.startAccepted {
		r.foreignSession = true
	}
}

func (r *agentRun) executeTool(f *frame) error {
	payload := f.payload()
	invocation := ToolInvocation{
		ToolCallID:    payload.str("tool_call_id"),
		ToolName:      payload.str("tool_name"),
		ArgumentsJSON: payload.strOrDefault("{}", "args_json"),
	}

	tool := findTool(r.request.Tools, invocation.ToolName)
	if tool == nil || tool.Execute == nil {
		return r.sendToolResult(f, invocation.ToolCallID,
			fmt.Sprintf("Tool %q is not executable by this client", invocation.ToolName), true)
	}

	result, err := tool.Execute(r.ctx, invocation)
	if err != nil {
		// A tool failure is reported to the model rather than ending the
		// run, so the model can react to it.
		return r.sendToolResult(f, invocation.ToolCallID, err.Error(), true)
	}
	return r.sendToolResult(f, invocation.ToolCallID, result, false)
}

func (r *agentRun) sendToolResult(request *frame, toolCallID, text string, isError bool) error {
	resultJSON, err := json.Marshal([]map[string]any{{"type": "text", "text": text}})
	if err != nil {
		return transportErrorf(err, "cannot encode tool result for %s", toolCallID)
	}
	return r.transport.send(newReplyEnvelope("tool_result", request, map[string]any{
		"tool_call_id": toolCallID,
		"result_json":  string(resultJSON),
		"is_error":     isError,
	}))
}

// teardown stops the run's session so its id does not stay registered until
// the runtime's idle TTL evicts it.
//
// It deliberately does not send in two cases. A session rejected with
// agent_busy belongs to another live run, and stopping it would cancel that
// run. A caller-supplied id whose agent_start drew no reply at all has an
// unknown owner: the start may have lost a race, and a stop carrying the
// expected sequence would then destroy the winner's session. Leaving such a
// session for the idle TTL is strictly better than tearing down someone
// else's run.
func (r *agentRun) teardown(reason string, probe bool) {
	if r.stopped {
		return
	}
	r.stopped = true
	if r.foreignSession {
		return
	}
	if !r.startReplyObserved && !r.idClientGenerated {
		return
	}
	if !probe || r.unresolvedMessageSequence == 0 {
		stopAgent(r.transport, r.sessionID, r.nextSequence, reason)
		r.sub.drain(drainIdle, drainBudget)
		return
	}
	r.stopWithSequenceProbe(reason)
}

func (r *agentRun) teardownAfter(err error) {
	if isAbort(err) {
		r.teardown("client aborted", false)
		return
	}
	r.teardown("completed", true)
}

// stopWithSequenceProbe stops a session whose last agent_message has an
// unknown outcome. The runtime's expected sequence depends on whether that
// message was accepted, so the pre-send value is tried first and the
// post-send value only if the runtime rejects it as out of order.
func (r *agentRun) stopWithSequenceProbe(reason string) {
	ctx, cancel := context.WithTimeout(context.Background(), drainBudget)
	defer cancel()

	candidates := []int64{r.unresolvedMessageSequence}
	if r.nextSequence != r.unresolvedMessageSequence {
		candidates = append(candidates, r.nextSequence)
	}
	for _, sequence := range candidates {
		messageID := stopAgent(r.transport, r.sessionID, sequence, reason)
		settled, retry := r.awaitStopReply(ctx, messageID)
		if settled || !retry {
			return
		}
	}
}

// awaitStopReply waits for the reply to one agent_stop. It reports whether
// the stop settled the session, and whether a different sequence is worth
// trying.
func (r *agentRun) awaitStopReply(ctx context.Context, messageID string) (settled, retry bool) {
	for {
		f, err := r.sub.next(ctx, drainBudget, "agent_stopped")
		if err != nil {
			return false, false
		}
		if f.InReplyTo != messageID {
			continue
		}
		if f.Type == "agent_stopped" {
			return true, false
		}
		if f.Type != "agent_error" && f.Type != "nack" {
			continue
		}
		payload := f.payload()
		switch payload.str("code", "error_code") {
		case CodeInvalidRequest, "invalid_sequence":
			return false, true
		default:
			return false, false
		}
	}
}

func (r *agentRun) close() {
	if r.sub != nil {
		r.sub.close()
	}
}

func findTool(tools []Tool, name string) *Tool {
	for i := range tools {
		if tools[i].Name == name {
			return &tools[i]
		}
	}
	return nil
}

func agentMessages(messages []Message) []map[string]any {
	out := make([]map[string]any, 0, len(messages))
	for _, message := range messages {
		entry := map[string]any{"role": string(message.Role)}
		if len(message.Parts) > 0 {
			entry["content"] = message.Parts
		} else {
			entry["content"] = message.Text
		}
		if message.Name != "" {
			entry["name"] = message.Name
		}
		if message.ToolCallID != "" {
			entry["tool_call_id"] = message.ToolCallID
		}
		out = append(out, entry)
	}
	return out
}

func streamErrorFromEvent(event *ErrorEvent, fallbackProvider, sessionID string) error {
	providerID := firstNonEmpty(event.ProviderID, "")
	if providerID == "" && isAuthCode(event.Code) {
		providerID = fallbackProvider
	}
	if event.Code == CodeAuthRequired {
		return newAuthRequiredError(providerID, event.Message)
	}
	return &StreamError{
		Kind:       KindProviderError,
		Code:       event.Code,
		ProviderID: providerID,
		Message:    event.Message,
		SessionID:  sessionID,
	}
}
