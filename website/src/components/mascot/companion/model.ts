import { BaseModel } from '../core/model';
import { SPRING, clamp, lerp, type SpringCfg } from '../core/motion';
import type { DemoMode, Pose, Pt } from '../core/types';
import { EYES, postures, restPose, type EyeName } from './expressions';
import { EYE_KEYS, GAZE_KEYS, type CompanionVariant } from './geometry';

/*
 * Choreography of the AIM companion, kept apart from the product: the app says what is true
 * (a state, an event), this file decides how it looks.
 *
 * Three layers, highest first:
 * 1. Rest — drowsy, asleep, waking. Driven by inactivity (or forced in the lab).
 * 2. Reaction — a short, one-off performance (done, oops, surprised…). Ends on its own.
 * 3. State — what the app is doing (idle, thinking, working…), held until the app changes it.
 * Gaze tracking is an overlay on the states that allow it.
 */

/** Persistent product states, set by the app. */
export const MASCOT_STATES = ['idle', 'listening', 'thinking', 'working', 'waiting', 'error'] as const;
export type MascotState = (typeof MASCOT_STATES)[number];

/** One-off reactions, triggered by app events. They return to the current state. */
export const MASCOT_REACTIONS = [
  'greet', 'done', 'celebrate', 'surprised', 'oops', 'nod', 'shake', 'confused', 'proud', 'sad', 'annoyed', 'shy', 'poke', 'yawn',
] as const;
export type MascotReaction = (typeof MASCOT_REACTIONS)[number];

export type RestPhase = 'awake' | 'drowsy' | 'sleeping' | 'waking';

export interface AutoSleep {
  /** Seconds of inactivity before heavy lids. */
  drowsyAfter: number;
  /** Seconds of inactivity before falling asleep. */
  sleepAfter: number;
}

export const DEFAULT_AUTO_SLEEP: AutoSleep = { drowsyAfter: 45, sleepAfter: 75 };

/** States where dozing off is allowed: never during a task or an error. */
const SLEEPY_STATES = new Set<MascotState>(['idle', 'waiting']);

const S = {
  snap: { w: 32, z: 0.9 },
  pop: { w: 13, z: 0.5 },
  land: { w: 17, z: 0.6 },
  settle: { w: 9, z: 0.76 },
  slow: { w: 4.5, z: 1 },
  lid: SPRING.lid,
  drift: SPRING.drift,
} satisfies Record<string, SpringCfg>;

const cfgFor = (k: string): SpringCfg => (GAZE_KEYS.has(k) ? SPRING.saccade : EYE_KEYS.has(k) ? SPRING.lid : SPRING.posture);

const BODY_KEYS = new Set(['len', 'lean', 'bend', 'sq', 'hop', 'roll']);

export interface CompanionOptions {
  seed?: number;
  variant: CompanionVariant;
  feet?: boolean;
  autoSleep?: AutoSleep | null;
}

export class CompanionModel extends BaseModel {
  state: MascotState = 'idle';
  rest: RestPhase = 'awake';
  reacting: MascotReaction | null = null;
  /** Seconds without activity while the state allows dozing. */
  inactive = 0;
  readonly variant: CompanionVariant;
  private readonly big: boolean;
  private readonly P: ReturnType<typeof postures>;
  private readonly feet: boolean;
  private autoSleep: AutoSleep | null;
  private pending: MascotReaction | null = null;
  private glance: Partial<Pose> | null = null;
  private breathing = false;
  private pokes: number[] = [];
  private nearSince = -1;
  private shyCooldown = 0;
  private lastSeen = -Infinity;
  private line = 0;
  private lastStep = -1;
  private lookAt: Pt = { x: 0, y: 0 };
  private slowBlinkAt = -Infinity;
  /**
   * Amplitude (0…1) of each continuous rhythm. They fade in and out instead of switching on and
   * off, so entering or leaving working, waiting, thinking or sleep never changes the size at once.
   */
  private env = { work: 0, wait: 0, think: 0, breath: 0 };

  constructor({ seed = 7, variant, feet = false, autoSleep = DEFAULT_AUTO_SLEEP }: CompanionOptions) {
    super(restPose(variant), cfgFor, seed);
    this.variant = variant;
    this.big = variant === 'companion';
    this.P = postures(variant);
    this.feet = feet;
    this.autoSleep = autoSleep;
    if (feet && this.big) this.springs.snap({ feet: 1 });
    this.enterState();
  }

  // ——— Public API ———

  setState(state: MascotState) {
    if (state === this.state) return;
    this.state = state;
    this.inactive = 0;
    if (this.rest === 'waking') return; // waking ends into the current state
    if (this.rest !== 'awake') return this.startle(() => this.afterWake(state === 'error' ? 'oops' : null));
    if (state === 'error') return this.play('oops');
    if (this.reacting) return; // the reaction ends into the new state
    this.enterState();
  }

  react(reaction: MascotReaction) {
    this.inactive = 0;
    if (reaction === 'poke') {
      this.pokes = this.pokes.filter((t) => this.t - t < 2.5).concat(this.t);
      // Mischief has limits: a third poke in a row gets a look.
      if (this.pokes.length >= 3) {
        this.pokes = [];
        reaction = 'annoyed';
      }
    }
    if (this.rest === 'waking') {
      this.pending = reaction;
      return;
    }
    if (this.rest !== 'awake') return this.startle(() => this.afterWake(reaction));
    this.play(reaction);
  }

