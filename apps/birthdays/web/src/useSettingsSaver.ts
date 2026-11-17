import { useCallback, useRef, useState } from "react";
import type { Dispatch, SetStateAction } from "react";
import { patchSettings } from "./api";
import type { Failure, Prefs, Settings } from "./api";

const PREF_KEYS: (keyof Prefs)[] = [
  "auto_remind",
  "default_offsets",
  "start_tab",
  "list_view",
  "calendar_zoom",
  "color_scheme",
];

const MSG_SAVING = "Saving…";
const MSG_SAVED = "Saved.";
const MSG_SAVE_FAILED = "Couldn't save that. It is changed on this screen only.";

// The one helper behind every PATCH /api/settings in the app. Local state changes at once; a single PATCH is in
// flight; the latest desired value per field is kept and coalesced into the next PATCH; "Saved." appears only when the
// last one lands; a failure is a quiet status line. It owns the preference fields of S: a PATCH response applies a
// field only when that field has no newer pending value, and notify responses (applyCounters) never touch them.
export function useSettingsSaver(
  setSettings: Dispatch<SetStateAction<Settings | null>>,
  onFailure: (f: Failure) => boolean,
) {
  const desired = useRef<Partial<Prefs>>({});
  const running = useRef(false);
  // Fields whose last PATCH failed: they stay as changed on screen, so a later response must not revert them.
  const overridden = useRef<Set<keyof Prefs>>(new Set());
  // The newest value the person chose per field that the server has not answered for yet (or that failed to save).
  // Handlers that derive a value from the previous one (ticking a box) read it through latest(), never the render.
  const latestRef = useRef<Partial<Prefs>>({});
  const [status, setStatus] = useState("");
  const [error, setError] = useState(false);

  const run = useCallback(async () => {
    if (running.current) {
      return;
    }
    running.current = true;
    let failed = false;
    let sessionLost = false;
    while (Object.keys(desired.current).length > 0) {
      const sending = desired.current;
      desired.current = {};
      setStatus(MSG_SAVING);
      setError(false);
      const res = await patchSettings(sending);
      if (res.kind === "ok") {
        failed = false;
        for (const k of Object.keys(sending) as (keyof Prefs)[]) {
          overridden.current.delete(k);
        }
        const skip = new Set(overridden.current);
        const pending = desired.current;
        const server = res.data;
        for (const k of Object.keys(sending) as (keyof Prefs)[]) {
          if (!(k in pending)) {
            delete latestRef.current[k];
          }
        }
        setSettings((s) => {
          if (s === null) {
            return server;
          }
          const next: Settings = {
            ...s,
            ntfy: server.ntfy,
            destinations: server.destinations,
            stale_destinations: server.stale_destinations,
          };
          const out: Record<string, unknown> = next;
          for (const k of PREF_KEYS) {
            if (!(k in pending) && !skip.has(k)) {
              out[k] = server[k];
            }
          }
          return next;
        });
      } else {
        failed = true;
        for (const k of Object.keys(sending) as (keyof Prefs)[]) {
          overridden.current.add(k);
        }
        if (onFailure(res)) {
          desired.current = {};
          latestRef.current = {};
          sessionLost = true;
          break;
        }
      }
    }
    running.current = false;
    setStatus(sessionLost ? "" : failed ? MSG_SAVE_FAILED : MSG_SAVED);
    setError(failed && !sessionLost);
  }, [setSettings, onFailure]);

  const save = useCallback(
    (patch: Partial<Prefs>) => {
      setSettings((s) => (s === null ? s : { ...s, ...patch }));
      desired.current = { ...desired.current, ...patch };
      latestRef.current = { ...latestRef.current, ...patch };
      void run();
    },
    [setSettings, run],
  );

  const latest = useCallback(<K extends keyof Prefs>(key: K): Prefs[K] | undefined => latestRef.current[key], []);

  // A notify response updates only the server-derived counters.
  const applyCounters = useCallback(
    (s: Settings) => {
      setSettings((cur) =>
        cur === null
          ? cur
          : { ...cur, ntfy: s.ntfy, destinations: s.destinations, stale_destinations: s.stale_destinations },
      );
    },
    [setSettings],
  );

  return { save, latest, status, error, applyCounters };
}

export type SettingsSaver = ReturnType<typeof useSettingsSaver>;
