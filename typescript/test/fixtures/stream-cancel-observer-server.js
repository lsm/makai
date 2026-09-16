const fs = require("node:fs");
const readline = require("node:readline");

const framePath = process.env.MAKAI_TEST_FRAME_LOG || "";
const deltaCount = Number(process.env.MAKAI_TEST_DELTA_COUNT || 40);
const deltaIntervalMs = Number(process.env.MAKAI_TEST_DELTA_INTERVAL_MS || 25);

function record(type) {
  if (framePath) fs.appendFileSync(framePath, type + "\n");
}

function emit(frame) {
  process.stdout.write(JSON.stringify(frame) + "\n");
}

emit({ type: "ready", protocol_version: "1" });

const rl = readline.createInterface({ input: process.stdin, crlfDelay: Infinity });
const timers = new Set();

function streamFrame(request, type, payload, sequence) {
  return {
    type,
    stream_id: request.stream_id,
    message_id: `${request.stream_id}-${type}-${sequence}`,
    sequence,
    timestamp: Date.now(),
    version: 1,
    in_reply_to: request.message_id,
    payload,
  };
}

rl.on("line", (line) => {
  let request;
  try {
    request = JSON.parse(line);
  } catch {
    return;
  }
  record(String(request.type));
  if (request.type !== "stream_request") return;

  emit(streamFrame(request, "ack", { acknowledged_id: request.message_id }, 2));
  let emitted = 0;
  const handle = setInterval(() => {
    emitted += 1;
    emit(streamFrame(request, "text_delta", { delta: `chunk${emitted}` }, emitted + 2));
    if (emitted >= deltaCount) {
      clearInterval(handle);
      timers.delete(handle);
      emit(streamFrame(request, "message_end", { stop_reason: "end_turn", usage: { input: 1, output: 1 } }, emitted + 3));
    }
  }, deltaIntervalMs);
  timers.add(handle);
});

process.on("exit", () => {
  for (const handle of timers) clearInterval(handle);
});
