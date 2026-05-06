// Fixture stdio server for verifying prompt-handler failures are drained.
// First login flow prompts and then returns a terminal cancelled result after
// the client sends auth_cancel. The server then accepts a second login flow on
// the same transport, proving the first flow did not leave orphaned frames that
// poison future calls.
const readline = require("node:readline");
const { ulid } = require("ulid");

process.stdout.write(JSON.stringify({ type: "ready", protocol_version: "1" }) + "\n");

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });

const outboundSequences = new Map();
function nextSeq(streamId) {
  const next = (outboundSequences.get(streamId) ?? 0) + 1;
  outboundSequences.set(streamId, next);
  return next;
}

function send(envelope) {
  process.stdout.write(JSON.stringify(envelope) + "\n");
}

function ack(envelope) {
  send({
    type: "ack",
    stream_id: envelope.stream_id,
    message_id: ulid(),
    sequence: nextSeq(envelope.stream_id),
    in_reply_to: envelope.message_id,
    timestamp: Date.now(),
    version: 1,
    payload: { acknowledged_id: envelope.message_id },
  });
}

const flows = new Map();

rl.on("line", (line) => {
  let envelope;
  try {
    envelope = JSON.parse(line);
  } catch {
    return;
  }

  if (envelope.type === "auth_login_start") {
    const flowId = envelope.stream_id;
    const providerId = envelope.payload?.provider_id ?? "fixture";
    flows.set(flowId, { providerId });
    ack(envelope);
    send({
      type: "auth_event",
      stream_id: flowId,
      message_id: ulid(),
      sequence: nextSeq(flowId),
      timestamp: Date.now(),
      version: 1,
      payload: {
        prompt: {
          flow_id: flowId,
          prompt_id: "device_code",
          provider_id: providerId,
          message: "Enter the code shown in browser",
          allow_empty: false,
        },
      },
    });
    return;
  }

  if (envelope.type === "auth_cancel") {
    const flow = flows.get(envelope.stream_id);
    if (!flow) return;
    ack(envelope);
    send({
      type: "auth_event",
      stream_id: envelope.stream_id,
      message_id: ulid(),
      sequence: nextSeq(envelope.stream_id),
      timestamp: Date.now(),
      version: 1,
      payload: {
        error: {
          flow_id: envelope.stream_id,
          provider_id: flow.providerId,
          code: "cancelled",
          message: "fixture auth cancelled",
        },
      },
    });
    send({
      type: "auth_login_result",
      stream_id: envelope.stream_id,
      message_id: ulid(),
      sequence: nextSeq(envelope.stream_id),
      timestamp: Date.now(),
      version: 1,
      payload: {
        flow_id: envelope.stream_id,
        provider_id: flow.providerId,
        status: "cancelled",
      },
    });
    flows.delete(envelope.stream_id);
    return;
  }

  if (envelope.type === "auth_prompt_response") {
    const flow = flows.get(envelope.stream_id);
    if (!flow) return;
    ack(envelope);
    send({
      type: "auth_event",
      stream_id: envelope.stream_id,
      message_id: ulid(),
      sequence: nextSeq(envelope.stream_id),
      timestamp: Date.now(),
      version: 1,
      payload: {
        success: { flow_id: envelope.stream_id, provider_id: flow.providerId },
      },
    });
    send({
      type: "auth_login_result",
      stream_id: envelope.stream_id,
      message_id: ulid(),
      sequence: nextSeq(envelope.stream_id),
      timestamp: Date.now(),
      version: 1,
      payload: {
        flow_id: envelope.stream_id,
        provider_id: flow.providerId,
        status: "success",
      },
    });
    flows.delete(envelope.stream_id);
  }
});
