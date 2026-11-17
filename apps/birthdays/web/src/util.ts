import type { Dispatch, SetStateAction } from "react";
import { flushSync } from "react-dom";

// Only http(s) links are rendered as links; anything else would be a javascript: or data: URL.
export function safeHref(url: string): string | null {
  try {
    const u = new URL(url);
    return u.protocol === "https:" || u.protocol === "http:" ? u.href : null;
  } catch {
    return null;
  }
}

// Clear, then set, so a repeated identical message is announced again by a screen reader.
export function announce(set: Dispatch<SetStateAction<string>>, message: string): void {
  flushSync(() => set(""));
  set(message);
}
