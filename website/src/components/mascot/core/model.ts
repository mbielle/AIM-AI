import { BLINK_LENGTH, SPRING, Springs, blinkCurve, mulberry32, type SpringCfg } from './motion';
import type { DemoMode, MascotModel, Pose, Pt } from './types';

interface Scheduled {
  at: number;
  epoch: number;
  fn: () => void;
}

/**
 * Shared choreography plumbing: a clock, springs for the pose, a scheduler whose events are
 * cancelled when the mode changes, seeded randomness and blinks. Concepts only describe what
 * each mode wants.
 */
export abstract class BaseModel implements MascotModel {
  mode: DemoMode = 'attention';
  /** Model time and time since the current mode started, in seconds. */
  t = 0;
  modeT = 0;
  reduced = false;
  gaze: Pt | null = null;
  /** Time since the gaze target was last set or lost. */
  gazeAge = 0;
  readonly springs: Springs;
  protected readonly rand: () => number;
  private events: Scheduled[] = [];
  private epoch = 0;
  /** Blink start times, per eye (index 0 left, 1 right). */
  private blinks: [number, number] = [-Infinity, -Infinity];

  constructor(initial: Pose, cfgFor: (key: string) => SpringCfg, seed = 1) {
    this.springs = new Springs(initial, cfgFor);
    this.rand = mulberry32(seed);
  }

  /** Called on entering a mode; set targets and schedule the mode's events. */
  protected abstract enter(mode: DemoMode): void;
  /** Called every tick before the springs step; set continuous targets. */
  protected abstract update(dt: number): void;
  /**
   * Time passing while parked (nothing moves): advance time-based counters such as an inactivity
   * clock, without starting anything. Starting things is `update`'s job, at the right time.
   */
  protected advanceQuiet(_dt: number) {}
  /** True while something moves continuously (breathing, working rhythm). */
  protected abstract continuous(): boolean;
  /** Current pose including procedural layers (blink, rhythm, breathing). */
  abstract pose(): Pose;

  start(mode: DemoMode = 'attention') {
    this.mode = mode;
    this.enter(mode);
  }

  setMode(mode: DemoMode) {
    if (mode === this.mode) return;
    this.mode = mode;
    this.modeT = 0;
    this.epoch++;
    this.events = this.events.filter((e) => e.epoch === -1);
    this.enter(mode);
  }

  setGaze(target: Pt | null) {
    const had = this.gaze !== null;
    if (target === null && !had) return;
    if (target && this.gaze && Math.abs(target.x - this.gaze.x) < 1e-3 && Math.abs(target.y - this.gaze.y) < 1e-3) return;
    this.gaze = target;
    this.gazeAge = 0;
  }

  setReduced(reduced: boolean) {
    if (reduced === this.reduced) return;
    this.reduced = reduced;
    this.epoch++;
    this.events = [];
    this.enter(this.mode);
  }

  /** Drop every scheduled event (a new scene takes over). */
  protected cancelScheduled() {
    this.epoch++;
    this.events = [];
  }

  /** Schedule `fn` after `delay` seconds; dropped if the mode changes first. */
  protected at(delay: number, fn: () => void) {
    this.events.push({ at: this.t + delay, epoch: this.epoch, fn });
    this.events.sort((a, b) => a.at - b.at);
  }

  protected between(lo: number, hi: number) {
    return lo + (hi - lo) * this.rand();
  }

  protected blink(eye: 'both' | 0 | 1 = 'both', delay = 0) {
    const start = this.t + delay;
    if (eye === 'both' || eye === 0) this.blinks[0] = start;
    if (eye === 'both' || eye === 1) this.blinks[1] = start;
  }

  /** Blink closure 0…1 for one eye. */
  protected blinkAmount(eye: 0 | 1) {
    return blinkCurve(this.t - this.blinks[eye]);
  }

  private blinking() {
    return this.t - Math.min(this.blinks[0], this.blinks[1]) < BLINK_LENGTH || this.t - Math.max(this.blinks[0], this.blinks[1]) < BLINK_LENGTH;
  }

  /** Spring config for posture keys, swapped for a short settle under reduced motion. */
  protected cfg(base: SpringCfg) {
    return this.reduced ? SPRING.reduced : base;
  }

  tick(dt: number) {
    this.t += dt;
    this.modeT += dt;
    this.gazeAge += dt;
    while (this.events.length && this.events[0].at <= this.t) {
      const e = this.events.shift()!;
      if (e.epoch === this.epoch) e.fn();
    }
    this.update(dt);
    this.springs.step(dt);
  }

  /**
   * Catch up on time spent parked. Nothing moved during that time, so the clocks simply run up to
   * the next scheduled event (or threshold); only what is left after it is simulated, in frame-sized
   * steps. Stepping the whole gap at once would jump straight to the end of whatever motion that
   * event starts — the “snap” seen when dozing off after a quiet period.
   */
  skip(seconds: number) {
    if (seconds <= 0) return;
    const quiet = Math.min(seconds, this.wakeIn());
    if (quiet > 0) {
      this.t += quiet;
      this.modeT += quiet;
      this.gazeAge += quiet;
      this.advanceQuiet(quiet);
    }
    let rest = seconds - quiet;
    while (rest > 1e-6) {
      const d = Math.min(1 / 60, rest);
      this.tick(d);
      rest -= d;
    }
  }

  isSettled() {
    return !this.continuous() && !this.blinking() && this.springs.settled();
  }

  wakeIn() {
    const next = this.events.find((e) => e.epoch === this.epoch);
    return next ? Math.max(0, next.at - this.t) : Infinity;
  }
}
