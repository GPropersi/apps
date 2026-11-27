// Typed API client. Every response lands on exactly one ApiResult. The edge (Traefik errors middleware, Cloudflare
// Access) can answer with HTML for 502-504, 5xx and expired sessions, so the Content-Type is checked before any body
// is read, and nothing here ever rejects.

export const START_TABS = ["auto", "add", "view"] as const;
export const LIST_VIEWS = ["upcoming", "month", "name", "calendar"] as const;
export const CALENDAR_ZOOMS = ["year", "month", "week"] as const;
export const COLOR_SCHEMES = ["confetti", "frosting", "candle"] as const;

export type StartTab = (typeof START_TABS)[number];
export type ListView = (typeof LIST_VIEWS)[number];
export type CalendarZoom = (typeof CALENDAR_ZOOMS)[number];
export type ColorScheme = (typeof COLOR_SCHEMES)[number];

// Preference fields: the only ones PATCH /api/settings accepts.
export type Prefs = {
  auto_remind: boolean;
  default_offsets: number[];
  start_tab: StartTab;
  list_view: ListView;
  calendar_zoom: CalendarZoom;
  color_scheme: ColorScheme;
};

// Server-derived counters; only a response may change them (HTTP API merge rule).
export type Counters = { ntfy: boolean; destinations: number; stale_destinations: number };

export type Settings = Prefs & Counters;

export type Birthday = {
  id: number;
  name: string;
  month: number;
  day: number;
  year: number | null;
  is_mine: boolean;
  owner_email: string;
  reminder_offsets: number[];
};

export type Gift = { id: number; text: string; shared: boolean; author_email: string; mine: boolean };
export type Destination = { id: number; kind: "discord" | "webhook"; label: string; hint: string; stale: boolean };
export type BirthdayDetail = { birthday: Birthday; shares: string[] | null; gifts: Gift[] };

// Error codes the server returns in `{"error": code}`; each becomes a Failure of that kind.
const SERVER_CODES = [
  "invalid_name",
  "invalid_date",
  "invalid_year",
  "invalid_offsets",
  "invalid_setting",
  "invalid_email",
  "invalid_text",
  "invalid_url",
  "invalid_label",
  "url_not_public",
  "self_share",
  "empty",
  "not_owner",
  "not_found",
  "too_many_birthdays",
  "too_many_shares",
  "too_many_gifts",
  "too_many_destinations",
  "ntfy_not_set_up",
  "rate_limited",
  "notify_unavailable",
  "destination_stale",
] as const;
export type ServerCode = (typeof SERVER_CODES)[number];

export type Failure =
  | { kind: "unavailable" }
  | { kind: "session_expired" }
  | { kind: "unauthenticated" }
  | { kind: "generic" }
  | { kind: ServerCode };

export type ApiResult<T> = { kind: "ok"; data: T } | Failure;

type Validate<T> = (body: unknown) => T | null;

const UNAVAILABLE: Failure = { kind: "unavailable" };
const GENERIC: Failure = { kind: "generic" };

function isRecord(v: unknown): v is Record<string, unknown> {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}

function isIntArray(v: unknown): v is number[] {
  return Array.isArray(v) && v.every((n) => typeof n === "number" && Number.isInteger(n));
}

function oneOf<T extends string>(list: readonly T[], v: unknown, fallback: T): T {
  return typeof v === "string" && (list as readonly string[]).includes(v) ? (v as T) : fallback;
}

// An unknown enum value from the server is softened to the default (so an unknown colour scheme renders Confetti)
// rather than failing the whole load.
export function toSettings(v: unknown): Settings | null {
  if (
    !isRecord(v) ||
    typeof v.auto_remind !== "boolean" ||
    !isIntArray(v.default_offsets) ||
    typeof v.ntfy !== "boolean" ||
    typeof v.destinations !== "number" ||
    typeof v.stale_destinations !== "number"
  ) {
    return null;
  }
  return {
    auto_remind: v.auto_remind,
    default_offsets: v.default_offsets,
    start_tab: oneOf(START_TABS, v.start_tab, "auto"),
    list_view: oneOf(LIST_VIEWS, v.list_view, "upcoming"),
    calendar_zoom: oneOf(CALENDAR_ZOOMS, v.calendar_zoom, "month"),
    color_scheme: oneOf(COLOR_SCHEMES, v.color_scheme, "confetti"),
    ntfy: v.ntfy,
    destinations: v.destinations,
    stale_destinations: v.stale_destinations,
  };
}

function isBirthday(v: unknown): v is Birthday {
  return (
    isRecord(v) &&
    typeof v.id === "number" &&
    typeof v.name === "string" &&
    typeof v.month === "number" &&
    typeof v.day === "number" &&
    (v.year === null || typeof v.year === "number") &&
    typeof v.is_mine === "boolean" &&
    typeof v.owner_email === "string" &&
    isIntArray(v.reminder_offsets)
  );
}

