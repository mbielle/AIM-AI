import type { ReactNode } from 'react';
import { cn } from '@/lib/utils';
import { LandingButton, LandingLink, type LandingButtonVariants } from './LandingButton';

/** Whether the button's own surface is dark (light-tone primary, or dark-tone outline/ghost). */
const onDarkSurface = ({ variant, tone }: LandingButtonVariants) =>
  (variant ?? 'primary') === 'primary' ? tone === 'light' : tone !== 'light';

interface ExternalCtaProps extends LandingButtonVariants {
  /** Destination, or `null` while it does not exist yet. */
  href: string | null;
  children: ReactNode;
  /** Id of the element explaining why the action is unavailable (shown by the caller). */
  unavailableNoteId: string;
  /** Short explanation, also used as the tooltip of the inactive control. */
  unavailableLabel: string;
  /** Small tag shown inside the inactive control (e.g. “Soon”), so the state is visible at a glance. */
  unavailableBadge?: string;
  onActivate?: (available: boolean) => void;
  className?: string;
}

/**
 * A call to action whose destination may not exist yet. With a URL it is a real link; without
 * one it stays in place as an inactive control that says why — never `href="#"`, never a fake
 * success. Filling in the URL is all it takes to enable it.
 */
export function ExternalCta({ href, children, unavailableNoteId, unavailableLabel, unavailableBadge, onActivate, className, ...variants }: ExternalCtaProps) {
  if (href) {
    return (
      <LandingLink href={href} className={className} onClick={() => onActivate?.(true)} {...variants}>
        {children}
      </LandingLink>
    );
  }
  return (
    <LandingButton
      aria-disabled="true"
      aria-describedby={unavailableNoteId}
      title={unavailableLabel}
      className={className}
      onClick={(e) => {
        e.preventDefault();
        onActivate?.(false);
      }}
      {...variants}
    >
      {children}
      {unavailableBadge && (
        <span
          className={cn(
            'ml-1 rounded-full px-2 py-[3px] text-[11.5px] font-medium leading-none',
            onDarkSurface(variants) ? 'bg-white/15 text-white/75' : 'bg-black/[0.07] text-black/55',
          )}
        >
          {unavailableBadge}
        </span>
      )}
    </LandingButton>
  );
}

export const isAvailable = (href: string | null): href is string => Boolean(href);
