import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import type { MouseEvent } from "react";
import { COLOR_SCHEMES, getBirthdays, getMe } from "./api";
import type { Birthday, ColorScheme, Failure, ListView, Settings } from "./api";
import { AddTab } from "./AddTab";
import { APP_NAME } from "./appName";
import { BirthdaysTab } from "./BirthdaysTab";
import { todayISO } from "./dates";
import { Detail } from "./Detail";
import { EMPTY_DRAFT, clearEditDraft, loadDraft, saveDraft, saveEditDraft } from "./draft";
import type { Draft, EditDraft } from "./draft";
import { RELOAD_PLAIN, RELOAD_WITH_DRAFT } from "./messages";
import { CakeMark, TabIcon } from "./parts";
import type { OpenDetail } from "./parts";
import { currentTab, hashFor, originOf, readRoute, routeKey, startHash } from "./route";
import type { Origin, Route, Tab } from "./route";
import { SecretPanels } from "./Secrets";
import type { NewSecret, Secret } from "./Secrets";
import { SettingsTab } from "./Settings";
import { announce } from "./util";
import { useCalendar } from "./useCalendar";
import { useSettingsSaver } from "./useSettingsSaver";

type Page = "normal" | "expired" | "noidentity";
type MeState = { s: "loading" } | { s: "ok"; email: string } | { s: "unavailable" } | { s: "none" };
type ListAlert = "unavailable" | "generic" | null;

const PALETTE_KEY = "birthdays:palette";
const KEYBOARD_GAP_PX = 150;
const TABS: { tab: Tab; label: string }[] = [
  { tab: "add", label: "Add" },
  { tab: "birthdays", label: "Birthdays" },
  { tab: "settings", label: "Settings" },
];

function isScheme(v: unknown): v is ColorScheme {
  return typeof v === "string" && (COLOR_SCHEMES as readonly string[]).includes(v);
}

// Confetti lives on bare :root, so a missing or unknown scheme just removes the attribute.
function applyPalette(scheme: unknown): void {
  if (isScheme(scheme)) {
    document.documentElement.setAttribute("data-palette", scheme);
  } else {
    document.documentElement.removeAttribute("data-palette");
  }
}

function readStoredPalette(): ColorScheme | null {
  try {
    const v = window.localStorage.getItem(PALETTE_KEY);
    return isScheme(v) ? v : null;
  } catch {
    return null;
  }
}

function storePalette(scheme: ColorScheme): void {
  try {
    window.localStorage.setItem(PALETTE_KEY, scheme);
  } catch {
    // per-device convenience only
  }
}

