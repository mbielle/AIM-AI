import { useLayoutEffect, useRef, useState, type ReactNode } from 'react';

interface ScaledScreenProps {
  /** Size the screen is designed at, px. It is scaled as a whole, like a screenshot. */
  width: number;
  height: number;
  children: ReactNode;
  className?: string;
}

/** Renders a fixed-size design and scales it to the available width, preserving composition. */
export function ScaledScreen({ width, height, children, className }: ScaledScreenProps) {
  const outer = useRef<HTMLDivElement>(null);
  const [scale, setScale] = useState(1);

  useLayoutEffect(() => {
    const el = outer.current;
    if (!el) return;
    const update = () => setScale(el.clientWidth / width);
    update();
    const ro = new ResizeObserver(update);
    ro.observe(el);
    return () => ro.disconnect();
  }, [width]);

  return (
    <div ref={outer} className={className} style={{ aspectRatio: `${width} / ${height}`, position: 'relative', overflow: 'hidden' }}>
      <div style={{ width, height, transform: `scale(${scale})`, transformOrigin: '0 0', position: 'absolute', inset: 0 }}>{children}</div>
    </div>
  );
}
