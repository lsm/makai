process.stderr.write("token exchange error 400: invalid_grant\n");
process.stdout.write(
  JSON.stringify({
    type: "error",
    provider: "fixture",
    code: "auth_failed",
    message: "fixture auth failed",
  }) + "\n",
);
process.exit(1);