  /** The app reports activity (typing, scrolling…): resets the inactivity clock. */
  activity() {
    this.inactive = 0;
    if (this.rest === 'drowsy') this.startle(() => this.afterWake(null), true);
  }

  setAutoSleep(cfg: AutoSleep | null) {
    this.autoSleep = cfg;
  }

  /** Lab: fall asleep now (drowsy first). */
  sleepNow() {
    this.reacting = null;
    this.fallAsleep();
  }

  /** Lab / app: wake up now with the full waking choreography. */
  wakeNow() {
    if (this.rest === 'sleeping' || this.rest === 'drowsy') this.wakeUp();
  }

  /** Compatibility with the phase-1 lab controls. */
  setMode(mode: DemoMode) {
    this.mode = mode;
    if (mode === 'sleep') return this.sleepNow();
    if (mode === 'wake') return this.wakeNow();
    if (this.rest !== 'awake') this.wakeNow();
    this.setState(mode === 'working' ? 'working' : 'idle');
  }

  setGaze(target: Pt | null) {
    const had = this.gaze !== null;
    super.setGaze(target);
    if (!target) return;
    // Pointer movement is presence: it keeps the companion awake, and coming close wakes it.
    const d = this.distanceRatio(target);
    if (this.rest === 'drowsy') this.activity();
    else if (this.rest === 'sleeping' && d < 0.9) this.wakeUp();
    else if (this.rest === 'awake') this.inactive = 0;
    if (!had && this.t - this.lastSeen > 4 && this.rest === 'awake' && !this.reacting && this.state === 'idle') this.notice();
    this.lastSeen = this.t;
  }

  setReduced(reduced: boolean) {
    if (reduced === this.reduced) return;
    this.reduced = reduced;
    if (this.rest === 'drowsy' || this.rest === 'waking') this.rest = 'awake';
    if (this.rest === 'sleeping') return this.go({ ...this.P.asleep, ...EYES.closed });
    if (this.reacting) return this.finishReaction();
    this.enterState();
  }

  // ——— Engine plumbing ———

  protected enter() {
    // Scenes are entered explicitly (enterState, play, fallAsleep…).
  }

  wakeIn() {
    const next = super.wakeIn();
    if (!this.autoSleep || this.reacting) return next;
    if (this.rest === 'drowsy') return Math.min(next, Math.max(0, this.autoSleep.sleepAfter - this.inactive));
    if (this.rest !== 'awake' || !SLEEPY_STATES.has(this.state)) return next;
    return Math.min(next, Math.max(0, this.autoSleep.drowsyAfter - this.inactive));
  }

  isSettled() {
    return super.isSettled() && this.t - this.slowBlinkAt > 1.2;
  }

  protected continuous() {
    if (this.rhythmFading()) return true;
    if (this.reduced) return false;
    if (this.rest === 'sleeping') return this.breathing;
    if (this.rest !== 'awake' || this.reacting) return false;
    return this.state === 'working' || this.state === 'thinking' || this.state === 'waiting';
  }

  private go(pose: Partial<Pose>, spring?: SpringCfg) {
    for (const k of Object.keys(pose)) {
      const v = pose[k] as number;
      if (k === 'hop' && this.reduced) continue;
      this.springs.set(k, v, this.reduced ? SPRING.reduced : (spring ?? cfgFor(k)));
    }
  }

  /** Eyes by name, optionally with overrides. */
  private eyes(name: EyeName, extra: Partial<Pose> = {}, spring?: SpringCfg) {
    this.go({ ...EYES[name], ...extra }, spring);
  }

  /** Body relative to a posture: deltas scaled down on the small sign. */
  private body(delta: Partial<Pose>, spring?: SpringCfg, from: Partial<Pose> = this.statePosture()) {
    const out: Partial<Pose> = {};
    const amp = this.P.amp;
    for (const k of Object.keys(delta)) {
      const d = delta[k] as number;
      const base = (from[k] as number) ?? (k === 'hop' ? 0 : this.springs.goal(k));
      const scale = k === 'len' || k === 'hop' || k === 'bend' ? amp : this.big ? 1 : 0.6;
      out[k] = base + d * scale;
    }
    this.go(out, spring);
  }

  private kick(key: string, v: number) {
    if (this.reduced) return;
    const scale = key === 'len' || key === 'hop' || key === 'bend' ? this.P.amp : 1;
    this.springs.kick(key, v * scale);
  }

  private statePosture(): Partial<Pose> {
    return this.P[this.state === 'idle' ? 'upright' : this.state];
  }

  private distanceRatio(g: Pt) {
    const m = Math.min(0.999, Math.hypot(g.x, g.y));
    return m / Math.sqrt(1 - m * m);
  }

  private scheduleBlink(lo = 2.4, hi = 6) {
    if (this.reduced) return;
    this.at(this.between(lo, hi), () => {
      this.blink();
      if (this.rand() < 0.16) this.blink('both', 0.3);
      this.scheduleBlink(lo, hi);
    });
  }

  // ——— States ———

