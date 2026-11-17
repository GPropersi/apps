import { useEffect, useRef, useState } from "react";
import { announce, safeHref } from "./util";

// A one-time secret waiting to be acknowledged. It lives only in app state (never localStorage, sessionStorage or a
// log): the server shows it once and never again.
export type Secret = {
  key: string; // "ntfy" or "webhook:<destination id>"
  seq: number; // bumps whenever the entry is added or replaced, so a replacement takes focus again
  kind: "ntfy" | "webhook";
  title: string;
  value: string;
  setupUrl: string | null;
};

export type NewSecret = Omit<Secret, "seq">;

const COPIED = "Copied";
const COPY_FAILED = "Couldn't copy. Select the text and copy it yourself.";

function SecretPanel({
  secret,
  h2Ref,
  onAck,
}: {
  secret: Secret;
  h2Ref: (el: HTMLHeadingElement | null) => void;
  onAck: () => void;
}) {
  const [copyStatus, setCopyStatus] = useState("");
  const id = `secret-${secret.seq}`;
  const href = secret.setupUrl === null ? null : safeHref(secret.setupUrl);

  async function copy() {
    try {
      await navigator.clipboard.writeText(secret.value);
      announce(setCopyStatus, COPIED);
    } catch {
      announce(setCopyStatus, COPY_FAILED);
    }
  }

  return (
    <section aria-labelledby={`${id}-h`} data-secret={secret.key}>
      <h2 id={`${id}-h`} tabIndex={-1} ref={h2Ref}>
        {secret.title}
      </h2>
      <p>
        {secret.kind === "ntfy"
          ? "Install the ntfy app, then follow the setup page to subscribe."
          : "Your webhook receiver uses this to check that messages really come from us."}
      </p>
      <p>
        <span className="meta">{secret.kind === "ntfy" ? "Password" : "Signing secret"}</span>
        <br />
        <strong className="secretval" data-testid={`${id}-value`}>
          {secret.value}
        </strong>
      </p>
      <p className="hint">
        {secret.kind === "ntfy"
          ? "Shown only once. It replaces any earlier password for this person. Copy it before you leave this page."
          : "Shown only once and never stored by this app. Copy it before you leave this page."}
      </p>
      <p className="hint">
        {secret.kind === "ntfy"
          ? "Lost it? Generate a new password in Settings."
          : "Lost it? Remove this destination and add it again."}
      </p>
      <div className="row">
        {href !== null && (
          <a className="signout" href={href} target="_blank" rel="noopener noreferrer">
            Open the setup page
          </a>
        )}
        <button className="secondary" type="button" onClick={() => void copy()}>
          Copy
        </button>
        <button className="primary" type="button" onClick={onAck}>
          I've saved it
        </button>
      </div>
      <p className="status" role="status">
        {copyStatus}
      </p>
    </section>
  );
}

// One panel per pending secret, oldest first, in the app shell above every screen. A new or replaced entry takes focus
// on its h2 (the newest, when several arrive together) and is announced.
export function SecretPanels({ secrets, onAck }: { secrets: Secret[]; onAck: (key: string) => void }) {
  const [notice, setNotice] = useState("");
  const headings = useRef(new Map<string, HTMLHeadingElement>());
  const seen = useRef(0);

  useEffect(() => {
    const fresh = secrets.filter((s) => s.seq > seen.current);
    if (fresh.length === 0) {
      return;
    }
    const newest = fresh.reduce((a, b) => (b.seq > a.seq ? b : a));
    seen.current = newest.seq;
    headings.current.get(newest.key)?.focus();
    announce(setNotice, `${newest.title}. Copy it before you leave this page.`);
  }, [secrets]);

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
          onAck={() => onAck(s.key)}
        />
      ))}
    </>
  );
}
