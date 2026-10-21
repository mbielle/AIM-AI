import { useState } from 'react';
import { DEFAULT_TRAIL_CONFIG, type TrailConfig } from './trailConfig';
import { TRAIL_CONFIG_EVENT } from './CodeTrailCanvas';

type Key = keyof TrailConfig;
const RANGES: Partial<Record<Key, [number, number, number]>> = {
  radius: [16, 120, 1],
  density: [0.1, 1, 0.01],
  runLength: [1, 10, 1],
  gainMin: [0, 1.2, 0.01],
  gainMax: [0.2, 1.6, 0.01],
  speedRef: [200, 4000, 50],
  inherit: [0, 1, 0.01],
  intensityHalfLife: [0.08, 1.2, 0.01],
  velocityHalfLife: [0.05, 1.5, 0.01],
  transport: [0, 3, 0.05],
  diffusion: [0, 3, 0.05],
  noiseAmp: [0, 120, 1],
  noiseScale: [40, 600, 5],
  noiseSpeed: [0, 3, 0.05],
  scramble: [0, 20, 0.5],
  alphaMax: [0.1, 1, 0.01],
  alphaGamma: [0.3, 1.5, 0.05],
  textDim: [0, 1, 0.01],
  cellW: [8, 24, 1],
  cellH: [10, 28, 1],
  fontPx: [8, 18, 1],
};

/** Dev/preview-only panel to tune the trail live (`?tune`). Never shipped in production builds. */
export default function TrailTuner({ config }: { config: TrailConfig }) {
  const [, force] = useState(0);
  const [open, setOpen] = useState(true);
  const set = (key: Key, value: number) => {
    (config as Record<Key, number>)[key] = value;
    window.dispatchEvent(new Event(TRAIL_CONFIG_EVENT));
    force((n) => n + 1);
  };
  const changed = (Object.keys(RANGES) as Key[]).filter((k) => config[k] !== DEFAULT_TRAIL_CONFIG[k]);
  return (
    <div className="fixed bottom-4 left-4 z-[100] w-[300px] rounded-xl border border-white/10 bg-black/80 p-3 font-mono text-[11px] text-white/80 backdrop-blur">
      <div className="mb-2 flex items-center justify-between">
        <span>Trail tuner</span>
        <button type="button" className="text-white/60 hover:text-white" onClick={() => setOpen((o) => !o)}>
          {open ? 'hide' : 'show'}
        </button>
      </div>
      {open && (
        <div className="max-h-[60vh] space-y-1.5 overflow-auto pr-1">
          {(Object.keys(RANGES) as Key[]).map((key) => {
            const [min, max, step] = RANGES[key]!;
            return (
              <label key={key} className="grid grid-cols-[110px_1fr_42px] items-center gap-2">
                <span className="truncate">{key}</span>
                <input type="range" min={min} max={max} step={step} value={config[key]} onChange={(e) => set(key, Number(e.target.value))} />
                <span className="text-right tabular-nums">{config[key]}</span>
              </label>
            );
          })}
          <button
            type="button"
            className="mt-2 w-full rounded-md border border-white/15 py-1.5 hover:bg-white/10"
            onClick={() => navigator.clipboard?.writeText(JSON.stringify(Object.fromEntries(changed.map((k) => [k, config[k]])), null, 2))}
          >
            Copy changed values ({changed.length})
          </button>
        </div>
      )}
    </div>
  );
}
