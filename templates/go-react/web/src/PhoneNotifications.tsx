import { useCallback, useEffect, useRef, useState } from "react";
import type { FormEvent, MutableRefObject } from "react";
import {
  checkDestination,
  deleteDestination,
  getDestinations,
  getMe,
  postDestination,
  postDestinationTest,
  postNtfy,
  postNtfyReset,
  postNtfyTest,
} from "./api";
import type { Destination, Failure, Phone } from "./api";
import {
  MSG_NTFY_SETUP_HINT,
  MSG_PHONE_UNKNOWN,
  MSG_SENDING,
  MSG_TEST_SENT_PHONE,
  added,
  announce,
  deliverable,
  failureText,
  removed,
  stillStale,
  testSentTo,
} from "./messages";
import { ConfirmPrompt, SecretPanel, safeHref } from "./parts";
import type { NewSecret, Secret } from "./parts";

type Fail = (f: Failure | { kind: "ok" }) => boolean;
type Kind = "discord" | "webhook";
type Confirm = ({ k: "remove"; id: number; label: string } | { k: "reset" }) & { n: number };
type RefreshOpts = { withMe: boolean; focus?: () => boolean };

const NTFY_TITLE = "Your phone notification password";
const KIND_LABEL: Record<Kind, string> = { discord: "Discord", webhook: "Webhook" };
const KIND_HINT: Record<Kind, string> = {
  discord: "Paste a Discord webhook address",
  webhook: "Your app will receive a signed POST; a signing secret is shown once after you add it",
};

const NTFY_TRIGGER = '[data-trigger="ntfy-setup"]';
const ADD_TRIGGER = '[data-trigger="add-destination"]';
const GENERATE_TRIGGER = '[data-trigger="ntfy-generate"]';
const LABEL_FIELD = "#dest-label";
const URL_FIELD = "#dest-url";
const removeSel = (id: number) => `[data-remove="${id}"]`;
const checkSel = (id: number) => `[data-check="${id}"]`;
const testSel = (id: number) => `[data-test="${id}"]`;

function focusSel(sel: string): boolean {
  const el = document.querySelector<HTMLElement>(sel);
  el?.focus();
  return el !== null;
}

