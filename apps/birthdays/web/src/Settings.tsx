import { useCallback, useEffect, useRef, useState } from "react";
import type { FormEvent } from "react";
import { checkDestination, deleteDestination, getDestinations, postDestination, postNtfy, postNtfyReset } from "./api";
import type { Birthday, CalendarZoom, ColorScheme, Destination, Failure, ListView, Settings, StartTab } from "./api";
import { noDestination } from "./format";
import { failureText } from "./messages";
import { ConfirmPrompt } from "./parts";
import type { NewSecret } from "./Secrets";
import { TimingPicker } from "./TimingPicker";
import type { SettingsSaver } from "./useSettingsSaver";
import { announce, safeHref } from "./util";

const SCHEMES: { value: ColorScheme; label: string; swatch: [string, string, string] }[] = [
  { value: "confetti", label: "Confetti", swatch: ["#fff8f1", "#c8402a", "#ffefbf"] },
  { value: "frosting", label: "Frosting", swatch: ["#faf6fd", "#7e22ce", "#be185d"] },
  { value: "candle", label: "Candlelight", swatch: ["#f6f4ef", "#0f5e6e", "#f2b134"] },
];

const START_TABS: { value: StartTab; label: string }[] = [
  { value: "auto", label: "Add on phones, Birthdays on bigger screens" },
  { value: "add", label: "Always Add" },
  { value: "view", label: "Always Birthdays" },
];

const VIEWS: { value: ListView; label: string }[] = [
  { value: "upcoming", label: "Upcoming" },
  { value: "month", label: "By month" },
  { value: "name", label: "A–Z" },
  { value: "calendar", label: "Calendar" },
];

const ZOOMS: { value: CalendarZoom; label: string }[] = [
  { value: "year", label: "Year" },
  { value: "month", label: "Month" },
  { value: "week", label: "Week" },
];

const NO_OFFSETS: number[] = [];

const NTFY_TITLE = "Your phone notification password";
const DEST_KINDS: { value: "discord" | "webhook"; label: string }[] = [
  { value: "discord", label: "Discord webhook" },
  { value: "webhook", label: "Other webhook" },
];

type ConfirmRequest = { k: "remove"; id: number; label: string } | { k: "reset" };
type Confirm = ConfirmRequest & { n: number };
type Fail = (f: Failure | { kind: "ok" }) => boolean;

const NTFY_TRIGGER = '[data-trigger="ntfy-setup"]';
const ADD_TRIGGER = '[data-trigger="add-destination"]';
const GENERATE_TRIGGER = '[data-trigger="ntfy-generate"]';
const LABEL_FIELD = "#dest-label";
const URL_FIELD = "#dest-url";
const removeSel =(id: number) => `[data-remove="${id}"]`;
const find = (sel: string) => document.querySelector<HTMLElement>(sel);

function destLabel(d: Destination): string {
  return `${d.kind === "discord" ? "Discord" : "Webhook"}: ${d.label}`;
}

