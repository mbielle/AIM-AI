import { mergePose, type Pose } from '../core/types';
import { REST, type CompanionVariant } from './geometry';

/*
 * Expression vocabulary. Eyes and posture are kept apart so a choreography can say "happy eyes"
 * and "crouch" independently. All values are partial poses blended onto the current one.
 */

const both = (k: string, l: number, r = l) => ({ [`${k}L`]: l, [`${k}R`]: r });

/** Resets every eye key, so an expression never inherits a stray lid or rotation. */
const EYE_BASE: Partial<Pose> = {
  ...both('lid', 0.1, 0.18), ...both('in', 0), ...both('curve', -0.04), ...both('low', 0), ...both('cheek', 0), ...both('smile', 0),
  ...both('scale', 1), ...both('rot', 0), ew: 1, eh: 1,
};

export const EYES = {
  /** Calm and present; one lid a touch lower — the resting signature. */
  neutral: EYE_BASE,
  /** Interested: lids lifted. */
  open: { ...EYE_BASE, ...both('lid', 0.02, 0.06), ...both('scale', 1.03) },
  /** Surprise: wide, rounder, no lids. */
  wide: { ...EYE_BASE, ...both('lid', 0), ...both('scale', 1.16), ew: 1.14, eh: 1.02 },
  /** Working: lids lowered, drawn slightly inwards. */
  focus: { ...EYE_BASE, ...both('lid', 0.27, 0.3), ...both('in', 0.04), ...both('curve', -0.12), ...both('low', 0.05) },
  /** Thinking: asymmetric, contemplative. */
  ponder: { ...EYE_BASE, ...both('lid', 0.34, 0.12), ...both('curve', -0.1), ...both('low', 0.04, 0) },
  /** Happy: closed upward arcs, wider than the open eye. */
  happy: { ...EYE_BASE, ...both('lid', 0), ...both('smile', 1), ew: 1.34, eh: 0.78 },
  /** Content: smiling from below, cheeks raised. */
  content: { ...EYE_BASE, ...both('lid', 0.04), ...both('curve', -0.16), ...both('low', 0.24), ...both('cheek', 0.08), ew: 1.1 },
  /** Proud, a little smug: heavy lids over smiling cheeks. */
  smug: { ...EYE_BASE, ...both('lid', 0.4, 0.36), ...both('curve', 0.06) },
  /** Error: squinted ("plissés") — lids down, cheeks up, drawn in a little. */
  squint: { ...EYE_BASE, ...both('lid', 0.36, 0.4), ...both('curve', -0.12), ...both('low', 0.3), ...both('in', 0.12), ew: 1.2, eh: 0.9 },
  /** The oops squeeze: > < */
  squeeze: { ...EYE_BASE, ...both('lid', 0), ...both('smile', 1), ...both('rot', 1.42), ew: 1.15, eh: 0.9 },
  /** Sad: outer corners down. */
  sad: { ...EYE_BASE, ...both('lid', 0.3), ...both('in', -0.2), ...both('curve', 0.06) },
  /** Skeptical / annoyed: one heavy flat lid — the mischievous "-_-". */
  skeptical: { ...EYE_BASE, ...both('lid', 0.47, 0.14), ...both('in', 0.08, 0), ...both('curve', 0, -0.04) },
  /** Confused: one eye wide, the other squinting. */
  confused: { ...EYE_BASE, ...both('lid', 0, 0.4), ...both('low', 0, 0.2), ...both('scale', 1.14, 0.9) },
  /** Shy: soft, smiling, looking away. */
  shy: { ...EYE_BASE, ...both('lid', 0.14), ...both('curve', -0.12), ...both('low', 0.22), ...both('cheek', 0.08), ew: 1.06 },
  /** Sleepy: heavy, sagging lids. */
  sleepy: { ...EYE_BASE, ...both('lid', 0.5, 0.56), ...both('curve', 0.08) },
  /** Asleep: closed ∪ lines. */
  closed: { ...EYE_BASE, ...both('lid', 1), ...both('curve', 0.3) },
} satisfies Record<string, Partial<Pose>>;

export type EyeName = keyof typeof EYES;

/** Postures, per variant: the compact sign keeps most of its shape; the companion stands up. */
export function postures(variant: CompanionVariant) {
  const big = variant === 'companion';
  const upright: Partial<Pose> = big
    ? { len: 24, rB: 35, rT: 32.5, flat: 0.7, lean: 0.06, bend: 2, sq: 0, hop: 0, roll: 0, face: 0.04 }
    : { len: 10, rB: 40, rT: 35, flat: 0.62, lean: 0.09, bend: 0, sq: 0, hop: 0, roll: 0, face: 0.12 };
  const u = (p: Partial<Pose>): Partial<Pose> => ({ ...upright, ...p });
  const amp = big ? 1 : 0.35;
  return {
    amp,
    upright,
    /** Leaning in towards the composer, attentive. */
    listening: u({ len: (upright.len as number) - 4 * amp, lean: 0.1 * amp + 0.04, bend: 3 * amp }),
    /** Sitting back a little, pondering. */
    thinking: u({ len: (upright.len as number) - 6 * amp, lean: -0.03, bend: -1 * amp }),
    /** Hunched towards the work. */
    working: big ? u({ len: 26, lean: 0.2, bend: 3.5 }) : u({ len: 9, lean: 0.12, bend: 3 }),
    /** Upright, facing us, patient. */
    waiting: u({ len: (upright.len as number) + 1 * amp, lean: 0.01, bend: 0 }),
    /** Shrunk, leaning back, a little embarrassed. */
    error: u({ len: (upright.len as number) - 5 * amp, lean: -0.05, bend: -1.5 * amp, sq: 0.03, roll: 0.06 }),
    /** Heavy, sinking. */
    drowsy: u({ len: (upright.len as number) - 10 * amp, bend: 5 * amp, lean: 0.12 }),
    /** Curled up, low and wide. */
    asleep: { len: 4, rB: 40, rT: 35, flat: 0.62, lean: 0, bend: 0, sq: 0.1, hop: 0, roll: 0, face: 0.12 } as Partial<Pose>,
  };
}

export function restPose(variant: CompanionVariant): Pose {
  return mergePose(REST, postures(variant).upright, EYES.neutral);
}
