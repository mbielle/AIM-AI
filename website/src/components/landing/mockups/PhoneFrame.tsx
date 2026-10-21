import type { ReactNode } from 'react';
import { cn } from '@/lib/utils';
import { ScaledScreen } from './ScaledScreen';

interface PhoneFrameProps {
  children: ReactNode;
  className?: string;
}

/**
 * iPhone close-up (Dynamic Island generation), shown from the front. A light, translucent surround
 * holds an opaque screen; the screen content (status bar, island, app UI) is designed at
 * 390 × 844 pt and scaled. Radii are given as % of width / % of height so the corners stay
 * circular and nested at any size. Cropping and the lower fade belong to the parent scene.
 */
export function PhoneFrame({ children, className }: PhoneFrameProps) {
  return (
    <div className={cn('l-phone relative rounded-[16%/7.4%] p-[2.8%]', className)}>
      <div className="relative overflow-hidden rounded-[13.6%/6.3%] bg-white shadow-[0_0_0_1px_rgba(15,18,24,0.07)]">
        <ScaledScreen width={390} height={844}>
          {children}
        </ScaledScreen>
      </div>
    </div>
  );
}
