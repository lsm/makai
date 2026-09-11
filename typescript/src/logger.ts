
export interface MakaiLogger {
  debug(message: string, context?: Record<string, unknown>): void;
  info(message: string, context?: Record<string, unknown>): void;
  warn(message: string, context?: Record<string, unknown>): void;
  error(message: string, context?: Record<string, unknown>): void;
}

const noopLogger: MakaiLogger = {
  debug() {},
  info() {},
  warn() {},
  error() {},
};

export function getNoopLogger(): MakaiLogger {
  return noopLogger;
}

export function isNoopLogger(logger: MakaiLogger): boolean {
  return logger === noopLogger;
}
