
export function checkAbort(signal: AbortSignal | undefined, context = "operation aborted"): void {
  if (signal?.aborted) {
    const error = new Error(context);
    error.name = "AbortError";
    throw error;
  }
}

export function raceWithAbort<T>(
  promise: Promise<T>,
  signal: AbortSignal | undefined,
  context = "operation aborted",
): Promise<T> {
  if (!signal) return promise;

  if (signal.aborted) {
    const error = new Error(context);
    error.name = "AbortError";
    promise.catch(() => {});
    return Promise.reject(error);
  }

  return new Promise<T>((resolve, reject) => {
    let settled = false;

    const onAbort = (): void => {
      queueMicrotask(() => {
        if (settled) return;
        settled = true;
        const error = new Error(context);
        error.name = "AbortError";
        reject(error);
      });
    };

    signal.addEventListener("abort", onAbort, { once: true });

    promise.then(
      (result) => {
        if (settled) return;
        settled = true;
        signal.removeEventListener("abort", onAbort);
        resolve(result);
      },
      (error) => {
        if (settled) return;
        settled = true;
        signal.removeEventListener("abort", onAbort);
        reject(error);
      },
    );
  });
}

export function isAbortError(error: unknown): error is Error & { name: "AbortError" } {
  return error instanceof Error && error.name === "AbortError";
}
