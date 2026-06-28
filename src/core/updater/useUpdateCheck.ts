import { useEffect, useState } from 'react';
import type { UpdateResult } from './checkForUpdate.js';
import { checkForUpdate } from './checkForUpdate.js';
import { readState, writeState, isStale, CHECK_INTERVAL_MS } from './state.js';

/**
 * Returns the latest known update result. Reads the cache immediately for an
 * instant banner, then (in interactive mode) checks on startup and every 10
 * minutes while the app stays open.
 */
export function useUpdateCheck(poll: boolean): UpdateResult | null {
  const [result, setResult] = useState<UpdateResult | null>(() => readState()?.result ?? null);

  useEffect(() => {
    let active = true;

    const refresh = async () => {
      const fresh = await checkForUpdate();
      writeState({ lastCheck: Date.now(), result: fresh });
      if (active) setResult(fresh);
    };

    if (isStale(readState(), Date.now())) void refresh();

    if (!poll) return;
    const timer = setInterval(() => void refresh(), CHECK_INTERVAL_MS);
    return () => {
      active = false;
      clearInterval(timer);
    };
  }, [poll]);

  return result;
}