  private enterState() {
    this.cancelScheduled();
    this.glance = null;
    this.reacting = null;
    this.line = 0;
    this.lastStep = -1;
    const p = this.statePosture();
    switch (this.state) {
      case 'idle':
        this.go({ ...p, feet: this.feet && this.big ? 1 : 0 });
        this.eyes('neutral', { gx: 0.3, gy: -0.1 });
        this.scheduleBlink();
        this.scheduleIdle();
        break;
      case 'listening':
        this.go(p);
        this.eyes('open', { gx: 0.15, gy: 0.7 });
        this.scheduleBlink(2.8, 5.5);
        this.scheduleNods();
        break;
      case 'thinking':
        this.go(p, S.settle);
        this.eyes('ponder', { gx: -0.5, gy: -0.8 });
        this.scheduleBlink(3, 6);
        this.scheduleWander();
        break;
      case 'working':
        this.go(p, S.settle);
        this.eyes('focus', { gx: 0.55, gy: 0.55 });
        this.scheduleBlink(3.5, 7);
        break;
      case 'waiting':
        this.go(p);
        this.eyes('open', { gx: 0, gy: -0.08 });
        this.scheduleBlink(2.4, 5);
        this.scheduleWaiting();
        break;
      case 'error':
        this.go(p, S.settle);
        this.eyes('squint', { gx: -0.32, gy: 0.32 });
        this.scheduleBlink(3, 6);
        this.scheduleSheepish();
        break;
    }
  }

  /** Unprompted behaviour at rest, well spaced: the character lives without asking for attention. */
  private scheduleIdle() {
    if (this.reduced) return;
    this.at(this.between(this.big ? 5 : 7, this.big ? 10 : 13), () => {
      if (this.gaze) return this.scheduleIdle();
      const side = this.rand() < 0.5 ? -1 : 1;
      const r = this.rand();
      const end = (secs: number) =>
        this.at(secs, () => {
          this.glance = null;
          this.scheduleIdle();
        });
      if (!this.big) {
        // The small sign only glances.
        this.glance = { gx: side * 0.9, gy: 0, [`lid${side < 0 ? 'L' : 'R'}`]: 0.3 };
        return end(this.between(0.9, 1.4));
      }
      if (r < 0.28) {
        // A sly sideways look, one lid lower.
        this.glance = { lean: side * 0.2, bend: side * 8, gx: side, gy: 0, [`lid${side < 0 ? 'L' : 'R'}`]: 0.32 };
        end(this.between(1, 1.5));
      } else if (r < 0.46) {
        // Something above caught its eye.
        this.glance = { len: (this.P.upright.len as number) + 5, lean: -0.02, bend: -2, gy: -0.9, gx: side * 0.2, lidL: 0.02, lidR: 0.04 };
        end(this.between(1.1, 1.6));
      } else if (r < 0.62) {
        // Slow blink: the cat's sign of trust.
        this.slowBlinkAt = this.t;
        end(1.4);
      } else if (r < 0.78) {
        // Curious tilt.
        this.glance = { roll: side * 0.13, lean: side * 0.04, gx: side * 0.4, gy: -0.2, lidL: 0.04, lidR: 0.08 };
        end(this.between(1.1, 1.5));
      } else {
        // Re-settles in place.
        this.kick('sq', 0.9);
        this.kick('lean', side * 0.6);
        end(0.8);
      }
    });
  }

  private scheduleNods() {
    if (this.reduced) return;
    this.at(this.between(1.2, 2.1), () => {
      this.kick('bend', 24);
      this.kick('len', -10);
      this.scheduleNods();
    });
  }

  private scheduleWander() {
    if (this.reduced) return;
    const spots: Pt[] = [
      { x: -0.6, y: -0.85 },
      { x: 0.6, y: -0.8 },
      { x: -0.9, y: -0.2 },
      { x: 0.1, y: -1 },
      { x: 0.85, y: -0.35 },
    ];
    this.at(this.between(0.7, 1.6), () => {
      const glanceAtUs = this.rand() < 0.16;
      this.lookAt = glanceAtUs ? { x: 0, y: -0.1 } : spots[Math.floor(this.rand() * spots.length)];
      // Now and then, a "hmm": one lid lowers, the body settles.
      if (!glanceAtUs && this.rand() < 0.3) {
        const L = this.rand() < 0.5 ? 'L' : 'R';
        this.go({ [`lid${L}`]: 0.5 });
        this.kick('sq', 0.6);
        this.at(0.6, () => this.go({ [`lid${L}`]: EYES.ponder[`lid${L}`] as number }));
      }
      this.scheduleWander();
    });
  }

  private scheduleWaiting() {
    if (this.reduced) return;
    this.at(this.between(4, 7), () => {
      // A glance towards where the answer is expected, then back to us.
      this.glance = { gx: 0.75, gy: 0.65 };
      this.at(0.85, () => (this.glance = null));
      if (this.rand() < 0.35) this.at(1.4, () => this.hopOnce(2.6));
      this.scheduleWaiting();
    });
  }

  private scheduleSheepish() {
    if (this.reduced) return;
    this.at(this.between(4, 7), () => {
      this.glance = { gx: 0, gy: -0.05, lidL: 0.22, lidR: 0.25, lowL: 0.14, lowR: 0.14 };
      this.at(1.1, () => (this.glance = null));
      this.scheduleSheepish();
    });
  }

  private hopOnce(height: number) {
    this.body({ sq: 0.06 }, S.land);
    this.at(0.1, () => this.body({ hop: height, sq: -0.04 }, S.pop));
    this.at(0.32, () => this.body({ hop: 0, sq: 0.04 }, S.land));
    this.at(0.5, () => this.body({ sq: 0 }, S.settle));
  }

