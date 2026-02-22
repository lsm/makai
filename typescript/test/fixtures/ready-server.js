const readline = require("node:readline");

process.stdout.write(JSON.stringify({ type: "ready", protocol_version: "1" }) + "\n");

const rl = readline.createInterface({
  input: process.stdin,
  crlfDelay: Infinity,
});

rl.on("line", (line) => {
  try {
    const msg = JSON.parse(line);
    if (msg.type === "stream_request") {
      process.stdout.write(
        JSON.stringify({
          type: "event",
          stream_id: msg.stream_id ?? "unknown",
          event_type: "text_delta",
          delta: "ok",
        }) + "\n",
      );
    }
  } catch {
    // ignore malformed frames in fixture
  }
});
