// Typed API client. Every response lands on exactly one ApiResult. The edge (Traefik errors middleware, Cloudflare
// Access) can answer with HTML for 502-504, 5xx and expired sessions, so the Content-Type is checked before any body
// is read, and nothing here ever rejects.

export type Item = {
  id: number;
  text: string;
  created_by: string;
  source: string;
  created_at: string;
};

// Server error codes the phone-notifications section shows by name (the code itself is never displayed).
const NOTIFY_CODES = [
  "rate_limited",
  "ntfy_not_set_up",
  "notify_unavailable",
  "destination_stale",
  "not_found",
  "too_many_destinations",
  "invalid_label",
  "invalid_url",
  "url_not_public",
] as const;
export type NotifyCode = (typeof NOTIFY_CODES)[number];

export type Failure =
  | { kind: "unavailable" }
  | { kind: "session_expired" }
  | { kind: "unauthenticated" }
  | { kind: "invalid_text" }
  | { kind: "busy" }
  | { kind: "generic" }
  | { kind: NotifyCode };

// Phone state counters from /api/me and every notify write route.
export type Phone = { ntfy: boolean; destinations: number; stale_destinations: number };
export type Me = { email: string; notifs: boolean; phone: Phone | null };
export type Destination = { id: number; kind: "discord" | "webhook"; label: string; hint: string; stale: boolean };

export type ApiResult<T> = { kind: "ok"; data: T } | Failure;

type Validate<T> = (body: unknown) => T | null;

const UNAVAILABLE: Failure = { kind: "unavailable" };
const GENERIC: Failure = { kind: "generic" };

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function isItem(v: unknown): v is Item {
  return (
    isRecord(v) &&
    typeof v.id === "number" &&
    typeof v.text === "string" &&
    typeof v.created_by === "string" &&
    typeof v.source === "string" &&
    typeof v.created_at === "string"
  );
}

function isPhone(v: unknown): v is Phone {
  return (
    isRecord(v) &&
    typeof v.ntfy === "boolean" &&
    typeof v.destinations === "number" &&
    typeof v.stale_destinations === "number"
  );
}

// A write response without a usable phone is still valid: it means "phone unknown", so a one-time secret in the same
// body is never thrown away by validation.
function phoneOf(b: Record<string, unknown>): Phone | null {
  const p = b.phone;
  return isPhone(p) ? { ntfy: p.ntfy, destinations: p.destinations, stale_destinations: p.stale_destinations } : null;
}

function isDestination(v: unknown): v is Destination {
  return (
    isRecord(v) &&
    typeof v.id === "number" &&
    (v.kind === "discord" || v.kind === "webhook") &&
    typeof v.label === "string" &&
    typeof v.hint === "string" &&
    typeof v.stale === "boolean"
  );
}

// Missing or non-true `notifs` is false (fail closed); `phone` only counts when notifs is true.
export const validateMe: Validate<Me> = (b) => {
  if (!isRecord(b) || typeof b.email !== "string" || b.email === "") {
    return null;
  }
  const notifs = b.notifs === true;
  return { email: b.email, notifs, phone: notifs ? phoneOf(b) : null };
};

export type NtfyResult = { setup_url: string; password: string | null; phone: Phone | null };
export const validateNtfy: Validate<NtfyResult> = (b) => {
  if (!isRecord(b) || typeof b.setup_url !== "string" || (b.password != null && (typeof b.password !== "string" || b.password === ""))) {
    return null;
  }
  return { setup_url: b.setup_url, password: (b.password as string | null | undefined) ?? null, phone: phoneOf(b) };
};

export type NtfyReset = { password: string; setup_url: string; phone: Phone | null };
export const validateNtfyReset: Validate<NtfyReset> = (b) =>
  isRecord(b) && typeof b.password === "string" && b.password !== "" && typeof b.setup_url === "string"
    ? { password: b.password, setup_url: b.setup_url, phone: phoneOf(b) }
    : null;

export const validatePhoneOnly: Validate<{ phone: Phone | null }> = (b) => (isRecord(b) ? { phone: phoneOf(b) } : null);

export const validateDestinations: Validate<Destination[]> = (b) =>
  isRecord(b) && Array.isArray(b.destinations) && b.destinations.every(isDestination)
    ? (b.destinations as Destination[])
    : null;

export type DestinationCreated = { destination: Destination; signing_secret: string | null; phone: Phone | null };
export const validateDestinationCreated: Validate<DestinationCreated> = (b) => {
  if (!isRecord(b) || !isDestination(b.destination) || (b.signing_secret != null && (typeof b.signing_secret !== "string" || b.signing_secret === ""))) {
    return null;
  }
  return {
    destination: b.destination,
    signing_secret: (b.signing_secret as string | null | undefined) ?? null,
    phone: phoneOf(b),
  };
};

export type DestinationChecked = { destination: Destination; phone: Phone | null };
export const validateDestinationChecked: Validate<DestinationChecked> = (b) =>
  isRecord(b) && isDestination(b.destination) ? { destination: b.destination, phone: phoneOf(b) } : null;