function isGift(v: unknown): v is Gift {
  return (
    isRecord(v) &&
    typeof v.id === "number" &&
    typeof v.text === "string" &&
    typeof v.shared === "boolean" &&
    typeof v.author_email === "string" &&
    typeof v.mine === "boolean"
  );
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

export type Me = { email: string; settings: Settings };

export const validateMe: Validate<Me> = (b) => {
  if (!isRecord(b) || typeof b.email !== "string" || b.email === "") {
    return null;
  }
  const settings = toSettings(b.settings);
  return settings === null ? null : { email: b.email, settings };
};

export const validateSettings: Validate<Settings> = (b) => toSettings(b);
export const validateBirthday: Validate<Birthday> = (b) => (isBirthday(b) ? b : null);
export const validateBirthdays: Validate<Birthday[]> = (b) =>
  isRecord(b) && Array.isArray(b.birthdays) && b.birthdays.every(isBirthday) ? (b.birthdays as Birthday[]) : null;
export const validateGift: Validate<Gift> = (b) => (isGift(b) ? b : null);
export const validateDetail: Validate<BirthdayDetail> = (b) => {
  if (!isRecord(b) || !isBirthday(b.birthday) || !Array.isArray(b.gifts) || !b.gifts.every(isGift)) {
    return null;
  }
  if (
    b.shares !== undefined &&
    b.shares !== null &&
    !(Array.isArray(b.shares) && b.shares.every((e) => typeof e === "string"))
  ) {
    return null;
  }
  return { birthday: b.birthday, shares: (b.shares as string[] | undefined) ?? null, gifts: b.gifts as Gift[] };
};
export const validateOffsets: Validate<{ offsets: number[] }> = (b) =>
  isRecord(b) && isIntArray(b.offsets) ? { offsets: b.offsets } : null;
export const validateEmail: Validate<{ email: string }> = (b) =>
  isRecord(b) && typeof b.email === "string" ? { email: b.email } : null;

export type NtfyResult = { user_id: string; setup_url: string; password: string | null; settings: Settings };
export const validateNtfy: Validate<NtfyResult> = (b) => {
  if (!isRecord(b) || typeof b.user_id !== "string" || typeof b.setup_url !== "string") {
    return null;
  }
  if (b.password !== null && typeof b.password !== "string") {
    return null;
  }
  const settings = toSettings(b.settings);
  return settings === null ? null : { user_id: b.user_id, setup_url: b.setup_url, password: b.password, settings };
};

export type NtfyReset = { password: string; setup_url: string; settings: Settings };
export const validateNtfyReset: Validate<NtfyReset> = (b) => {
  if (!isRecord(b) || typeof b.password !== "string" || typeof b.setup_url !== "string") {
    return null;
  }
  const settings = toSettings(b.settings);
  return settings === null ? null : { password: b.password, setup_url: b.setup_url, settings };
};

export const validateDestinations: Validate<Destination[]> = (b) =>
  isRecord(b) && Array.isArray(b.destinations) && b.destinations.every(isDestination)
    ? (b.destinations as Destination[])
    : null;

export type DestinationCreated = { destination: Destination; signing_secret: string | null; settings: Settings };
export const validateDestinationCreated: Validate<DestinationCreated> = (b) => {
  if (!isRecord(b) || !isDestination(b.destination)) {
    return null;
  }
  if (b.signing_secret !== undefined && typeof b.signing_secret !== "string") {
    return null;
  }
  const settings = toSettings(b.settings);
  return settings === null
    ? null
    : { destination: b.destination, signing_secret: (b.signing_secret as string | undefined) ?? null, settings };
};

export type DestinationChecked = { destination: Destination; settings: Settings };
export const validateDestinationChecked: Validate<DestinationChecked> = (b) => {
  if (!isRecord(b) || !isDestination(b.destination)) {
    return null;
  }
  const settings = toSettings(b.settings);
  return settings === null ? null : { destination: b.destination, settings };
};

export const validateSettingsOnly: Validate<{ settings: Settings }> = (b) => {
  const settings = isRecord(b) ? toSettings(b.settings) : null;
  return settings === null ? null : { settings };
};

function isJSON(res: Response): boolean {
  return (res.headers.get("Content-Type") ?? "").toLowerCase().startsWith("application/json");
}

function isServerCode(code: string): code is ServerCode {
  return (SERVER_CODES as readonly string[]).includes(code);
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

  // 1b. A 204 has no body and no Content-Type: it is success, checked before the JSON Content-Type test.
  if (res.status === 204) {
    return { kind: "ok", data: undefined as T };
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

  // 4. OK payload.
  if (res.ok) {
    const data = validate(body);
    return data === null ? (res.status >= 500 ? UNAVAILABLE : GENERIC) : { kind: "ok", data };
  }

  // 5. A known field or limit error keeps its code; every other JSON error is generic. The code is never shown.
  if (isServerCode(code)) {
    return { kind: code };
  }
  return GENERIC;
}

const JSON_HEADERS = { "Content-Type": "application/json" };

function get<T>(path: string, validate: Validate<T>): Promise<ApiResult<T>> {
  return request(path, { method: "GET" }, validate);
}

function send<T>(method: string, path: string, body: unknown, validate: Validate<T>): Promise<ApiResult<T>> {
  return request(path, { method, headers: JSON_HEADERS, body: JSON.stringify(body) }, validate);
}

const NO_BODY: Validate<undefined> = () => undefined;

export function getMe(): Promise<ApiResult<Me>> {
  return get("/api/me", validateMe);
}

export function patchSettings(patch: Partial<Prefs>): Promise<ApiResult<Settings>> {
  return send("PATCH", "/api/settings", patch, validateSettings);
}

export function getBirthdays(): Promise<ApiResult<Birthday[]>> {
  return get("/api/birthdays", validateBirthdays);
}

export type NewBirthday = { name: string; month: number; day: number; year?: number; offsets: number[] };

export function postBirthday(b: NewBirthday): Promise<ApiResult<Birthday>> {
  return send("POST", "/api/birthdays", b, validateBirthday);
}

export function getBirthday(id: number): Promise<ApiResult<BirthdayDetail>> {
  return get(`/api/birthdays/${id}`, validateDetail);
}

export function putBirthday(
  id: number,
  b: { name: string; month: number; day: number; year: number | null },
): Promise<ApiResult<Birthday>> {
  return send("PUT", `/api/birthdays/${id}`, b, validateBirthday);
}

export function deleteBirthday(id: number): Promise<ApiResult<undefined>> {
  return send("DELETE", `/api/birthdays/${id}`, {}, NO_BODY);
}

export function putReminders(id: number, offsets: number[]): Promise<ApiResult<{ offsets: number[] }>> {
  return send("PUT", `/api/birthdays/${id}/reminders`, { offsets }, validateOffsets);
}

export function postShare(id: number, email: string): Promise<ApiResult<{ email: string }>> {
  return send("POST", `/api/birthdays/${id}/shares`, { email }, validateEmail);
}

export function deleteShare(id: number, email: string): Promise<ApiResult<undefined>> {
  return send("DELETE", `/api/birthdays/${id}/shares`, { email }, NO_BODY);
}

export function postGift(id: number, text: string, shared?: boolean): Promise<ApiResult<Gift>> {
  return send("POST", `/api/birthdays/${id}/gifts`, shared === undefined ? { text } : { text, shared }, validateGift);
}

export function patchGift(id: number, shared: boolean): Promise<ApiResult<Gift>> {
  return send("PATCH", `/api/gifts/${id}`, { shared }, validateGift);
}

export function deleteGift(id: number): Promise<ApiResult<undefined>> {
  return send("DELETE", `/api/gifts/${id}`, {}, NO_BODY);
}

export function postNtfy(): Promise<ApiResult<NtfyResult>> {
  return send("POST", "/api/notify/ntfy", {}, validateNtfy);
}

export function postNtfyReset(): Promise<ApiResult<NtfyReset>> {
  return send("POST", "/api/notify/ntfy/reset", {}, validateNtfyReset);
}

export function postNtfyTest(): Promise<ApiResult<{ settings: Settings }>> {
  return send("POST", "/api/notify/ntfy/test", {}, validateSettingsOnly);
}

export function postDestinationTest(id: number): Promise<ApiResult<{ settings: Settings }>> {
  return send("POST", `/api/notify/destinations/${id}/test`, {}, validateSettingsOnly);
}

export function getDestinations(): Promise<ApiResult<Destination[]>> {
  return get("/api/notify/destinations", validateDestinations);
}

export function postDestination(d: {
  kind: "discord" | "webhook";
  label: string;
  url: string;
}): Promise<ApiResult<DestinationCreated>> {
  return send("POST", "/api/notify/destinations", d, validateDestinationCreated);
}

export function checkDestination(id: number): Promise<ApiResult<DestinationChecked>> {
  return send("POST", `/api/notify/destinations/${id}/check`, {}, validateDestinationChecked);
}

export function deleteDestination(id: number): Promise<ApiResult<{ settings: Settings }>> {
  return send("DELETE", `/api/notify/destinations/${id}`, {}, validateSettingsOnly);
}
