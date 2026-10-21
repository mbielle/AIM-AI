import { useEffect, useState } from 'react';
import { createPortal } from 'react-dom';
import { AnimatePresence, motion, useSpring, useTransform, useVelocity, type MotionValue } from 'motion/react';
import { MEDIA, type MediaSlotId } from '../media';
import { MediaFrame } from './MediaFrame';

const WIDTH = 340;
const OFFSET = 28;
const EDGE = 16;
const NAV = 72;

interface CursorPreviewProps {
  /** Slot to show, or null when the pointer is outside the list. */
  slot: MediaSlotId | null;
  /** Raw pointer position (client px), updated by the list on pointer move. */
  x: MotionValue<number>;
  y: MotionValue<number>;
}

/**
 * One floating preview that follows the pointer, rendered in a portal at the landing root so no
 * ancestor's overflow can clip it and it never takes the pointer (no hover loop). It sits to the
 * right of the cursor and switches to the left near the right edge, always inside the viewport.
 * Position and tilt are motion values: moving the mouse never re-renders React.
 */
export function CursorPreview({ slot, x, y }: CursorPreviewProps) {
  const [host, setHost] = useState<Element | null>(null);
  useEffect(() => setHost(document.querySelector('.aim-landing')), []);

  const height = WIDTH / (slot ? MEDIA[slot].aspect : 4 / 3);

  const tx = useTransform(x, (px) => {
    const vw = window.innerWidth;
    const right = px + OFFSET;
    const left = px - OFFSET - WIDTH;
    const pos = right + WIDTH > vw - EDGE ? left : right;
    return Math.min(vw - EDGE - WIDTH, Math.max(EDGE, pos));
  });
  const ty = useTransform(y, (py) => {
    const vh = window.innerHeight;
    return Math.min(vh - EDGE - height, Math.max(NAV + 8, py - height / 2));
  });
  // Short damping: it follows closely, with a little weight.
  const sx = useSpring(tx, { stiffness: 420, damping: 38, mass: 0.6 });
  const sy = useSpring(ty, { stiffness: 420, damping: 38, mass: 0.6 });
  // A slight tilt in the direction of travel, settling back to rest.
  const vx = useVelocity(sx);
  const tilt = useTransform(vx, [-1600, 0, 1600], [-4, 0, 4], { clamp: true });
  const rotate = useSpring(tilt, { stiffness: 260, damping: 26 });

  if (!host) return null;
  return createPortal(
    <motion.div aria-hidden="true" className="pointer-events-none fixed left-0 top-0 z-[45]" style={{ x: sx, y: sy, rotate, width: WIDTH }}>
      <AnimatePresence>
        {slot && (
          <motion.div
            key="preview"
            className="l-float relative overflow-hidden rounded-[14px] bg-[#E9ECF0]"
            style={{ aspectRatio: String(MEDIA[slot].aspect), transformOrigin: '0% 50%' }}
            initial={{ opacity: 0, scale: 0.9 }}
            animate={{ opacity: 1, scale: 1 }}
            exit={{ opacity: 0, scale: 0.94 }}
            transition={{ duration: 0.22, ease: [0.22, 1, 0.36, 1] }}
          >
            {/* Changing row: the new media fades in over the previous one, no blank frame. */}
            <AnimatePresence initial={false}>
              <motion.div
                key={slot}
                className="absolute inset-0"
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                exit={{ opacity: 0, transition: { duration: 0.18, delay: 0.06 } }}
                transition={{ duration: 0.16 }}
              >
                <MediaFrame slot={slot} variant="bare" active eager className="h-full" />
              </motion.div>
            </AnimatePresence>
          </motion.div>
        )}
      </AnimatePresence>
    </motion.div>,
    host,
  );
}