// The phone-notifications section, rendered only when /api/me says notifs is true. It owns the phone state P after the
// first render and does its own /api/me fetch for refresh, so the Notes form in App is never touched. One-time secrets
// live in memory only.
export function PhoneNotifications({
  initialPhone,
  pageDown,
  onSessionFailure,
  resetRef,
}: {
  initialPhone: Phone | null;
  pageDown: boolean;
  onSessionFailure: Fail;
  resetRef: MutableRefObject<(() => void) | null>;
}) {
  const [phone, setPhone] = useState<Phone | null>(initialPhone);
  const [dests, setDests] = useState<Destination[] | null>(null);
  const [listErr, setListErr] = useState("");
  const [refreshing, setRefreshing] = useState(true);
  const [status, setStatus] = useState("");
  const [testText, setTestText] = useState("");
  const [testOk, setTestOk] = useState(false);
  const [notice, setNotice] = useState("");
  const [secrets, setSecrets] = useState<Secret[]>([]);
  const [confirm, setConfirmState] = useState<Confirm | null>(null);
  const [confirmBusy, setConfirmBusy] = useState(false);
  const [ntfyOpen, setNtfyOpen] = useState(false);
  const [setupUrl, setSetupUrl] = useState<string | null>(null);
  const [ntfyBusy, setNtfyBusy] = useState(false);
  const [testing, setTesting] = useState<string | null>(null);
  const [checking, setChecking] = useState<number[]>([]);

  const [kind, setKind] = useState<Kind>("discord");
  const [label, setLabel] = useState("");
  const [url, setUrl] = useState("");
  const [labelErr, setLabelErr] = useState("");
  const [urlErr, setUrlErr] = useState("");
  const [adding, setAdding] = useState(false);

  const alive = useRef(true);
  const seqRef = useRef(0);
  // The refresh that is awaiting an answer, re-issued once by a mutation that supersedes it.
  const inFlight = useRef<{ id: number; withMe: boolean } | null>(null);
  const reissue = useRef<{ withMe: boolean } | null>(null);
  // Double-submit guards, one per write action; the test guard covers both test routes.
  const testingRef = useRef(false);
  const setupRef = useRef(false);
  const resettingRef = useRef(false);
  const addRef = useRef(false);
  const checkIds = useRef(new Set<number>());
  const removeIds = useRef(new Set<number>());
  const confirmRef = useRef<Confirm | null>(null);
  const nonce = useRef(0);
  const secretSeq = useRef(0);
  const seenSecret = useRef(0);
  const backs = useRef(new Map<string, () => boolean>());
  const headings = useRef(new Map<string, HTMLHeadingElement>());
  const noticeOverride = useRef<string | null>(null);
  const focusAfter = useRef<(() => boolean) | null>(null);
  const headingRef = useRef<HTMLHeadingElement>(null);
  const setupH = useRef<HTMLHeadingElement>(null);
  const hasNtfySecret = secrets.some((s) => s.key === "ntfy");
  const hasNtfyRef = useRef(false);
  hasNtfyRef.current = hasNtfySecret;

  const locked = phone === null;
  const needRetry = listErr !== "" || phone === null;
  const showSetup = ntfyOpen && phone?.ntfy === true && !hasNtfySecret;

  const say = useCallback((message: string) => announce(setStatus, message), []);
  const sayTest = useCallback((message: string, ok: boolean) => {
    setTestOk(ok);
    announce(setTestText, message);
  }, []);
  const focusHeading = useCallback(() => {
    headingRef.current?.focus();
    return headingRef.current !== null;
  }, []);

  function putConfirm(c: Confirm | null) {
    confirmRef.current = c;
    setConfirmState(c);
  }

  // Takes a sequence value for a mutation; an unanswered refresh is remembered so it can be re-issued afterwards.
  function begin(): number {
    focusAfter.current = null;
    const mine = ++seqRef.current;
    if (inFlight.current !== null) {
      reissue.current = { withMe: inFlight.current.withMe };
    }
    return mine;
  }
  const isCurrent = (mine: number) => alive.current && mine === seqRef.current;

  const refresh = useCallback(
    async (o: RefreshOpts): Promise<"ok" | "failed" | "dropped"> => {
      const mine = ++seqRef.current;
      inFlight.current = { id: mine, withMe: o.withMe };
      setRefreshing(true);
      const [me, list] = await Promise.all([o.withMe ? getMe() : Promise.resolve(null), getDestinations()]);
      if (inFlight.current?.id === mine) {
        inFlight.current = null;
      }
      if (!alive.current || mine !== seqRef.current) {
        return "dropped";
      }
      setRefreshing(false);
      let failure: Failure | null = null;
      for (const r of [me, list]) {
        if (r !== null && r.kind !== "ok") {
          if (onSessionFailure(r)) {
            return "failed";
          }
          failure ??= r;
        }
      }
      if (me?.kind === "ok") {
        setPhone(me.data.phone);
      }
      if (list.kind === "ok") {
        const rows = list.data;
        const open = confirmRef.current;
        if (open?.k === "remove" && !rows.some((d) => d.id === open.id)) {
          putConfirm(null);
          focusAfter.current = focusHeading;
        } else if (o.focus !== undefined && failure === null) {
          focusAfter.current = o.focus;
        }
        setDests(rows);
      }
      if (failure !== null) {
        const text = failureText(failure.kind);
        setListErr(text);
        say(text);
        return "failed";
      }
      setListErr("");
      if (me?.kind === "ok" && me.data.phone === null) {
        say(MSG_PHONE_UNKNOWN);
      }
      return "ok";
    },
    [onSessionFailure, say, focusHeading],
  );

  // A mutation whose result was overtaken by another mutation never applied it, so the list and phone counts are
  // refreshed from the server once its guards have cleared (a refresh already in flight will deliver the state itself).
  function converge(mine: number) {
    if (mine >= 0 && alive.current && mine !== seqRef.current && inFlight.current === null) {
      reissue.current = { withMe: true };
    }
  }

  // Re-issues a refresh that a finished mutation overtook (after the mutation has applied its own result).
  function flushReissue() {
    const r = reissue.current;
    reissue.current = null;
    if (r !== null && alive.current) {
      void refresh({ withMe: r.withMe });
    }
  }

  useEffect(() => {
    alive.current = true;
    void refresh({ withMe: false });
    return () => {
      alive.current = false;
      seqRef.current += 1;
    };
  }, [refresh]);

  // Clears every guard and pending UI state after a page-level session failure, so a later recovery starts clean.
  useEffect(() => {
    resetRef.current = () => {
      seqRef.current += 1;
      inFlight.current = null;
      reissue.current = null;
      focusAfter.current = null;
      testingRef.current = false;
      setupRef.current = false;
      resettingRef.current = false;
      addRef.current = false;
      checkIds.current.clear();
      removeIds.current.clear();
      backs.current.clear();
      confirmRef.current = null;
      setConfirmState(null);
      setConfirmBusy(false);
      setTesting(null);
      setChecking([]);
      setNtfyBusy(false);
      setAdding(false);
      setRefreshing(false);
      setTestText("");
      setStatus("");
    };
    const mine = resetRef;
    return () => {
      mine.current = null;
    };
  }, [resetRef]);

  // Runs a requested focus move once its target has rendered.
  useEffect(() => {
    const f = focusAfter.current;
    if (f !== null && f()) {
      focusAfter.current = null;
    }
  });

  // A new or replaced secret takes focus on its heading and is announced (a combined message may override the text).
  useEffect(() => {
    const fresh = secrets.filter((s) => s.seq > seenSecret.current);
    if (fresh.length === 0) {
      return;
    }
    const newest = fresh.reduce((a, b) => (b.seq > a.seq ? b : a));
    seenSecret.current = newest.seq;
    headings.current.get(newest.key)?.focus();
    const text = noticeOverride.current ?? `${newest.title}. Copy it before you leave this page.`;
    noticeOverride.current = null;
    announce(setNotice, text);
  }, [secrets]);

  // Leaving the page loses an unacknowledged secret, so the browser is asked first.
  useEffect(() => {
    if (secrets.length === 0) {
      return;
    }
    const guard = (e: BeforeUnloadEvent) => e.preventDefault();
    window.addEventListener("beforeunload", guard);
    return () => window.removeEventListener("beforeunload", guard);
  }, [secrets.length]);

  function addSecret(s: NewSecret, back: () => boolean) {
    if (!alive.current) {
      return;
    }
    backs.current.set(s.key, back);
    secretSeq.current += 1;
    const entry = { ...s, seq: secretSeq.current };
    setSecrets((prev) => [...prev.filter((x) => x.key !== s.key), entry]);
  }

  function ackSecret(key: string) {
    setSecrets((prev) => prev.filter((s) => s.key !== key));
    const back = backs.current.get(key);
    backs.current.delete(key);
    if (back === undefined || !back()) {
      focusHeading();
    }
  }

  function openConfirm(next: { k: "remove"; id: number; label: string } | { k: "reset" }) {
    nonce.current += 1;
    putConfirm({ ...next, n: nonce.current });
    say(next.k === "remove" ? `Remove destination ${next.label}? Confirm or cancel.` : "Generate a new password? Confirm or cancel.");
  }

  function cancelConfirm() {
    const was = confirmRef.current;
    putConfirm(null);
    if (was !== null) {
      focusSel(was.k === "remove" ? removeSel(was.id) : GENERATE_TRIGGER);
    }
  }

  // A destination that is gone on the server: announce it, converge on the server's state and park focus on the heading.
  function convergeNotFound() {
    say(failureText("not_found"));
    focusHeading();
    void refresh({ withMe: true });
  }

  async function onSetup() {
    if (setupRef.current || locked) {
      return;
    }
    setupRef.current = true;
    let mine = -1;
    try {
      mine = begin();
      setNtfyBusy(true);
      setTestText("");
      const res = await postNtfy();
      // A repeat call answers password:null: it never adds or replaces a secret entry.
      if (res.kind === "ok" && res.data.password !== null) {
        addSecret(
          { key: "ntfy", kind: "ntfy", title: NTFY_TITLE, value: res.data.password, setupUrl: res.data.setup_url },
          () => focusSel(NTFY_TRIGGER),
        );
      }
      if (!alive.current) {
        return;
      }
      setNtfyBusy(false);
      if (res.kind !== "ok") {
        if (!onSessionFailure(res)) {
          say(failureText(res.kind));
        }
        return;
      }
      if (!isCurrent(mine)) {
        return;
      }
      setPhone(res.data.phone);
      setSetupUrl(res.data.setup_url);
      if (res.data.password !== null) {
        setNtfyOpen(false);
      } else {
        focusAfter.current = () => {
          setupH.current?.focus();
          return setupH.current !== null;
        };
        setNtfyOpen(true);
      }
      flushReissue();
    } finally {
      setupRef.current = false;
      converge(mine);
      flushReissue();
    }
  }

  function onNtfyButton() {
    if (locked) {
      return;
    }
    if (hasNtfyRef.current) {
      // The password panel is still up: bring it back instead of opening a second panel.
      headings.current.get("ntfy")?.focus();
      announce(setNotice, `${NTFY_TITLE} is shown on this page. Copy it before you leave.`);
      return;
    }
    if (showSetup) {
      if (confirmBusy) {
        return;
      }
      if (confirmRef.current?.k === "reset") {
        putConfirm(null);
      }
      setNtfyOpen(false);
      return;
    }
    void onSetup();
  }

  async function onReset() {
    if (resettingRef.current) {
      return;
    }
    resettingRef.current = true;
    let mine = -1;
    try {
      mine = begin();
      setConfirmBusy(true);
      const res = await postNtfyReset();
      if (res.kind === "ok") {
        // The block closes after a reset (Generate unmounts), so acknowledging lands on the phone row button.
        addSecret(
          { key: "ntfy", kind: "ntfy", title: NTFY_TITLE, value: res.data.password, setupUrl: res.data.setup_url },
          () => focusSel(NTFY_TRIGGER),
        );
      }
      if (!alive.current) {
        return;
      }
      setConfirmBusy(false);
      putConfirm(null);
      if (res.kind === "ok") {
        if (isCurrent(mine)) {
          setPhone(res.data.phone);
          setSetupUrl(res.data.setup_url);
          setNtfyOpen(false);
          flushReissue();
        }
        return;
      }
      if (!onSessionFailure(res)) {
        say(failureText(res.kind));
        if (isCurrent(mine)) {
          focusSel(GENERATE_TRIGGER);
        }
      }
    } finally {
      resettingRef.current = false;
      converge(mine);
      flushReissue();
    }
  }

  // One test at a time: the guard is held until the whole flow (including the stale refresh) has finished.
  async function onTest(target: "ntfy" | Destination) {
    if (locked || testingRef.current) {
      return;
    }
    testingRef.current = true;
    let mine = -1;
    try {
      mine = begin();
      const id = target === "ntfy" ? null : target.id;
      setTesting(id === null ? "ntfy" : String(id));
      sayTest(MSG_SENDING, true);
      const res = await (target === "ntfy" ? postNtfyTest() : postDestinationTest(target.id));
      if (!alive.current) {
        return;
      }
      setTesting(null);
      if (res.kind === "ok") {
        sayTest(target === "ntfy" ? MSG_TEST_SENT_PHONE : testSentTo(target.label), true);
        if (isCurrent(mine)) {
          setPhone(res.data.phone);
          flushReissue();
        }
        return;
      }
      if (onSessionFailure(res)) {
        return;
      }
      if (id !== null && res.kind === "not_found") {
        setTestText("");
        if (isCurrent(mine)) {
          convergeNotFound();
        }
        return;
      }
      if (id !== null && res.kind === "destination_stale") {
        sayTest(failureText("destination_stale"), false);
        mine = -1;
        await refresh({ withMe: true, focus: () => focusSel(checkSel(id)) });
        return;
      }
      const extra = id === null && res.kind === "ntfy_not_set_up" ? MSG_NTFY_SETUP_HINT : "";
      sayTest(`${failureText(res.kind)}${extra}`, false);
    } finally {
      testingRef.current = false;
      converge(mine);
      flushReissue();
    }
  }

  async function onCheck(d: Destination) {
    if (locked || checkIds.current.has(d.id)) {
      return;
    }
    checkIds.current.add(d.id);
    let mine = -1;
    try {
      mine = begin();
      setChecking((c) => [...c, d.id]);
      const res = await checkDestination(d.id);
      if (!alive.current) {
        return;
      }
      setChecking((c) => c.filter((x) => x !== d.id));
      if (res.kind !== "ok") {
        if (onSessionFailure(res)) {
          return;
        }
        if (res.kind === "not_found") {
          if (isCurrent(mine)) {
            convergeNotFound();
          }
          return;
        }
        say(failureText(res.kind));
        return;
      }
      const fresh = res.data.destination;
      if (isCurrent(mine)) {
        if (!fresh.stale) {
          focusAfter.current = () => focusSel(testSel(fresh.id));
        }
        setPhone(res.data.phone);
        setDests((all) => (all === null ? all : all.map((x) => (x.id === fresh.id ? fresh : x))));
        flushReissue();
      }
      say(fresh.stale ? stillStale(fresh.label) : deliverable(fresh.label));
    } finally {
      checkIds.current.delete(d.id);
      converge(mine);
      flushReissue();
    }
  }

  async function onRemove(c: { id: number; label: string }) {
    if (removeIds.current.has(c.id)) {
      return;
    }
    removeIds.current.add(c.id);
    let mine = -1;
    try {
      mine = begin();
      setConfirmBusy(true);
      const res = await deleteDestination(c.id);
      if (!alive.current) {
        return;
      }
      setConfirmBusy(false);
      putConfirm(null);
      if (res.kind === "ok") {
        say(removed(c.label));
        if (isCurrent(mine)) {
          setPhone(res.data.phone);
          setDests((d) => (d === null ? d : d.filter((x) => x.id !== c.id)));
          setTestText("");
          focusHeading();
          flushReissue();
        }
        return;
      }
      if (onSessionFailure(res)) {
        return;
      }
      if (res.kind === "not_found") {
        if (isCurrent(mine)) {
          convergeNotFound();
        }
        return;
      }
      say(`Couldn't remove ${c.label}. ${failureText(res.kind)}`);
      if (isCurrent(mine)) {
        focusSel(removeSel(c.id));
      }
    } finally {
      removeIds.current.delete(c.id);
      converge(mine);
      flushReissue();
    }
  }

  async function onAdd(e: FormEvent) {
    e.preventDefault();
    if (addRef.current || locked) {
      return;
    }
    const l = label.trim();
    const u = url.trim();
    const le = l === "" ? failureText("invalid_label") : "";
    const ue = u === "" ? failureText("invalid_url") : "";
    setLabelErr(le);
    setUrlErr(ue);
    if (le !== "" || ue !== "") {
      focusSel(le !== "" ? LABEL_FIELD : URL_FIELD);
      say(le !== "" ? le : ue);
      return;
    }
    addRef.current = true;
    let mine = -1;
    try {
      mine = begin();
      setAdding(true);
      const res = await postDestination({ kind, label: l, url: u });
      if (res.kind === "ok" && res.data.signing_secret !== null) {
        const created = res.data.destination;
        noticeOverride.current = `Added ${created.label}. Signing secret shown below, copy it now.`;
        addSecret(
          {
            key: `webhook:${created.id}`,
            kind: "webhook",
            title: `Signing secret for webhook: ${created.label}`,
            value: res.data.signing_secret,
            setupUrl: null,
          },
          () => focusSel(ADD_TRIGGER),
        );
      }
      if (!alive.current) {
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
          focusSel(LABEL_FIELD);
        } else if (res.kind === "invalid_url" || res.kind === "url_not_public") {
          setUrlErr(text);
          focusSel(URL_FIELD);
        }
        say(text);
        return;
      }
      const created = res.data.destination;
      setLabel("");
      setUrl("");
      setLabelErr("");
      setUrlErr("");
      if (isCurrent(mine)) {
        setPhone(res.data.phone);
        setDests((d) => (d?.some((x) => x.id === created.id) === true ? d : [...(d ?? []), created]));
        flushReissue();
      }
      say(added(created.label));
    } finally {
      addRef.current = false;
      converge(mine);
      flushReissue();
    }
  }

  const setupHref = setupUrl === null ? null : safeHref(setupUrl);
  const testDisabled = testing !== null || locked;

  return (
    <>
      <p className="sr-only" role="status" aria-live="polite" data-testid="secret-notice">
        {notice}
      </p>
      {secrets.map((s) => (
        <SecretPanel
          key={`${s.key}#${s.seq}`}
          secret={s}
          h2Ref={(el) => {
            if (el === null) {
              headings.current.delete(s.key);
            } else {
              headings.current.set(s.key, el);
            }
          }}
          onAck={() => ackSecret(s.key)}
        />
      ))}
      {!pageDown && (
        <section aria-labelledby="phone-h">
          <h2 id="phone-h" tabIndex={-1} ref={headingRef}>
            Phone notifications
          </h2>
          <p className="desc">
            Get notifications from this app on your phone with ntfy, or send them to a Discord or webhook address.
          </p>
          <ul className="items dests" aria-label="Notification destinations">
            <li>
              <div className="pinfo">
                <strong>Phone (ntfy)</strong>
                <div className="meta">{phone === null ? "Status unknown" : phone.ntfy ? "Set up" : "Not set up yet"}</div>
              </div>
              <div className="actions">
                {phone?.ntfy === true && (
                  <button
                    className="secondary"
                    type="button"
                    data-trigger="ntfy-test"
                    aria-disabled={testDisabled ? "true" : undefined}
                    aria-label={testing === "ntfy" ? "Sending…: your phone" : "Send test to your phone"}
                    onClick={() => void onTest("ntfy")}
                  >
                    {testing === "ntfy" ? "Sending…" : "Send test"}
                  </button>
                )}
                <button
                  className="secondary"
                  type="button"
                  data-trigger="ntfy-setup"
                  aria-disabled={ntfyBusy || locked ? "true" : undefined}
                  aria-expanded={phone?.ntfy === true ? showSetup : undefined}
                  aria-controls={showSetup ? "ntfy-setup" : undefined}
                  onClick={onNtfyButton}
                >
                  {phone?.ntfy !== true ? "Set up phone" : showSetup ? "Hide setup" : "Show setup again"}
                </button>
              </div>
              {showSetup && (
                <div className="ntfysetup" id="ntfy-setup" role="group" aria-labelledby="pw-h">
                  <h3 id="pw-h" tabIndex={-1} ref={setupH}>
                    Phone notifications are set up
                  </h3>
                  <p>Install the ntfy app, then follow the setup page to subscribe.</p>
                  <p className="hint">
                    Your password was shown once when you set this up. If you lost it, generate a new one.
                  </p>
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
                  <strong>{d.label}</strong>
                  <div className="meta">
                    {d.kind} · {d.hint}
                    {d.stale ? " · stale, not used" : ""}
                  </div>
                </div>
                <div className="actions">
                  {d.stale ? (
                    <button
                      className="secondary"
                      type="button"
                      data-check={d.id}
                      aria-disabled={checking.includes(d.id) || locked ? "true" : undefined}
                      aria-label={`${checking.includes(d.id) ? "Checking…" : "Check again"}: ${d.label}`}
                      onClick={() => void onCheck(d)}
                    >
                      {checking.includes(d.id) ? "Checking…" : "Check again"}
                    </button>
                  ) : (
                    <button
                      className="secondary"
                      type="button"
                      data-test={d.id}
                      aria-disabled={testDisabled ? "true" : undefined}
                      aria-label={testing === String(d.id) ? `Sending…: ${d.label}` : `Send test to ${d.label}`}
                      onClick={() => void onTest(d)}
                    >
                      {testing === String(d.id) ? "Sending…" : "Send test"}
                    </button>
                  )}
                  <button
                    className="secondary"
                    type="button"
                    data-remove={d.id}
                    aria-disabled={locked ? "true" : undefined}
                    aria-label={`Remove destination ${d.label}`}
                    onClick={() => {
                      if (!locked) {
                        openConfirm({ k: "remove", id: d.id, label: d.label });
                      }
                    }}
                  >
                    Remove
                  </button>
                </div>
              </li>
            ))}
            <li>
              <form className="destform" noValidate onSubmit={(e) => void onAdd(e)}>
                <h3 id="dest-add-h">Add a destination</h3>
                <div className="fields" role="group" aria-labelledby="dest-add-h">
                  <div className="field">
                    <label htmlFor="dest-kind">Type</label>
                    <select
                      id="dest-kind"
                      disabled={locked}
                      value={kind}
                      onChange={(e) => setKind(e.target.value === "webhook" ? "webhook" : "discord")}
                    >
                      <option value="discord">{KIND_LABEL.discord}</option>
                      <option value="webhook">{KIND_LABEL.webhook}</option>
                    </select>
                  </div>
                  <div className="field">
                    <label htmlFor="dest-label">Label</label>
                    <input
                      id="dest-label"
                      type="text"
                      maxLength={50}
                      autoComplete="off"
                      disabled={locked}
                      value={label}
                      aria-invalid={labelErr !== "" ? true : undefined}
                      aria-describedby="dest-label-err"
                      onChange={(e) => {
                        setLabel(e.target.value);
                        setLabelErr("");
                      }}
                    />
                    <p className="fielderr" id="dest-label-err">
                      {labelErr}
                    </p>
                  </div>
                  <div className="field">
                    <label htmlFor="dest-url">Address</label>
                    <input
                      id="dest-url"
                      type="url"
                      autoComplete="off"
                      disabled={locked}
                      value={url}
                      aria-invalid={urlErr !== "" ? true : undefined}
                      aria-describedby={urlErr !== "" ? "dest-url-err dest-url-hint" : "dest-url-hint"}
                      onChange={(e) => {
                        setUrl(e.target.value);
                        setUrlErr("");
                      }}
                    />
                    <p className="hint" id="dest-url-hint">
                      {KIND_HINT[kind]}
                    </p>
                    <p className="fielderr" id="dest-url-err">
                      {urlErr}
                    </p>
                  </div>
                </div>
                <button
                  className="secondary"
                  type="submit"
                  data-trigger="add-destination"
                  aria-label="Add destination"
                  aria-disabled={adding || locked ? "true" : undefined}
                >
                  Add
                </button>
              </form>
            </li>
          </ul>
          <p
            className={testText === "" ? "status" : testOk ? "status ok" : "status err"}
            role="status"
            aria-live="polite"
            data-testid="test-status"
          >
            {testText}
          </p>
          <p className="status" role="status" aria-live="polite" data-testid="destinations-status">
            {status}
          </p>
          {dests === null && !needRetry && refreshing && <p className="loading">Loading destinations…</p>}
          {needRetry && (
            <div className="row">
              <p className="status err" role="status" data-testid="phone-error">
                {listErr !== "" ? listErr : MSG_PHONE_UNKNOWN}
              </p>
              <button
                className="secondary"
                type="button"
                aria-disabled={refreshing ? "true" : undefined}
                onClick={() => {
                  if (!refreshing) {
                    void refresh({ withMe: true, focus: focusHeading });
                  }
                }}
              >
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
        </section>
      )}
    </>
  );
}