// The Settings tab. Preference changes all go through the shared settings saver; notify responses only ever update the
// app-level counters (applyCounters), never the preference fields.
export function SettingsTab({
  settings,
  list,
  disabled,
  saver,
  onSessionFailure,
  addSecret,
  hasNtfySecret,
}: {
  settings: Settings | null;
  list: Birthday[] | null;
  disabled: boolean;
  saver: SettingsSaver;
  onSessionFailure: Fail;
  addSecret: (secret: NewSecret, back: () => HTMLElement | null) => void;
  hasNtfySecret: boolean;
}) {
  const { applyCounters } = saver;
  const locked = disabled || settings === null;

  const [dests, setDests] = useState<Destination[] | null>(null);
  const [loadErr, setLoadErr] = useState("");
  const [status, setStatus] = useState("");
  const [confirm, setConfirm] = useState<Confirm | null>(null);
  const [confirmBusy, setConfirmBusy] = useState(false);
  const [ntfySetup, setNtfySetup] = useState<string | null>(null);
  // The phone setup details under the phone row; opened by the button, closed by Hide setup or a successful reset.
  const [ntfyOpen, setNtfyOpen] = useState(false);
  const [ntfyBusy, setNtfyBusy] = useState(false);
  const [checking, setChecking] = useState<number | null>(null);

  const [kind, setKind] = useState<"discord" | "webhook">("discord");
  const [label, setLabel] = useState("");
  const [url, setUrl] = useState("");
  const [labelErr, setLabelErr] = useState("");
  const [urlErr, setUrlErr] = useState("");
  const [adding, setAdding] = useState(false);

  const nonce = useRef(0);
  const checkingRef = useRef(false);
  const ntfyRef = useRef(false);
  const addingRef = useRef(false);
  const confirmBusyRef = useRef(false);
  const pendingFocus = useRef<number | null>(null);
  const destH = useRef<HTMLHeadingElement>(null);
  const setupH = useRef<HTMLHeadingElement>(null);
  // One-shot request to focus the setup heading once the block has mounted.
  const focusSetup = useRef(false);
  const live = useRef(true);
  const loadSeq = useRef(0);
  // Rows added or removed here, so a destinations load that started earlier cannot undo them.
  const addedRef = useRef<Destination[]>([]);
  const removedRef = useRef<Set<number>>(new Set());
  const hasNtfyRef = useRef(hasNtfySecret);
  hasNtfyRef.current = hasNtfySecret;

  useEffect(() => {
    live.current = true;
    return () => {
      live.current = false;
    };
  }, []);

  const say = useCallback((message: string) => announce(setStatus, message), []);

  const loadDests = useCallback(async () => {
    setLoadErr("");
    loadSeq.current += 1;
    const seq = loadSeq.current;
    const res = await getDestinations();
    if (!live.current || seq !== loadSeq.current) {
      return;
    }
    if (res.kind === "ok") {
      const rows = res.data.filter((d) => !removedRef.current.has(d.id));
      const extra = addedRef.current.filter((a) => !removedRef.current.has(a.id) && !rows.some((d) => d.id === a.id));
      setDests([...rows, ...extra]);
    } else if (!onSessionFailure(res)) {
      setLoadErr(failureText(res.kind));
    }
  }, [onSessionFailure]);

  useEffect(() => {
    void loadDests();
  }, [loadDests]);

  // After Check again un-stales a row, focus moves to that row's Remove button once it has rendered.
  useEffect(() => {
    if (pendingFocus.current !== null) {
      find(removeSel(pendingFocus.current))?.focus();
      pendingFocus.current = null;
    }
  }, [dests]);

  const showSetup = ntfyOpen && settings?.ntfy === true && !hasNtfySecret;
  useEffect(() => {
    if (showSetup && focusSetup.current) {
      focusSetup.current = false;
      setupH.current?.focus();
    }
  }, [showSetup]);

  function openConfirm(next: ConfirmRequest) {
    nonce.current += 1;
    const n = nonce.current;
    setConfirm({ ...next, n });
    say(next.k === "remove" ? `Remove destination ${next.label}? Confirm or cancel.` : "Generate a new password? Confirm or cancel.");
  }

  function cancelConfirm() {
    const was = confirm;
    setConfirm(null);
    if (was !== null) {
      find(was.k === "remove" ? removeSel(was.id) : GENERATE_TRIGGER)?.focus();
    }
  }

  async function onRemove(c: { id: number; label: string }) {
    if (confirmBusyRef.current) {
      return;
    }
    confirmBusyRef.current = true;
    setConfirmBusy(true);
    const res = await deleteDestination(c.id);
    confirmBusyRef.current = false;
    if (res.kind === "ok") {
      applyCounters(res.data.settings);
    }
    if (res.kind === "ok" || res.kind === "not_found") {
      removedRef.current.add(c.id);
      addedRef.current = addedRef.current.filter((a) => a.id !== c.id);
    }
    if (!live.current) {
      return;
    }
    setConfirmBusy(false);
    setConfirm(null);
    if (res.kind === "ok" || res.kind === "not_found") {
      setDests((d) => (d === null ? d : d.filter((x) => x.id !== c.id)));
      say(`Removed ${c.label}`);
      destH.current?.focus();
      return;
    }
    if (!onSessionFailure(res)) {
      say(`Couldn't remove ${c.label}. ${failureText(res.kind)}`);
      find(removeSel(c.id))?.focus();
    }
  }

  async function onReset() {
    if (confirmBusyRef.current) {
      return;
    }
    confirmBusyRef.current = true;
    setConfirmBusy(true);
    const res = await postNtfyReset();
    confirmBusyRef.current = false;
    if (res.kind === "ok") {
      applyCounters(res.data.settings);
      // The block closes after a reset (Generate unmounts), so acknowledging lands on the phone row button.
      addSecret(
        { key: "ntfy", kind: "ntfy", title: NTFY_TITLE, value: res.data.password, setupUrl: res.data.setup_url },
        () => find(NTFY_TRIGGER),
      );
    }
    if (!live.current) {
      return;
    }
    setConfirmBusy(false);
    setConfirm(null);
    if (res.kind === "ok") {
      setNtfySetup(res.data.setup_url);
      setNtfyOpen(false);
      return;
    }
    if (!onSessionFailure(res)) {
      say(failureText(res.kind));
      find(GENERATE_TRIGGER)?.focus();
    }
  }

  async function onNtfy() {
    if (ntfyRef.current) {
      return;
    }
    ntfyRef.current = true;
    setNtfyBusy(true);
    const res = await postNtfy();
    ntfyRef.current = false;
    // A repeat call answers password:null: it never adds or replaces a secret entry.
    if (res.kind === "ok") {
      applyCounters(res.data.settings);
      if (res.data.password !== null) {
        addSecret(
          { key: "ntfy", kind: "ntfy", title: NTFY_TITLE, value: res.data.password, setupUrl: res.data.setup_url },
          () => find(NTFY_TRIGGER),
        );
      }
    }
    if (!live.current) {
      return;
    }
    setNtfyBusy(false);
    if (res.kind !== "ok") {
      if (!onSessionFailure(res)) {
        say(failureText(res.kind));
      }
      return;
    }
    setNtfySetup(res.data.setup_url);
    if (res.data.password !== null) {
      focusSetup.current = false;
      setNtfyOpen(false);
    } else if (!hasNtfyRef.current) {
      focusSetup.current = true;
      setNtfyOpen(true);
    } else {
      focusSetup.current = false;
      setNtfyOpen(false);
      find("[data-secret=ntfy] h2")?.focus();
      say("Your phone notification password is shown above.");
    }
  }

  function onNtfyButton() {
    if (locked) {
      return;
    }
    if (showSetup) {
      if (confirmBusy) {
        return;
      }
      if (confirm?.k === "reset") {
        setConfirm(null);
      }
      setNtfyOpen(false);
      return;
    }
    void onNtfy();
  }

  async function onCheck(d: Destination) {
    if (checkingRef.current) {
      return;
    }
    checkingRef.current = true;
    setChecking(d.id);
    const res = await checkDestination(d.id);
    checkingRef.current = false;
    if (res.kind === "ok") {
      applyCounters(res.data.settings);
    }
    if (!live.current) {
      return;
    }
    setChecking(null);
    if (res.kind !== "ok") {
      if (!onSessionFailure(res)) {
        say(failureText(res.kind));
      }
      return;
    }
    const fresh = res.data.destination;
    if (!fresh.stale) {
      pendingFocus.current = fresh.id;
    }
    setDests((all) => (all === null ? all : all.map((x) => (x.id === fresh.id ? fresh : x))));
    say(fresh.stale ? `${fresh.label} still can't be reached` : `${fresh.label} is deliverable again`);
  }

  async function onAdd(e: FormEvent) {
    e.preventDefault();
    if (addingRef.current || locked) {
      return;
    }
    const l = label.trim();
    const u = url.trim();
    const le = l === "" ? failureText("invalid_label") : "";
    const ue = u === "" ? failureText("invalid_url") : "";
    setLabelErr(le);
    setUrlErr(ue);
    if (le !== "" || ue !== "") {
      find(le !== "" ? LABEL_FIELD : URL_FIELD)?.focus();
      say(le !== "" ? le : ue);
      return;
    }
    addingRef.current = true;
    setAdding(true);
    const res = await postDestination({ kind, label: l, url: u });
    addingRef.current = false;
    // The signing secret is shown once: it is handed to the app even if the person has left Settings meanwhile.
    if (res.kind === "ok") {
      applyCounters(res.data.settings);
      addedRef.current = [...addedRef.current, res.data.destination];
      removedRef.current.delete(res.data.destination.id);
      if (res.data.signing_secret !== null) {
        addSecret(
          {
            key: `webhook:${res.data.destination.id}`,
            kind: "webhook",
            title: `Signing secret for webhook: ${res.data.destination.label}`,
            value: res.data.signing_secret,
            setupUrl: null,
          },
          () => find(ADD_TRIGGER),
        );
      }
    }
    if (!live.current) {
      return;
    }
    setAdding(false);
    if (res.kind !== "ok") {
      if (onSessionFailure(res)) {
        return;
      }
      const text = failureText(res.kind);
      if (res.kind === "invalid_label") {
        setLabelErr(text);
        find(LABEL_FIELD)?.focus();
      } else if (res.kind === "invalid_url" || res.kind === "url_not_public") {
        setUrlErr(text);
        find(URL_FIELD)?.focus();
      }
      say(text);
      return;
    }
    const created = res.data.destination;
    setDests((d) => (d?.some((x) => x.id === created.id) === true ? d : [...(d ?? []), created]));
    setLabel("");
    setUrl("");
    setLabelErr("");
    setUrlErr("");
    say(`Added ${created.label}`);
  }

  const noDest = noDestination(settings);
  const remindersOn = list === null ? 0 : list.filter((b) => b.reminder_offsets.length > 0).length;
  const staleNames = (dests ?? []).filter((d) => d.stale).map((d) => d.label);
  const setupHref = ntfySetup === null ? null : safeHref(ntfySetup);

  return (
    <>
      <section aria-labelledby="settings-h">
        <h2 id="settings-h" data-screen-h tabIndex={-1}>
          Settings
        </h2>
        <fieldset disabled={locked} className="spaced">
          <legend>Color scheme</legend>
          <div className="schemes">
            {SCHEMES.map((s) => (
              <label key={s.value} className={settings?.color_scheme === s.value ? "on" : undefined}>
                <input
                  type="radio"
                  name="palette"
                  value={s.value}
                  checked={settings?.color_scheme === s.value}
                  onChange={() => saver.save({ color_scheme: s.value })}
                />
                <span className="swatch" aria-hidden="true">
                  {s.swatch.map((c) => (
                    <i key={c} style={{ background: c }} />
                  ))}
                </span>
                {s.label}
              </label>
            ))}
          </div>
          <p className="hint">Light or dark follows your device.</p>
        </fieldset>
        <fieldset disabled={locked}>
          <legend>Open the app on</legend>
          {START_TABS.map((t) => (
            <label key={t.value} className="check">
              <input
                type="radio"
                name="start"
                value={t.value}
                checked={settings?.start_tab === t.value}
                onChange={() => saver.save({ start_tab: t.value })}
              />
              {t.label}
            </label>
          ))}
        </fieldset>
        <div className="row spaced-top">
          <div className="field">
            <label htmlFor="pref-view">Birthdays view</label>
            <select
              id="pref-view"
              disabled={locked}
              value={settings?.list_view ?? "upcoming"}
              onChange={(e) => saver.save({ list_view: e.target.value as ListView })}
            >
              {VIEWS.map((v) => (
                <option key={v.value} value={v.value}>
                  {v.label}
                </option>
              ))}
            </select>
          </div>
          <div className="field">
            <label htmlFor="pref-zoom">Calendar zoom</label>
            <select
              id="pref-zoom"
              disabled={locked}
              value={settings?.calendar_zoom ?? "month"}
              onChange={(e) => saver.save({ calendar_zoom: e.target.value as CalendarZoom })}
            >
              {ZOOMS.map((z) => (
                <option key={z.value} value={z.value}>
                  {z.label}
                </option>
              ))}
            </select>
          </div>
        </div>
        <p className="hint spaced-top">
          The Birthdays tab also remembers the last view you picked, on every device you sign in on.
        </p>
        <p className={saver.error ?"status err" : "status ok"} role="status" data-testid="settings-status">
          {saver.status}
        </p>
      </section>

      <section aria-labelledby="def-h">
        <h2 id="def-h">Reminders for new birthdays</h2>
        <label className="check">
          <input
            type="checkbox"
            disabled={locked}
            checked={settings?.auto_remind ?? false}
            onChange={(e) => saver.save({ auto_remind: e.target.checked })}
          />
          Turn reminders on when I add a birthday
        </label>
        <TimingPicker
          idPrefix="dt"
          legend="Default timing"
          value={saver.latest("default_offsets") ?? settings?.default_offsets ?? NO_OFFSETS}
          disabled={locked}
          allowEmpty={false}
          emptyMessage={failureText("invalid_offsets")}
          onChange={(next) => saver.save({ default_offsets: next })}
        />
      </section>

      <section aria-labelledby="dst-h">
        <h2 id="dst-h" tabIndex={-1} ref={destH}>
          Where reminders go
        </h2>
        <ul className="items dests" aria-label="Reminder destinations">
          <li>
            <div className="pinfo">
              <strong>Phone notifications (ntfy)</strong>
              <div className="meta">{settings?.ntfy === true ? "Set up" : "Not set up yet"}</div>
            </div>
            <button
              className="secondary"
              type="button"
              data-trigger="ntfy-setup"
              aria-disabled={ntfyBusy || locked || (confirm?.k === "reset" && confirmBusy) ? "true" : undefined}
              aria-expanded={settings?.ntfy === true ? showSetup : undefined}
              aria-controls={showSetup ? "ntfy-setup" : undefined}
              onClick={onNtfyButton}
            >
              {settings?.ntfy !== true ? "Set up phone" : showSetup ? "Hide setup" : "Show setup again"}
            </button>
            {showSetup && (
              <div className="ntfysetup" id="ntfy-setup" role="group" aria-labelledby="pw-h">
                <h3 id="pw-h" tabIndex={-1} ref={setupH}>
                  Phone notifications are set up
                </h3>
                <p>Install the ntfy app, then follow the setup page to subscribe.</p>
                <p className="hint">Your password was shown once when you set this up. If you lost it, generate a new one.</p>
                <div className="row">
                  {setupHref !== null && (
                    <a className="signout" href={setupHref} target="_blank" rel="noopener noreferrer">
                      Open the setup page
                    </a>
                  )}
                  <button
                    className="secondary"
                    type="button"
                    data-trigger="ntfy-generate"
                    onClick={() => openConfirm({ k: "reset" })}
                  >
                    Generate a new password
                  </button>
                </div>
                {confirm !== null && confirm.k === "reset" && (
                  <ConfirmPrompt
                    key={`reset:${confirm.n}`}
                    question="Generate a new password?"
                    note="The old password stops working. You will need to enter the new one in the ntfy app."
                    confirmLabel="Yes, generate"
                    busy={confirmBusy}
                    onConfirm={() => void onReset()}
                    onCancel={cancelConfirm}
                  />
                )}
              </div>
            )}
          </li>
          {(dests ?? []).map((d) => (
            <li key={d.id}>
              <div className="pinfo">
                <strong>{destLabel(d)}</strong>
                <div className="meta">
                  {d.hint}
                  {d.stale ? " · stale, not used for reminders" : ""}
                </div>
              </div>
              {d.stale && (
                <button
                  className="secondary"
                  type="button"
                  aria-disabled={checking === d.id ? "true" : undefined}
                  aria-label={`${checking === d.id ? "Checking…" : "Check again"}: ${d.label}`}
                  onClick={() => void onCheck(d)}
                >
                  {checking === d.id ? "Checking…" : "Check again"}
                </button>
              )}
              <button
                className="secondary"
                type="button"
                data-remove={d.id}
                aria-label={`Remove destination ${d.label}`}
                onClick={() => openConfirm({ k: "remove", id: d.id, label: d.label })}
              >
                Remove
              </button>
            </li>
          ))}
        </ul>
        {dests === null && loadErr === "" && <p className="loading">Loading destinations&hellip;</p>}
        {loadErr !== "" && (
          <div className="row">
            <p className="status err">{loadErr}</p>
            <button className="secondary" type="button" onClick={() => void loadDests()}>
              Try again
            </button>
          </div>
        )}
        {confirm !== null && confirm.k === "remove" && (
          <ConfirmPrompt
            key={`remove:${confirm.id}:${confirm.n}`}
            question={`Remove destination ${confirm.label}?`}
            note="This app doesn't store the address, so adding it again means pasting it again. A webhook gets a new signing secret."
            confirmLabel="Yes, remove"
            busy={confirmBusy}
            onConfirm={() => void onRemove(confirm)}
            onCancel={cancelConfirm}
          />
        )}
        <form className="destform" noValidate onSubmit={(e) => void onAdd(e)}>
          <h3 id="dest-add-h">Add a destination</h3>
          <div className="fields" role="group" aria-labelledby="dest-add-h">
            <div className="field kind">
              <label htmlFor="dest-kind">Type</label>
              <select id="dest-kind" disabled={locked} value={kind} onChange={(e) => setKind(e.target.value as "discord" | "webhook")}>
                {DEST_KINDS.map((k) => (
                  <option key={k.value} value={k.value}>
                    {k.label}
                  </option>
                ))}
              </select>
            </div>
            <div className="field label">
              <label htmlFor="dest-label">
                Label <span className="meta">(shown in this list)</span>
              </label>
              <input
                id="dest-label"
                type="text"
                maxLength={50}
                autoComplete="off"
                placeholder="e.g. Family server"
                disabled={locked}
                value={label}
                aria-invalid={labelErr !== "" ? true : undefined}
                aria-describedby="dest-label-err"
                onChange={(e) => setLabel(e.target.value)}
              />
              <p className="fielderr" id="dest-label-err">
                {labelErr}
              </p>
            </div>
            <div className="field url">
              <label htmlFor="dest-url">{kind === "discord" ? "Discord webhook URL" : "Webhook URL"}</label>
              <input
                id="dest-url"
                type="url"
                autoComplete="off"
                placeholder="Paste the address here"
                disabled={locked}
                value={url}
                aria-invalid={urlErr !== "" ? true : undefined}
                aria-describedby="dest-url-err"
                onChange={(e) => setUrl(e.target.value)}
              />
              <p className="fielderr" id="dest-url-err">
                {urlErr}
              </p>
            </div>
          </div>
          <button
            className="secondary"
            type="submit"
            data-trigger="add-destination"
            aria-disabled={adding || locked ? "true" : undefined}
          >
            Add
          </button>
        </form>
        <p className="status" role="status" data-testid="destinations-status">
          {status}
        </p>
      </section>

      {noDest !== null && remindersOn > 0 && (
        <div className="alert" role="alert">
          <strong>No place to send reminders yet.</strong>
          <span>
            {`Reminders are on for ${remindersOn} ${remindersOn === 1 ? "birthday" : "birthdays"}, but ${
              noDest === "stale"
                ? staleNames.length > 0
                  ? `${staleNames.join(", ")} can't be reached, so nothing will be sent.`
                  : "your destinations can't be reached, so nothing will be sent."
                : "you haven't set up a destination, so nothing will be sent."
            }`}
          </span>
        </div>
      )}
    </>
  );
}
