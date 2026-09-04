import type { Message } from "@/state/store";

/** Whether the transcript tail should show the "working" dots.
 *
 * Shown whenever a turn is still running, including while a partial reply
 * is already on screen — otherwise the only signal is a blinking caret
 * during long gaps between tokens (tools, thinking). A turn ends across
 * three server frames: the settled reply (`message`), `turn.completed`,
 * then the bot patch that flips `busy` off. A settled reply at the tail
 * means there is nothing to wait for, so the dots stay hidden until
 * something actually new starts: a tool chip, the user's next prompt, or
 * (in rooms) a different speaker taking the floor. That avoids the
 * end-of-stream jitter of dots popping back under a finished reply.
 */
export function showWorkingDots(
  busy: boolean | undefined,
  _streaming: string | undefined,
  lastMessage: Message | undefined,
  /** rooms: the bot currently speaking. A settled reply from a PREVIOUS
   * speaker doesn't cover this one — its dots are real information. */
  speakerBotId?: string,
): boolean {
  if (!busy) return false;
  if (!lastMessage) return true;
  const settledReply = lastMessage.role === "bot" && lastMessage.kind === "text";
  if (!settledReply) return true;
  return speakerBotId !== undefined && lastMessage.from?.botId !== speakerBotId;
}