  /** The pointer came back after a while: a small "oh, hello". */
  private notice() {
    if (this.reduced || !this.big) return;
    this.go({ scaleL: 1.08, scaleR: 1.08, lidL: 0, lidR: 0 }, S.snap);
    this.kick('hop', 22);
    this.at(0.45, () => this.go({ scaleL: 1, scaleR: 1 }));
  }

  /** Targets of the continuous rhythms for the current situation. */
  private rhythmTargets() {
    const awake = !this.reduced && this.rest === 'awake' && !this.reacting;
    return {
      work: awake && this.state === 'working' ? 1 : 0,
      wait: awake && this.state === 'waiting' ? 1 : 0,
      think: awake && this.state === 'thinking' ? 1 : 0,
      breath: !this.reduced && this.rest === 'sleeping' && this.breathing ? 1 : 0,
    };
  }

  private rhythmFading() {
    const t = this.rhythmTargets();
    return (Object.keys(t) as Array<keyof typeof t>).some((k) => Math.abs(this.env[k] - t[k]) > 0.002);
  }

  /** Ease each rhythm's amplitude towards its target (≈ 0.45 s), frame-rate independent. */
  private easeRhythms(dt: number) {
    if (this.reduced) {
      this.env = { work: 0, wait: 0, think: 0, breath: 0 };
      return;
    }
    const t = this.rhythmTargets();
    const k = 1 - Math.exp(-dt / 0.45);
    for (const key of Object.keys(t) as Array<keyof typeof t>) {
      const next = this.env[key] + (t[key] - this.env[key]) * k;
      this.env[key] = Math.abs(next - t[key]) <= 0.002 ? t[key] : next;
    }
  }

  protected advanceQuiet(dt: number) {
    this.shyCooldown = Math.max(0, this.shyCooldown - dt);
    // Same rule as `update`: the inactivity clock runs while dozing is allowed. `wakeIn` stops the
    // quiet span at the next threshold, so the transition itself is animated by `update`.
    if (this.autoSleep && !this.reacting && ((this.rest === 'awake' && SLEEPY_STATES.has(this.state)) || this.rest === 'drowsy')) {
      this.inactive += dt;
    }
    this.easeRhythms(dt);
  }

  protected update(dt: number) {
    this.easeRhythms(dt);
    this.shyCooldown = Math.max(0, this.shyCooldown - dt);
    // Inactivity clock: only while awake, between performances, in a state that allows dozing.
    if (this.autoSleep && this.rest === 'awake' && !this.reacting && SLEEPY_STATES.has(this.state)) {
      this.inactive += dt;
      if (this.inactive >= this.autoSleep.drowsyAfter) this.becomeDrowsy();
    } else if (this.autoSleep && this.rest === 'drowsy') {
      this.inactive += dt;
      if (this.inactive >= this.autoSleep.sleepAfter) this.fallAsleep(true);
    }
    if (this.rest !== 'awake' || this.reacting || this.reduced) return;

    const p = this.statePosture();
    const g = this.gaze;
    switch (this.state) {
      case 'idle': {
        if (g) {
          const near = this.distanceRatio(g);
          const k = this.big ? 1 : 0.35;
          const lean = clamp(near < 1 ? 1.4 - near * 0.6 : 0.8, 0.8, 1.4);
          this.go({
            gx: clamp(g.x * 1.15, -1, 1),
            gy: clamp(g.y * 1.15, -1, 1),
            lean: (p.lean as number) + clamp(g.x * 0.17 * k * lean, -0.24, 0.24),
            bend: (p.bend as number) + clamp(g.x * 7 * k * lean, -9, 9),
            len: (p.len as number) + clamp(-g.y * 5 * k, -5, 5),
            lidL: near < 0.8 ? 0 : 0.05,
            lidR: near < 0.8 ? 0.02 : 0.1,
            scaleL: near < 0.6 ? 1.05 : 1,
            scaleR: near < 0.6 ? 1.05 : 1,
          });
          // Quick moves stretch the body a little; it settles back when still.
          this.go({ sq: -clamp(Math.abs(this.springs.velocity('lean')) * 0.05, 0, 0.05) });
          // Hovering right on it for a while makes it shy (mischievous, not needy).
          if (near < 0.35 && this.big) {
            if (this.nearSince < 0) this.nearSince = this.t;
            else if (this.t - this.nearSince > 1.4 && this.shyCooldown === 0) {
              this.shyCooldown = 12;
              this.nearSince = -1;
              this.play('shy');
            }
          } else this.nearSince = -1;
        } else if (this.gazeAge > 0.7) {
          this.go({ ...p, ...EYES.neutral, gx: 0.3, gy: -0.1, ...(this.glance ?? {}) });
        }
        break;
      }
      case 'listening':
        if (g) this.go({ gx: clamp(0.15 + g.x * 0.4, -1, 1) });
        break;
      case 'thinking':
        this.go({ gx: this.lookAt.x, gy: this.lookAt.y, lean: (p.lean as number) + this.lookAt.x * 0.05, roll: this.lookAt.x * 0.07 });
        break;
      case 'working': {
        // Reading in steps, like lines of code: three saccades, one long return.
        const period = 1.7;
        const step = Math.floor((this.modeT % period) / (period / 4));
        if (step !== this.lastStep) {
          if (step === 0 && this.lastStep !== -1) {
            this.line = (this.line + 1) % 5;
            this.kick('len', -14);
          }
          this.lastStep = step;
          this.go({ gx: [0.15, 0.4, 0.62, 0.85][step], gy: 0.42 + this.line * 0.06 });
        }
        break;
      }
      case 'waiting':
        if (this.glance) this.go(this.glance);
        else if (g) this.go({ gx: clamp(g.x * 1.1, -1, 1), gy: clamp(g.y * 1.1, -1, 1) });
        else this.go({ gx: 0, gy: -0.08 });
        break;
      case 'error':
        if (this.glance) this.go(this.glance);
        else this.go({ ...EYES.squint, gx: g ? clamp(g.x * 0.5, -0.6, 0.6) - 0.15 : -0.32, gy: g ? clamp(g.y * 0.4, -0.3, 0.6) : 0.32 });
        break;
    }
  }

