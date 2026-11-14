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

export type Failure =
  | { kind: "unavailable" }
  | { kind: "session_expired" }
  | { kind: "unauthenticated" }
  | { kind: "invalid_text" }
  | { kind: "busy" }
  | { kind: "generic" };

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

export const validateMe: Validate<{ email: string }> = (b) =>
  isRecord(b) && typeof b.email === "string" && b.email !== "" ? { email: b.email } : null;

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
  if (res.status === 429 && code === "queue_full") {
    return { kind: "busy" };
  }

  // 5. Every other JSON error. The code is never shown.
  return GENERIC;
}

const JSON_HEADERS = { "Content-Type": "application/json" };

export function getMe(): Promise<ApiResult<{ email: string }>> {
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
