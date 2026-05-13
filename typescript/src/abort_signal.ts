/**
 * AbortSignal utility helpers for the Makai SDK.
 *
 * Provides a single `raceWithAbort` function used by the execution, models,
 * and auth layers to integrate `AbortSignal` with promise-based frame waits.
 */

/**
 * Rejects immediately if the signal is already aborted.
 *
 * @param signal Optional abort signal to check.
 * @param context Optional context string for the error message.
 * @throws {Error} with `name: "AbortError"` if the signal is already aborted.
 */
export function checkAbort(signal: AbortSignal | undefined, context = "operation aborted"): void {
  if (signal?.aborted) {
    const error = new Error(context);
    error.name = "AbortError";
    throw error;
  }
}

/**
 * Races a promise against an `AbortSignal`. Returns the promise result
 * normally if the operation completes before the signal fires, or rejects
 * with an `AbortError` if the signal aborts first.
 *
 * Listener cleanup is guaranteed on both resolution and rejection.
 *
 * @param promise The promise to race against the abort signal.
 * @param signal Optional abort signal.
 * @param context Optional context string for the error message on abort.
 * @returns The resolved value of the promise.
 * @throws {Error} with `name: "AbortError"` if the signal fires first or is already aborted.
 */
export function raceWithAbort<T>(
  promise: Promise<T>,
  signal: AbortSignal | undefined,
  context = "operation aborted",
): Promise<T> {
  if (!signal) return promise;

  if (signal.aborted) {
    const error = new Error(context);
    error.name = "AbortError";
    // Attach a no-op catch to prevent unhandled rejection if the caller's
    // promise rejects later.  The promise was constructed before we checked
    // the signal, so without this a late rejection could crash Node processes
    // configured to fail on unhandled rejections.
    promise.catch(() => {});
    return Promise.reject(error);
  }

  return new Promise<T>((resolve, reject) => {
    const onAbort = (): void => {
      const error = new Error(context);
      error.name = "AbortError";
      reject(error);
    };

    signal.addEventListener("abort", onAbort, { once: true });

    promise.then(
      (result) => {
        signal.removeEventListener("abort", onAbort);
        resolve(result);
      },
      (error) => {
        signal.removeEventListener("abort", onAbort);
        reject(error);
      },
    );
  });
}

/**
 * Returns true if the error was caused by abort signal cancellation.
 *
 * @param error The error to inspect.
 */
export function isAbortError(error: unknown): error is Error & { name: "AbortError" } {
  return error instanceof Error && error.name === "AbortError";
}
