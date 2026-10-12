// Bot avatar — the Blob Studio "Cursor" mascot (CursorAvatar.tsx), wrapped
// in the app's historical MausAvatar API so no call site changes: per-bot
// color becomes a body gradient, the app's one-shot motion beats borrow the
// face/state for a moment, and the eyes follow the pointer. The previous
// hand-built Maus body + face engine (maus-engine/face/driver) is gone;
// CursorAvatar owns morphing, blinking, drift, body motion and effects.
import {
  forwardRef,
  memo,
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
  type PointerEvent as ReactPointerEvent,
} from "react";
import {
  MAUS_COLORS,
  eyeInkFor,
  silhouetteFor,
  type MausColor,
  type MausMotion,
  type MausState,
} from "@/lib/mascot";
import { CursorAvatar, type CursorAvatarHandle } from "./CursorAvatar";
import { SpriteSheetAvatar } from "./SpriteSheetAvatar";
import { SvgAvatar } from "./SvgAvatar";
import { clampSheetRow } from "@/lib/sprite-sheet";
import { useStillAvatars } from "@/lib/still-avatars";
import { useAvatarFrameSlot, useNearViewport } from "@/lib/avatar-frames";

/**
 * Everything about how one bot looks. Call sites pass the bot itself, so a
 * new appearance field reaches every avatar in the app without touching the
 * thirty places that render one.
 */
/** Whether a bot wears a picture of its own — a file or SVG markup. */
export function wearsPicture(look: MausLook): boolean {
  return Boolean(look.mascotAvatarImage) || Boolean(look.mascotAvatarSvg);
}

export type MausLook = {
  mascotSilhouette?: string | null;
  /** An uploaded SVG, which replaces the mascot entirely when set. */
  mascotAvatarSvg?: string | null;
  /** A picture of your own, as an attachment filename on this machine. */
  mascotAvatarImage?: string | null;
  /** Row of a 9×8 sheet to animate. */
  mascotAvatarSheetRow?: number | null;
};

/**
 * Legacy face-placement knobs from the Maus body era. The cursor mascot
 * places its own face; these remain only so the preview harness's sliders
 * keep compiling — the matching props are accepted and ignored.
 */
export const FACE_X = 80;
export const FACE_Y = 102;
export const FACE_SCALE = 0.47;
export const EYE_SCALE = 1.12;
export const MOUTH_WEIGHT = 11;

/**
 * How far the pointer may pull the eyes. Facing forward the full range is
 * safe; with the expressions' authored gaze they already start off-centre.
 */
const POINTER_GAZE = { forward: 1, authored: 0.25 };

/**
 * What a one-shot motion does while it plays: CursorAvatar animates the body
 * per state, so borrowing the state for a beat moves body and face together.
 */
interface MotionFaces
  extends Partial<
    Record<Exclude<MausMotion, "none">, { state?: MausState; blink?: boolean; spin?: number }>
  > {}

const MOTION_FACE: MotionFaces = {
  arrive: { state: "spawning", spin: 900 },
  switch: { state: "waking", spin: 620 },
  customize: { state: "proud", blink: true },
  alert: { state: "alerting" },
  thinking: { state: "thinking" },
  working: { state: "working" },
  launch: { state: "loading" },
  success: { state: "happy", blink: true },
  celebrate: { state: "celebrate", spin: 700 },
  blink: { blink: true },
  surprise: { state: "surprised", blink: true },
  failure: { state: "sad" },
};

/** How long a one-shot motion holds its state before the bot's own returns. */
const MOTION_FACE_MS = 1400;

/** Channel-wise mix of a hex color toward another, t in 0..1. */
function mix(hex: string, toward: string, t: number): string {
  const a = Number.parseInt(hex.slice(1), 16);
  const b = Number.parseInt(toward.slice(1), 16);
  const channel = (shift: number) => {
    const va = (a >> shift) & 0xff;
    const vb = (b >> shift) & 0xff;
    return Math.round(va + (vb - va) * t);
  };
  return `#${[channel(16), channel(8), channel(0)]
    .map((part) => part.toString(16).padStart(2, "0"))
    .join("")}`;
}

