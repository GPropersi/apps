import { afterEach, describe, expect, it, vi } from "vitest";
import {
  checkDestination,
  deleteBirthday,
  deleteGift,
  deleteShare,
  getBirthday,
  getBirthdays,
  getDestinations,
  getMe,
  patchGift,
  patchSettings,
  postBirthday,
  postDestination,
  postDestinationTest,
  postGift,
  postNtfy,
  postNtfyReset,
  postNtfyTest,
  postShare,
  putBirthday,
  putReminders,
} from "./api";

const HTML = { "Content-Type": "text/html; charset=utf-8" };
const JSON_CT = { "Content-Type": "application/json" };

function respond(body: string | null, status: number, headers: Record<string, string>) {
  const fetchMock = vi.fn().mockResolvedValue(new Response(body, { status, headers }));
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

const SETTINGS = {
  auto_remind: false,
  default_offsets: [7, 1],
  start_tab: "auto",
  list_view: "upcoming",
  calendar_zoom: "month",
  color_scheme: "confetti",
  ntfy: false,
  destinations: 0,
  stale_destinations: 0,
};
const BIRTHDAY = {
  id: 1,
  name: "Sam Rivera",
  month: 7,
  day: 4,
  year: 1990,
  is_mine: true,
  owner_email: "a@example.com",
  reminder_offsets: [7, 1],
};
const GIFT = { id: 3, text: "Socks", shared: false, author_email: "a@example.com", mine: true };
const DEST = { id: 4, kind: "discord", label: "Family", hint: "abc", stale: false };

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("api result mapping", () => {
  it("maps a network TypeError to unavailable", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new TypeError("Failed to fetch")));
    expect(await getBirthdays()).toEqual({ kind: "unavailable" });
  });

  it.each([502, 503, 504])("maps %i with an HTML body to unavailable", async (status) => {
    respond("<html>down</html>", status, HTML);
    expect(await getBirthdays()).toEqual({ kind: "unavailable" });
  });

  it("maps a 503 with a JSON body to unavailable", async () => {
    respond('{"error":"x"}', 503, JSON_CT);
    expect(await getBirthdays()).toEqual({ kind: "unavailable" });
  });

  it("maps a 200 HTML body to session_expired", async () => {
    respond("<html>login</html>", 200, HTML);
    expect(await getMe()).toEqual({ kind: "session_expired" });
  });

  it("maps a 401 HTML body to session_expired", async () => {
    respond("<html>login</html>", 401, HTML);
    expect(await getMe()).toEqual({ kind: "session_expired" });
  });

  it("maps a 403 HTML body to session_expired", async () => {
    respond("<html>denied</html>", 403, HTML);
    expect(await getBirthdays()).toEqual({ kind: "session_expired" });
  });

  it("maps an opaque redirect to session_expired", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn().mockResolvedValue({ status: 0, ok: false, type: "opaqueredirect", headers: new Headers() }),
    );
    expect(await getMe()).toEqual({ kind: "session_expired" });
  });

  it("maps a 520 HTML body to unavailable", async () => {
    respond("<html>cf</html>", 520, HTML);
    expect(await getBirthdays()).toEqual({ kind: "unavailable" });
  });

  it("maps a 500 plain-text body to unavailable", async () => {
    respond("boom", 500, { "Content-Type": "text/plain" });
    expect(await getBirthdays()).toEqual({ kind: "unavailable" });
  });

  it("maps a 404 HTML body to generic", async () => {
    respond("<html>nf</html>", 404, HTML);
    expect(await getBirthdays()).toEqual({ kind: "generic" });
  });

  it("maps a body with no Content-Type on a 404 to generic", async () => {
    respond(null, 404, {});
    expect(await getBirthdays()).toEqual({ kind: "generic" });
  });

  it("maps a JSON 401 unauthenticated to unauthenticated", async () => {
    respond('{"error":"unauthenticated"}', 401, JSON_CT);
    expect(await getMe()).toEqual({ kind: "unauthenticated" });
  });

  it("maps any other JSON 401 or 403 to generic", async () => {
    respond('{"error":"other"}', 401, JSON_CT);
    expect(await getMe()).toEqual({ kind: "generic" });
    respond('{"error":"cross_site"}', 403, JSON_CT);
    expect(await deleteBirthday(1)).toEqual({ kind: "generic" });
  });

  it("counts application/json; charset=utf-8 as JSON", async () => {
    respond(JSON.stringify({ birthdays: [BIRTHDAY] }), 200, { "Content-Type": "application/json; charset=utf-8" });
    expect(await getBirthdays()).toEqual({ kind: "ok", data: [BIRTHDAY] });
  });

  it.each([
    [400, "invalid_name"],
    [400, "invalid_date"],
    [400, "invalid_year"],
    [409, "too_many_birthdays"],
    [409, "too_many_shares"],
    [409, "too_many_gifts"],
    [403, "not_owner"],
    [404, "not_found"],
    [400, "invalid_offsets"],
    [400, "invalid_setting"],
    [400, "empty"],
    [500, "notify_unavailable"],
    [409, "destination_stale"],
  ])("maps %i %s to its own kind", async (status, code) => {
    respond(JSON.stringify({ error: code }), status, JSON_CT);
    expect(await postBirthday({ name: "x", month: 1, day: 1, offsets: [] })).toEqual({ kind: code });
  });

  it("maps an unknown JSON error code to generic and never exposes it", async () => {
    respond('{"error":"internal"}', 500, JSON_CT);
    expect(await getBirthdays()).toEqual({ kind: "generic" });
  });

  it.each([
    [200, "generic"],
    [404, "generic"],
    [500, "unavailable"],
  ])("maps a JSON content type with a truncated body at %i to %s", async (status, kind) => {
    respond('{"birthdays":[', status, JSON_CT);
    expect(await getBirthdays()).toEqual({ kind });
  });

  it("maps a 200 body of the wrong shape to generic", async () => {
    respond('{"birthdays":"nope"}', 200, JSON_CT);
    expect(await getBirthdays()).toEqual({ kind: "generic" });
    respond('{"email":5}', 200, JSON_CT);
    expect(await getMe()).toEqual({ kind: "generic" });
    respond(JSON.stringify({ email: "a@example.com", settings: { auto_remind: "yes" } }), 200, JSON_CT);
    expect(await getMe()).toEqual({ kind: "generic" });
  });

  it("maps a 204 with an empty body to ok before the Content-Type test", async () => {
    respond(null, 204, {});
    expect(await deleteBirthday(1)).toEqual({ kind: "ok" });
  });

  it("keeps a 200 non-JSON body on a write as session_expired, and any other non-JSON 2xx as generic", async () => {
    respond("<html>login</html>", 200, HTML);
    expect(await postBirthday({ name: "x", month: 1, day: 1, offsets: [] })).toEqual({ kind: "session_expired" });
    respond("<html>odd</html>", 201, HTML);
    expect(await postBirthday({ name: "x", month: 1, day: 1, offsets: [] })).toEqual({ kind: "generic" });
  });
});

