import { useEffect, useRef, useState } from "react";
import type { KeyboardEvent } from "react";
import { announce } from "./messages";

// Only http(s) links are ever rendered from a server-provided URL.
export function safeHref(url: string): string | null {
  try {
    const u = new URL(url);
    return u.protocol === "https:" || u.protocol === "http:" ? u.href : null;
  } catch {
    return null;
  }
}

// A one-time secret waiting to be acknowledged. It lives only in component state (never localStorage, sessionStorage
// or a log): the server shows it once and never again.
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

export function SecretPanel({
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
    <section aria-labelledby={`${id}-h`} className="secret" data-secret={secret.key}>
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
          ? "Lost it? Use Generate a new password in the Phone notifications section."
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

// An inline confirm. It focuses Cancel when it mounts (so a stray Enter cancels) and Escape cancels. The owner keeps
// one confirm state, so mounting a new prompt replaces the old one; give each prompt a distinct `key` so focus follows.
export function ConfirmPrompt({
  question,
  note,
  confirmLabel,
  busy,
  onConfirm,
  onCancel,
}: {
  question: string;
  note?: string;
  confirmLabel: string;
  busy: boolean;
  onConfirm: () => void;
  onCancel: () => void;
}) {
  const cancelRef = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    cancelRef.current?.focus();
  }, []);
  return (
    <div
      className="alert confirm"
      role="group"
      aria-label={question}
      onKeyDown={(e: KeyboardEvent<HTMLDivElement>) => {
        if (e.key === "Escape") {
          e.stopPropagation();
          onCancel();
        }
      }}
    >
      <strong>{question}</strong>
      {note !== undefined && <span>{note}</span>}
      <div className="row">
        <button className="secondary" type="button" ref={cancelRef} onClick={onCancel}>
          Cancel
        </button>
        <button className="danger" type="button" aria-disabled={busy ? "true" : undefined} onClick={onConfirm}>
          {confirmLabel}
        </button>
      </div>
    </div>
  );
}
