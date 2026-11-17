import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import type { FormEvent, MouseEvent } from "react";
import { deleteBirthday, deleteShare, getBirthday, postShare } from "./api";
import type { Birthday, BirthdayDetail, Failure, Gift, Settings } from "./api";
import { turning, weekday, WDL } from "./dates";
import type { EditDraft } from "./draft";
import { EditForm } from "./EditForm";
import { monthName, withDates } from "./format";
import { MSG_GENERIC, MSG_UNAVAILABLE, failureText } from "./messages";
import { Avatar, Chip, ConfirmPrompt } from "./parts";
import { MyGifts, OthersGifts, Reminders } from "./DetailSections";
import type { Origin } from "./route";
import { announce } from "./util";

type Load =
  | { k: "loading" }
  | { k: "ok"; data: BirthdayDetail }
  | { k: "notfound" }
  | { k: "error"; unavailable: boolean }
  | { k: "session" }; // the App's banner owns this state; no skeleton behind it

// Only one confirm is open at a time: opening another replaces the first.
// `n` is a nonce so re-opening the same confirm remounts the prompt and refocuses Cancel.
type Confirm = { k: "delete"; n: number } | { k: "stop"; email: string; n: number };

export function Detail({
  id,
  origin,
  today,
  email,
  settings,
  disabled,
  edit,
  setEdit,
  onBack,
  onRemoved,
  onChanged,
  onGone,
  onSessionFailure,
}: {
  id: number | null;
  origin: Origin;
  today: string;
  email: string | null;
  settings: Settings | null;
  disabled: boolean;
  edit: EditDraft | undefined;
  setEdit: (id: number, d: EditDraft | null) => void;
  onBack: (e: MouseEvent<HTMLAnchorElement>) => void;
  onRemoved: (id: number, message: string) => void;
  onChanged: (b: Birthday) => void;
  onGone: (id: number) => void;
  onSessionFailure: (f: Failure) => boolean;
}) {
  const [load, setLoad] = useState<Load>(id === null ? { k: "notfound" } : { k: "loading" });
  const [confirm, setConfirm] = useState<Confirm | null>(null);
  const [busy, setBusy] = useState(false);
  const [alert, setAlert] = useState("");
  const [live, setLive] = useState("");
  const [shareEmail, setShareEmail] = useState("");
  const [shareErr, setShareErr] = useState("");
  const [shareAlert, setShareAlert] = useState("");
  const seq = useRef(0);
  const alive = useRef(true);
  const confirmRef = useRef<Confirm | null>(null);
  const nonce = useRef(0);
  const busyRef = useRef(false);
  const sharingRef = useRef(false);
  const opener = useRef<HTMLElement | null>(null);
  const sharedHeading = useRef<HTMLHeadingElement>(null);
  const shareInput = useRef<HTMLInputElement>(null);

  const say = useCallback((message: string) => announce(setLive, message), []);

  const fetchDetail = useCallback(async () => {
    const mine = ++seq.current;
    if (id === null) {
      setLoad({ k: "notfound" });
      return;
    }
    setLoad({ k: "loading" });
    const res = await getBirthday(id);
    if (mine !== seq.current) {
      return; // overtaken by a newer request or a different birthday
    }
    if (res.kind === "ok") {
      setLoad({ k: "ok", data: res.data });
    } else if (res.kind === "not_found") {
      setLoad({ k: "notfound" });
      onGone(id);
    } else if (onSessionFailure(res)) {
      setLoad({ k: "session" });
    } else {
      setLoad({ k: "error", unavailable: res.kind === "unavailable" });
    }
  }, [id, onSessionFailure, onGone]);

  useEffect(() => {
    void fetchDetail();
    return () => {
      seq.current++;
    };
  }, [fetchDetail]);

  // The App keys Detail by birthday id, so a late response from an unmounted Detail must not touch state.
  useEffect(() => {
    alive.current = true;
    return () => {
      alive.current = false;
    };
  }, []);

  const patch = useCallback((fn: (d: BirthdayDetail) => BirthdayDetail) => {
    setLoad((l) => (l.k === "ok" ? { k: "ok", data: fn(l.data) } : l));
  }, []);

  // A failed call: null when the App's banner or the not-found panel already says it, else the copy to show.
  const fail = (f: Failure): string | null => {
    if (onSessionFailure(f)) {
      return null;
    }
    if (f.kind === "not_found" && id !== null) {
      if (alive.current) {
        confirmRef.current = null;
        setConfirm(null);
        setLoad({ k: "notfound" });
      }
      onGone(id);
      return null;
    }
    return failureText(f.kind);
  };

  const data = load.k === "ok" ? load.data : null;
  const b = data === null ? null : data.birthday;
  // A reminder save can finish after the name was edited: it reports the newest birthday to the list.
  const latest = useRef<Birthday | null>(null);
  useEffect(() => {
    latest.current = b;
  }, [b]);

  function open(c: { k: "delete" } | { k: "stop"; email: string }, question: string, el: HTMLElement) {
    if (busyRef.current) {
      return;
    }
    opener.current = el;
    nonce.current++;
    const next: Confirm = { ...c, n: nonce.current };
    confirmRef.current = next;
    setConfirm(next);
    setAlert("");
    setShareAlert("");
    say(`${question} Confirm or cancel.`);
  }

  function cancel() {
    confirmRef.current = null;
    setConfirm(null);
    const el = opener.current;
    if (el !== null && el.isConnected) {
      el.focus();
    }
  }

  async function onDelete() {
    if (b === null || busyRef.current) {
      return;
    }
    busyRef.current = true;
    setBusy(true);
    setAlert("");
    const res = await deleteBirthday(b.id);
    busyRef.current = false;
    setBusy(false);
    if (res.kind === "ok" || res.kind === "not_found") {
      onRemoved(b.id, b.is_mine ? `Deleted ${b.name}.` : `Removed ${b.name} from your list.`);
      return;
    }
    const msg = fail(res);
    if (msg !== null) {
      setAlert(msg);
    }
  }

  async function onStop(target: string) {
    if (b === null || busyRef.current) {
      return;
    }
    busyRef.current = true;
    setBusy(true);
    setShareAlert("");
    const res = await deleteShare(b.id, target);
    busyRef.current = false;
    setBusy(false);
    if (res.kind === "ok") {
      patch((d) => ({ ...d, shares: (d.shares ?? []).filter((s) => s !== target) }));
      // Only close (and move focus for) the confirm this request belonged to; a newer one stays open.
      const was = confirmRef.current;
      if (was !== null && was.k === "stop" && was.email === target) {
        confirmRef.current = null;
        setConfirm(null);
        sharedHeading.current?.focus();
      }
      say(`Stopped sharing with ${target}.`);
      return;
    }
    const msg = fail(res);
    if (msg !== null) {
      setShareAlert(msg);
    }
  }

  async function onShare(e: FormEvent) {
    e.preventDefault();
    if (b === null || sharingRef.current || disabled) {
      return;
    }
    setShareAlert("");
    const target = shareEmail.trim();
    if (target === "") {
      setShareErr(failureText("invalid_email"));
      shareInput.current?.focus();
      return;
    }
    sharingRef.current = true;
    const res = await postShare(b.id, target);
    sharingRef.current = false;
    if (res.kind === "ok") {
      const added = res.data.email;
      patch((d) => ({
        ...d,
        shares: (d.shares ?? []).some((s) => s === added) ? d.shares : [...(d.shares ?? []), added],
      }));
      setShareEmail("");
      setShareErr("");
      say(`Shared with ${added}.`);
      shareInput.current?.focus();
      return;
    }
    if (res.kind === "self_share" || res.kind === "invalid_email" || res.kind === "too_many_shares") {
      setShareErr(failureText(res.kind));
      shareInput.current?.focus();
      return;
    }
    const msg = fail(res);
    if (msg !== null) {
      setShareAlert(msg);
    }
  }

  const dated = b === null ? null : withDates([b], today)[0];
  const age = dated === undefined || dated === null ? null : turning(dated.b.year, dated.occ);
  const heading = b !== null ? b.name : load.k === "notfound" ? "Birthday not found" : "Birthday";
  const label = origin === "add" ? "Add" : "Birthdays";
  const deleteQuestion =
    b === null ? "" : b.is_mine ? `Delete ${b.name} for everyone?` : `Remove ${b.name} from your list?`;
  const allGifts: Gift[] | null = data === null ? null : data.gifts;
  const myGifts = useMemo(() => (allGifts ?? []).filter((g) => g.mine), [allGifts]);
  const othersGifts = useMemo(() => (allGifts ?? []).filter((g) => !g.mine), [allGifts]);
  const shares = data?.shares ?? [];

  return (
    <>
      <nav className="back" aria-label="Back">
        <a href={`#/${origin}`} onClick={onBack}>
          &larr; {label}
        </a>
      </nav>
      <p className="sr-only" role="status" aria-live="polite" data-testid="detail-live">
        {live}
      </p>
      <section aria-labelledby="detail-h">
        <div className="dhead">
          {b !== null && <Avatar name={b.name} big />}
          <div>
            <h2 id="detail-h" data-screen-h tabIndex={-1}>
              {heading}
            </h2>
            {b !== null && dated !== undefined && dated !== null && (
              <p className="meta">
                {WDL[weekday(dated.occ)]}, {monthName(b.month)} {b.day}
                {age !== null && ` · turns ${age}`}
              </p>
            )}
          </div>
          {dated !== undefined && dated !== null && (
            <span className="push">
              <Chip days={dated.days} />
            </span>
          )}
        </div>

        {load.k === "loading" && (
          <>
            <p className="loading" role="status">Loading birthday&hellip;</p>
            <div className="skeleton w1" aria-hidden="true" />
          </>
        )}
        {load.k === "notfound" && (
          <div className="alert" role="alert">
            <p>
              <strong>That birthday isn't here.</strong> {failureText("not_found")}
            </p>
            <a className="button secondary" href="#/birthdays">
              Back to birthdays
            </a>
          </div>
        )}
        {load.k === "error" && (
          <div className="alert" role="alert">
            <p>
              <strong>Couldn't load this birthday.</strong> {load.unavailable ? MSG_UNAVAILABLE : MSG_GENERIC}
            </p>
            <button className="secondary" type="button" onClick={() => void fetchDetail()}>
              Try again
            </button>
          </div>
        )}
        {b !== null && b.is_mine && (
          <EditForm
            b={b}
            edit={edit}
            setEdit={setEdit}
            email={email}
            disabled={disabled}
            onSaved={(saved) => {
              patch((d) => ({ ...d, birthday: saved }));
              onChanged(saved);
            }}
            fail={fail}
          />
        )}
        {b !== null && !b.is_mine && (
          <p className="meta sharedby">Shared with you by {b.owner_email}. Only they can edit it.</p>
        )}
      </section>

      {b !== null && (
        <Reminders
          id={b.id}
          offsets={b.reminder_offsets}
          owner={b.is_mine}
          settings={settings}
          disabled={disabled}
          onSaved={(offsets) => {
            // The list row is updated even when this Detail was left mid-save (the Detail is keyed by id, so the
            // row is this birthday's); only the local state write is skipped.
            if (alive.current) {
              patch((d) => ({ ...d, birthday: { ...d.birthday, reminder_offsets: offsets } }));
            }
            onChanged({ ...(latest.current ?? b), reminder_offsets: offsets });
          }}
          fail={fail}
        />
      )}
      {b !== null && (
        <MyGifts
          id={b.id}
          gifts={myGifts}
          setGifts={(fn) => patch((d) => ({ ...d, gifts: fn(d.gifts) }))}
          disabled={disabled}
          fail={fail}
          say={say}
        />
      )}
      {b !== null && <OthersGifts gifts={othersGifts} />}

      {b !== null && b.is_mine && (
        <section aria-labelledby="sh-h">
          <h2 id="sh-h" tabIndex={-1} ref={sharedHeading}>
            Shared with
          </h2>
          {shares.length === 0 ? (
            <p className="empty">Not shared with anyone.</p>
          ) : (
            <ul className="items" aria-label="People this birthday is shared with">
              {shares.map((s) => (
                <li key={s}>
                  <span className="pinfo">{s}</span>
                  <button
                    className="secondary"
                    type="button"
                    disabled={disabled}
                    aria-label={`Stop sharing with ${s}`}
                    onClick={(e) =>
                      open({ k: "stop", email: s }, `Stop sharing with ${s}?`, e.currentTarget)
                    }
                  >
                    Stop sharing
                  </button>
                </li>
              ))}
            </ul>
          )}
          <p className="hint">Stopping removes their reminders and gift ideas for this birthday.</p>
          {confirm !== null && confirm.k === "stop" && (
            <ConfirmPrompt
              key={`stop:${confirm.email}:${confirm.n}`}
              question={`Stop sharing with ${confirm.email}?`}
              confirmLabel="Yes, stop sharing"
              busy={busy}
              onConfirm={() => void onStop(confirm.email)}
              onCancel={cancel}
            />
          )}
          <div role="alert">{shareAlert !== "" && <p className="status err">{shareAlert}</p>}</div>
          <form className="detailform" onSubmit={(e) => void onShare(e)} noValidate aria-label="Share this birthday">
            <div className="field name">
              <label htmlFor="share-email">Share with (email they sign in with)</label>
              <input
                id="share-email"
                type="email"
                autoComplete="off"
                ref={shareInput}
                value={shareEmail}
                disabled={disabled}
                aria-invalid={shareErr !== "" ? "true" : undefined}
                aria-describedby="share-email-err"
                onChange={(e) => {
                  setShareEmail(e.target.value);
                  setShareErr("");
                }}
              />
              <p className="fielderr" id="share-email-err">
                {shareErr}
              </p>
            </div>
            <button className="secondary" type="submit" disabled={disabled}>
              Share
            </button>
          </form>
        </section>
      )}

      {b !== null && (
        <section aria-labelledby="del-h">
          <h2 id="del-h">{b.is_mine ? "Delete" : "Remove from my list"}</h2>
          <p className="hint">
            {b.is_mine
              ? "Removes it for everyone it's shared with, along with their reminders and gift ideas."
              : "You'll stop seeing it, and your reminders and gift ideas for it are deleted."}
          </p>
          <div className="row">
            <button
              className="danger"
              type="button"
              disabled={disabled}
              onClick={(e) => open({ k: "delete" }, deleteQuestion, e.currentTarget)}
            >
              {b.is_mine ? "Delete" : "Remove from my list"}
            </button>
          </div>
          {confirm !== null && confirm.k === "delete" && (
            <ConfirmPrompt
              key={`delete:${confirm.n}`}
              question={deleteQuestion}
              confirmLabel={b.is_mine ? "Yes, delete" : "Yes, remove"}
              busy={busy}
              onConfirm={() => void onDelete()}
              onCancel={cancel}
            />
          )}
          <div role="alert">{alert !== "" && <p className="status err">{alert}</p>}</div>
        </section>
      )}
    </>
  );
}