export function App() {
  const [page, setPage] = useState<Page>("normal");
  const [me, setMe] = useState<MeState>({ s: "loading" });
  const [settings, setSettings] = useState<Settings | null>(null);
  const [route, setRoute] = useState<Route>(readRoute);
  const [today, setToday] = useState(() => todayISO());
  const [keyboardOpen, setKeyboardOpen] = useState(false);
  const [notice, setNotice] = useState("");

  const [list, setList] = useState<Birthday[] | null>(null);
  const [listLoading, setListLoading] = useState(true);
  const [listAlert, setListAlert] = useState<ListAlert>(null);
  const [recent, setRecent] = useState<Birthday[]>([]);
  const [draft, setDraft] = useState<Draft>(EMPTY_DRAFT);
  // Dirty owner edits, one per birthday id (kept across a detail round trip, mirrored to sessionStorage).
  const [edits, setEdits] = useState<Record<number, EditDraft>>({});
  const emailRef = useRef<string | null>(null);

  const mainRef = useRef<HTMLElement>(null);
  const nameRef = useRef<HTMLInputElement>(null);
  const reloadRef = useRef<HTMLButtonElement>(null);
  const listSeq = useRef(0);
  const changedAt = useRef(new Map<number, { b: Birthday; seq: number }>());
  const goneAt = useRef(new Map<number, number>()); // birthday id -> the list request number current when it went
  const draftReady = useRef(false);
  const autofocusPending = useRef(true);
  const scrollRef = useRef<Record<string, number>>({});
  const keyRef = useRef(routeKey(route));
  const prevRoute = useRef<Route | null>(null);

  // Page-level states win over section states: an expired or unconfirmed sign-in disables the forms.
  const sessionFailure = useCallback((f: Failure | { kind: "ok" }): boolean => {
    if (f.kind !== "session_expired" && f.kind !== "unauthenticated") {
      return false;
    }
    // The first page-level failure wins, so the banner copy and focus do not flip between the two.
    setPage((p) => (p !== "normal" ? p : f.kind === "session_expired" ? "expired" : "noidentity"));
    setMe((m) => (m.s === "loading" ? { s: "none" } : m));
    return true;
  }, []);

  const saver = useSettingsSaver(setSettings, sessionFailure);

  // One-time secrets (ntfy password, webhook signing secret) wait here, above every tab, until acknowledged. They are
  // held in memory only: never in localStorage or sessionStorage, never logged.
  const [secrets, setSecrets] = useState<Secret[]>([]);
  const secretSeq = useRef(0);
  const secretBack = useRef(new Map<string, () => HTMLElement | null>());

  // A webhook secret stacks; a new ntfy password replaces only the ntfy entry (the old one is dead server-side).
  const addSecret = useCallback((s: NewSecret, back: () => HTMLElement | null) => {
    secretSeq.current += 1;
    const entry: Secret = { ...s, seq: secretSeq.current };
    secretBack.current.set(s.key, back);
    setSecrets((all) => (all.some((x) => x.key === s.key) ? all.map((x) => (x.key === s.key ? entry : x)) : [...all, entry]));
  }, []);

  // Focus goes back to the control that produced the secret when it is still mounted, else the current screen's h2.
  const ackSecret = useCallback((key: string) => {
    const back = secretBack.current.get(key)?.() ?? null;
    secretBack.current.delete(key);
    setSecrets((all) => all.filter((x) => x.key !== key));
    if (back !== null && back.isConnected) {
      back.focus();
    } else {
      mainRef.current?.querySelector<HTMLElement>("[data-screen-h]")?.focus();
    }
  }, []);

  // Desktop best effort: ask before leaving or reloading while any secret is unacknowledged.
  const hasSecrets = secrets.length > 0;
  useEffect(() => {
    if (!hasSecrets) {
      return;
    }
    const guard = (e: BeforeUnloadEvent) => {
      e.preventDefault();
      e.returnValue = "";
    };
    window.addEventListener("beforeunload", guard);
    return () => window.removeEventListener("beforeunload", guard);
  }, [hasSecrets]);

  // Ignores a response that a newer request has overtaken.
  const fetchList = useCallback(async (): Promise<"ok" | "failed" | "stale"> => {
    const id = ++listSeq.current;
    setListLoading(true);
    const res = await getBirthdays();
    if (id !== listSeq.current) {
      return "stale";
    }
    setListLoading(false);
    if (res.kind === "ok") {
      // A birthday found gone while this request was in flight must not come back from its older response.
      // Likewise a birthday saved while it was in flight keeps the saved values.
      setList(
        res.data
          .filter((b) => (goneAt.current.get(b.id) ?? -1) < id)
          .map((b) => {
            const saved = changedAt.current.get(b.id);
            return saved !== undefined && saved.seq >= id ? saved.b : b;
          }),
      );
      setListAlert(null);
      return "ok";
    }
    if (!sessionFailure(res)) {
      setListAlert(res.kind === "unavailable" ? "unavailable" : "generic");
    }
    return "failed";
  }, [sessionFailure]);

  // Stored colour scheme before first render (no flash of Confetti); the server value wins once loaded.
  useLayoutEffect(() => {
    const stored = readStoredPalette();
    if (stored !== null) {
      applyPalette(stored);
    }
  }, []);

  const scheme = settings?.color_scheme;
  useEffect(() => {
    if (scheme !== undefined) {
      applyPalette(scheme);
      storePalette(scheme);
    }
  }, [scheme]);

  useEffect(() => {
    let live = true;
    void (async () => {
      const res = await getMe();
      if (!live) {
        return;
      }
      if (res.kind === "ok") {
        const { email, settings: s } = res.data;
        // A restored draft counts as touched (plan draft rule): its remind value is explicit, never the auto_remind
        // default.
        const stored = loadDraft(email);
        draftReady.current = true;
        if (stored !== null) {
          setDraft({ ...stored, remind: stored.remind ?? s.auto_remind });
        }
        setSettings(s);
        setMe({ s: "ok", email });
      } else if (!sessionFailure(res)) {
        setMe({ s: "unavailable" });
      }
    })();
    void fetchList();
    return () => {
      live = false;
    };
  }, [fetchList, sessionFailure]);

  // Mirror the Add draft to sessionStorage (after the restore decision, so the empty draft never overwrites it).
  const email = me.s === "ok" ? me.email : null;
  useEffect(() => {
    emailRef.current = email;
  }, [email]);
  useEffect(() => {
    if (email !== null && draftReady.current) {
      saveDraft(email, draft);
    }
  }, [draft, email]);

  useEffect(() => {
    if (page !== "normal") {
      reloadRef.current?.focus();
    }
  }, [page]);

  // Relative text ("in 3 days") recomputes when the tab becomes visible again.
  useEffect(() => {
    const onVisible = () => {
      if (document.visibilityState === "visible") {
        setToday(todayISO());
      }
    };
    document.addEventListener("visibilitychange", onVisible);
    return () => document.removeEventListener("visibilitychange", onVisible);
  }, []);

  // The tab bar hides (under 40rem, in CSS) only while the on-screen keyboard is actually open.
  useEffect(() => {
    const vv = window.visualViewport;
    if (!vv) {
      return;
    }
    const onResize = () => setKeyboardOpen(window.innerHeight - vv.height > KEYBOARD_GAP_PX);
    vv.addEventListener("resize", onResize);
    return () => vv.removeEventListener("resize", onResize);
  }, []);

  // Route changes: remember the scroll position of the screen being left, then re-read the location.
  useEffect(() => {
    try {
      window.history.scrollRestoration = "manual";
    } catch {
      // not supported: the browser restores scroll itself
    }
    const sync = () => {
      const next = readRoute();
      // Back fires popstate and then hashchange: only the event that actually leaves the current screen saves its scroll.
      if (routeKey(next) !== keyRef.current) {
        scrollRef.current[keyRef.current] = window.scrollY;
      }
      setRoute(next);
    };
    window.addEventListener("hashchange", sync);
    window.addEventListener("popstate", sync);
    return () => {
      window.removeEventListener("hashchange", sync);
      window.removeEventListener("popstate", sync);
    };
  }, []);

  // `#/` (or no or an unknown hash) resolves once, after GET /api/me, from the start tab; replaceState keeps Back
  // from looping.
  useEffect(() => {
    if (route.kind !== "pending" || me.s === "loading") {
      return;
    }
    window.history.replaceState(window.history.state, "", startHash(settings?.start_tab ?? "auto"));
    setRoute(readRoute());
  }, [route, me.s, settings?.start_tab]);

  const key = routeKey(route);
  useLayoutEffect(() => {
    keyRef.current = key;
    if (prevRoute.current === null || prevRoute.current.kind === "pending" || route.kind === "pending") {
      return;
    }
    if (routeKey(prevRoute.current) === key) {
      return;
    }
    const stored = scrollRef.current[key];
    window.scrollTo(0, stored ?? 0);
    // Deps are intentionally [key]: restore the scroll position only when the route changes.
  }, [key]);

  // The h2 focus rule: every route change that renders a screen focuses its h2 (preventScroll when a scroll position
  // was restored). The first load, and the start-tab resolution, move no focus. Returning from a detail focuses the
  // originating link when it is still there.
  useEffect(() => {
    const prev = prevRoute.current;
    if (route.kind === "pending") {
      return;
    }
    prevRoute.current = route;
    if (prev === null || prev.kind === "pending" || routeKey(prev) === key) {
      return;
    }
    autofocusPending.current = false;
    const root = mainRef.current;
    if (root === null) {
      return;
    }
    if (prev.kind === "detail" && prev.id !== null && (route.kind === "add" || route.kind === "birthdays")) {
      const link = root.querySelector<HTMLElement>(`a[data-bid="${prev.id}"]`);
      if (link !== null) {
        link.focus({ preventScroll: true });
        return;
      }
      const fallback = root.querySelector<HTMLElement>("[data-screen-h]");
      if (scrollRef.current[key] !== undefined) {
        fallback?.focus({ preventScroll: true });
      } else {
        fallback?.focus();
      }
      return;
    }
    const h2 = root.querySelector<HTMLElement>("[data-screen-h]");
    if (scrollRef.current[key] !== undefined) {
      h2?.focus({ preventScroll: true });
    } else {
      h2?.focus();
    }
    // Deps are intentionally [key]: move focus only when the route changes.
  }, [key]);

  const open: OpenDetail = useCallback((e: MouseEvent<HTMLAnchorElement>, id: number, origin: Origin) => {
    if (e.defaultPrevented || e.button !== 0 || e.metaKey || e.ctrlKey || e.shiftKey || e.altKey) {
      return;
    }
    e.preventDefault();
    scrollRef.current[keyRef.current] = window.scrollY;
    window.history.pushState({ origin }, "", `#/b/${id}`);
    setRoute(readRoute());
  }, []);

  // The in-page back link: a real history Back when the entry before is an app tab (the marker we pushed), else a
  // replaceState to the Birthdays tab so it never pushes a loop.
  const detailBack = useCallback((e: MouseEvent<HTMLAnchorElement>) => {
    e.preventDefault();
    if (originOf(window.history.state) !== null) {
      window.history.back();
      return;
    }
    scrollRef.current[keyRef.current] = window.scrollY;
    window.history.replaceState(null, "", hashFor("birthdays"));
    setRoute(readRoute());
  }, []);

  const goTab = useCallback((tab: Tab) => {
    scrollRef.current[keyRef.current] = window.scrollY;
    window.history.pushState(null, "", hashFor(tab));
    setRoute(readRoute());
  }, []);

  // After Delete / Remove from my list: replaceState to the Birthdays tab so Back never lands on a dead detail.
  const setEdit = useCallback((id: number, d: EditDraft | null) => {
    setEdits((all) => {
      const next = { ...all };
      if (d === null) {
        delete next[id];
      } else {
        next[id] = d;
      }
      return next;
    });
    if (d === null) {
      clearEditDraft(id);
    } else if (emailRef.current !== null) {
      saveEditDraft(emailRef.current, id, d);
    }
  }, []);

  // A draft typed before /me answered is only in app state; mirror every current edit once the email is known.
  useEffect(() => {
    if (email === null) {
      return;
    }
    for (const [id, d] of Object.entries(edits)) {
      saveEditDraft(email, Number(id), d);
    }
  }, [email, edits]);

  // A birthday that is gone (deleted, removed, or no longer shared): drop it from every loaded list and its draft.
  const onGone = useCallback(
    (id: number) => {
      goneAt.current.set(id, listSeq.current);
      setList((l) => (l === null ? l : l.filter((b) => b.id !== id)));
      setRecent((r) => r.filter((b) => b.id !== id));
      setEdit(id, null);
    },
    [setEdit],
  );

  // An edit or reminder save updates the loaded rows without a refetch.
  const onChanged = useCallback((b: Birthday) => {
    changedAt.current.set(b.id, { b, seq: listSeq.current });
    setList((l) => (l === null ? l : l.map((x) => (x.id === b.id ? b : x))));
    setRecent((r) => r.map((x) => (x.id === b.id ? b : x)));
  }, []);

  const onRemoved = useCallback((id: number, message: string) => {
    onGone(id);
    window.history.replaceState(null, "", hashFor("birthdays"));
    setRoute(readRoute());
    announce(setNotice, message);
  }, [onGone]);

  const onAdded = useCallback(
    (b: Birthday) => {
      setList((l) => (l === null ? l : [b, ...l]));
      setRecent((r) => [b, ...r]);
      void fetchList();
    },
    [fetchList],
  );

  const loading = me.s === "loading" && page === "normal";
  const pageDown = page !== "normal";
  const formDisabled = loading || pageDown;
  const current = currentTab(route);
  // Only Add and an owner's dirty detail edit keep what was typed across the Reload.
  const keepsDraft = route.kind === "add" || (route.kind === "detail" && route.id !== null && edits[route.id] !== undefined);
  const view: ListView = settings?.list_view ?? "upcoming";
  const cal = useCalendar(today, settings?.calendar_zoom ?? "month", (z) => saver.save({ calendar_zoom: z }));

  function renderHeaderWho() {
    if (loading) {
      return <span>Checking sign-in&hellip;</span>;
    }
    if (pageDown || me.s === "none") {
      return null;
    }
    if (me.s === "unavailable") {
      return <span>Sign-in status unavailable</span>;
    }
    if (me.s !== "ok") {
      return null;
    }
    if (import.meta.env.DEV) {
      return (
        <span>
          Signed in as <strong>{me.email}</strong> (dev)
        </span>
      );
    }
    return (
      <>
        <span>
          Signed in as <strong>{me.email}</strong>
        </span>
        <a className="signout" href="/cdn-cgi/access/logout">
          Sign out
        </a>
        <span className="hint">Signs you out of all family apps</span>
      </>
    );
  }

  function renderScreen() {
    if (route.kind === "pending") {
      return (
        <section aria-label="Loading">
          <p className="loading">Loading&hellip;</p>
          <ul className="items skeletons" aria-hidden="true">
            {[1, 2, 3].map((n) => (
              <li key={n}>
                <div className={`skeleton w${n}`} />
              </li>
            ))}
          </ul>
        </section>
      );
    }
    if (route.kind === "add") {
      return (
        <AddTab
          disabled={formDisabled}
          draft={draft}
          setDraft={setDraft}
          settings={settings}
          today={today}
          recent={recent}
          open={open}
          onAdded={onAdded}
          onSessionFailure={sessionFailure}
          nameRef={nameRef}
          autofocusPending={autofocusPending}
        />
      );
    }
    if (route.kind === "birthdays") {
      return (
        <BirthdaysTab
          list={list}
          loading={listLoading}
          alert={pageDown ? null : listAlert}
          retry={() => {
            if (!listLoading) {
              void fetchList();
            }
          }}
          view={view}
          viewDisabled={settings === null}
          onView={(v) => saver.save({ list_view: v })}
          today={today}
          open={open}
          settings={settings}
          saveStatus={saver.status}
          goAdd={() => goTab("add")}
          cal={cal}
        />
      );
    }
    if (route.kind === "settings") {
      return (
        <SettingsTab
          settings={settings}
          list={list}
          disabled={pageDown}
          saver={saver}
          onSessionFailure={sessionFailure}
          addSecret={addSecret}
          hasNtfySecret={secrets.some((s) => s.key === "ntfy")}
        />
      );
    }
    if (route.kind !== "detail") {
      return null;
    }
    return (
      <Detail
        key={routeKey(route)}
        id={route.id}
        origin={route.origin}
        today={today}
        email={email}
        settings={settings}
        disabled={pageDown}
        edit={route.id === null ? undefined : edits[route.id]}
        setEdit={setEdit}
        onBack={detailBack}
        onRemoved={onRemoved}
        onChanged={onChanged}
        onGone={onGone}
        onSessionFailure={sessionFailure}
      />
    );
  }

  return (
    <div className="app">
      <header>
        <div className="bar">
          <h1>
            <CakeMark />
            {APP_NAME}
          </h1>
          <nav className="tabs" aria-label="Main" data-kbd={keyboardOpen ? "open" : undefined}>
            {TABS.map((t) => (
              <a key={t.tab} href={hashFor(t.tab)} aria-current={current === t.tab ? "page" : undefined}>
                <span className="ico">
                  <TabIcon tab={t.tab} />
                </span>
                {t.label}
              </a>
            ))}
          </nav>
          <div className="who">{renderHeaderWho()}</div>
        </div>
      </header>
      <main ref={mainRef}>
        <p className="sr-only" role="status" aria-live="polite" data-testid="app-notice">
          {notice}
        </p>
        {pageDown && (
          <div className="alert" role="alert">
            <p>
              {page === "expired" ? (
                <>
                  <strong>Your sign-in has expired.</strong>{" "}
                  {keepsDraft ? RELOAD_WITH_DRAFT : RELOAD_PLAIN}
                </>
              ) : (
                <>
                  <strong>We couldn't confirm your sign-in.</strong> Reload the page to try again.
                </>
              )}
            </p>
            <button className="primary" type="button" ref={reloadRef} onClick={() => window.location.reload()}>
              Reload
            </button>
          </div>
        )}
        <SecretPanels secrets={secrets} onAck={ackSecret} />
        {renderScreen()}
      </main>
    </div>
  );
}