  // ——— Reactions ———

  private play(reaction: MascotReaction) {
    this.cancelScheduled();
    this.reacting = reaction;
    this.glance = null;
    if (this.reduced) {
      // Reduced motion: the expression's key pose, held, then back. No travel, no bounce.
      this.go({ ...reactionKeyPose(reaction, this.variant) });
      this.at(1.2, () => this.finishReaction());
      return;
    }
    const duration = this.perform(reaction);
    this.at(duration, () => this.finishReaction());
  }

  private finishReaction() {
    this.reacting = null;
    const next = this.pending;
    this.pending = null;
    if (next) return this.play(next);
    this.enterState();
  }

  /** The performances. Each returns its length in seconds. */
  private perform(r: MascotReaction): number {
    const at = (t: number, fn: () => void) => this.at(t, fn);
    switch (r) {
      case 'greet':
        this.body({ sq: 0.08, len: -4 }, S.land);
        this.eyes('content');
        at(0.16, () => {
          this.body({ sq: -0.08, len: 10, hop: 6 }, S.pop);
          this.eyes('happy', { gx: 0, gy: -0.2 });
        });
        at(0.46, () => this.body({ hop: 0, sq: 0.06, len: 3 }, S.land));
        at(0.62, () => this.body({ sq: 0, lean: 0.12, bend: 4, roll: 0.05 }, S.settle));
        at(0.95, () => this.body({ lean: -0.1, bend: -4, roll: -0.05 }, S.settle));
        at(1.28, () => this.body({ lean: 0.07, bend: 2, roll: 0.03 }, S.settle));
        at(1.6, () => {
          this.body({ lean: 0, bend: 0, roll: 0, len: 0 }, S.settle);
          this.eyes('content', { gx: 0.1, gy: -0.1 });
        });
        return 2.1;

      case 'done':
        // Anticipation, a hop with happy eyes, landing, a content beat.
        this.body({ sq: 0.1, len: -5 }, S.land);
        this.go({ lidL: 0.22, lidR: 0.25 });
        at(0.14, () => {
          this.body({ hop: 9, sq: -0.1, len: 6 }, S.pop);
          this.eyes('happy', { gx: 0, gy: -0.2 });
        });
        at(0.42, () => this.body({ hop: 0, sq: 0.09, len: 0 }, S.land));
        at(0.6, () => {
          this.body({ sq: 0 }, S.settle);
          this.eyes('content', { gx: 0.1, gy: -0.1 });
        });
        return 1.5;

      case 'celebrate':
        this.body({ sq: 0.12, len: -6 }, S.land);
        this.eyes('happy', { gx: 0, gy: -0.3 });
        at(0.14, () => this.body({ hop: 10, sq: -0.1, len: 7, lean: 0.1, roll: 0.06 }, S.pop));
        at(0.42, () => this.body({ hop: 0, sq: 0.1, len: -3, lean: 0, roll: 0 }, S.land));
        at(0.56, () => this.body({ hop: 13, sq: -0.12, len: 9, lean: -0.12, roll: -0.08 }, S.pop));
        at(0.88, () => this.body({ hop: 0, sq: 0.1, len: 0, lean: 0, roll: 0 }, S.land));
        at(1.05, () => this.body({ sq: 0, lean: 0.08 }, S.settle));
        at(1.35, () => this.body({ lean: -0.06 }, S.settle));
        at(1.65, () => {
          this.body({ lean: 0 }, S.settle);
          this.eyes('content', { gx: 0.1, gy: -0.1 });
        });
        return 2.3;

      case 'surprised':
        // Eyes first, then the body recoils and stretches, holds, blinks, settles.
        this.eyes('wide', { gx: 0, gy: -0.15 }, S.snap);
        at(0.05, () => this.body({ lean: -0.13, bend: -4, len: 8, sq: -0.06 }, { w: 18, z: 0.6 }));
        at(0.6, () => this.blink());
        at(0.95, () => {
          this.body({ lean: 0, bend: 0, len: 0, sq: 0 }, S.settle);
          this.go({ scaleL: 1.05, scaleR: 1.05, ew: 1.04 });
        });
        return 1.5;

      case 'oops':
        // Squeezed > <, a duck and a little shake, then sheepish squinting eyes.
        this.eyes('squeeze', { gx: 0, gy: 0.1 }, S.snap);
        this.body({ sq: 0.12, len: -7, hop: 0 }, { w: 20, z: 0.6 });
        at(0.14, () => this.kick('lean', 2.2));
        at(0.26, () => this.kick('lean', -3));
        at(0.4, () => this.kick('lean', 1.8));
        at(0.58, () => {
          this.eyes('squint', { gx: -0.35, gy: 0.3 });
          this.body({ sq: 0.03, len: -4, roll: 0.08, lean: -0.05 }, S.settle);
        });
        return 1.3;

      case 'nod':
        this.eyes('content', { gx: 0.05, gy: 0.1 });
        for (const t of [0, 0.42]) {
          at(t, () => this.body({ bend: 9, len: -4, lean: 0.08 }, { w: 15, z: 0.65 }));
          at(t + 0.2, () => this.body({ bend: 0, len: 0, lean: 0 }, { w: 15, z: 0.65 }));
        }
        return 1.1;

      case 'shake':
        this.eyes('neutral', { lidL: 0.38, lidR: 0.4, gy: 0.1 });
        [0.1, 0.24, 0.38, 0.52].forEach((t, i) => at(t, () => this.body({ lean: (i % 2 ? -1 : 1) * 0.13 * (1 - i * 0.18), roll: (i % 2 ? -1 : 1) * 0.05 }, { w: 22, z: 0.7 })));
        at(0.68, () => this.body({ lean: 0, roll: 0 }, S.settle));
        return 1.1;

      case 'confused':
        this.eyes('confused', { gx: -0.3, gy: -0.4 }, S.lid);
        this.body({ roll: 0.2, lean: 0.06 }, S.settle);
        at(0.55, () => this.kick('len', 14));
        at(1.1, () => this.go({ gx: 0.3 }));
        at(1.5, () => this.body({ roll: 0, lean: 0 }, S.settle));
        return 1.9;

      case 'proud':
        this.body({ lean: -0.08, len: 6, bend: -2 }, S.settle);
        this.eyes('smug', { gx: 0, gy: -0.3 });
        at(0.8, () => this.hopOnce(3));
        at(1.5, () => this.body({ lean: 0, len: 0, bend: 0 }, S.settle));
        return 2;

      case 'sad':
        this.body({ len: -8, bend: 6, lean: 0.05, sq: 0.03 }, S.slow);
        this.eyes('sad', { gx: -0.1, gy: 0.55 }, S.slow);
        at(1.5, () => this.blink());
        at(1.9, () => this.body({ len: 0, bend: 0, lean: 0, sq: 0 }, S.slow));
        return 2.6;

      case 'annoyed':
        // "-_-": a slow look at us, a little huff, a look away.
        this.eyes('skeptical', { gx: 0, gy: -0.05 }, S.slow);
        at(0.6, () => {
          this.kick('sq', 0.8);
          this.kick('len', -10);
        });
        at(1, () => this.go({ gx: 0.75, gy: 0.05 }));
        at(1.5, () => this.body({ roll: -0.05 }, S.settle));
        return 2;

      case 'shy':
        this.eyes('shy', { gx: -0.75, gy: 0.4 });
        this.body({ sq: 0.05, lean: -0.08, roll: -0.08, len: -2 }, S.settle);
        at(1.1, () => this.go({ gx: -0.2, gy: 0.1 }));
        at(1.4, () => this.body({ sq: 0, lean: 0, roll: 0, len: 0 }, S.settle));
        return 1.9;

      case 'poke':
        // Squashed, a giggle, shaken off.
        this.body({ sq: 0.16, len: -6 }, { w: 26, z: 0.5 });
        this.eyes('happy', { gx: 0, gy: 0.1 }, S.snap);
        [0.12, 0.2, 0.28, 0.36].forEach((t, i) => at(t, () => this.kick('lean', i % 2 ? -1.2 : 1.2)));
        at(0.45, () => this.body({ sq: 0, len: 0 }, S.settle));
        at(0.75, () => this.eyes('content', { gx: 0.1, gy: -0.05 }));
        return 1.15;

      case 'yawn':
        this.body({ len: 10, sq: -0.08 }, S.slow);
        this.go({ lidL: 1, lidR: 1, curveL: -0.2, curveR: -0.2 }, { w: 5, z: 1 });
        at(1.2, () => {
          this.body({ len: 0, sq: 0.02 }, S.slow);
          this.go({ lidL: 0.42, lidR: 0.48, curveL: 0.06, curveR: 0.06 }, S.slow);
        });
        return 1.9;
    }
  }

