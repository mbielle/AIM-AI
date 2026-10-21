import type { ReactNode } from 'react';
import { cn } from '@/lib/utils';

interface MacWindowProps {
  children: ReactNode;
  className?: string;
}

/**
 * macOS window frame. The AIM app uses a unified toolbar: the traffic lights sit on the same gray
 * surface as the sidebar, so the frame only provides the shape, hairline and shadow.
 */
export function MacWindow({ children, className }: MacWindowProps) {
  return <div className={cn('l-window overflow-hidden rounded-[10px] bg-[#EEEEED] sm:rounded-[12px]', className)}>{children}</div>;
}

/** The three window controls, drawn at their real macOS size (12 px, 8 px apart). */
export function TrafficLights({ className }: { className?: string }) {
  const light = (bg: string, ring: string) => (
    <span className="h-3 w-3 rounded-full" style={{ background: bg, boxShadow: `inset 0 0 0 0.5px ${ring}` }} />
  );
  return (
    <div className={cn('flex items-center gap-2', className)} aria-hidden="true">
      {light('#FF5F57', '#E14640')}
      {light('#FEBC2E', '#DFA023')}
      {light('#28C840', '#1AAB29')}
    </div>
  );
}
