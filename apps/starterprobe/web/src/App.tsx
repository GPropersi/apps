import { useCallback, useEffect, useRef, useState } from "react";
import type { Dispatch, FormEvent, SetStateAction } from "react";
import { flushSync } from "react-dom";
import { getItems, getMe, postItem, postTask } from "./api";
import type { Failure, Item } from "./api";
import { APP_NAME } from "./appName";

const MAX_NOTES = 50;
const MSG_UNAVAILABLE = "Can't reach the app right now. Try again in a minute.";
const MSG_GENERIC = "Something went wrong on our side. Try again in a minute.";
const MSG_BUSY = "Too many background tasks are waiting. Try again in a few minutes.";
const MSG_INVALID = "Write something first (up to 200 characters).";
const MSG_QUEUED = "Queued. It will show up in your notes in a few seconds.";

type Page = "normal" | "expired" | "noidentity";
type Me = { s: "loading" } | { s: "ok"; email: string } | { s: "unavailable" } | { s: "none" };
type ListAlert = "unavailable" | "generic" | null;

function failureText(kind: Failure["kind"]): string {
  switch (kind) {
    case "unavailable":
      return MSG_UNAVAILABLE;
    case "busy":
      return MSG_BUSY;
    default:
      return MSG_GENERIC;
  }
}

// Clear, then set, so a repeated identical message is announced again by a screen reader.
function announce(set: Dispatch<SetStateAction<string>>, message: string): void {
  flushSync(() => set(""));
  set(message);
}

function formatTime(iso: string): string {
  const d = new Date(iso);
  return Number.isNaN(d.getTime()) ? iso : d.toLocaleString(undefined, { dateStyle: "medium", timeStyle: "short" });
}

