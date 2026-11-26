import { useEffect, useRef, useState } from "react";
import type { FormEvent, KeyboardEvent, RefObject } from "react";
import { postBirthday } from "./api";
import type { Birthday, Failure, Settings } from "./api";
import { EMPTY_DRAFT } from "./draft";
import type { Draft } from "./draft";
import { MONTHS, MON, daysInMonth } from "./dates";
import { addedText, noDestination, withDates } from "./format";
import { failureText } from "./messages";
import { BirthdayRow, DestinationNotice } from "./parts";
import type { OpenDetail } from "./parts";
import { pointerIsFine } from "./route";
import { TimingPicker } from "./TimingPicker";
import { announce } from "./util";

const NO_OFFSETS_TEXT = failureText("invalid_offsets");

type Errors = { name: string; month: string; day: string; year: string };
const NO_ERRORS: Errors = { name: "", month: "", day: "", year: "" };

// Validates the Add form; every message is specific to the field (and cleared as it is fixed).
export function validateAdd(d: Draft): Errors {
  const errors: Errors = { ...NO_ERRORS };
  if (d.name.trim() === "") {
    errors.name = "Enter a name.";
  }
  if (d.month === 0) {
    errors.month = "Pick a month.";
  }
  let year: number | null = null;
  const yearText = d.year.trim();
  if (yearText !== "") {
    if (!/^\d{4}$/.test(yearText) || Number(yearText) < 1900 || Number(yearText) > 2200) {
      errors.year = "Enter a year from 1900 to 2200.";
    } else {
      year = Number(yearText);
    }
  }
  const dayText = d.day.trim();
  if (!/^\d{1,2}$/.test(dayText) || Number(dayText) < 1) {
    errors.day = "Enter a day.";
  } else {
    const day = Number(dayText);
    if (d.month !== 0) {
      const max = daysInMonth(d.month, year);
      if (day > max) {
        errors.day =
          d.month === 2 && day === 29 && year !== null
            ? `${year} had no February 29.`
            : `${MONTHS[d.month - 1] ?? ""} has ${max} days.`;
      }
    } else if (day > 31) {
      errors.day = "Enter a day from 1 to 31.";
    }
  }
  return errors;
}

