const fs = require("node:fs");

const pidFile = process.env.MAKAI_TEST_PID_FILE;
if (pidFile) fs.writeFileSync(pidFile, String(process.pid));

const handshake = process.env.MAKAI_TEST_HANDSHAKE || "silent";
if (handshake === "version_mismatch") {
  process.stdout.write(JSON.stringify({ type: "ready", protocol_version: "99" }) + "\n");
} else if (handshake === "error_frame") {
  process.stdout.write(JSON.stringify({ type: "error", code: "version_mismatch", message: "unsupported protocol" }) + "\n");
}

setInterval(() => {}, 1000);
