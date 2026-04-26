// Fixture stdio server that emulates a cancelled auth login flow.
// Emits ack + terminal `auth_login_result.status = cancelled` with no
// preceding auth events. Used by the SDK auth client tests.
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

rl.on("line", (line) => {
  let envelope;
  try {
    envelope = JSON.parse(line);
  } catch {
    return;
  }
  if (envelope.type !== "auth_login_start") return;

  const flowId = envelope.stream_id;
  const providerId = envelope.payload?.provider_id ?? "fixture";

  process.stdout.write(
    JSON.stringify({
      type: "ack",
      stream_id: flowId,
      message_id: crypto.randomUUID(),
      sequence: nextSeq(flowId),
      in_reply_to: envelope.message_id,
      timestamp: Date.now(),
      version: 1,
      payload: { acknowledged_id: envelope.message_id },
    }) + "\n",
  );
  process.stdout.write(
    JSON.stringify({
      type: "auth_login_result",
      stream_id: flowId,
      message_id: crypto.randomUUID(),
      sequence: nextSeq(flowId),
      timestamp: Date.now(),
      version: 1,
      payload: {
        flow_id: flowId,
        provider_id: providerId,
        status: "cancelled",
      },
    }) + "\n",
  );
});
