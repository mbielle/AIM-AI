export interface Pt {
  x: number;
  y: number;
}

/** Phase-1 demo behaviours. Product states (thinking, done, oops…) come in phase 2. */
export type DemoMode = 'attention' | 'working' | 'sleep' | 'wake';

/**
 * - `icon`: the smallest sign (favicon, 16–24 px).
 * - `mark`: the static logo used next to the wordmark.
 * - `stage`: the animated character, with room around it to move.
 */
export type Variant = 'icon' | 'mark' | 'stage';

export interface Palette {
  body: string;
  eye: string;
}

/** A pose is a flat bag of numbers so every parameter can be sprung and interpolated. */
export type Pose = Record<string, number>;
/** Applying a partial pose must not replace a numeric rest value with undefined. */
export function mergePose(base: Pose, ...changes: Partial<Pose>[]): Pose {
  const merged = { ...base };
  for (const change of changes) for (const [key, value] of Object.entries(change)) {
    if (typeof value === 'number') merged[key] = value;
  }
  return merged;
}

/** Geometry for one rendered frame, as SVG path data in viewBox units. */
export interface Frame {
  /** Filled in the body colour. */
  fills: string;
  /** Stroked in the body colour (round caps and joins). */
  strokes?: string;
  strokeWidth?: number;
  /** Filled in the eye colour, drawn above the body. */
  eyes: string;
}

export interface ConceptOptions {
  /** A: where the eyes rest when nothing draws attention. */
  restGaze?: 'three-quarter' | 'front';
  /** C: two small filled feet in the large formats. */
  feet?: boolean;
}

export interface DrawOptions extends ConceptOptions {
  /** Rendered size in CSS pixels, used for optical sizing. */
  size: number;
  variant: Variant;
}

export interface MascotModel {
  readonly mode: DemoMode;
  setMode(mode: DemoMode): void;
  /** Normalised gaze target (roughly -1…1 on each axis), or null when nothing to look at. */
  setGaze(target: Pt | null): void;
  setReduced(reduced: boolean): void;
  tick(dt: number): void;
  /** Nothing moves until the next scheduled event. */
  isSettled(): boolean;
  /** Seconds until the next scheduled event (Infinity when none). */
  wakeIn(): number;
  /** Advance time without rendering (used after being parked). */
  skip(seconds: number): void;
  pose(): Pose;
}

export interface Concept {
  id: 'a' | 'b' | 'c';
  letter: 'A' | 'B' | 'C';
  name: string;
  principle: string;
  viewBox(variant: Variant): [number, number, number, number];
  /** Which variant a static sign should use at a given pixel size. */
  variantForSize(size: number): Variant;
  staticPose(mode: DemoMode, variant: Variant, options?: ConceptOptions): Pose;
  draw(pose: Pose, options: DrawOptions): Frame;
  createModel(options: { seed?: number; variant: Variant; options?: ConceptOptions }): MascotModel;
}