  // ——— Rest: drowsy, asleep, waking ———

  private becomeDrowsy() {
    if (this.reduced) {
      this.rest = 'drowsy';
      this.go({ ...this.P.drowsy, ...EYES.sleepy });
      return;
    }
    this.cancelScheduled();
    this.rest = 'drowsy';
    this.go({ ...this.P.drowsy }, S.drift);
    this.eyes('sleepy', { gx: 0.1, gy: 0.3 }, S.drift);
    this.scheduleBlink(4, 7);
    // Fighting it: the head drops and catches itself, a yawn.
    const nod = () =>
      this.at(this.between(2.8, 4.6), () => {
        this.go({ len: (this.P.drowsy.len as number) - 6 * this.P.amp, lidL: 0.85, lidR: 0.9, gy: 0.6 }, { w: 5, z: 1 });
        this.at(0.65, () => {
          this.go({ len: this.P.drowsy.len as number, lidL: 0.3, lidR: 0.34, gy: 0.2 }, { w: 15, z: 0.7 });
          this.blink('both', 0.12);
        });
        this.at(1.3, () => this.go({ ...EYES.sleepy, gy: 0.3 }, S.drift));
        nod();
      });
    nod();
    if (this.big) this.at(1.5, () => this.yawnInPlace());
  }

