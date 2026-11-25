import { useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { putBirthday } from "./api";
import type { Birthday, Failure } from "./api";
import { validateAdd } from "./AddTab";
import { MONTHS } from "./dates";
import { clearEditDraft, loadEditDraft } from "./draft";
import type { EditDraft } from "./draft";
import { failureText } from "./messages";
import { announce } from "./util";

type Errors = ReturnType<typeof validateAdd>;
const NO_ERRORS: Errors = { name: "", month: "", day: "", year: "" };

function formOf(b: Birthday): EditDraft {
  return { name: b.name, month: b.month, day: String(b.day), year: b.year === null ? "" : String(b.year) };
}

function same(a: EditDraft, b: EditDraft): boolean {
  return a.name === b.name && a.month === b.month && a.day === b.day && a.year === b.year;
}

// The owner's edit form. It reuses the Add validator and its per-field error ids. A dirty edit lives in app-level
// state per birthday id (`edit`, undefined when the form matches the server), mirrored to sessionStorage by the App.
export function EditForm({
  b,
  edit,
  setEdit,
  tag,
  disabled,
  onSaved,
  fail,
}: {
  b: Birthday;
  edit: EditDraft | undefined;
  setEdit: (id: number, d: EditDraft | null) => void;
  tag: string | null;
  disabled: boolean;
  onSaved: (b: Birthday) => void;
  fail: (f: Failure) => string | null;
}) {
  const [errors, setErrors] = useState<Errors>(NO_ERRORS);
  const [restored, setRestored] = useState(edit !== undefined);
  const [status, setStatus] = useState("");
  const [alert, setAlert] = useState("");
  const [saving, setSaving] = useState(false);
  const savingRef = useRef(false);
  const storageChecked = useRef(false);
  const nameRef = useRef<HTMLInputElement>(null);
  const monthRef = useRef<HTMLSelectElement>(null);
  const dayRef = useRef<HTMLInputElement>(null);
  const yearRef = useRef<HTMLInputElement>(null);

  const server = formOf(b);
  const form = edit ?? server;
  // The form as last rendered: an in-flight save compares it with what it sent, so typing meanwhile is not lost.
  const formRef = useRef(form);
  useEffect(() => {
    formRef.current = form;
  });

  // After a reload the draft comes back from sessionStorage, once the signed-in person's tag is known and matches.
  useEffect(() => {
    if (storageChecked.current || tag === null) {
      return;
    }
    storageChecked.current = true;
    if (edit !== undefined) {
      return;
    }
    const stored = loadEditDraft(tag, b.id);
    if (stored === null) {
      return;
    }
    if (same(stored, server)) {
      clearEditDraft(b.id);
    } else {
      setEdit(b.id, stored);
      setRestored(true);
    }
  }, [tag, edit, b.id, server, setEdit]);

  function change(patch: Partial<EditDraft>, clear: (keyof Errors)[]) {
    const next = { ...form, ...patch };
    setEdit(b.id, same(next, server) ? null : next);
    setErrors((er) => {
      const out = { ...er };
      for (const k of clear) {
        out[k] = "";
      }
      return out;
    });
    setStatus("");
    setRestored(false);
  }

  function discard() {
    setEdit(b.id, null);
    setRestored(false);
    setErrors(NO_ERRORS);
    setAlert("");
    announce(setStatus, "Unsaved changes discarded.");
    nameRef.current?.focus();
  }

  async function onSubmit(e: FormEvent) {
    e.preventDefault();
    if (savingRef.current || disabled) {
      return;
    }
    setAlert("");
    setStatus("");
    const found = validateAdd({ ...form, remind: null, offsets: null });
    setErrors(found);
    if (found.name !== "") {
      nameRef.current?.focus();
      return;
    }
    if (found.month !== "") {
      monthRef.current?.focus();
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
    const sent = form;
    const yearText = sent.year.trim();
    savingRef.current = true;
    setSaving(true);
    setStatus("Saving…");
    const res = await putBirthday(b.id, {
      name: form.name.trim(),
      month: form.month,
      day: Number(form.day),
      year: yearText === "" ? null : Number(yearText),
    });
    savingRef.current = false;
    setSaving(false);
    setStatus("");
    if (res.kind === "ok") {
      // Keep anything typed while the request ran; clear the draft only when the form still equals what was sent.
      if (same(formRef.current, sent) || same(formRef.current, formOf(res.data))) {
        setEdit(b.id, null);
        setRestored(false);
      }
      setErrors(NO_ERRORS);
      onSaved(res.data);
      announce(setStatus, "Saved.");
      return;
    }
    // The typed values stay in the draft on every failure.
    if (res.kind === "invalid_name") {
      setErrors({ ...found, name: failureText(res.kind) });
      nameRef.current?.focus();
    } else if (res.kind === "invalid_date") {
      setErrors({ ...found, day: failureText(res.kind) });
      dayRef.current?.focus();
    } else if (res.kind === "invalid_year") {
      setErrors({ ...found, year: failureText(res.kind) });
      yearRef.current?.focus();
    } else {
      const msg = fail(res);
      if (msg !== null) {
        setAlert(msg);
      }
    }
  }

  return (
    <>
      <form className="detailform" onSubmit={(e) => void onSubmit(e)} noValidate aria-label="Edit birthday">
        <div className="field name">
          <label htmlFor="edit-name">Name</label>
          <input
            id="edit-name"
            type="text"
            maxLength={100}
            autoComplete="off"
            ref={nameRef}
            value={form.name}
            disabled={disabled}
            aria-invalid={errors.name !== "" ? "true" : undefined}
            aria-describedby="edit-name-err"
            onChange={(e) => change({ name: e.target.value }, ["name"])}
          />
          <p className="fielderr" id="edit-name-err">
            {errors.name}
          </p>
        </div>
        <div className="field month">
          <label htmlFor="edit-month">Month</label>
          <select
            id="edit-month"
            ref={monthRef}
            value={form.month}
            disabled={disabled}
            aria-invalid={errors.month !== "" ? "true" : undefined}
            aria-describedby="edit-month-err"
            onChange={(e) => change({ month: Number(e.target.value) }, ["month", "day"])}
          >
            {MONTHS.map((full, i) => (
              <option key={full} value={i + 1}>
                {full}
              </option>
            ))}
          </select>
          <p className="fielderr" id="edit-month-err">
            {errors.month}
          </p>
        </div>
        <div className="field">
          <label htmlFor="edit-day">Day</label>
          <input
            id="edit-day"
            type="text"
            inputMode="numeric"
            maxLength={2}
            autoComplete="off"
            ref={dayRef}
            value={form.day}
            disabled={disabled}
            aria-invalid={errors.day !== "" ? "true" : undefined}
            aria-describedby="edit-day-err"
            onChange={(e) => change({ day: e.target.value }, ["day"])}
          />
          <p className="fielderr" id="edit-day-err">
            {errors.day}
          </p>
        </div>
        <div className="field">
          <label htmlFor="edit-year">
            Year <span className="meta">(optional)</span>
          </label>
          <input
            id="edit-year"
            type="text"
            inputMode="numeric"
            maxLength={4}
            autoComplete="off"
            ref={yearRef}
            value={form.year}
            disabled={disabled}
            aria-invalid={errors.year !== "" ? "true" : undefined}
            aria-describedby="edit-year-err"
            onChange={(e) => change({ year: e.target.value }, ["year", "day"])}
          />
          <p className="fielderr" id="edit-year-err">
            {errors.year}
          </p>
        </div>
        <button className="primary" type="submit" disabled={disabled} aria-disabled={saving ? "true" : undefined}>
          Save
        </button>
      </form>
      <div className="row draftnote" role="status" data-testid="edit-restored">
        {restored && edit !== undefined && (
          <>
            <span>Unsaved changes restored.</span>
            <button className="secondary" type="button" disabled={disabled} onClick={discard}>
              Discard
            </button>
          </>
        )}
      </div>
      <p className="status ok" role="status" data-testid="edit-status">
        {status}
      </p>
      <div role="alert">{alert !== "" && <p className="status err">{alert}</p>}</div>
    </>
  );
}
