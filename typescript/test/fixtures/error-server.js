process.stdout.write(
  JSON.stringify({
    type: "error",
    code: "version_mismatch",
    message: "unsupported protocol",
  }) + "\n",
);