export function AddTab({
  disabled,
  draft,
  setDraft,
  settings,
  today,
  recent,
  open,
  onAdded,
  onDefaultOffsets,
  onSessionFailure,
  nameRef,
  autofocusPending,
}: {
  disabled: boolean;
  draft: Draft;
  setDraft: (u: (d: Draft) => Draft) => void;
  settings: Settings | null;
  today: string;
  recent: Birthday[];
  open: OpenDetail;
  onAdded: (b: Birthday) => void;
  onDefaultOffsets: (offsets: number[]) => void;
  onSessionFailure: (f: Failure) => boolean;
  nameRef: RefObject<HTMLInputElement | null>;
  autofocusPending: RefObject<boolean>;
}) {
  const [errors, setErrors] = useState<Errors>(NO_ERRORS);
  const [status, setStatus] = useState("");
  const [alert, setAlert] = useState("");
  const [offsetsError, setOffsetsError] = useState("");
  const [adding, setAdding] = useState(false);
  const addingRef = useRef(false);
  const monthsRef = useRef<HTMLDivElement>(null);
  const dayRef = useRef<HTMLInputElement>(null);
  const yearRef = useRef<HTMLInputElement>(null);

  const remind = draft.remind ?? settings?.auto_remind ?? false;
  const pickerValue = draft.offsets ?? settings?.default_offsets ?? [];

  // First load only: autofocus the name field on a fine pointer (mouse) device; on a phone the person taps it.
  useEffect(() => {
    if (!disabled && autofocusPending.current) {
      autofocusPending.current = false;
      if (pointerIsFine()) {
        nameRef.current?.focus();
      }
    }
  }, [disabled, autofocusPending, nameRef]);

  function focusMonthGroup() {
    const group = monthsRef.current;
    const target = group?.querySelector<HTMLInputElement>("input:checked") ?? group?.querySelector("input");
    target?.focus();
  }

  function focusPicker() {
    // "add-0" is the first checkbox id produced by TimingPicker's id scheme; the two must change together.
    document.getElementById("add-0")?.focus();
  }

  function onNameKeyDown(e: KeyboardEvent<HTMLInputElement>) {
    if (e.key !== "Enter") {
      return;
    }
    // Enter confirms an IME composition; it must not move focus.
    if (e.nativeEvent.isComposing || e.keyCode === 229) {
      return;
    }
    e.preventDefault();
    focusMonthGroup();
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (addingRef.current || disabled) {
      return;
    }
    setAlert("");
    const found = validateAdd(draft);
    setErrors(found);
    const emptyPicker = remind && pickerValue.length === 0;
    setOffsetsError(emptyPicker ? NO_OFFSETS_TEXT : "");
    if (found.name !== "") {
      nameRef.current?.focus();
      return;
    }
    if (found.month !== "") {
      focusMonthGroup();
      return;
    }
    if (found.day !== "") {
      dayRef.current?.focus();
      return;
    }
    if (found.year !== "") {
      yearRef.current?.focus();
      return;
    }
    if (emptyPicker) {
      focusPicker();
      return;
    }
    const year = draft.year.trim();
    addingRef.current = true;
    setAdding(true);
    announce(setStatus, "Adding…");
    const res = await postBirthday({
      name: draft.name.trim(),
      month: draft.month,
      day: Number(draft.day),
      ...(year === "" ? {} : { year: Number(year) }),
      offsets: remind ? pickerValue : [],
    });
    addingRef.current = false;
    setAdding(false);
    setStatus("");
    if (res.kind === "ok") {
      setDraft(() => EMPTY_DRAFT);
      setErrors(NO_ERRORS);
      setOffsetsError("");
      // The server saved the timing as the new default (non-empty only); adopt its canonical copy locally.
      if (res.data.reminder_offsets.length > 0) {
        onDefaultOffsets(res.data.reminder_offsets);
      }
      onAdded(res.data);
      announce(setStatus, addedText(res.data, today));
      nameRef.current?.focus();
      return;
    }
    // The typed values stay in the draft on every failure.
    if (onSessionFailure(res)) {
      return;
    }
    if (res.kind === "invalid_name") {
      setErrors({ ...found, name: failureText(res.kind) });
      nameRef.current?.focus();
    } else if (res.kind === "invalid_date") {
      setErrors({ ...found, day: failureText(res.kind) });
      dayRef.current?.focus();
    } else if (res.kind === "invalid_year") {
      setErrors({ ...found, year: failureText(res.kind) });
      yearRef.current?.focus();
    } else if (res.kind === "invalid_offsets") {
      setErrors(found);
      setOffsetsError(NO_OFFSETS_TEXT);
      focusPicker();
    } else {
      setAlert(failureText(res.kind));
    }
  }

  function field<K extends keyof Draft>(key: K, value: Draft[K], clear: (keyof Errors)[]) {
    setDraft((d) => ({ ...d, [key]: value }));
    setErrors((er) => {
      const next = { ...er };
      for (const k of clear) {
        next[k] = "";
      }
      return next;
    });
  }

  const dest = noDestination(settings);
  const hintIds = dest !== null ? "add-timing-hint add-remind-hint" : "add-timing-hint";

  return (
    <>
      <section className="narrow" aria-labelledby="add-h">
        <h2 id="add-h" data-screen-h tabIndex={-1}>
          Add a birthday
        </h2>
        <form className="addform" onSubmit={(e) => void onSubmit(e)} noValidate>
          <div className="field">
            <label htmlFor="add-name">Name</label>
            <input
              id="add-name"
              type="text"
              maxLength={100}
              autoComplete="off"
              enterKeyHint="next"
              placeholder="Who's celebrating?"
              ref={nameRef}
              value={draft.name}
              disabled={disabled}
              aria-invalid={errors.name !== "" ? "true" : undefined}
              aria-describedby="add-name-err"
              onChange={(e) => field("name", e.target.value, ["name"])}
              onKeyDown={onNameKeyDown}
            />
            <p className="fielderr" id="add-name-err">
              {errors.name}
            </p>
          </div>

          <fieldset aria-describedby="add-month-err">
            <legend>Month</legend>
            <div className="months" ref={monthsRef} data-invalid={errors.month !== "" ? "true" : undefined}>
              {MONTHS.map((full, i) => (
                <label key={full} className={draft.month === i + 1 ? "on" : undefined}>
                  <input
                    type="radio"
                    name="month"
                    value={i + 1}
                    aria-label={full}
                    checked={draft.month === i + 1}
                    disabled={disabled}
                    onChange={() => field("month", i + 1, ["month", "day"])}
                  />
                  <span>{MON[i]}</span>
                </label>
              ))}
            </div>
            <p className="fielderr" id="add-month-err" role="alert">
              {errors.month}
            </p>
          </fieldset>

          <div className="daterow">
            <div className="field">
              <label htmlFor="add-day">Day</label>
              <input
                id="add-day"
                type="text"
                inputMode="numeric"
                maxLength={2}
                autoComplete="off"
                ref={dayRef}
                value={draft.day}
                disabled={disabled}
                aria-invalid={errors.day !== "" ? "true" : undefined}
                aria-describedby="add-day-err"
                onChange={(e) => field("day", e.target.value, ["day"])}
              />
              <p className="fielderr" id="add-day-err">
                {errors.day}
              </p>
            </div>
            <div className="field">
              <label htmlFor="add-year">
                Year<span className="sr-only"> (optional)</span>
              </label>
              <input
                id="add-year"
                type="text"
                inputMode="numeric"
                maxLength={4}
                autoComplete="off"
                placeholder="Optional"
                ref={yearRef}
                value={draft.year}
                disabled={disabled}
                aria-invalid={errors.year !== "" ? "true" : undefined}
                aria-describedby="add-year-hint add-year-err"
                onChange={(e) => field("year", e.target.value, ["year", "day"])}
              />
              <p className="fielderr" id="add-year-err">
                {errors.year}
              </p>
            </div>
          </div>
          <p className="hint pull" id="add-year-hint">
            Add the year to see how old they're turning.
          </p>

          <label className="check">
            <input
              type="checkbox"
              checked={remind}
              disabled={disabled}
              aria-describedby={dest !== null ? "add-remind-hint" : undefined}
              onChange={(e) => {
                setDraft((d) => ({ ...d, remind: e.target.checked }));
                if (!e.target.checked) {
                  setOffsetsError("");
                }
              }}
            />
            Remind me
          </label>
          {remind && (
            <>
              <TimingPicker
                idPrefix="add"
                allowEmpty
                legend="When"
                disabled={disabled}
                error={offsetsError}
                describedBy={hintIds}
                value={pickerValue}
                onChange={(next) => {
                  setDraft((d) => ({ ...d, offsets: next }));
                  setOffsetsError("");
                }}
              />
              <p className="hint" id="add-timing-hint">
                Sent at 7am Pacific. Your choice is kept for next time. A time that has already passed this year starts
                next year.
              </p>
            </>
          )}
          {dest !== null && (
            <div id="add-remind-hint">
              <DestinationNotice kind={dest} />
            </div>
          )}

          <button
            className="primary wide"
            type="submit"
            disabled={disabled}
            aria-disabled={adding ? "true" : undefined}
          >
            Add birthday
          </button>
          <p className="status added" role="status" aria-live="polite" data-testid="add-status">
            {status}
          </p>
          <div role="alert" data-testid="add-alert">
            {alert !== "" && <p className="status err">{alert}</p>}
          </div>
        </form>
      </section>

      {recent.length > 0 && (
        <section className="narrow" aria-labelledby="recent-h">
          <h2 id="recent-h">Added just now</h2>
          <ul className="items">
            {withDates(recent, today).map((d) => (
              <BirthdayRow key={d.b.id} d={d} origin="add" open={open} />
            ))}
          </ul>
        </section>
      )}
    </>
  );
}
