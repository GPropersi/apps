import { describe, expect, it } from "vitest";
import { failureText } from "./messages";

describe("failureText", () => {
  it.each([
    ["too_many_shares", "This birthday is already shared with 20 people."],
    ["not_owner", "Only the person who added this birthday can change it."],
    ["invalid_url", "That address doesn't look right. Check it and try again."],
    ["url_not_public", "That address isn't reachable from the internet."],
    ["notify_unavailable", "Reminders are unavailable right now. Try again in a minute."],
    ["rate_limited", "Too many tries. Wait a minute and try again."],
    ["ntfy_not_set_up", "Phone notifications aren't set up yet."],
    [
      "destination_stale",
      "That destination didn't accept the test, so it's marked stale. Check the address, then tap Check again.",
    ],
    ["invalid_offsets", "Pick at least one reminder time."],
  ] as const)("has the copy for %s", (kind, text) => {
    expect(failureText(kind)).toBe(text);
  });
});