export const validateItems: Validate<Item[]> = (b) =>
  isRecord(b) && Array.isArray(b.items) && b.items.every(isItem) ? (b.items as Item[]) : null;

export const validateItem: Validate<Item> = (b) => (isItem(b) ? b : null);

export const validateTask: Validate<{ id: string }> = (b) =>
  isRecord(b) && typeof b.id === "string" ? { id: b.id } : null;

function isJSON(res: Response): boolean {
  return (res.headers.get("Content-Type") ?? "").toLowerCase().startsWith("application/json");
}

async function request<T>(path: string, init: RequestInit, validate: Validate<T>): Promise<ApiResult<T>> {
  let res: Response;
  try {
    res = await fetch(path, { ...init, credentials: "same-origin", redirect: "manual" });
  } catch {
    return UNAVAILABLE; // network TypeError (or anything else fetch throws)
  }

  // 1. The edge's down page replaces 502-504 whatever the body.
  if (res.status === 502 || res.status === 503 || res.status === 504) {
    return UNAVAILABLE;
  }

  // 2. Non-JSON body.
  if (!isJSON(res)) {
    if (res.type === "opaqueredirect" || res.status === 401 || res.status === 403 || res.status === 200) {
      return { kind: "session_expired" };
    }
    return res.status >= 500 ? UNAVAILABLE : GENERIC;
  }

  // 6. A JSON Content-Type whose body does not parse maps by status.
  let body: unknown;
  try {
    body = await res.json();
  } catch {
    return res.status >= 500 ? UNAVAILABLE : GENERIC;
  }

  const code = isRecord(body) && typeof body.error === "string" ? body.error : "";

  // 3. JSON 401 unauthenticated.
  if (res.status === 401 && code === "unauthenticated") {
    return { kind: "unauthenticated" };
  }

  // 4. OK payload, field error, queue full.
  if (res.ok) {
    const data = validate(body);
    return data === null ? (res.status >= 500 ? UNAVAILABLE : GENERIC) : { kind: "ok", data };
  }
  if (code === "invalid_text") {
    return { kind: "invalid_text" };
  }
  const notify = NOTIFY_CODES.find((c) => c === code);
  if (notify !== undefined) {
    return { kind: notify };
  }
  if (res.status === 429 && code === "queue_full") {
    return { kind: "busy" };
  }

  // 5. Every other JSON error. The code is never shown.
  return GENERIC;
}

const JSON_HEADERS = { "Content-Type": "application/json" };

export function getMe(): Promise<ApiResult<Me>> {
  return request("/api/me", { method: "GET" }, validateMe);
}

export function getItems(): Promise<ApiResult<Item[]>> {
  return request("/api/items", { method: "GET" }, validateItems);
}

export function postItem(text: string): Promise<ApiResult<Item>> {
  return request("/api/items", { method: "POST", headers: JSON_HEADERS, body: JSON.stringify({ text }) }, validateItem);
}

export function postTask(): Promise<ApiResult<{ id: string }>> {
  return request("/api/tasks", { method: "POST", headers: JSON_HEADERS, body: "{}" }, validateTask);
}

// Every write route (POST and DELETE) goes through the server's stateChanging wrapper, which answers 415 unless the
// request is JSON, so each write sends a JSON Content-Type and a body.
function write<T>(method: "POST" | "DELETE", path: string, body: unknown, validate: Validate<T>): Promise<ApiResult<T>> {
  return request(path, { method, headers: JSON_HEADERS, body: JSON.stringify(body) }, validate);
}

export function postNtfy(): Promise<ApiResult<NtfyResult>> {
  return write("POST", "/api/notify/ntfy", {}, validateNtfy);
}

export function postNtfyReset(): Promise<ApiResult<NtfyReset>> {
  return write("POST", "/api/notify/ntfy/reset", {}, validateNtfyReset);
}

export function postNtfyTest(): Promise<ApiResult<{ phone: Phone | null }>> {
  return write("POST", "/api/notify/ntfy/test", {}, validatePhoneOnly);
}

export function getDestinations(): Promise<ApiResult<Destination[]>> {
  return request("/api/notify/destinations", { method: "GET" }, validateDestinations);
}

export function postDestination(d: {
  kind: "discord" | "webhook";
  label: string;
  url: string;
}): Promise<ApiResult<DestinationCreated>> {
  return write("POST", "/api/notify/destinations", d, validateDestinationCreated);
}

export function checkDestination(id: number): Promise<ApiResult<DestinationChecked>> {
  return write("POST", `/api/notify/destinations/${id}/check`, {}, validateDestinationChecked);
}

export function postDestinationTest(id: number): Promise<ApiResult<{ phone: Phone | null }>> {
  return write("POST", `/api/notify/destinations/${id}/test`, {}, validatePhoneOnly);
}

export function deleteDestination(id: number): Promise<ApiResult<{ phone: Phone | null }>> {
  return write("DELETE", `/api/notify/destinations/${id}`, {}, validatePhoneOnly);
}
