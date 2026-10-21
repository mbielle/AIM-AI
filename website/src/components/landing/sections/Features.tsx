import { useEffect, useRef, useState } from 'react';
import { AnimatePresence, motion, useMotionValue, useReducedMotion } from 'motion/react';
import { Plus } from 'lucide-react';
import { cn } from '@/lib/utils';
import { FEATURES } from '../content';
import { CursorPreview } from '../media/CursorPreview';
import { MediaFrame } from '../media/MediaFrame';
import { Reveal } from '../ui/Reveal';
import type { MediaSlotId } from '../media';

function useFinePointer() {
  const query = '(hover: hover) and (pointer: fine)';
  const [fine, setFine] = useState(() => typeof window !== 'undefined' && window.matchMedia(query).matches);
  useEffect(() => {
    const mq = window.matchMedia(query);
    const onChange = () => setFine(mq.matches);
    mq.addEventListener('change', onChange);
    return () => mq.removeEventListener('change', onChange);
  }, []);
  return fine;
}

/**
 * Capabilities as a short numbered list. Every row reads on its own; with a fine pointer, hovering
 * a row shows its short demo in a preview that follows the cursor. Touch, keyboard and reduced
 * motion get the same demo inline, behind an explicit “Preview” button.
 */
export function Features() {
  const reduced = useReducedMotion() ?? false;
  const fine = useFinePointer();
  const floating = fine && !reduced;
  const [hovered, setHovered] = useState<MediaSlotId | null>(null);
  const [inline, setInline] = useState<string | null>(null);
  const x = useMotionValue(0);
  const y = useMotionValue(0);
  const list = useRef<HTMLOListElement>(null);

  // Scrolling without moving the mouse: follow the row now under the pointer, or hide the preview.
  useEffect(() => {
    if (!hovered) return;
    let raf = 0;
    const onScroll = () => {
      if (raf) return;
      raf = requestAnimationFrame(() => {
        raf = 0;
        const row = document.elementFromPoint(x.get(), y.get())?.closest<HTMLElement>('[data-feature-media]');
        const next = row && list.current?.contains(row) ? (row.dataset.featureMedia as MediaSlotId) : null;
        setHovered(next);
      });
    };
    window.addEventListener('scroll', onScroll, { passive: true });
    return () => {
      window.removeEventListener('scroll', onScroll);
      if (raf) cancelAnimationFrame(raf);
    };
  }, [hovered, x, y]);

  return (
    <section id="features" aria-labelledby="features-title" className="relative scroll-mt-[var(--l-nav)] px-4 py-28 sm:px-8 sm:py-36">
      <div className="mx-auto w-full max-w-[1240px]">
        <Reveal className="max-w-[760px]">
          <h2 id="features-title" className="l-h2 text-balance">
            {FEATURES.title} <span className="l-title-muted">{FEATURES.titleMuted}</span>
          </h2>
          <p className="mt-6 max-w-[56ch] text-pretty text-[17px] leading-relaxed text-[#5D6168]">{FEATURES.intro}</p>
        </Reveal>

        <ol
          ref={list}
          className="mt-16 border-t border-black/[0.08] sm:mt-20"
          onPointerMove={(e) => {
            if (e.pointerType !== 'mouse') return;
            x.set(e.clientX);
            y.set(e.clientY);
          }}
          onPointerLeave={() => setHovered(null)}
        >
          {FEATURES.items.map((item, i) => {
            const open = inline === item.id;
            return (
              <li
                key={item.id}
                data-feature-media={item.media}
                className="group border-b border-black/[0.08]"
                onPointerEnter={(e) => {
                  if (!floating || e.pointerType !== 'mouse') return;
                  x.set(e.clientX);
                  y.set(e.clientY);
                  setHovered(item.media);
                }}
              >
                <div className="grid grid-cols-[40px_minmax(0,1fr)] gap-x-4 gap-y-3 py-8 sm:grid-cols-[56px_minmax(0,1fr)_minmax(0,380px)] sm:gap-x-8 sm:py-10">
                  <span className="l-mono pt-[10px] text-[12px] text-[#8E939B] transition-colors group-hover:text-[#0B0B0C]">{String(i + 1).padStart(2, '0')}</span>
                  <div className="flex items-start justify-between gap-4">
                    <h3 className="text-balance text-[clamp(24px,2.6vw,34px)] font-medium leading-[1.15] tracking-[-0.03em] text-[#0B0B0C]">{item.title}</h3>
                    <button
                      type="button"
                      aria-expanded={open}
                      aria-controls={`feature-preview-${item.id}`}
                      onClick={() => setInline(open ? null : item.id)}
                      className={cn(
                        'mt-1 inline-flex h-8 shrink-0 items-center gap-1.5 rounded-full px-3 text-[13px] font-medium text-[#34373C] shadow-[inset_0_0_0_1px_rgba(11,11,12,0.12)] transition-[opacity,background-color] hover:bg-black/[0.04]',
                        // With a fine pointer the hover preview is the main path; the button stays reachable by keyboard.
                        floating && !open && 'opacity-0 focus-visible:opacity-100 group-focus-within:opacity-100',
                      )}
                    >
                      <Plus className={cn('h-3.5 w-3.5 transition-transform duration-300', open && 'rotate-45')} strokeWidth={2} aria-hidden="true" />
                      {FEATURES.previewLabel}
                    </button>
                  </div>
                  <p className="col-start-2 max-w-[52ch] text-pretty text-[15.5px] leading-relaxed text-[#5D6168] sm:col-start-3 sm:row-start-1 sm:pt-[6px]">{item.body}</p>
                </div>
                <AnimatePresence initial={false}>
                  {open && (
                    <motion.div
                      id={`feature-preview-${item.id}`}
                      initial={reduced ? false : { height: 0, opacity: 0 }}
                      animate={{ height: 'auto', opacity: 1 }}
                      exit={reduced ? { opacity: 0 } : { height: 0, opacity: 0 }}
                      transition={{ duration: 0.3, ease: [0.22, 1, 0.36, 1] }}
                      className="overflow-hidden"
                    >
                      <div className="pb-8 sm:pl-[88px]">
                        <MediaFrame slot={item.media} variant="card" active eager className="max-w-[560px]" />
                      </div>
                    </motion.div>
                  )}
                </AnimatePresence>
              </li>
            );
          })}
        </ol>
      </div>
      {floating && <CursorPreview slot={hovered} x={x} y={y} />}
    </section>
  );
}
