import { useEffect, useRef } from "react";
import type { KeyboardEvent, MouseEvent } from "react";
import { initials, tintIndex } from "./colors";
import { chipClass, metaText, whenText } from "./format";
import type { Dated } from "./format";
import type { Origin } from "./route";

export type OpenDetail = (e: MouseEvent<HTMLAnchorElement>, id: number, origin: Origin) => void;

export function Avatar({ name, big }: { name: string; big?: boolean }) {
  return (
    <span className={`avatar tint${tintIndex(name)}${big ? " big" : ""}`} aria-hidden="true">
      {initials(name)}
    </span>
  );
}

export function Chip({ days }: { days: number }) {
  return <span className={chipClass(days)}>{whenText(days)}</span>;
}

export function Bell() {
  return (
    <>
      <svg
        className="bell"
        viewBox="0 0 24 24"
        fill="none"
        stroke="currentColor"
        strokeWidth="2.2"
        strokeLinecap="round"
        aria-hidden="true"
      >
        <path d="M6 16V11a6 6 0 0 1 12 0v5l1.5 2h-15L6 16ZM10 21h4" />
      </svg>
      <span className="sr-only">Reminders on</span>
    </>
  );
}

export function Chevron() {
  return (
    <span className="chev" aria-hidden="true">
      &rsaquo;
    </span>
  );
}

// A birthday row: tinted avatar, the name as a real link (its ::after stretches over the whole row), meta line, bell and
// days-until chip. `origin` records which tab the detail was opened from.
export function BirthdayRow({
  d,
  origin,
  open,
  showChip = true,
}: {
  d: Dated;
  origin: Origin;
  open: OpenDetail;
  showChip?: boolean;
}) {
  return (
    <li>
      <Avatar name={d.b.name} />
      <div className="pinfo">
        <a className="link" href={`#/b/${d.b.id}`} data-bid={d.b.id} onClick={(e) => open(e, d.b.id, origin)}>
          {d.b.name}
        </a>
        <div className="meta">{metaText(d)}</div>
      </div>
      {d.b.reminder_offsets.length > 0 && <Bell />}
      {showChip && <Chip days={d.days} />}
      <Chevron />
    </li>
  );
}

export function CakeMark() {
  return (
    <svg viewBox="0 0 32 32" fill="none" aria-hidden="true">
      <path d="M5 26h22v-8a3 3 0 0 0-3-3H8a3 3 0 0 0-3 3v8Z" fill="currentColor" opacity=".18" />
      <path
        d="M5 26h22M5 26v-8a3 3 0 0 1 3-3h16a3 3 0 0 1 3 3v8M5 20c2 1.5 4 1.5 5.5 0s3.5-1.5 5.5 0 3.5 1.5 5.5 0 3.5-1.5 5.5 0M11 15v-4M16 15v-4M21 15v-4"
        stroke="currentColor"
        strokeWidth="2"
        strokeLinecap="round"
      />
      <path
        d="M11 8.5c-.8-.8-.8-2 0-3 .8 1 .8 2.2 0 3ZM16 8.5c-.8-.8-.8-2 0-3 .8 1 .8 2.2 0 3ZM21 8.5c-.8-.8-.8-2 0-3 .8 1 .8 2.2 0 3Z"
        fill="currentColor"
      />
    </svg>
  );
}

const ICON_PROPS = {
  viewBox: "0 0 24 24",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 2.2,
  strokeLinecap: "round" as const,
  "aria-hidden": true,
};

export function TabIcon({ tab }: { tab: "add" | "birthdays" | "settings" }) {
  if (tab === "add") {
    return (
      <svg {...ICON_PROPS}>
        <circle cx="12" cy="12" r="9" />
        <path d="M12 8v8M8 12h8" />
      </svg>
    );
  }
  if (tab === "birthdays") {
    return (
      <svg {...ICON_PROPS}>
        <rect x="3" y="5" width="18" height="16" rx="3" />
        <path d="M3 10h18M8 3v4M16 3v4" />
      </svg>
    );
  }
  return (
    <svg {...ICON_PROPS}>
      <path d="M4 7h10M18 7h2M4 17h4M12 17h8" />
      <circle cx="16" cy="7" r="2" />
      <circle cx="10" cy="17" r="2" />
    </svg>
  );
}

// The in-page confirm for a destructive action (Delete, Remove from my list, Stop sharing; Step 11 reuses it). It
// focuses Cancel when it mounts (so a stray Enter cancels) and Escape cancels. The owner keeps one confirm state, so
// mounting a new prompt replaces the old one; give each prompt a distinct `key` so focus follows the new Cancel.
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
        <button className="danger" type="button" disabled={busy} onClick={onConfirm}>
          {confirmLabel}
        </button>
      </div>
    </div>
  );
}

// The notice for a reminder with nowhere to go, with a link to Settings.
export function DestinationNotice({ kind }: { kind: "none" | "stale" }) {
  return (
    <p className="hint notice">
      {kind === "stale"
        ? "Your reminder destinations stopped working, so reminders can't be sent. "
        : "Reminders have nowhere to go yet. "}
      <a href="#/settings">{kind === "stale" ? "Check Settings" : "Set up a place to send them in Settings"}</a>.
    </p>
  );
}
