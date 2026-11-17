import { describe, expect, it } from "vitest";
import { EMPTY_DRAFT, loadDraft, saveDraft } from "./draft";

const DRAFT = { ...EMPTY_DRAFT, name: "Kept", month: 4, day: "9" };

describe("draft storage", () => {
  it("stores the lowercased email and restores for the same person in any case", () => {
    saveDraft("Alex@Example.com", DRAFT);
    expect(window.sessionStorage.getItem("birthdays:add-draft")).toContain('"email":"alex@example.com"');
    expect(loadDraft("ALEX@example.com")).toEqual(DRAFT);
  });

  it("keeps an untouched remind as null", () => {
    saveDraft("a@example.com", DRAFT);
    expect(loadDraft("a@example.com")?.remind).toBeNull();
  });

  it("discards another person's draft", () => {
    saveDraft("a@example.com", DRAFT);
    expect(loadDraft("b@example.com")).toBeNull();
    expect(window.sessionStorage.getItem("birthdays:add-draft")).toBeNull();
  });
});