  private yawnInPlace() {
    this.go({ len: (this.P.drowsy.len as number) + 10, sq: -0.08, lidL: 1, lidR: 1, curveL: -0.2, curveR: -0.2 }, { w: 5, z: 1 });
    this.at(1.2, () => this.go({ ...this.P.drowsy, ...EYES.sleepy }, S.slow));
  }

  /** The falling-asleep choreography from the phase-1 lab, kept as it was. */
  private fallAsleep(fromDrowsy = false) {
    this.cancelScheduled();
    this.rest = 'sleeping';
    this.breathing = false;
    if (this.reduced) {
      this.go({ ...this.P.asleep, ...EYES.closed, feet: 0 });
      return;
    }
    const big = this.big;
    if (!fromDrowsy) this.go({ ...EYES.sleepy, len: big ? 22 : 8, bend: big ? 6 : 2, lean: 0.12, gy: 0.35, gx: 0.15, sq: 0, hop: 0, roll: 0 }, S.drift);
    const t0 = fromDrowsy ? -0.6 : 0;
    // Nods off, catches itself, then settles into a low, wide rest.
    this.at(1.3 + t0, () => this.go({ len: big ? 13 : 6, bend: big ? 9 : 3, lidL: 0.85, lidR: 0.9, gy: 0.6 }, { w: 5, z: 1 }));
    this.at(1.95 + t0, () => {
      this.go({ len: big ? 27 : 10, bend: 2, lidL: 0.2, lidR: 0.24, gy: 0 }, { w: 15, z: 0.7 });
      this.blink('both', 0.12);
    });
    this.at(2.7 + t0, () => this.go({ len: big ? 16 : 7, bend: big ? 5 : 2, lidL: 0.7, lidR: 0.75, gy: 0.4 }, S.drift));
    this.at(3.4 + t0, () => this.go({ ...this.P.asleep, ...EYES.closed, gx: 0.05, gy: 0.35, feet: 0 }, { w: 3.6, z: 1 }));
    this.at(4.6 + t0, () => (this.breathing = true));
  }

  /** The waking choreography from the phase-1 lab: one eye first, a stretch, a shake-off. */
  private wakeUp() {
    this.cancelScheduled();
    this.rest = 'waking';
    this.breathing = false;
    this.inactive = 0;
    const up = { ...this.statePosture(), feet: this.feet && this.big ? 1 : 0 };
    if (this.reduced) {
      this.go({ ...up, ...EYES.neutral });
      this.at(0.4, () => this.afterWake(null));
      return;
    }
    const big = this.big;
    this.go({ lidR: 0.45, curveR: 0, sq: 0.04, gy: 0.2 }, S.lid);
    this.at(0.35, () => this.go({ lidR: 0.08, lidL: 0.5, curveL: 0 }));
    this.at(0.65, () =>
      this.go({ len: big ? 46 : 15, sq: -0.07, lidL: 0, lidR: 0, scaleL: 1.14, scaleR: 1.14, ew: 1.1, gy: -0.6, gx: 0, lean: 0, bend: 0, feet: up.feet }, { w: 8, z: 0.6 }),
    );
    this.at(1.35, () => {
      this.go({ ...up, ...EYES.neutral, gx: 0.3, gy: -0.1 }, { w: 9, z: 0.75 });
      this.springs.kick('lean', 1.6);
    });
    this.at(1.6, () => this.springs.kick('lean', -2.2));
    this.at(1.9, () => this.blink());
    this.at(2.4, () => this.afterWake(null));
  }

  /** Woken by an event: a quick startle instead of the slow stretch. */
  private startle(then: () => void, light = false) {
    this.cancelScheduled();
    this.rest = 'waking';
    this.breathing = false;
    this.inactive = 0;
    if (this.reduced) {
      this.go({ ...this.statePosture(), ...EYES.neutral });
      this.at(0.3, then);
      return;
    }
    this.go({ ...this.statePosture(), ...EYES.wide, gx: 0, gy: -0.1 }, S.snap);
    if (!light) this.body({ len: 8, hop: 3, sq: -0.06 }, S.pop);
    this.at(0.3, () => this.blink());
    this.at(0.45, () => this.body({ len: 0, hop: 0, sq: 0 }, S.land));
    this.at(light ? 0.5 : 0.75, then);
  }

  private afterWake(reaction: MascotReaction | null) {
    this.rest = 'awake';
    this.inactive = 0;
    const next = reaction ?? this.pending;
    this.pending = null;
    if (next) this.play(next);
    else this.enterState();
  }

  // ——— Output ———

