import type { Pose } from './types';

/** Angular frequency (rad/s) and damping ratio (≤ 1). */
export interface SpringCfg {
  w: number;
  z: number;
}

export const SPRING = {
  /** Eye saccades: fast and precise. */
  saccade: { w: 34, z: 0.92 },
  /** Lids and eye shape. */
  lid: { w: 22, z: 1 },
  /** Head or body posture: calm, a touch of follow-through. */
  posture: { w: 9, z: 0.78 },
  /** Slow drift (sinking into sleep). */
  drift: { w: 3.2, z: 1 },
  /** Reduced motion: a short, overshoot-free settle. */
  reduced: { w: 30, z: 1 },
} satisfies Record<string, SpringCfg>;

/**
 * Exact step of a damped spring towards a constant target. Being analytic, the result after
 * one second is the same at 30, 60 or 120 Hz, which keeps rhythms identical across displays.
 */
export function springStep(x: number, v: number, target: number, cfg: SpringCfg, dt: number): [number, number] {
  if (dt <= 0) return [x, v];
  const { w, z } = cfg;
  const x0 = x - target;
  if (z >= 1) {
    const e = Math.exp(-w * dt);
    const c = v + w * x0;
    return [target + (x0 + c * dt) * e, (v - w * c * dt) * e];
  }
  const wd = w * Math.sqrt(1 - z * z);
  const e = Math.exp(-z * w * dt);
  const cos = Math.cos(wd * dt);
  const sin = Math.sin(wd * dt);
  const b = (v + z * w * x0) / wd;
  return [target + e * (x0 * cos + b * sin), e * (v * cos - (x0 * wd + z * w * b) * sin)];
}

/** A set of named springs that together hold a pose. */
export class Springs {
  readonly x: Pose;
  private v: Pose = {};
  private target: Pose = {};
  private cfg: Record<string, SpringCfg> = {};

  constructor(initial: Pose, cfgFor: (key: string) => SpringCfg) {
    this.x = { ...initial };
    for (const k of Object.keys(initial)) {
      this.v[k] = 0;
      this.target[k] = initial[k];
      this.cfg[k] = cfgFor(k);
    }
  }

  set(key: string, target: number, cfg?: SpringCfg) {
    this.target[key] = target;
    if (cfg) this.cfg[key] = cfg;
  }

  setMany(pose: Partial<Pose>, cfg?: SpringCfg) {
    for (const k of Object.keys(pose)) this.set(k, pose[k] as number, cfg);
  }

  /** Jump to a value with no motion (used by reduced motion and static renders). */
  snap(pose: Partial<Pose>) {
    for (const k of Object.keys(pose)) {
      this.x[k] = pose[k] as number;
      this.target[k] = pose[k] as number;
      this.v[k] = 0;
    }
  }

  kick(key: string, velocity: number) {
    this.v[key] += velocity;
  }

  velocity(key: string) {
    return this.v[key];
  }

  goal(key: string) {
    return this.target[key];
  }

  step(dt: number) {
    for (const k in this.x) {
      const [x, v] = springStep(this.x[k], this.v[k], this.target[k], this.cfg[k], dt);
      this.x[k] = x;
      this.v[k] = v;
    }
  }

  settled(eps = 2e-3) {
    for (const k in this.x) {
      if (Math.abs(this.x[k] - this.target[k]) > eps || Math.abs(this.v[k]) > eps * 10) return false;
    }
    return true;
  }
}

/** Deterministic PRNG so the lab, the tests and the recordings replay identically. */
export function mulberry32(seed: number) {
  let a = seed >>> 0;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

export const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));
export const lerp = (a: number, b: number, t: number) => a + (b - a) * t;
export const smoothstep = (e0: number, e1: number, x: number) => {
  const t = clamp((x - e0) / (e1 - e0), 0, 1);
  return t * t * (3 - 2 * t);
};

/** Blink closure over time: quick close, tiny hold, slower open. Returns 0…1. */
export function blinkCurve(t: number, close = 0.07, hold = 0.035, open = 0.12) {
  if (t < 0) return 0;
  if (t < close) return smoothstep(0, close, t);
  if (t < close + hold) return 1;
  if (t < close + hold + open) return 1 - smoothstep(0, open, t - close - hold);
  return 0;
}
export const BLINK_LENGTH = 0.07 + 0.035 + 0.12;

// Reduced motion: the OS setting, live, with a lab override.
const query = typeof window !== 'undefined' && window.matchMedia ? window.matchMedia('(prefers-reduced-motion: reduce)') : null;
let override: boolean | null = null;
const listeners = new Set<() => void>();
const notify = () => listeners.forEach((l) => l());
query?.addEventListener?.('change', notify);

export function prefersReducedMotion() {
  return override ?? query?.matches ?? false;
}
export function setReducedMotionOverride(value: boolean | null) {
  override = value;
  notify();
}
export function subscribeReducedMotion(listener: () => void) {
  listeners.add(listener);
  return () => listeners.delete(listener);
}
