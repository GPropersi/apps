import { useEffect, useRef, useState } from "react";
import type { KeyboardEvent, ReactNode } from "react";
import { announce } from "./util";

const WEEKS = Array.from({ length: 52 }, (_, i) => i + 1);

export function weeksLabel(n: number): string {
  return n === 1 ? "1 week" : `${n} weeks`;
}

function canonical(values: number[]): number[] {
  return [...new Set(values)].sort((a, b) => b - a);
}

function same(a: number[], b: number[]): boolean {
  const x = canonical(a);
  const y = canonical(b);
  return x.length === y.length && x.every((v, i) => v === y[i]);
}

// The one place reminder timing is chosen: "on the day" and "1 day before" boxes, removable week chips, and a select
// to add a week count. Purely presentational: the caller owns saving. onChange always receives the canonical
// (descending, de-duplicated) array.
export function TimingPicker({
  value,
  onChange,
  idPrefix,
  disabled,
  legend,
  labelledBy,
  describedBy,
  allowEmpty,
  emptyMessage,
  error,
}: {
  value: number[];
  onChange: (next: number[]) => void;
  idPrefix: string;
  disabled?: boolean;
  legend?: ReactNode;
  labelledBy?: string;
  describedBy?: string;
  allowEmpty: boolean;
  emptyMessage?: string;
  error?: string;
}) {
  const [status, setStatus] = useState("");
  const [emptyErr, setEmptyErr] = useState("");
  const [pick, setPick] = useState("");
  const pickRef = useRef("");
  const selectRef = useRef<HTMLSelectElement>(null);
  const fieldsetRef = useRef<HTMLFieldSetElement>(null);
  const focusAfter = useRef<number | "select" | null>(null);
  const lastEmitted = useRef<number[] | null>(null);
  // The newest value the person chose: a second change made before the parent re-renders builds on it.
  const cur = useRef<number[]>(value);
  const prevValue = useRef<number[]>(value);
  if (!same(prevValue.current, value)) {
    cur.current = value;
    prevValue.current = value;
  }

  const weeks = canonical(value).filter((v) => v >= 7);

  // A value that differs in content from what this picker last emitted came from outside (a revert): drop the stale
  // announcement.
  useEffect(() => {
    if (lastEmitted.current === null || !same(lastEmitted.current, value)) {
      setStatus("");
    }
  }, [value]);

  useEffect(() => {
    const target = focusAfter.current;
    if (target === null) {
      return;
    }
    focusAfter.current = null;
    if (target === "select") {
      selectRef.current?.focus();
    } else {
      fieldsetRef.current?.querySelector<HTMLElement>(`[data-week-x="${target}"]`)?.focus();
    }
  }, [value]);

  function emit(next: number[]) {
    const c = canonical(next);
    cur.current = c;
    lastEmitted.current = c;
    onChange(c);
  }

  function setDay(v: 0 | 1, on: boolean) {
    const base = cur.current;
    const next = base.filter((x) => x !== v);
    if (on) {
      next.push(v);
    }
    if (next.length === 0 && !allowEmpty) {
      setEmptyErr(emptyMessage ?? "");
      return;
    }
    setEmptyErr("");
    emit(next);
  }

  function removeWeek(offset: number) {
    const base = cur.current;
    const next = base.filter((x) => x !== offset);
    if (next.length === 0 && !allowEmpty) {
      setEmptyErr(emptyMessage ?? "");
      return;
    }
    const w = canonical(base).filter((v) => v >= 7);
    const i = w.indexOf(offset);
    const neighbour = w[i + 1] ?? w[i - 1];
    focusAfter.current = neighbour ?? "select";
    setEmptyErr("");
    announce(setStatus, `Removed ${weeksLabel(offset / 7)} before`);
    emit(next);
  }

  function addWeek() {
    const chosen = pickRef.current;
    if (chosen === "") {
      return;
    }
    pickRef.current = "";
    setPick("");
    const offset = Number(chosen) * 7;
    if (cur.current.includes(offset)) {
      return;
    }
    const next = [...cur.current, offset];
    focusAfter.current = canonical(next).filter((v) => v >= 7).length === WEEKS.length ? offset : "select";
    setEmptyErr("");
    announce(setStatus, `Added ${weeksLabel(Number(chosen))} before`);
    emit(next);
  }

  function onSwallowEnter(e: KeyboardEvent) {
    if (e.key === "Enter") {
      e.preventDefault();
    }
  }

  function onSelectKey(e: KeyboardEvent) {
    if (e.key === "Enter") {
      e.preventDefault();
      const shown = (e.currentTarget as HTMLSelectElement).value;
      if (shown !== "") {
        pickRef.current = shown;
      }
      addWeek();
    }
  }

  const available = WEEKS.filter((k) => !value.includes(k * 7));
  const full = available.length === 0;
  // A pick that became chosen from outside (a revert or adopted server value) is no longer offered: fall back to the placeholder.
  const sel = available.includes(Number(pick)) ? pick : "";
  pickRef.current = sel;
  const errId = `${idPrefix}-err`;
  const shown = error !== undefined && error !== "" ? error : emptyErr;
  const describedIds = describedBy === undefined || describedBy === "" ? errId : `${errId} ${describedBy}`;

  return (
    <fieldset
      className="timing"
      ref={fieldsetRef}
      disabled={disabled}
      aria-labelledby={legend === undefined ? labelledBy : undefined}
      aria-describedby={describedIds}
    >
      {legend !== undefined && <legend className="hint plain">{legend}</legend>}
      <label className="check">
        <input
          type="checkbox"
          id={`${idPrefix}-0`}
          checked={value.includes(0)}
          onChange={(e) => setDay(0, e.target.checked)}
          onKeyDown={onSwallowEnter}
        />
        On the day
      </label>
      <label className="check">
        <input
          type="checkbox"
          id={`${idPrefix}-1`}
          checked={value.includes(1)}
          onChange={(e) => setDay(1, e.target.checked)}
          onKeyDown={onSwallowEnter}
        />
        1 day before
      </label>
      {weeks.length > 0 && (
        <>
          <p className="hint">Weeks before</p>
          <ul className="weeks" aria-label="Weeks before">
            {weeks.map((o) => (
              <li className="week" key={o}>
                {weeksLabel(o / 7)}
                <button
                  className="week-x"
                  type="button"
                  data-week-x={o}
                  aria-label={`Remove ${weeksLabel(o / 7)} before`}
                  onClick={() => removeWeek(o)}
                >
                  <svg viewBox="0 0 16 16" aria-hidden="true" focusable="false">
                    <path d="M3 3l10 10M13 3L3 13" stroke="currentColor" strokeWidth="2" strokeLinecap="round" fill="none" />
                  </svg>
                </button>
              </li>
            ))}
          </ul>
        </>
      )}
      <div className="row adder">
        <div className="field">
          <label htmlFor={`${idPrefix}-add`}>Add weeks before</label>
          <select
            id={`${idPrefix}-add`}
            ref={selectRef}
            disabled={full}
            value={sel}
            onChange={(e) => {
              pickRef.current = e.target.value;
              setPick(e.target.value);
            }}
            onKeyDown={onSelectKey}
          >
            <option value="">Choose weeks</option>
            {available.map((k) => (
              <option key={k} value={String(k)}>
                {weeksLabel(k)}
              </option>
            ))}
          </select>
        </div>
        <button className="secondary" type="button" disabled={full || sel === ""} onClick={addWeek}>
          Add
        </button>
      </div>
      <p className="status" role="status">
        {status}
      </p>
      <p className="fielderr" id={errId} role="alert">
        {shown}
      </p>
    </fieldset>
  );
}
