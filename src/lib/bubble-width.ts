// How wide the two sides of a conversation are allowed to run.
//
// They are deliberately different. A bot's turn is the long one — prose,
// lists, code — and a narrow column makes it harder to read, not easier: it
// costs vertical space and breaks lists onto more lines than they need. A
// user's turn is usually a sentence, and keeping it narrow is what makes the
// two sides tellable apart at a glance, which is the whole job the alignment
// and the colour are doing.
//
// Shared because the same value has to hold for a settled bubble, the
// streaming one it replaces, and every other bot-side card in the thread —
// otherwise the column visibly jumps as a turn lands.

/** Bot turns: nearly the full column.
 *
 * Not 100%: the pin, the copy/speak stack and the timestamp still sit in the
 * row and are laid out even while invisible (they fade, they do not unmount),
 * so a bubble told to take everything would squeeze them instead. This leaves
 * them their ~110px. The reaction bar, which alone wanted 160px more, is
 * lifted out of the flow by its callers. */
export const BOT_BUBBLE = "max-w-[88%]";

/** User turns: short by nature, narrow on purpose. */
export const USER_BUBBLE = "max-w-[70%]";
