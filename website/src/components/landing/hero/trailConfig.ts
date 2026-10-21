/**
 * Every value that shapes the hero's cursor trail. Nothing here is final until it has been
 * validated visually — tune live with `?tune` (dev / preview builds only).
 */
export interface TrailConfig {
  /** Invisible monospace grid, CSS px. */
  cellW: number;
  cellH: number;
  fontPx: number;
  /** Radius of the disturbance around the pointer path, px. */
  radius: number;
  /** Share of glyph runs inside the radius that light up (0–1). Lower = sparser texture. */
  density: number;
  /** Cells are lit in horizontal runs of this length, so glyphs form rows rather than dust. */
  runLength: number;
  /** Intensity of a slow pass; a normal-speed move is always visible thanks to this floor. */
  gainMin: number;
  gainMax: number;
  /** Pointer speed (px/s) that adds +1 gain above the floor. */
  speedRef: number;
  maxPointerSpeed: number;
  /** Share of the pointer velocity a cell inherits (its own inertia). */
  inherit: number;
  /** Seconds for a cell's intensity to halve. Drives how long the trail persists. */
  intensityHalfLife: number;
  /** Seconds for a cell's own velocity to halve (how long the shape keeps drifting). */
  velocityHalfLife: number;
  /** Multiplier on the transport of intensity along each cell's velocity. */
  transport: number;
  /** Share of intensity spread to neighbours per second (soft edges). */
  diffusion: number;
  /** Low-frequency drift so the shape keeps evolving as it fades, px/s. */
  noiseAmp: number;
  noiseScale: number;
  noiseSpeed: number;
  /** Glyph changes per second per cell (subtle scramble). */
  scramble: number;
  alphaMax: number;
  /** Below 1, faint cells stay visible longer, so the fade reads as gradual rather than abrupt. */
  alphaGamma: number;
  /** Cells below this intensity are dropped. */
  threshold: number;
  maxCells: number;
  /** Largest simulated step, s (a stalled frame never jumps the simulation). */
  maxDt: number;
  /** A pause or jump larger than these starts a new stroke instead of drawing a line across. */
  resumeGapMs: number;
  resumeGapPx: number;
  /** Trail strength over the headline and buttons (0–1), and the soft edge of that mask, px. */
  textDim: number;
  textFeather: number;
}

export const DEFAULT_TRAIL_CONFIG: TrailConfig = {
  cellW: 11,
  cellH: 17,
  fontPx: 13,
  radius: 64,
  density: 0.8,
  runLength: 5,
  gainMin: 0.7,
  gainMax: 1.25,
  speedRef: 1600,
  maxPointerSpeed: 2600,
  inherit: 0.45,
  intensityHalfLife: 0.45,
  velocityHalfLife: 0.5,
  transport: 1,
  diffusion: 0.5,
  noiseAmp: 30,
  noiseScale: 170,
  noiseSpeed: 0.45,
  scramble: 5,
  alphaMax: 0.72,
  alphaGamma: 0.7,
  threshold: 0.025,
  maxCells: 1600,
  maxDt: 0.05,
  resumeGapMs: 160,
  resumeGapPx: 160,
  textDim: 0.3,
  textFeather: 56,
};
