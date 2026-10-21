import { useCallback, useEffect, useLayoutEffect, useRef, useState } from 'react';
import { motion, useReducedMotion } from 'motion/react';
import { Menu as MenuIcon, X } from 'lucide-react';
import { cn } from '@/lib/utils';
import { FOOTER, HERO, LINKS, NAV, REMOTE } from '../content';
import { SocialLinks } from './SocialLinks';

interface MenuPanelProps {
  /** Surface under the closed capsule. The open panel is always light. */
  tone: 'dark' | 'light';
  onCta: (name: string) => void;
  onOpenChange?: (open: boolean) => void;
}

const CAPSULE = { w: 108, h: 44 };
const PANEL_MAX_W = 520;
const GUTTER = 16;
const EASE = [0.22, 1, 0.36, 1] as const;

/**
 * The “Menu” capsule that unfolds into the navigation panel. A single surface grows from the
 * capsule (top edge fixed, opening downwards); the capsule itself becomes the long “Close” bar at
 * the top of the panel, then the links appear in sequence. Interruptible: reversing mid-way
 * animates from wherever it is. The page behind stays visible — no full-screen veil.
 */
export function MenuPanel({ tone, onCta, onOpenChange }: MenuPanelProps) {
  const reduced = useReducedMotion() ?? false;
  const [open, setOpen] = useState(false);
  const [panel, setPanel] = useState({ w: PANEL_MAX_W, h: 420, maxH: 800 });
  const root = useRef<HTMLDivElement>(null);
  const trigger = useRef<HTMLButtonElement>(null);
  const content = useRef<HTMLDivElement>(null);
  const firstLink = useRef<HTMLAnchorElement>(null);

  const setOpenState = useCallback(
    (next: boolean, { restoreFocus = false } = {}) => {
      setOpen(next);
      onOpenChange?.(next);
      if (!next && restoreFocus) trigger.current?.focus();
    },
    [onOpenChange],
  );

  // Panel size: width from the viewport, height from the content (scrolls inside if too tall).
  useLayoutEffect(() => {
    const measure = () => {
      const w = Math.min(PANEL_MAX_W, window.innerWidth - GUTTER * 2);
      const maxH = window.innerHeight - 24;
      const h = Math.min((content.current?.scrollHeight ?? 420) + 0, maxH);
      setPanel({ w, h, maxH });
    };
    measure();
    const ro = new ResizeObserver(measure);
    if (content.current) ro.observe(content.current);
    window.addEventListener('resize', measure);
    return () => {
      ro.disconnect();
      window.removeEventListener('resize', measure);
    };
  }, []);

  // Closed content is out of the tab order and the accessibility tree.
  useEffect(() => {
    const el = content.current as (HTMLDivElement & { inert?: boolean }) | null;
    if (el) el.inert = !open;
    if (open) {
      const id = window.setTimeout(() => firstLink.current?.focus({ preventScroll: true }), reduced ? 0 : 180);
      return () => window.clearTimeout(id);
    }
  }, [open, reduced]);

  // Escape and outside click close it.
  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') setOpenState(false, { restoreFocus: true });
    };
    const onPointer = (e: PointerEvent) => {
      if (root.current && !root.current.contains(e.target as Node)) setOpenState(false);
    };
    window.addEventListener('keydown', onKey);
    document.addEventListener('pointerdown', onPointer);
    return () => {
      window.removeEventListener('keydown', onKey);
      document.removeEventListener('pointerdown', onPointer);
    };
  }, [open, setOpenState]);

  const close = () => setOpenState(false);
  const dur = reduced ? 0 : open ? 0.46 : 0.36;
  const dark = tone === 'dark' && !open;

  // Links appear in sequence after the surface has started to open; on close they leave at once.
  const item = (i: number) => ({
    initial: false as const,
    animate: open ? { opacity: 1, y: 0 } : { opacity: 0, y: -6 },
    transition: reduced ? { duration: 0 } : open ? { duration: 0.32, delay: 0.12 + i * 0.035, ease: EASE } : { duration: 0.12 },
  });

  const linkClass = 'block w-fit whitespace-nowrap rounded-md py-[3px] text-[17px] font-medium sm:text-[19px] tracking-[-0.02em] text-[#0B0B0C] transition-colors hover:text-[#5B6B80]';
  const smallLink = 'text-[13px] text-[#5D6168] transition-colors hover:text-[#0B0B0C]';
  let n = 0;

  return (
    <div ref={root} className="relative h-[44px] w-[108px]">
      <motion.div
        initial={false}
        animate={{
          width: open ? panel.w : CAPSULE.w,
          height: open ? panel.h : CAPSULE.h,
          borderRadius: open ? 24 : 22,
          backgroundColor: open ? 'rgba(252,252,253,0.94)' : dark ? 'rgba(255,255,255,0.08)' : 'rgba(255,255,255,0.92)',
        }}
        transition={{ duration: dur, ease: EASE }}
        className={cn(
          'absolute left-1/2 top-0 -translate-x-1/2 overflow-hidden backdrop-blur-xl backdrop-saturate-150',
          dark ? 'shadow-[inset_0_0_0_1px_rgba(255,255,255,0.12)]' : 'shadow-[0_0_0_1px_rgba(15,18,24,0.06),0_8px_24px_-10px_rgba(15,18,24,0.18)]',
          open && 'shadow-[0_0_0_1px_rgba(15,18,24,0.06),0_30px_80px_-24px_rgba(15,18,24,0.35),0_10px_24px_-12px_rgba(15,18,24,0.16)]',
        )}
      >
        {/* The capsule, which becomes the “Close” bar. */}
        <motion.button
          ref={trigger}
          type="button"
          initial={false}
          animate={{ top: open ? 8 : 0, left: open ? 8 : 0, right: open ? 8 : 0, height: open ? 40 : CAPSULE.h, borderRadius: open ? 20 : 22 }}
          transition={{ duration: dur, ease: EASE }}
          aria-expanded={open}
          aria-controls="landing-menu"
          onClick={() => setOpenState(!open)}
          className={cn(
            'absolute z-10 flex items-center justify-center gap-2 text-[14px] font-medium tracking-[-0.01em] transition-colors',
            open ? 'bg-white text-[#0B0B0C] shadow-[0_0_0_1px_rgba(15,18,24,0.08)] hover:bg-[#F6F7F8]' : dark ? 'text-[#F2F3F5]' : 'text-[#0B0B0C]',
          )}
        >
          {open ? <X className="h-4 w-4" strokeWidth={1.8} aria-hidden="true" /> : <MenuIcon className="h-4 w-4" strokeWidth={1.8} aria-hidden="true" />}
          {open ? NAV.close : NAV.menu}
        </motion.button>

        {/* Content laid out at the final width, so it never reflows while the surface grows. */}
        <div
          ref={content}
          id="landing-menu"
          className="absolute left-0 top-0 overflow-y-auto overscroll-contain px-6 pb-5 pt-[68px]"
          style={{ width: panel.w, maxHeight: panel.maxH }}
        >
          <nav aria-label="Site" className="grid grid-cols-[minmax(0,1fr)_minmax(0,1.25fr)] gap-x-4 gap-y-8 sm:grid-cols-2 sm:gap-x-6">
            <div>
              <motion.p {...item(n++)} className="mb-3 text-[11px] font-medium uppercase tracking-[0.08em] text-[#8E939B]">
                {NAV.product.title}
              </motion.p>
              <ul className="space-y-[2px]">
                {NAV.product.links.map((l, i) => (
                  <motion.li key={l.href} {...item(n++)}>
                    <a ref={i === 0 ? firstLink : undefined} href={l.href} onClick={close} className={linkClass}>
                      {l.label}
                    </a>
                  </motion.li>
                ))}
              </ul>
            </div>
            <div>
              <motion.p {...item(n++)} className="mb-3 text-[11px] font-medium uppercase tracking-[0.08em] text-[#8E939B]">
                {NAV.getAim.title}
              </motion.p>
              <ul className="space-y-[2px]">
                <motion.li {...item(n++)}>
                  <MaybeLink href={LINKS.macDownload} className={linkClass} soon={FOOTER.soon} title={HERO.downloadUnavailable} onClick={(ok) => onCta(ok ? 'menu_download' : 'menu_download_unavailable')}>
                    AIM for Mac
                  </MaybeLink>
                </motion.li>
                <motion.li {...item(n++)}>
                  <MaybeLink href={LINKS.appStore} className={linkClass} soon={FOOTER.soon} title={REMOTE.appStoreUnavailable} onClick={(ok) => onCta(ok ? 'menu_appstore' : 'menu_appstore_unavailable')}>
                    AIM for iPhone
                  </MaybeLink>
                </motion.li>
                <motion.li {...item(n++)}>
                  <a href={LINKS.guide} onClick={() => onCta('menu_guide')} className={linkClass}>
                    {NAV.guide}
                  </a>
                </motion.li>
              </ul>
            </div>
          </nav>

          <motion.div {...item(n++)} className="mt-7 border-t border-black/[0.07] pt-4">
            <p className="mb-2 text-[11px] font-medium uppercase tracking-[0.08em] text-[#8E939B]">{NAV.socialTitle}</p>
            <div className="flex flex-wrap items-center justify-between gap-x-6 gap-y-2">
              <SocialLinks className="gap-x-5 gap-y-1" itemClassName={smallLink} />
              <ul className="flex items-center gap-x-5">
                {NAV.bottom.map((l) => (
                  <li key={l.label}>
                    <a href={l.href} onClick={close} className={smallLink}>
                      {l.label}
                    </a>
                  </li>
                ))}
              </ul>
            </div>
          </motion.div>
        </div>
      </motion.div>
    </div>
  );
}

/** A real link when the destination exists; otherwise the same text, inactive, tagged “Soon”. */
function MaybeLink({ href, className, soon, title, onClick, children }: { href: string | null; className: string; soon: string; title: string; onClick: (available: boolean) => void; children: string }) {
  if (href) {
    return (
      <a href={href} className={className} onClick={() => onClick(true)}>
        {children}
      </a>
    );
  }
  return (
    <button type="button" aria-disabled="true" title={title} onClick={() => onClick(false)} className={cn(className, 'inline-flex max-w-full cursor-default flex-wrap items-center gap-x-2 gap-y-1 whitespace-normal text-left text-[#6B6F76] hover:text-[#6B6F76]')}>
      {children}
      <span className="whitespace-nowrap rounded-full bg-black/[0.06] px-2 py-[3px] text-[11px] font-medium leading-none tracking-normal text-black/55">{soon}</span>
    </button>
  );
}
