import { describe, expect, it } from "vitest";
import { STILL_AVATARS_KEY, useStillAvatars } from "./still-avatars";

describe("still avatars", () => {
  // Importing at all is the assertion here: the override is read at module
  // load, and a build step or a test runner without a DOM must not blow up on
  // the way past it.
  it("loads without a window to read the override from", () => {
    expect(typeof useStillAvatars).toBe("function");
  });

  it("names the override key the console can set", () => {
    expect(STILL_AVATARS_KEY).toBe("swarmebot.stillAvatars");
  });
});