/**
 * Bot color -> the mascot's three-stop body gradient (highlight, base,
 * shadow), with the same light/dark spread as the pack's default green
 * ["#9FE6B5", "#3FAE6E", "#1C7A4C"].
 */
const gradientFor = (color: MausColor): [string, string, string] => {
  const fill = MAUS_COLORS[color] ?? MAUS_COLORS.green;
  return [mix(fill, "#ffffff", 0.55), fill, mix(fill, "#000000", 0.42)];
};

export type MausAvatarHandle = CursorAvatarHandle;

export type MausAvatarProps = {
  color: MausColor;
  /** Named behaviour — drives the expression pool, its cadence and blinking. */
  state?: MausState;
  /** Pin one of the 25 faces and stop the state's own drift. */
  expression?: number;
  /** Body shape to wear, from MAUS_SILHOUETTES. Unknown/absent = the default. */
  silhouette?: string | null;
  /**
   * The bot being drawn. Supplies its shape and, when it has one, its
   * picture — which is a still image, so state, motion and gaze stop
   * applying. Explicit `silhouette` wins, which is how the appearance
   * pickers preview one shape at a time.
   */
  look?: MausLook | null;
  size?: number;
  label?: string;
  motion?: MausMotion;
  motionKey?: number;
  /** Head turn in degrees. */
  turn?: number;
  gaze?: { x?: number; y?: number };
  spring?: number;
  eyeScale?: number;
  showMouth?: boolean;
  mouthStroke?: number;
  /**
   * Face the viewer at turn 0, cancelling each expression's authored gaze
   * direction. Off restores the engine's own drawn-in directions.
   */
  forward?: boolean;
  /** Let the eyes follow the pointer across this avatar. */
  trackPointer?: boolean;
  /**
   * Let this mascot animate. Off renders the state's resting face and is
   * final; on is a request, still subject to being on screen and to the
   * app-wide frame budget (see lib/avatar-frames).
   */
  animated?: boolean;
  /**
   * Claim a frame slot ahead of the decorative mascots. For the frames that
   * carry meaning rather than life: the selected row, a bot mid-turn, a
   * one-shot motion beat playing.
   */
  priority?: boolean;
  /** Legacy Maus face-placement knobs — accepted, ignored. */
  eyeSpacing?: number;
  faceX?: number;
  faceY?: number;
  faceScale?: number;
};

