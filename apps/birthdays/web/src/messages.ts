import type { Failure } from "./api";

export const MSG_UNAVAILABLE = "Can't reach the app right now. Try again in a minute.";
export const MSG_GENERIC = "Something went wrong on our side. Try again in a minute.";

// One user-facing message per server code (later steps reuse this table). Codes a screen handles inline (a field
// error next to its input) still have copy here for the places that show them as a general message.
const BY_KIND: Record<Failure["kind"], string> = {
  unavailable: MSG_UNAVAILABLE,
  session_expired: "Your sign-in has expired. Reload the page to sign in again.",
  unauthenticated: "We couldn't confirm your sign-in. Reload the page to try again.",
  generic: MSG_GENERIC,
  invalid_name: "Enter a name of up to 100 characters.",
  invalid_date: "That date doesn't exist. Check the month and day.",
  invalid_year: "Enter a year from 1900 to 2200, or leave it empty.",
  invalid_offsets: "Pick at least one reminder time.",
  invalid_setting: "That setting isn't valid.",
  invalid_email: "Enter a valid email address.",
  invalid_text: "Write something first (up to 200 characters).",
  invalid_url: "That address doesn't look right. Check it and try again.",
  invalid_label: "Enter a label of up to 50 characters.",
  url_not_public: "That address isn't reachable from the internet.",
  self_share: "You already have this birthday.",
  empty: "Nothing to save.",
  not_owner: "Only the person who added this birthday can change it.",
  not_found: "That birthday isn't available any more.",
  too_many_birthdays: "You have reached the limit of 500 birthdays. Remove one to add another.",
  too_many_shares: "This birthday is already shared with 20 people.",
  too_many_gifts: "You have reached the limit of 50 gift ideas on this birthday.",
  too_many_destinations: "You have reached the limit of 10 reminder destinations.",
  ntfy_not_set_up: "Phone notifications aren't set up yet.",
  rate_limited: "Too many tries. Wait a minute and try again.",
  notify_unavailable: "Reminders are unavailable right now. Try again in a minute.",
};

export function failureText(kind: Failure["kind"]): string {
  return BY_KIND[kind];
}

export const RELOAD_WITH_DRAFT = "Reload to sign in again. Your birthday details are still here.";
export const RELOAD_PLAIN = "Reload to sign in again.";
