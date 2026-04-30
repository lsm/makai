// Fixture stdio server that emulates a successful auth login flow.
const readline = require("node:readline");
const crypto = require("node:crypto");

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
    message_id: crypto.randomUUID(),
    sequence: nextSeq(envelope.stream_id),
    in_reply_to: envelope.message_id,
    timestamp: Date.now(),
    version: 1,
    payload: { acknowledged_id: envelope.message_id },
  });
}

let flowState = null;

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
    flowState = { flowId, providerId };
    ack(envelope);

    send({
      type: "auth_event",
      stream_id: flowId,
      message_id: crypto.randomUUID(),
      sequence: nextSeq(flowId),
      timestamp: Date.now(),
      version: 1,
      payload: {
        auth_url: {
          flow_id: flowId,
          provider_id: providerId,
          url: "https://example.invalid/fixture-login",
          instructions: "open the link in a browser",
        },
      },
    });

    send({
      type: "auth_event",
      stream_id: flowId,
      message_id: crypto.randomUUID(),
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

  if (envelope.type === "auth_prompt_response") {
    if (!flowState) return;
    ack(envelope);
    const answer = envelope.payload?.answer ?? "";
    if (answer === "letmein") {
      send({
        type: "auth_event",
        stream_id: flowState.flowId,
        message_id: crypto.randomUUID(),
        sequence: nextSeq(flowState.flowId),
        timestamp: Date.now(),
        version: 1,
        payload: {
          success: { flow_id: flowState.flowId, provider_id: flowState.providerId },
        },
      });
      send({
        type: "auth_login_result",
        stream_id: flowState.flowId,
        message_id: crypto.randomUUID(),
        sequence: nextSeq(flowState.flowId),
        timestamp: Date.now(),
        version: 1,
        payload: {
          flow_id: flowState.flowId,
          provider_id: flowState.providerId,
          status: "success",
        },
      });
      return;
    }
    send({
      type: "auth_event",
      stream_id: flowState.flowId,
      message_id: crypto.randomUUID(),
      sequence: nextSeq(flowState.flowId),
      timestamp: Date.now(),
      version: 1,
      payload: {
        error: {
          flow_id: flowState.flowId,
          provider_id: flowState.providerId,
          code: "invalid_code",
          message: "fixture rejected the supplied code",
        },
      },
    });
    send({
      type: "auth_login_result",
      stream_id: flowState.flowId,
      message_id: crypto.randomUUID(),
      sequence: nextSeq(flowState.flowId),
      timestamp: Date.now(),
      version: 1,
      payload: {
        flow_id: flowState.flowId,
        provider_id: flowState.providerId,
        status: "failed",
      },
    });
    return;
  }

  if (envelope.type === "auth_cancel" && flowState) {
    ack(envelope);
    send({
      type: "auth_login_result",
      stream_id: flowState.flowId,
      message_id: crypto.randomUUID(),
      sequence: nextSeq(flowState.flowId),
      timestamp: Date.now(),
      version: 1,
      payload: {
        flow_id: flowState.flowId,
        provider_id: flowState.providerId,
        status: "cancelled",
      },
    });
  }
});
