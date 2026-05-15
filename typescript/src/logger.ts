/**
 * Structured debug logging interface for the Makai TypeScript SDK.
 *
 * When no logger is configured, a zero-overhead no-op implementation is used.
 * Supply a custom `MakaiLogger` via `createMakaiClient({ logger })` or
 * `createMakaiAuthClient({ logger })` to capture diagnostic information.
 */

/** Structured logger interface accepted by Makai client factories. */
export interface MakaiLogger {
  debug(message: string, context?: Record<string, unknown>): void;
  info(message: string, context?: Record<string, unknown>): void;
  warn(message: string, context?: Record<string, unknown>): void;
  error(message: string, context?: Record<string, unknown>): void;
}

/** No-op logger — default when no logger is configured. Zero overhead. */
const noopLogger: MakaiLogger = {
  debug() {},
  info() {},
  warn() {},
  error() {},
};

/**
 * Returns the no-op logger singleton.
 *
 * Every call returns the same object, so identity checks like
 * `logger === getNoopLogger()` can be used for branching in hot paths.
 */
export function getNoopLogger(): MakaiLogger {
  return noopLogger;
}

/**
 * Tests whether a logger is the no-op singleton.
 *
 * Use this to skip context-object allocation on hot paths when logging is
 * disabled. Identity comparison is safe because `getNoopLogger()` always
 * returns the same object.
 */
export function isNoopLogger(logger: MakaiLogger): boolean {
  return logger === noopLogger;
}