describe("test sends", () => {
  it("posts to the phone test path and returns the settings", async () => {
    const f = respond(JSON.stringify({ settings: SETTINGS }), 200, JSON_CT);
    expect(await postNtfyTest()).toEqual({ kind: "ok", data: { settings: SETTINGS } });
    expect(f.mock.calls[0]?.[0]).toBe("/api/notify/ntfy/test");
    expect((f.mock.calls[0]?.[1] as RequestInit).method).toBe("POST");
  });

  it("posts to the destination test path and returns the settings", async () => {
    const f = respond(JSON.stringify({ settings: SETTINGS }), 200, JSON_CT);
    expect(await postDestinationTest(7)).toEqual({ kind: "ok", data: { settings: SETTINGS } });
    expect(f.mock.calls[0]?.[0]).toBe("/api/notify/destinations/7/test");
    expect((f.mock.calls[0]?.[1] as RequestInit).method).toBe("POST");
  });

  it("maps a 409 destination_stale to its own kind", async () => {
    respond('{"error":"destination_stale"}', 409, JSON_CT);
    expect(await postDestinationTest(7)).toEqual({ kind: "destination_stale" });
  });
});

describe("api payloads", () => {
  it("returns typed payloads for OK responses", async () => {
    respond(JSON.stringify({ email: "a@example.com", settings: SETTINGS }), 200, JSON_CT);
    expect(await getMe()).toEqual({ kind: "ok", data: { email: "a@example.com", settings: SETTINGS } });
    respond(JSON.stringify(BIRTHDAY), 201, JSON_CT);
    expect(await postBirthday({ name: "Sam Rivera", month: 7, day: 4, year: 1990, offsets: [14, 7, 1] })).toEqual({
      kind: "ok",
      data: BIRTHDAY,
    });
  });

  it("softens an unknown enum value in S to its default", async () => {
    respond(
      JSON.stringify({ email: "a@example.com", settings: { ...SETTINGS, color_scheme: "neon", list_view: "grid" } }),
      200,
      JSON_CT,
    );
    const res = await getMe();
    expect(res.kind).toBe("ok");
    if (res.kind === "ok") {
      expect(res.data.settings.color_scheme).toBe("confetti");
      expect(res.data.settings.list_view).toBe("upcoming");
    }
  });

  it("validates the detail, with shares only for the owner", async () => {
    respond(JSON.stringify({ birthday: BIRTHDAY, shares: ["b@example.com"], gifts: [GIFT] }), 200, JSON_CT);
    expect(await getBirthday(1)).toEqual({
      kind: "ok",
      data: { birthday: BIRTHDAY, shares: ["b@example.com"], gifts: [GIFT] },
    });
    respond(JSON.stringify({ birthday: { ...BIRTHDAY, is_mine: false }, gifts: [] }), 200, JSON_CT);
    const res = await getBirthday(1);
    expect(res.kind === "ok" && res.data.shares).toBeNull();
    respond(JSON.stringify({ birthday: BIRTHDAY, gifts: [{ id: "x" }] }), 200, JSON_CT);
    expect(await getBirthday(1)).toEqual({ kind: "generic" });
  });

  it("validates the other shapes", async () => {
    respond(JSON.stringify({ offsets: [1] }), 200, JSON_CT);
    expect(await putReminders(1, [1])).toEqual({ kind: "ok", data: { offsets: [1] } });
    respond(JSON.stringify({ email: "b@example.com" }), 201, JSON_CT);
    expect(await postShare(1, "b@example.com")).toEqual({ kind: "ok", data: { email: "b@example.com" } });
    respond(JSON.stringify(GIFT), 201, JSON_CT);
    expect(await postGift(1, "Socks")).toEqual({ kind: "ok", data: GIFT });
    respond(JSON.stringify(GIFT), 200, JSON_CT);
    expect(await patchGift(3, true)).toEqual({ kind: "ok", data: GIFT });
    respond(JSON.stringify(SETTINGS), 200, JSON_CT);
    expect(await patchSettings({ list_view: "month" })).toEqual({ kind: "ok", data: SETTINGS });
    respond(JSON.stringify({ destinations: [DEST] }), 200, JSON_CT);
    expect(await getDestinations()).toEqual({ kind: "ok", data: [DEST] });
    respond(JSON.stringify({ destination: DEST, signing_secret: "s", settings: SETTINGS }), 201, JSON_CT);
    expect(await postDestination({ kind: "webhook", label: "x", url: "https://example.com" })).toEqual({
      kind: "ok",
      data: { destination: DEST, signing_secret: "s", settings: SETTINGS },
    });
    respond(JSON.stringify({ destination: DEST, settings: SETTINGS }), 200, JSON_CT);
    expect(await checkDestination(4)).toEqual({ kind: "ok", data: { destination: DEST, settings: SETTINGS } });
    respond(JSON.stringify({ user_id: "u", setup_url: "https://x", password: null, settings: SETTINGS }), 200, JSON_CT);
    expect(await postNtfy()).toEqual({
      kind: "ok",
      data: { user_id: "u", setup_url: "https://x", password: null, settings: SETTINGS },
    });
    respond(JSON.stringify({ password: "p", setup_url: "https://x", settings: SETTINGS }), 200, JSON_CT);
    expect(await postNtfyReset()).toEqual({
      kind: "ok",
      data: { password: "p", setup_url: "https://x", settings: SETTINGS },
    });
  });

  it("maps DELETE 204s on shares and gifts to ok", async () => {
    respond(null, 204, {});
    expect(await deleteShare(1, "b@example.com")).toEqual({ kind: "ok" });
    respond(null, 204, {});
    expect(await deleteGift(3)).toEqual({ kind: "ok" });
  });
});

