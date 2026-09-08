import { describe, expect, it } from "vitest";

import { configStatusFromFrame, initialState, reducer, type Bot, type Message } from "./store";

describe("config status frames", () => {
  it("keeps the room turn timeout with the existing config fields", () => {
    expect(
      configStatusFromFrame({
        xai: { configured: true },
        composio: { configured: true, mode: "managed" },
        box: { configured: false },
        vps: { configured: true, sshAlias: "homelab" },
        rooms: { turnTimeoutMinutes: 20 },
        opencodeGo: { configured: true },
        localEndpoint: { configured: true },
        tts: { configured: true, ready: true, voice: "Ada" },
        profile: { name: "Ian", email: "ian@example.test" },
      }),
    ).toEqual({
      xai: { configured: true },
      composio: { configured: true, mode: "managed" },
      box: { configured: false },
      vps: { configured: true, sshAlias: "homelab" },
      rooms: { turnTimeoutMinutes: 20 },
      opencodeGo: { configured: true },
      localEndpoint: { configured: true },
      tts: { configured: true, ready: true, voice: "Ada" },
      profile: { name: "Ian", email: "ian@example.test" },
    });
  });
});

describe("cross-client bot creation", () => {
  it("adds an announced bot before its greeting frames arrive", () => {
    const announced = {
      id: "phone-bot",
      threadId: "phone-thread",
      name: "Scout",
      title: "",
      description: "",
      notifications: true,
      color: "green",
      unread: false,
      modelSelection: { instanceId: "codex", model: "default" },
    } satisfies Omit<Bot, "messages">;

    const added = reducer(initialState, { type: "botPatched", bot: announced });

    expect(added.bots).toEqual([{ ...announced, messages: [] }]);

    const greeting = {
      id: "greeting",
      role: "bot",
      kind: "text",
      text: "Hey — I'm Scout. Nice to meet you.",
      at: 2,
    } satisfies Message;
    const greeted = reducer(added, {
      type: "messageAdded",
      threadId: announced.threadId,
      message: greeting,
    });

    expect(greeted.bots[0]?.messages).toEqual([greeting]);
  });
});

describe("request-card retry restoration", () => {
  it("restores an optimistic answer or dismissal after a retryable delivery failure", () => {
    // SAFETY: this complete in-memory fixture supplies every Bot field the reducer reads.
    const bot = {
      id: "retry-bot", threadId: "retry-thread", name: "Retry", title: "", description: "", notifications: false,
      color: "green", unread: false, modelSelection: { instanceId: "deepseekHarness", model: "deepseek/chat" },
      messages: [{ id: "ask", role: "bot", kind: "options", at: 1, card: { title: "Question", subtitle: "Pick", options: ["A", "B"], requestId: "request" } }],
    } as Bot;
    const present = reducer(initialState, { type: "botPatched", bot });
    const answered = reducer(present, { type: "answerCard", botId: bot.id, messageId: "ask", answer: "A", selected: ["A"] });
    expect(answered.bots[0]!.messages[0]!.card?.answered).toBe("A");
    const restoredAnswer = reducer(answered, { type: "restoreCard", botId: bot.id, messageId: "ask", requestId: "request", expectedAnswer: "A" });
    expect(restoredAnswer.bots[0]!.messages[0]!.card).toMatchObject({ dismissed: false });
    expect(restoredAnswer.bots[0]!.messages[0]!.card?.answered).toBeUndefined();
    const dismissed = reducer(restoredAnswer, { type: "dismissCard", botId: bot.id, messageId: "ask" });
    expect(dismissed.bots[0]!.messages[0]!.card?.dismissed).toBe(true);
    expect(reducer(dismissed, { type: "restoreCard", botId: bot.id, messageId: "ask", requestId: "request", expectedDismissed: true }).bots[0]!.messages[0]!.card?.dismissed).toBe(false);
  });

  it("does not let a late failed fetch restore over a newer authoritative patch", () => {
    // SAFETY: this complete in-memory fixture supplies every Bot field the reducer reads.
    const bot = {
      id: "race-bot", threadId: "race-thread", name: "Race", title: "", description: "", notifications: false,
      color: "green", unread: false, modelSelection: { instanceId: "deepseekHarness", model: "deepseek/chat" },
      messages: [{ id: "ask", role: "bot", kind: "options", at: 1, card: { title: "Question", subtitle: "Pick", options: ["A"], requestId: "race-request" } }],
    } as Bot;
    const present = reducer(initialState, { type: "botPatched", bot });
    const optimistic = reducer(present, { type: "answerCard", botId: bot.id, messageId: "ask", answer: "A", selected: ["A"] });
    const authoritative = reducer(optimistic, {
      type: "messagePatched",
      threadId: bot.threadId,
      message: { ...optimistic.bots[0]!.messages[0]!, card: { ...optimistic.bots[0]!.messages[0]!.card!, answered: "answer", dismissed: true } },
    });
    const lateFailure = reducer(authoritative, { type: "restoreCard", botId: bot.id, messageId: "ask", requestId: "race-request", expectedAnswer: "A" });
    expect(lateFailure.bots[0]!.messages[0]!.card).toMatchObject({ answered: "answer", dismissed: true });
  });

  it("applies the same retry restoration fence to room question cards", () => {
    const group = {
      id: "race-room",
      threadId: "race-room-thread",
      name: "Race room",
      memberIds: ["member"],
      defaultResponder: { kind: "everyone" as const },
      bulletin: "",
      unread: false,
      createdAt: 1,
      messages: [{
        id: "room-ask",
        role: "bot" as const,
        kind: "options" as const,
        at: 1,
        card: { title: "Question", subtitle: "Pick", options: ["A"], requestId: "room-request" },
      }],
    };
    const present = reducer(initialState, { type: "groupPatched", group });
    const optimistic = reducer(present, {
      type: "answerGroupCard",
      groupId: group.id,
      messageId: "room-ask",
      answer: "A",
      selected: ["A"],
    });
    const authoritative = reducer(optimistic, {
      type: "groupPatched",
      group: {
        ...optimistic.groups[0]!,
        messages: [{
          ...optimistic.groups[0]!.messages[0]!,
          card: { ...optimistic.groups[0]!.messages[0]!.card!, answered: "answer", dismissed: true },
        }],
      },
    });

    const lateFailure = reducer(authoritative, {
      type: "restoreGroupCard",
      groupId: group.id,
      messageId: "room-ask",
      requestId: "room-request",
      expectedAnswer: "A",
    });
    expect(lateFailure.groups[0]!.messages[0]!.card).toMatchObject({ answered: "answer", dismissed: true });
  });

  it("keeps multi-select card metadata through the state fold", () => {
    // SAFETY: this complete in-memory fixture supplies every Bot field the reducer reads.
    const bot = {
      id: "multi-bot", threadId: "multi-thread", name: "Multi", title: "", description: "", notifications: false,
      color: "green", unread: false, modelSelection: { instanceId: "deepseekHarness", model: "deepseek/chat" },
      messages: [{ id: "multi", role: "bot", kind: "options", at: 1, card: { title: "Question", subtitle: "Pick", options: ["A", "B"], requestId: "multi-request", multiSelect: true } }],
    } as Bot;
    const state = reducer(initialState, { type: "botPatched", bot });
    expect(state.bots[0]!.messages[0]!.card?.multiSelect).toBe(true);
  });
});