export function App() {
  const [page, setPage] = useState<Page>("normal");
  const [me, setMe] = useState<Me>({ s: "loading" });
  const [items, setItems] = useState<Item[] | null>(null);
  const [listLoading, setListLoading] = useState(true);
  const [listAlert, setListAlert] = useState<ListAlert>(null);

  const [text, setText] = useState("");
  const [fieldError, setFieldError] = useState(false);
  const [adding, setAdding] = useState(false);
  const [addStatus, setAddStatus] = useState("");
  const [addAlert, setAddAlert] = useState("");

  const [tasking, setTasking] = useState(false);
  const [taskStatus, setTaskStatus] = useState("");
  const [taskAlert, setTaskAlert] = useState("");
  const [showRefresh, setShowRefresh] = useState(false);
  const [refreshing, setRefreshing] = useState(false);

  const inputRef = useRef<HTMLInputElement>(null);
  const reloadRef = useRef<HTMLButtonElement>(null);
  const listSeq = useRef(0);
  // Synchronous in-flight guards: state alone would let two events in the same tick both pass.
  const addingRef = useRef(false);
  const taskingRef = useRef(false);
  const refreshingRef = useRef(false);

  // Page-level states win over section states: an expired or unconfirmed sign-in disables the form and hides the task.
  const sessionFailure = useCallback((f: Failure | { kind: "ok" }): boolean => {
    if (f.kind !== "session_expired" && f.kind !== "unauthenticated") {
      return false;
    }
    // The first page-level failure wins, so the banner copy and focus do not flip between the two.
    setPage((p) => (p !== "normal" ? p : f.kind === "session_expired" ? "expired" : "noidentity"));
    setMe((m) => (m.s === "loading" ? { s: "none" } : m));
    setAddStatus("");
    setTaskStatus("");
    setAdding(false);
    setTasking(false);
    setRefreshing(false);
    addingRef.current = false;
    taskingRef.current = false;
    refreshingRef.current = false;
    return true;
  }, []);

  // Ignores a response that a newer request has overtaken.
  const fetchList = useCallback(async (): Promise<"ok" | "failed" | "stale"> => {
    const id = ++listSeq.current;
    setListLoading(true);
    const res = await getItems();
    if (id !== listSeq.current) {
      return "stale";
    }
    setListLoading(false);
    if (res.kind === "ok") {
      setItems(res.data);
      setListAlert(null);
      return "ok";
    }
    if (!sessionFailure(res)) {
      setListAlert(res.kind === "unavailable" ? "unavailable" : "generic");
    }
    return "failed";
  }, [sessionFailure]);

  useEffect(() => {
    let live = true;
    void (async () => {
      const res = await getMe();
      if (!live) {
        return;
      }
      if (res.kind === "ok") {
        setMe({ s: "ok", email: res.data.email });
      } else if (!sessionFailure(res)) {
        setMe({ s: "unavailable" });
      }
    })();
    void fetchList();
    return () => {
      live = false;
    };
  }, [fetchList, sessionFailure]);

  useEffect(() => {
    if (page !== "normal") {
      reloadRef.current?.focus();
    }
  }, [page]);

  const loading = me.s === "loading" && page === "normal";
  const pageDown = page !== "normal";
  const formDisabled = loading || pageDown;

  async function onAdd(e: FormEvent) {
    e.preventDefault();
    if (addingRef.current || formDisabled) {
      return;
    }
    setTaskStatus("");
    setAddAlert("");
    const trimmed = text.trim();
    if (trimmed === "") {
      setFieldError(true);
      announce(setAddStatus, MSG_INVALID);
      inputRef.current?.focus();
      return;
    }
    setFieldError(false);
    addingRef.current = true;
    setAdding(true);
    announce(setAddStatus, "Adding…");
    const res = await postItem(trimmed);
    addingRef.current = false;
    setAdding(false);
    setAddStatus("");
    if (res.kind === "ok") {
      setText("");
      setFieldError(false);
      setItems((prev) => [res.data, ...(prev ?? [])]);
      announce(setAddStatus, "Note added.");
      inputRef.current?.focus();
      void fetchList();
      return;
    }
    if (sessionFailure(res)) {
      return;
    }
    if (res.kind === "invalid_text") {
      setFieldError(true);
      announce(setAddStatus, MSG_INVALID);
    } else {
      setAddAlert(failureText(res.kind));
    }
    inputRef.current?.focus();
  }

  async function onTask() {
    if (taskingRef.current || loading) {
      return;
    }
    setTaskAlert("");
    announce(setTaskStatus, "Queuing…");
    taskingRef.current = true;
    setTasking(true);
    const res = await postTask();
    taskingRef.current = false;
    setTasking(false);
    setTaskStatus("");
    if (res.kind === "ok") {
      setShowRefresh(true);
      announce(setTaskStatus, MSG_QUEUED);
      return;
    }
    if (!sessionFailure(res)) {
      setTaskAlert(failureText(res.kind));
    }
  }

  async function onRefresh() {
    if (refreshingRef.current) {
      return;
    }
    setTaskStatus("");
    refreshingRef.current = true;
    setRefreshing(true);
    const outcome = await fetchList();
    refreshingRef.current = false;
    setRefreshing(false);
    if (outcome === "ok") {
      announce(setTaskStatus, "Notes refreshed.");
    }
  }

  function renderHeaderWho() {
    if (loading) {
      return <span>Checking sign-in…</span>;
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

  function renderList() {
    const showSkeleton = listLoading && items === null && listAlert === null && !pageDown;
    return (
      <>
        {showSkeleton && (
          <>
            <p className="loading">Loading notes…</p>
            <ul className="items skeletons" aria-busy="true" aria-label="Loading notes">
              {["80%", "60%", "70%"].map((w) => (
                <li key={w} aria-hidden="true">
                  <div className="skeleton" style={{ width: w }} />
                </li>
              ))}
            </ul>
          </>
        )}
        {!pageDown && listAlert !== null && (
          <div className="alert" role="alert">
            <p>
              {listAlert === "unavailable" ? (
                <>
                  <strong>Can't reach the app right now.</strong> Try again in a minute.
                </>
              ) : (
                <>
                  <strong>Couldn't load your notes.</strong> {MSG_GENERIC}
                </>
              )}
            </p>
            <button
              className="secondary"
              type="button"
              aria-disabled={listLoading ? "true" : undefined}
              onClick={() => {
                if (!listLoading) {
                  void fetchList();
                }
              }}
            >
              Try again
            </button>
          </div>
        )}
        {items !== null && items.length === 0 && !pageDown && (
          <p className="empty">No notes yet. Add your first one above.</p>
        )}
        {items !== null && items.length > 0 && (
          <>
            <ul
              className="items"
              aria-busy={listLoading ? "true" : undefined}
              aria-label={listAlert !== null || pageDown ? "Notes (last loaded)" : "Notes"}
            >
              {items.map((i) => (
                <li key={i.id}>
                  <div className="itemtext">{i.text}</div>
                  <div className="meta">
                    {i.source === "user" ? i.created_by : "Background task"} ·{" "}
                    <time dateTime={i.created_at}>{formatTime(i.created_at)}</time>
                  </div>
                </li>
              ))}
            </ul>
            {items.length >= MAX_NOTES && <p className="hint">Showing the latest {MAX_NOTES} notes.</p>}
          </>
        )}
      </>
    );
  }

  return (
    <div className="app">
      <header>
        <div className="bar">
          <h1>{APP_NAME}</h1>
          <div className="who">{renderHeaderWho()}</div>
        </div>
      </header>
      <main>
        {pageDown && (
          <div className="alert" role="alert">
            <p>
              {page === "expired" ? (
                <>
                  <strong>Your sign-in has expired.</strong> Reload the page to sign in again.
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

        <section aria-labelledby="notes-h">
          <h2 id="notes-h">Notes</h2>
          <form onSubmit={(e) => void onAdd(e)} noValidate>
            <label htmlFor="newnote">New note</label>
            <input
              id="newnote"
              type="text"
              maxLength={200}
              autoComplete="off"
              ref={inputRef}
              value={text}
              disabled={formDisabled}
              aria-invalid={fieldError ? "true" : undefined}
              aria-describedby={fieldError ? "newnote-err" : "newnote-hint"}
              onChange={(e) => {
                setText(e.target.value);
                setFieldError(false);
              }}
            />
            <button className="primary" type="submit" disabled={formDisabled} aria-disabled={adding ? "true" : undefined}>
              Add
            </button>
            {fieldError ? (
              <p className="fielderr" id="newnote-err">
                {MSG_INVALID}
              </p>
            ) : (
              <p className="hint" id="newnote-hint">
                Up to 200 characters.
              </p>
            )}
          </form>
          <p className="status" role="status" aria-live="polite" data-testid="add-status">
            {addStatus}
          </p>
          <div role="alert" data-testid="add-alert">
            {addAlert !== "" && <p className="status err">{addAlert}</p>}
          </div>
          {renderList()}
        </section>

        {!pageDown && (
          <section aria-labelledby="task-h">
            <h2 id="task-h">Background task</h2>
            <p className="desc">Adds a note from a background task, to show background work running.</p>
            <div className="row">
              <button
                className="primary"
                type="button"
                disabled={loading}
                aria-disabled={tasking ? "true" : undefined}
                onClick={() => void onTask()}
              >
                Run background task
              </button>
              {showRefresh && (
                <button
                  className="secondary"
                  type="button"
                  aria-disabled={refreshing ? "true" : undefined}
                  onClick={() => void onRefresh()}
                >
                  Refresh notes
                </button>
              )}
            </div>
            <p className="status" role="status" aria-live="polite" data-testid="task-status">
              {taskStatus}
            </p>
            <div role="alert" data-testid="task-alert">
              {taskAlert !== "" && <p className="status err">{taskAlert}</p>}
            </div>
          </section>
        )}
      </main>
    </div>
  );
}