describe("api totality", () => {
  it("maps a non-TypeError fetch rejection on a write to unavailable", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("boom")));
    expect(await postBirthday({ name: "x", month: 1, day: 1, offsets: [] })).toEqual({ kind: "unavailable" });
  });

  it("maps a truncated JSON body and a wrong-shape 2xx on a write", async () => {
    respond('{"id":', 201, JSON_CT);
    expect(await postBirthday({ name: "x", month: 1, day: 1, offsets: [] })).toEqual({ kind: "generic" });
    respond('{"id":"nope"}', 201, JSON_CT);
    expect(await postBirthday({ name: "x", month: 1, day: 1, offsets: [] })).toEqual({ kind: "generic" });
  });

  it.each([
    [401, "session_expired"],
    [520, "unavailable"],
  ])("never reads the body of a non-JSON %i", async (status, kind) => {
    const res = new Response("<html></html>", { status, headers: HTML });
    vi.spyOn(res, "json").mockRejectedValue(new Error("read the body"));
    vi.spyOn(res, "text").mockRejectedValue(new Error("read the body"));
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(res));
    expect(await getBirthdays()).toEqual({ kind });
  });

  it("maps default text/plain 200 and 401 responses to session_expired", async () => {
    respond("ok", 200, {});
    expect(await getBirthdays()).toEqual({ kind: "session_expired" });
    respond("no", 401, {});
    expect(await getBirthdays()).toEqual({ kind: "session_expired" });
  });
});

