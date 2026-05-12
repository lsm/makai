export type TimeoutDiagnosticContext = {
  operation: string;
  timeout_ms: number;
  stream_id?: string;
  message_id?: string;
  session_id?: string;
  provider_id?: string;
  api?: string;
  model_ref?: string;
  model_id?: string;
};

export type TimeoutDiagnostics = TimeoutDiagnosticContext & {
  suggestions: string[];
};

export type ErrorWithDiagnostics = Error & {
  diagnostics?: TimeoutDiagnostics;
};

export const TIMEOUT_SUGGESTIONS = [
  "Verify the makai binary is installed, executable, and still running.",
  "Check network connectivity and provider service health.",
  "Review server logs using the included stream_id/message_id for correlation.",
  "Increase the responseTimeoutMs/frameTimeoutMs option if the provider is expected to be slow.",
] as const;

export function createTimeoutDiagnostics(context: TimeoutDiagnosticContext): TimeoutDiagnostics {
  return {
    ...context,
    suggestions: [...TIMEOUT_SUGGESTIONS],
  };
}

export function formatTimeoutMessage(context: TimeoutDiagnosticContext): string {
  const diagnostics = createTimeoutDiagnostics(context);
  const ids = formatIds(diagnostics);
  const provider = diagnostics.provider_id ? ` for provider '${diagnostics.provider_id}'` : "";
  const model = diagnostics.model_ref ? ` (model_ref='${diagnostics.model_ref}')` : "";
  return `Timed out waiting for ${diagnostics.operation} after ${diagnostics.timeout_ms}ms${provider}${model}${ids}. Suggestions: ${diagnostics.suggestions.join(" ")}`;
}

export function timeoutError(message: string, context: TimeoutDiagnosticContext): ErrorWithDiagnostics {
  const error = new Error(message) as ErrorWithDiagnostics;
  error.diagnostics = createTimeoutDiagnostics(context);
  return error;
}

export function isTimeoutLikeError(error: unknown): boolean {
  return error instanceof Error && /^timed out waiting for|^Timed out waiting for|timed out after/.test(error.message);
}

function formatIds(diagnostics: TimeoutDiagnostics): string {
  const fields: string[] = [];
  if (diagnostics.stream_id) fields.push(`stream_id=${diagnostics.stream_id}`);
  if (diagnostics.session_id) fields.push(`session_id=${diagnostics.session_id}`);
  if (diagnostics.message_id) fields.push(`message_id=${diagnostics.message_id}`);
  return fields.length > 0 ? ` (${fields.join(", ")})` : "";
}