  pose(): Pose {
    const p = { ...this.springs.x };
    const bl = this.blinkAmount(0);
    const br = this.blinkAmount(1);
    if (bl > 0) p.lidL = lerp(p.lidL, 1, bl);
    if (br > 0) p.lidR = lerp(p.lidR, 1, br);
    const sb = slowBlink(this.t - this.slowBlinkAt);
    if (sb > 0) {
      p.lidL = lerp(p.lidL, 1, sb);
      p.lidR = lerp(p.lidR, 1, sb);
      p.curveL += 0.2 * sb;
      p.curveR += 0.2 * sb;
    }
    if (this.reduced) {
      p.hop = 0;
      return p;
    }
    // Continuous rhythms, each scaled by its fading amplitude (see `env`).
    const { work, wait, think, breath } = this.env;
    if (work > 0) {
      const ph = this.t * 2 * Math.PI * 1.85;
      p.len += work * (this.big ? 1.3 : 0.5) * Math.sin(ph);
      p.lean += work * 0.012 * Math.sin(ph);
    }
    if (wait > 0) p.lean += wait * 0.028 * Math.sin(this.t * 2 * Math.PI * 0.32) * (this.big ? 1 : 0.5);
    if (think > 0) p.lean += think * 0.01 * Math.sin(this.t * 2 * Math.PI * 0.27);
    if (breath > 0) p.sq += breath * 0.02 * Math.sin(this.t * 2 * Math.PI * 0.22);
    return p;
  }
}

/** A slow, deliberate blink: close, hold, open (1.15 s). */
function slowBlink(t: number) {
  if (t < 0 || t > 1.15) return 0;
  const ease = (x: number) => x * x * (3 - 2 * x);
  if (t < 0.45) return ease(t / 0.45);
  if (t < 0.6) return 1;
  return 1 - ease((t - 0.6) / 0.55);
}

/** Representative still pose of a reaction: used under reduced motion and in the gallery. */
export function reactionKeyPose(r: MascotReaction, variant: CompanionVariant): Partial<Pose> {
  const P = postures(variant);
  const u = P.upright as Record<string, number>;
  const a = P.amp;
  const body = (d: Partial<Pose>) => {
    const out: Partial<Pose> = { ...u };
    for (const k of Object.keys(d)) out[k] = (u[k] ?? 0) + (d[k] as number) * (BODY_KEYS.has(k) && ['len', 'hop', 'bend'].includes(k) ? a : 1);
    return out;
  };
  switch (r) {
    case 'greet':
      return { ...body({ lean: 0.1, bend: 3, roll: 0.05 }), ...EYES.happy, gx: 0, gy: -0.2 };
    case 'done':
      return { ...body({ len: 3 }), ...EYES.happy, gx: 0, gy: -0.2 };
    case 'celebrate':
      return { ...body({ len: 6, lean: -0.1, roll: -0.06 }), ...EYES.happy, gx: 0, gy: -0.3 };
    case 'surprised':
      return { ...body({ lean: -0.13, bend: -4, len: 8, sq: -0.06 }), ...EYES.wide, gx: 0, gy: -0.15 };
    case 'oops':
      return { ...body({ sq: 0.1, len: -6 }), ...EYES.squeeze, gx: 0, gy: 0.1 };
    case 'nod':
      return { ...body({ bend: 8, len: -4, lean: 0.06 }), ...EYES.content, gx: 0.05, gy: 0.2 };
    case 'shake':
      return { ...body({ lean: 0.12, roll: 0.05 }), ...EYES.neutral, lidL: 0.38, lidR: 0.4, gy: 0.1 };
    case 'confused':
      return { ...body({ roll: 0.2, lean: 0.06 }), ...EYES.confused, gx: -0.3, gy: -0.4 };
    case 'proud':
      return { ...body({ lean: -0.08, len: 6, bend: -2 }), ...EYES.smug, gx: 0, gy: -0.3 };
    case 'sad':
      return { ...body({ len: -8, bend: 6, lean: 0.05, sq: 0.03 }), ...EYES.sad, gx: -0.1, gy: 0.55 };
    case 'annoyed':
      return { ...body({ roll: -0.05 }), ...EYES.skeptical, gx: 0.6, gy: 0 };
    case 'shy':
      return { ...body({ sq: 0.05, lean: -0.08, roll: -0.08, len: -2 }), ...EYES.shy, gx: -0.75, gy: 0.4 };
    case 'poke':
      return { ...body({ sq: 0.14, len: -6 }), ...EYES.happy, gx: 0, gy: 0.1 };
    case 'yawn':
      return { ...body({ len: 10, sq: -0.08 }), ...EYES.closed, curveL: -0.2, curveR: -0.2 };
  }
}

/** Still pose of a state (static renders, gallery, reduced motion). */
export function stateKeyPose(s: MascotState | 'drowsy' | 'asleep', variant: CompanionVariant): Partial<Pose> {
  const P = postures(variant);
  switch (s) {
    case 'idle':
      return { ...P.upright, ...EYES.neutral, gx: 0.3, gy: -0.1 };
    case 'listening':
      return { ...P.listening, ...EYES.open, gx: 0.15, gy: 0.7 };
    case 'thinking':
      return { ...P.thinking, ...EYES.ponder, gx: -0.5, gy: -0.8, roll: -0.035 };
    case 'working':
      return { ...P.working, ...EYES.focus, gx: 0.55, gy: 0.55 };
    case 'waiting':
      return { ...P.waiting, ...EYES.open, gx: 0, gy: -0.08 };
    case 'error':
      return { ...P.error, ...EYES.squint, gx: -0.32, gy: 0.32 };
    case 'drowsy':
      return { ...P.drowsy, ...EYES.sleepy, gx: 0.1, gy: 0.3 };
    case 'asleep':
      return { ...P.asleep, ...EYES.closed, gx: 0.05, gy: 0.35 };
  }
}