describe("api requests", () => {
  it("sends same-origin credentials and manual redirects", async () => {
    const f = respond('{"birthdays":[]}', 200, JSON_CT);
    await getBirthdays();
    expect(f.mock.calls[0][1]).toMatchObject({ credentials: "same-origin", redirect: "manual", method: "GET" });
  });

  it("POSTs the birthday JSON with offsets", async () => {
    const f = respond(JSON.stringify(BIRTHDAY), 201, JSON_CT);
    await postBirthday({ name: "Sam", month: 7, day: 4, offsets: [14, 1] });
    const init = f.mock.calls[0][1] as RequestInit;
    expect(f.mock.calls[0][0]).toBe("/api/birthdays");
    expect(init.method).toBe("POST");
    expect(init.headers).toMatchObject({ "Content-Type": "application/json" });
    expect(JSON.parse(init.body as string)).toEqual({ name: "Sam", month: 7, day: 4, offsets: [14, 1] });
  });

  it("uses the right method, path and JSON body for each write", async () => {
    const cases: [() => Promise<unknown>, string, string, unknown][] = [
      [() => patchSettings({ auto_remind: true }), "PATCH", "/api/settings", { auto_remind: true }],
      [
        () => putBirthday(5, { name: "S", month: 2, day: 29, year: null }),
        "PUT",
        "/api/birthdays/5",
        { name: "S", month: 2, day: 29, year: null },
      ],
      [() => deleteBirthday(5), "DELETE", "/api/birthdays/5", {}],
      [() => putReminders(5, [0]), "PUT", "/api/birthdays/5/reminders", { offsets: [0] }],
      [() => postShare(5, "b@example.com"), "POST", "/api/birthdays/5/shares", { email: "b@example.com" }],
      [() => deleteShare(5, "b@example.com"), "DELETE", "/api/birthdays/5/shares", { email: "b@example.com" }],
      [() => postGift(5, "x", true), "POST", "/api/birthdays/5/gifts", { text: "x", shared: true }],
      [() => patchGift(6, true), "PATCH", "/api/gifts/6", { shared: true }],
      [() => deleteGift(6), "DELETE", "/api/gifts/6", {}],
      [() => postNtfy(), "POST", "/api/notify/ntfy", {}],
      [() => postNtfyReset(), "POST", "/api/notify/ntfy/reset", {}],
      [() => checkDestination(7), "POST", "/api/notify/destinations/7/check", {}],
    ];
    for (const [call, method, path, body] of cases) {
      const f = respond("{}", 500, JSON_CT);
      await call();
      const init = f.mock.calls[0][1] as RequestInit;
      expect([init.method, f.mock.calls[0][0]], path).toEqual([method, path]);
      expect(JSON.parse(init.body as string), path).toEqual(body);
      expect(init.headers).toMatchObject({ "Content-Type": "application/json" });
    }
  });
});
