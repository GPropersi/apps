import { afterEach, describe, expect, it, vi } from "vitest";
import { getItems, getMe, postItem, postTask } from "./api";

const HTML = { "Content-Type": "text/html; charset=utf-8" };
const JSON_CT = { "Content-Type": "application/json" };

function respond(body: string | null, status: number, headers: Record<string, string>) {
  const fetchMock = vi.fn().mockResolvedValue(new Response(body, { status, headers }));
  vi.stubGlobal("fetch", fetchMock);
  return fetchMock;
}

const ITEM = { id: 1, text: "hi", created_by: "a@example.com", source: "user", created_at: "2026-11-07T14:32:00Z" };

afterEach(() => {
  vi.unstubAllGlobals();
});

describe("api result mapping", () => {
  it("maps a network TypeError to unavailable", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new TypeError("Failed to fetch")));
    expect(await getItems()).toEqual({ kind: "unavailable" });
  });

  it.each([502, 503, 504])("maps %i with an HTML body to unavailable", async (status) => {
    respond("<html>down</html>", status, HTML);
    expect(await getItems()).toEqual({ kind: "unavailable" });
  });

  it("maps a 503 with a JSON body to unavailable", async () => {
    respond('{"error":"x"}', 503, JSON_CT);
    expect(await getItems()).toEqual({ kind: "unavailable" });
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
    expect(await getItems()).toEqual({ kind: "session_expired" });
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
    expect(await getItems()).toEqual({ kind: "unavailable" });
  });

  it("maps a 500 plain-text body to unavailable", async () => {
    respond("boom", 500, { "Content-Type": "text/plain" });
    expect(await getItems()).toEqual({ kind: "unavailable" });
  });

  it("maps a 404 HTML body to generic", async () => {
    respond("<html>nf</html>", 404, HTML);
    expect(await getItems()).toEqual({ kind: "generic" });
  });

  it("maps a body with no Content-Type on a 404 to generic", async () => {
    respond(null, 404, {});
    expect(await getItems()).toEqual({ kind: "generic" });
  });

  it("maps a JSON 401 unauthenticated to unauthenticated", async () => {
    respond('{"error":"unauthenticated"}', 401, JSON_CT);
    expect(await getMe()).toEqual({ kind: "unauthenticated" });
  });

  it("maps any other JSON 401 or 403 to generic", async () => {
    respond('{"error":"other"}', 401, JSON_CT);
    expect(await getMe()).toEqual({ kind: "generic" });
    respond('{"error":"cross_site"}', 403, JSON_CT);
    expect(await postTask()).toEqual({ kind: "generic" });
  });

  it("counts application/json; charset=utf-8 as JSON", async () => {
    respond(JSON.stringify({ items: [ITEM] }), 200, { "Content-Type": "application/json; charset=utf-8" });
    expect(await getItems()).toEqual({ kind: "ok", data: [ITEM] });
  });

  it("maps a 429 queue_full to busy and any other 429 to generic", async () => {
    respond('{"error":"queue_full"}', 429, JSON_CT);
    expect(await postTask()).toEqual({ kind: "busy" });
    respond('{"error":"slow_down"}', 429, JSON_CT);
    expect(await postTask()).toEqual({ kind: "generic" });
  });

  it("maps invalid_text to its own result", async () => {
    respond('{"error":"invalid_text"}', 400, JSON_CT);
    expect(await postItem("x")).toEqual({ kind: "invalid_text" });
  });

  it("maps a JSON 500 to generic and the code is not exposed", async () => {
    respond('{"error":"internal"}', 500, JSON_CT);
    expect(await getItems()).toEqual({ kind: "generic" });
  });

  it.each([
    [200, "generic"],
    [404, "generic"],
    [500, "unavailable"],
  ])("maps a JSON content type with a truncated body at %i to %s", async (status, kind) => {
    respond('{"items":[', status, JSON_CT);
    expect(await getItems()).toEqual({ kind });
  });

  it("maps a 200 body of the wrong shape to generic", async () => {
    respond('{"items":"nope"}', 200, JSON_CT);
    expect(await getItems()).toEqual({ kind: "generic" });
    respond('{"email":5}', 200, JSON_CT);
    expect(await getMe()).toEqual({ kind: "generic" });
  });

  it("returns typed payloads for OK responses", async () => {
    respond('{"email":"a@example.com"}', 200, JSON_CT);
    expect(await getMe()).toEqual({ kind: "ok", data: { email: "a@example.com" } });
    respond(JSON.stringify(ITEM), 201, JSON_CT);
    expect(await postItem("hi")).toEqual({ kind: "ok", data: ITEM });
    respond('{"id":"01ABC"}', 202, JSON_CT);
    expect(await postTask()).toEqual({ kind: "ok", data: { id: "01ABC" } });
  });
});

describe("api totality", () => {
  it("maps a non-TypeError fetch rejection on a POST to unavailable", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("boom")));
    expect(await postItem("x")).toEqual({ kind: "unavailable" });
    expect(await postTask()).toEqual({ kind: "unavailable" });
  });

  it("maps a truncated JSON body and a wrong-shape 2xx on the POSTs", async () => {
    respond('{"id":', 202, JSON_CT);
    expect(await postTask()).toEqual({ kind: "generic" });
    respond('{"id":5}', 202, JSON_CT);
    expect(await postTask()).toEqual({ kind: "generic" });
    respond('{"text":', 201, JSON_CT);
    expect(await postItem("x")).toEqual({ kind: "generic" });
    respond('{"id":"nope"}', 201, JSON_CT);
    expect(await postItem("x")).toEqual({ kind: "generic" });
  });

  it.each([
    [401, "session_expired"],
    [520, "unavailable"],
  ])("never reads the body of a non-JSON %i", async (status, kind) => {
    const res = new Response("<html></html>", { status, headers: HTML });
    vi.spyOn(res, "json").mockRejectedValue(new Error("read the body"));
    vi.spyOn(res, "text").mockRejectedValue(new Error("read the body"));
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue(res));
    expect(await getItems()).toEqual({ kind });
  });

  it("maps default text/plain 200 and 401 responses to session_expired", async () => {
    respond("ok", 200, {});
    expect(await getItems()).toEqual({ kind: "session_expired" });
    respond("no", 401, {});
    expect(await getItems()).toEqual({ kind: "session_expired" });
  });
});

describe("api requests", () => {
  it("sends same-origin credentials and manual redirects", async () => {
    const f = respond('{"items":[]}', 200, JSON_CT);
    await getItems();
    expect(f.mock.calls[0][1]).toMatchObject({ credentials: "same-origin", redirect: "manual", method: "GET" });
  });

  it("sends Content-Type application/json on the note POST", async () => {
    const f = respond(JSON.stringify(ITEM), 201, JSON_CT);
    await postItem("hello");
    const init = f.mock.calls[0][1] as RequestInit;
    expect(f.mock.calls[0][0]).toBe("/api/items");
    expect(init.method).toBe("POST");
    expect(init.headers).toMatchObject({ "Content-Type": "application/json" });
    expect(init.body).toBe('{"text":"hello"}');
  });

  it("sends Content-Type application/json and body {} on the task POST", async () => {
    const f = respond('{"id":"x"}', 202, JSON_CT);
    await postTask();
    const init = f.mock.calls[0][1] as RequestInit;
    expect(f.mock.calls[0][0]).toBe("/api/tasks");
    expect(init.method).toBe("POST");
    expect(init.headers).toMatchObject({ "Content-Type": "application/json" });
    expect(init.body).toBe("{}");
  });
});
