import type { Dispatch, SetStateAction } from "react";
import { flushSync } from "react-dom";
import type { Failure } from "./api";

export const MSG_UNAVAILABLE = "Can't reach the app right now. Try again in a minute.";
export const MSG_GENERIC = "Something went wrong on our side. Try again in a minute.";
export const MSG_BUSY = "Too many background tasks are waiting. Try again in a few minutes.";

// Clear, then set, so a repeated identical message is announced again by a screen reader.
export function announce(set: Dispatch<SetStateAction<string>>, message: string): void {
  flushSync(() => set(""));
  set(message);
}

// One user-facing message per server code. The code itself is never shown.
const BY_KIND: Partial<Record<Failure["kind"], string>> = {
  unavailable: MSG_UNAVAILABLE,
  busy: MSG_BUSY,
  generic: MSG_GENERIC,
  session_expired: "Your sign-in has expired. Reload the page to sign in again.",
  unauthenticated: "We couldn't confirm your sign-in. Reload the page to try again.",
  rate_limited: "Too many tries. Wait a minute and try again.",
  notify_unavailable: "Notifications are unavailable right now. Try again in a minute.",
  ntfy_not_set_up: "Phone notifications aren't set up yet.",
  destination_stale:
    "That destination didn't accept the test, so it's marked stale. Check the address, then tap Check again.",
  invalid_url: "That address doesn't look right. Check it and try again.",
  invalid_label: "Enter a label of up to 50 characters.",
  url_not_public: "That address isn't reachable from the internet.",
  too_many_destinations: "You have reached the limit of 10 notification destinations.",
  not_found: "That destination isn't available any more.",
};

export function failureText(kind: Failure["kind"]): string {
  return BY_KIND[kind] ?? MSG_GENERIC;
}

export const MSG_NTFY_SETUP_HINT = " Tap Show setup again to finish phone setup.";
export const MSG_PHONE_UNKNOWN = "Phone status is unavailable right now. Try again in a minute.";
export const MSG_TEST_SENT_PHONE = "Test sent to your phone. It can take a few seconds to arrive.";
export const MSG_SENDING = "Sending test…";
export const testSentTo = (label: string) => `Test sent to ${label}. It can take a few seconds to arrive.`;
export const added = (label: string) => `Added ${label}`;
export const removed = (label: string) => `Removed ${label}`;
export const deliverable = (label: string) => `${label} is deliverable again`;
export const stillStale = (label: string) => `${label} still can't be reached`;
