import { AimMark, AimMascot } from '@/components/mascot/AimMascot';

interface SiteWordmarkProps {
  /** Width of the mark in px. */
  size?: number;
  /** The surface the wordmark sits on: decides the eye colour against `currentColor`. */
  tone?: 'dark' | 'light';
  /** Animated mark (blinks, reacts) or the still drawing. */
  animated?: boolean;
  /** The mark alone, without the “AIM” text (e.g. inside the navigation disc). */
  markOnly?: boolean;
}

/** The AIM mascot sign followed by “AIM”. Body colour follows `currentColor`. */
export function SiteWordmark({ size = 30, tone = 'light', animated = false, markOnly = false }: SiteWordmarkProps) {
  const eyeColor = tone === 'dark' ? '#0A0A0B' : '#FAFAFA';
  return (
    <span className="inline-flex items-center gap-2.5">
      {animated ? (
        // A logo should not doze off in the navigation bar.
        <AimMascot size={size} variant="mark" autoSleep={false} eyeColor={eyeColor} seed={21} />
      ) : (
        <AimMark size={size} eyeColor={eyeColor} />
      )}
      {!markOnly && <span className="text-[17px] font-semibold leading-none tracking-[-0.01em]">AIM</span>}
    </span>
  );
}
