// Hash routes (no router dependency): #/add, #/birthdays, #/b/<id>, #/settings. `#/`, no hash and an unknown hash are
// "pending": resolved once from the person's start tab after GET /api/me.
import type { StartTab } from "./api";

export type Origin = "add" | "birthdays";
export type Tab = "add" | "birthdays" | "settings";
export type Route =
  | { kind: "pending" }
  | { kind: Tab }
  | { kind: "detail"; id: number | null; origin: Origin };

const NARROW_QUERY = "(max-width: 39.99rem)";

function isOrigin(v: unknown): v is Origin {
  return v === "add" || v === "birthdays";
}

// The marker the app pushes with a detail entry (never document.referrer): which tab it was opened from.
export function originOf(state: unknown): Origin | null {
  if (typeof state === "object" && state !== null && "origin" in state) {
    const o = (state as { origin: unknown }).origin;
    return isOrigin(o) ? o : null;
  }
  return null;
}

export function readRoute(): Route {
  const hash = window.location.hash;
  if (hash === "#/add") {
    return { kind: "add" };
  }
  if (hash === "#/birthdays") {
    return { kind: "birthdays" };
  }
  if (hash === "#/settings") {
    return { kind: "settings" };
  }
  const m = /^#\/b\/([^/]*)$/.exec(hash);
  if (m !== null) {
    const raw = m[1] ?? "";
    const id = /^\d{1,15}$/.test(raw) ? Number(raw) : null;
    return { kind: "detail", id, origin: originOf(window.history.state) ?? "birthdays" };
  }
  return { kind: "pending" };
}

export function routeKey(r: Route): string {
  return r.kind === "detail" ? `detail:${r.id ?? "x"}` : r.kind;
}

// The tab the nav marks as current: a detail shows the tab it was opened from.
export function currentTab(r: Route): Tab | null {
  if (r.kind === "pending") {
    return null;
  }
  return r.kind === "detail" ? r.origin : r.kind;
}

export function hashFor(tab: Tab): string {
  return `#/${tab}`;
}

function isNarrow(): boolean {
  return typeof window.matchMedia === "function" && window.matchMedia(NARROW_QUERY).matches;
}

export function pointerIsFine(): boolean {
  return typeof window.matchMedia === "function" && window.matchMedia("(pointer: fine)").matches;
}

export function startHash(startTab: StartTab): string {
  if (startTab === "add") {
    return hashFor("add");
  }
  if (startTab === "view") {
    return hashFor("birthdays");
  }
  return isNarrow() ? hashFor("add") : hashFor("birthdays");
}
