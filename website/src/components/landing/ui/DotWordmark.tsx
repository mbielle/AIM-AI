import { useId } from 'react';

/**
 * The large “AIM” closing the footer: the letters are filled with a regular grid of small dots
 * that fades out towards the bottom. One static SVG (a dot pattern masked by the text) — no DOM
 * element per dot, nothing animated.
 */
export function DotWordmark({ className }: { className?: string }) {
  const id = useId().replace(/:/g, '');
  return (
    <svg viewBox="0 0 1000 330" className={className} aria-hidden="true" focusable="false">
      <defs>
        <pattern id={`${id}-dots`} width="7" height="7" patternUnits="userSpaceOnUse">
          <circle cx="3.5" cy="3.5" r="1.55" fill="#9EA9B8" />
        </pattern>
        <linearGradient id={`${id}-fade`} x1="0" y1="0" x2="0" y2="1">
          <stop offset="0" stopColor="#fff" stopOpacity="1" />
          <stop offset="0.55" stopColor="#fff" stopOpacity="0.75" />
          <stop offset="1" stopColor="#fff" stopOpacity="0" />
        </linearGradient>
        <mask id={`${id}-mask`} maskUnits="userSpaceOnUse" x="0" y="0" width="1000" height="330">
          <text
            x="500"
            y="350"
            textAnchor="middle"
            fill={`url(#${id}-fade)`}
            style={{ font: '700 420px Inter, ui-sans-serif, system-ui, sans-serif', letterSpacing: '-0.03em' }}
          >
            AIM
          </text>
        </mask>
      </defs>
      <rect width="1000" height="330" fill={`url(#${id}-dots)`} mask={`url(#${id}-mask)`} />
    </svg>
  );
}