function MausAvatarComponent(
  {
    color,
    state = "idle",
    expression,
    silhouette,
    look,
    size = 44,
    label,
    motion = "none",
    motionKey = 0,
    turn,
    gaze,
    spring,
    eyeScale,
    showMouth,
    mouthStroke,
    forward = true,
    trackPointer = true,
    animated: animatedProp = true,
    priority = false,
  }: MausAvatarProps,
  ref: React.Ref<MausAvatarHandle>,
) {
  // Reduce-motion — the system setting or the stored override — reaches the
  // mascot engine here, so one check covers every avatar in the app.
  const still = useStillAvatars();
  const picture = silhouette === undefined && look != null && wearsPicture(look);
  // Three gates, cheapest first: the caller's own opt-out, reduce-motion, and
  // a picture (a still image has no face engine to run). What survives asks to
  // be on screen and to fit the frame budget — so a roster is alive where you
  // are looking without every mascot in the app costing a frame.
  const mayAnimate = animatedProp && !still && !picture;
  const frame = useRef<HTMLSpanElement>(null);
  const near = useNearViewport(frame, mayAnimate);
  const animated = useAvatarFrameSlot(mayAnimate && near, priority);
  const inner = useRef<CursorAvatarHandle>(null);
  useImperativeHandle(ref, () => ({
    blink: () => inner.current?.blink(),
    spin: (durationMs?: number) => inner.current?.spin(durationMs),
    setExpression: (index: number) => inner.current?.setExpression(index),
    setPointerGaze: (x: number, y: number) => inner.current?.setPointerGaze(x, y),
  }));

  // A one-shot motion borrows the state for a moment, then hands it back.
  const [motionState, setMotionState] = useState<MausState | null>(null);
  useEffect(() => {
    if (motion === "none" || !animated) return;
    const beat = MOTION_FACE[motion];
    if (!beat) return;
    if (beat.blink) inner.current?.blink();
    if (beat.spin) inner.current?.spin(beat.spin);
    if (!beat.state) return;
    setMotionState(beat.state);
    const timer = setTimeout(() => setMotionState(null), MOTION_FACE_MS);
    return () => clearTimeout(timer);
  }, [motion, motionKey, animated]);

  // Pointer-follow gaze. Both halves of the obvious implementation are
  // traps at mouse-move rates: a getBoundingClientRect per move forces the
  // whole document through layout, and a state update per move re-renders
  // the avatar. So the box is measured once when the pointer arrives, and
  // the offset goes straight into the engine, which is redrawing anyway.
  const box = useRef<DOMRect | null>(null);
  const range = forward ? POINTER_GAZE.forward : POINTER_GAZE.authored;
  const onPointerEnter = (event: ReactPointerEvent<HTMLSpanElement>) => {
    box.current = event.currentTarget.getBoundingClientRect();
  };
  const onPointerMove = (event: ReactPointerEvent<HTMLSpanElement>) => {
    const rect = box.current;
    if (!rect || !rect.width || !rect.height) return;
    inner.current?.setPointerGaze(
      Math.max(-1, Math.min(1, ((event.clientX - rect.left) / rect.width) * 2 - 1)) * range,
      Math.max(-1, Math.min(1, ((event.clientY - rect.top) / rect.height) * 2 - 1)) * range,
    );
  };
  const onPointerLeave = () => {
    box.current = null;
    inner.current?.setPointerGaze(0, 0);
  };

  // A picture is a still image: the face engine, its states and the pointer
  // gaze have nothing to drive. The hooks above still run, so switching
  // between a picture and the mascot does not change the hook order.
  if (picture && look?.mascotAvatarImage) {
    const src = `/api/attachments/${encodeURIComponent(look.mascotAvatarImage)}`;
    const sheetRow = clampSheetRow(look.mascotAvatarSheetRow);
    if (sheetRow != null) {
      // A sheet is a CSS background step, not the mascot frame loop. Call
      // sites pause unused mascots (`animated={false}` in the roster, search,
      // pickers); that must not freeze a sprite. Only reduce-motion / the
      // still-avatars override holds it on the first frame.
      return (
        <SpriteSheetAvatar
          src={src}
          row={sheetRow}
          size={size}
          label={label}
          animated={!still}
        />
      );
    }
    return (
      <img
        className="inline-flex shrink-0 rounded-full object-cover"
        style={{ width: size, height: size }}
        src={src}
        alt={label ?? ""}
        aria-hidden={label ? undefined : true}
        draggable={false}
      />
    );
  }

  if (picture && look?.mascotAvatarSvg) {
    return <SvgAvatar svg={look.mascotAvatarSvg} size={size} label={label ?? null} />;
  }

  return (
    <span
      ref={frame}
      className="inline-flex shrink-0"
      onPointerEnter={trackPointer && animated ? onPointerEnter : undefined}
      onPointerMove={trackPointer && animated ? onPointerMove : undefined}
      onPointerLeave={trackPointer && animated ? onPointerLeave : undefined}
    >
      <CursorAvatar
        ref={inner}
        state={motionState ?? state}
        expression={expression}
        size={size}
        silhouette={silhouetteFor(silhouette ?? look?.mascotSilhouette)}
        gradient={gradientFor(color)}
        eyeColor={eyeInkFor(color)}
        title={label ?? null}
        lookAround={forward ? 0 : 1}
        gaze={gaze}
        turn={turn}
        spring={spring}
        eyeScale={eyeScale}
        showMouth={showMouth}
        mouthStroke={mouthStroke}
        paused={!animated}
      />
    </span>
  );
}

export const MausAvatar = memo(forwardRef(MausAvatarComponent));

export function InitialsAvatar({
  initials,
  size = 32,
}: {
  initials: string;
  size?: number;
}) {
  return (
    <div
      className="flex shrink-0 items-center justify-center rounded-full bg-raised text-ink-secondary font-medium"
      style={{ width: size, height: size, fontSize: size * 0.38 }}
    >
      {initials}
    </div>
  );
}
