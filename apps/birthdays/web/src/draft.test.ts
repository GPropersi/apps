import { describe, expect, it } from "vitest";
import { EMPTY_DRAFT, draftTag, loadDraft, loadEditDraft, saveDraft, saveEditDraft, sha256Hex } from "./draft";

const DRAFT = { ...EMPTY_DRAFT, name: "Kept", month: 4, day: "9" };
const EDIT = { name: "Sammy", month: 11, day: "16", year: "1990" };

describe("sha256Hex", () => {
  it.each([
    ["", "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"],
    ["abc", "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"],
    [
      "abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq",
      "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1",
    ],
  ])("matches the standard vector for %j", (input, want) => {
    expect(sha256Hex(input)).toBe(want);
  });

  it("hashes non-ASCII text to 64 lowercase hex characters", () => {
    expect(sha256Hex("Élodie@example.com")).toMatch(/^[0-9a-f]{64}$/);
  });
});

describe("draftTag", () => {
  it("is the same for one address in any case and differs between addresses", () => {
    expect(draftTag("Alex@Example.com")).toBe(draftTag("alex@example.com"));
    expect(draftTag("a@example.com")).not.toBe(draftTag("b@example.com"));
  });

  it("does not contain the address", () => {
    expect(draftTag("alex@example.com")).not.toContain("alex");
  });
});

describe("draft storage", () => {
  it("stores the person's tag, never the email, and restores for the same person in any case", () => {
    saveDraft(draftTag("Alex@Example.com"), DRAFT);
    const stored = window.sessionStorage.getItem("birthdays:add-draft") ?? "";
    expect(stored).toContain(`"who":"${draftTag("alex@example.com")}"`);
    expect(stored.toLowerCase()).not.toContain("alex");
    expect(stored).not.toContain("example.com");
    expect(loadDraft(draftTag("ALEX@example.com"))).toEqual(DRAFT);
  });

  it("keeps an untouched remind as null", () => {
    saveDraft(draftTag("a@example.com"), DRAFT);
    expect(loadDraft(draftTag("a@example.com"))?.remind).toBeNull();
  });

  it("discards another person's draft", () => {
    saveDraft(draftTag("a@example.com"), DRAFT);
    expect(loadDraft(draftTag("b@example.com"))).toBeNull();
    expect(window.sessionStorage.getItem("birthdays:add-draft")).toBeNull();
  });

  it("discards a draft stored in the old shape, with a raw email and no tag", () => {
    window.sessionStorage.setItem(
      "birthdays:add-draft",
      JSON.stringify({ ...DRAFT, email: "a@example.com" }),
    );
    expect(loadDraft(draftTag("a@example.com"))).toBeNull();
    expect(window.sessionStorage.getItem("birthdays:add-draft")).toBeNull();
  });
});

describe("edit draft storage", () => {
  it("stores the tag, never the email, and restores only for the same person", () => {
    saveEditDraft(draftTag("alex@example.com"), 7, EDIT);
    const stored = window.sessionStorage.getItem("birthdays:edit-draft:7") ?? "";
    expect(stored).not.toContain("example.com");
    expect(loadEditDraft(draftTag("Alex@Example.com"), 7)).toEqual(EDIT);
    expect(loadEditDraft(draftTag("b@example.com"), 7)).toBeNull();
    expect(window.sessionStorage.getItem("birthdays:edit-draft:7")).toBeNull();
  });
});
