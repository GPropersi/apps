import { useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { deleteGift, patchGift, postGift, putReminders } from "./api";
import type { Failure, Gift, Settings } from "./api";
import { noDestination } from "./format";
import { failureText } from "./messages";
import { DestinationNotice } from "./parts";
import { announce } from "./util";

type Fail = (f: Failure) => string | null;
type Say = (message: string) => void;

const OFFSETS: { value: number; label: string }[] = [
  { value: 7, label: "1 week before" },
  { value: 1, label: "1 day before" },
  { value: 0, label: "On the day" },
];

// "My reminders": checkboxes for the person's own offsets. Saves are serialized: the latest desired value is kept and
// one PUT runs at a time; a failure reverts to the last value the server confirmed and announces an error. Unticking
// everything means no reminders for this birthday (unlike Settings' non-empty default).
export function Reminders({
  id,
  offsets,
  owner,
  settings,
  disabled,
  onSaved,
  fail,
}: {
  id: number;
  offsets: number[];
  owner: boolean;
  settings: Settings | null;
  disabled: boolean;
  onSaved: (offsets: number[]) => void;
  fail: Fail;
}) {
  const [checked, setChecked] = useState<number[]>(offsets);
  const [status, setStatus] = useState("");
  const [alert, setAlert] = useState("");
  const ui = useRef<number[]>(offsets);
  const confirmed = useRef<number[]>(offsets);
  const desired = useRef<number[] | null>(null);
  const running = useRef(false);

  async function run() {
    if (running.current) {
      return;
    }
    running.current = true;
    setAlert("");
    while (desired.current !== null) {
      const sending = desired.current;
      desired.current = null;
      setStatus("Saving…");
      const res = await putReminders(id, sending);
      if (res.kind === "ok") {
        confirmed.current = res.data.offsets;
        onSaved(res.data.offsets);
        if (desired.current === null) {
          ui.current = res.data.offsets;
          setChecked(res.data.offsets);
          setStatus("Reminders saved.");
        }
      } else {
        desired.current = null;
        ui.current = confirmed.current;
        setChecked(confirmed.current);
        setStatus("");
        const msg = fail(res);
        if (msg !== null) {
          announce(setAlert, `Couldn't save your reminders. ${msg}`);
        }
        break;
      }
    }
    running.current = false;
  }

  function toggle(value: number, on: boolean) {
    const next = OFFSETS.map((o) => o.value).filter((v) => (v === value ? on : ui.current.includes(v)));
    ui.current = next;
    setChecked(next);
    desired.current = next;
    void run();
  }

  const dest = noDestination(settings);
  return (
    <section aria-labelledby="rm-h">
      <h2 id="rm-h">My reminders</h2>
      <p className="hint" id="rm-hint">
        {owner ? "Only you get these. Sent at 7am Pacific to the places in Settings." : "Only you get these."}
      </p>
      {dest !== null && <DestinationNotice kind={dest} />}
      <fieldset disabled={disabled} aria-labelledby="rm-h" aria-describedby="rm-hint">
        {OFFSETS.map((o) => (
          <label key={o.value} className="check">
            <input
              type="checkbox"
              checked={checked.includes(o.value)}
              onChange={(e) => toggle(o.value, e.target.checked)}
            />
            {o.label}
          </label>
        ))}
      </fieldset>
      <p className="hint">Untick all of them to turn reminders off for this birthday.</p>
      <p className="status ok" role="status" data-testid="reminders-status">
        {status}
      </p>
      <div role="alert">{alert !== "" && <p className="status err">{alert}</p>}</div>
    </section>
  );
}

// "My gift ideas" (private unless shared; each has a Share checkbox and an immediate Remove) and the add form.
export function MyGifts({
  id,
  gifts,
  setGifts,
  disabled,
  fail,
  say,
}: {
  id: number;
  gifts: Gift[];
  setGifts: (fn: (g: Gift[]) => Gift[]) => void;
  disabled: boolean;
  fail: Fail;
  say: Say;
}) {
  const [text, setText] = useState("");
  const [fieldErr, setFieldErr] = useState("");
  const [alert, setAlert] = useState("");
  const [busy, setBusy] = useState<number[]>([]);
  const addingRef = useRef(false);
  const inputRef = useRef<HTMLInputElement>(null);
  const sectionRef = useRef<HTMLElement>(null);
  const focusNext = useRef<number | "input" | null>(null);
  const latest = useRef<Gift[]>(gifts);
  useEffect(() => {
    latest.current = gifts;
  }, [gifts]);

  // After a Remove the list has re-rendered: focus the next idea's Remove button, else the input.
  useEffect(() => {
    const target = focusNext.current;
    if (target === null) {
      return;
    }
    focusNext.current = null;
    if (target === "input") {
      inputRef.current?.focus();
    } else {
      sectionRef.current?.querySelector<HTMLElement>(`[data-gift-remove="${target}"]`)?.focus();
    }
  }, [gifts]);

  async function onAdd(e: FormEvent) {
    e.preventDefault();
    if (addingRef.current || disabled) {
      return;
    }
    setAlert("");
    const trimmed = text.trim();
    if (trimmed === "") {
      setFieldErr(failureText("invalid_text"));
      inputRef.current?.focus();
      return;
    }
    addingRef.current = true;
    const res = await postGift(id, trimmed);
    addingRef.current = false;
    if (res.kind === "ok") {
      setGifts((g) => [...g, res.data]);
      setText("");
      setFieldErr("");
      say("Added gift idea.");
      inputRef.current?.focus();
      return;
    }
    if (res.kind === "invalid_text" || res.kind === "too_many_gifts") {
      setFieldErr(failureText(res.kind));
      inputRef.current?.focus();
      return;
    }
    const msg = fail(res);
    if (msg !== null) {
      setAlert(msg);
    }
  }

  async function onShare(g: Gift, shared: boolean) {
    if (busy.includes(g.id) || disabled) {
      return;
    }
    setAlert("");
    setBusy((b) => [...b, g.id]);
    const res = await patchGift(g.id, shared);
    setBusy((b) => b.filter((x) => x !== g.id));
    if (res.kind === "ok") {
      setGifts((list) => list.map((x) => (x.id === g.id ? res.data : x)));
      say(res.data.shared ? "Gift idea shared." : "Gift idea kept private.");
    } else if (res.kind === "not_found") {
      setGifts((list) => list.filter((x) => x.id !== g.id));
      say("That gift idea is already gone.");
    } else {
      const msg = fail(res);
      if (msg !== null) {
        setAlert(msg);
      }
    }
  }

  async function onRemove(g: Gift) {
    if (busy.includes(g.id) || disabled) {
      return;
    }
    setAlert("");
    setBusy((b) => [...b, g.id]);
    const res = await deleteGift(g.id);
    setBusy((b) => b.filter((x) => x !== g.id));
    if (res.kind === "ok" || res.kind === "not_found") {
      const list = latest.current;
      const i = list.findIndex((x) => x.id === g.id);
      focusNext.current = list[i + 1]?.id ?? "input";
      setGifts((list) => list.filter((x) => x.id !== g.id));
      say("Removed gift idea.");
      return;
    }
    const msg = fail(res);
    if (msg !== null) {
      setAlert(msg);
    }
  }

  return (
    <section aria-labelledby="gi-h" ref={sectionRef}>
      <h2 id="gi-h">My gift ideas</h2>
      <p className="hint">
        Private unless you share one. A shared idea is seen only by people this birthday is shared with.
      </p>
      {gifts.length === 0 ? (
        <p className="empty">No gift ideas yet.</p>
      ) : (
        <ul className="items gifts" aria-label="My gift ideas">
          {gifts.map((g) => (
            <li key={g.id}>
              <div className="pinfo">
                <span>{g.text}</span>
                <div className="meta">{g.shared ? "Shared" : "Only you"}</div>
              </div>
              <label className="check">
                <input
                  type="checkbox"
                  checked={g.shared}
                  disabled={disabled}
                  aria-disabled={busy.includes(g.id) ? "true" : undefined}
                  aria-label={`Share gift idea: ${g.text}`}
                  onChange={(e) => void onShare(g, e.target.checked)}
                />
                Share
              </label>
              <button
                className="secondary"
                type="button"
                data-gift-remove={g.id}
                disabled={disabled}
                aria-disabled={busy.includes(g.id) ? "true" : undefined}
                aria-label={`Remove gift idea: ${g.text}`}
                onClick={() => void onRemove(g)}
              >
                Remove
              </button>
            </li>
          ))}
        </ul>
      )}
      <form className="detailform" onSubmit={(e) => void onAdd(e)} noValidate aria-label="Add a gift idea">
        <div className="field name">
          <label htmlFor="gift-new">New gift idea</label>
          <input
            id="gift-new"
            type="text"
            maxLength={200}
            autoComplete="off"
            ref={inputRef}
            value={text}
            disabled={disabled}
            aria-invalid={fieldErr !== "" ? "true" : undefined}
            aria-describedby="gift-new-err"
            onChange={(e) => {
              setText(e.target.value);
              setFieldErr("");
            }}
          />
          <p className="fielderr" id="gift-new-err">
            {fieldErr}
          </p>
        </div>
        <button className="secondary" type="submit" disabled={disabled}>
          Add idea
        </button>
      </form>
      <div role="alert">{alert !== "" && <p className="status err">{alert}</p>}</div>
    </section>
  );
}

// Gift ideas other people shared: read-only. Hidden when there are none.
export function OthersGifts({ gifts }: { gifts: Gift[] }) {
  if (gifts.length === 0) {
    return null;
  }
  return (
    <section aria-labelledby="ogi-h">
      <h2 id="ogi-h">Gift ideas shared by others</h2>
      <ul className="items">
        {gifts.map((g) => (
          <li key={g.id}>
            <div className="pinfo">
              <span>{g.text}</span>
              <div className="meta">from {g.author_email}</div>
            </div>
          </li>
        ))}
      </ul>
    </section>
  );
}
