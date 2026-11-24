/**
 * Shared coalescing observer for derived projections backed by Pi commits / live subscriptions.
 * Subscribes before reading the initial snapshot so no commit between subscribe and read is missed.
 */
export async function watchDerived<T>(options: {
  read: () => Promise<T>;
  identity: (value: T) => string;
  subscribe: (schedule: () => void) => Promise<() => void> | (() => void);
  emit: (value: T) => void;
  failed: (error: unknown) => void;
}): Promise<() => Promise<void>> {
  let closed = false;
  let subscribed = false;
  let dirty = false;
  let pending: Promise<void> | undefined;
  let previous: string | undefined;

  const refresh = (): Promise<void> => {
    if (closed) return Promise.resolve();
    dirty = true;
    return pending ??= (async () => {
      try {
        while (dirty && !closed) {
          dirty = false;
          const value = await options.read();
          if (closed) return;
          const nextIdentity = options.identity(value);
          if (nextIdentity !== previous) {
            previous = nextIdentity;
            options.emit(value);
          }
        }
      } catch (error) {
        dirty = false;
        throw error;
      }
    })().finally(() => {
      pending = undefined;
      if (dirty && !closed) {
        void refresh().catch((error: unknown) => {
          if (!closed) options.failed(error);
        });
      }
    });
  };

  const schedule = () => {
    if (closed) return;
    dirty = true;
    if (subscribed && pending === undefined) {
      void refresh().catch((error: unknown) => {
        if (!closed) options.failed(error);
      });
    }
  };

  const detach = await options.subscribe(schedule);
  try {
    subscribed = true;
    await refresh();
  } catch (error) {
    closed = true;
    detach();
    throw error;
  }

  return async () => {
    if (closed) return;
    closed = true;
    detach();
    await pending;
  };
}
