import { useLayoutEffect, useRef, useState, type ReactNode } from 'react';
import type { MediaFallback as Fallback } from '../media';
import { PhoneFrame } from '../mockups/PhoneFrame';
import { ApprovalScene, APPROVAL_SCENE_SIZE } from '../mockups/screens/ApprovalScene';
import { ChatScreen, CHAT_SCREEN_SIZE } from '../mockups/screens/ChatScreen';
import { PhoneRemoteScreen } from '../mockups/screens/PhoneRemoteScreen';

/**
 * Temporary content for a media slot: an existing coded mockup, cropped to a region, or a quiet
 * placeholder. Nothing here simulates new interface — it is replaced by captures through media.ts.
 */
export function MediaFallback({ fallback }: { fallback: Fallback }) {
  switch (fallback.screen) {
    case 'chat':
      return (
        <CoverCrop width={CHAT_SCREEN_SIZE.width} height={CHAT_SCREEN_SIZE.height} region={fallback.region}>
          <ChatScreen />
        </CoverCrop>
      );
    case 'approval':
      return (
        <div className="l-stage absolute inset-0">
          <CoverCrop width={APPROVAL_SCENE_SIZE.width} height={APPROVAL_SCENE_SIZE.height} region={fallback.region}>
            <ApprovalScene />
          </CoverCrop>
        </div>
      );
    case 'phone':
      return (
        <div className="l-stage-soft absolute inset-0 overflow-hidden">
          <PhoneFrame className="absolute left-1/2 top-[10%] w-[min(62%,300px)] -translate-x-1/2">
            <PhoneRemoteScreen />
          </PhoneFrame>
          <div className="l-fade-bottom absolute inset-x-0 bottom-0 h-[30%]" />
        </div>
      );
    default:
      return <Placeholder label={fallback.label} />;
  }
}

/** Scales a fixed-size design so `region` covers the box (like object-fit: cover), centred. */
function CoverCrop({ width, height, region, children }: { width: number; height: number; region?: [number, number, number, number]; children: ReactNode }) {
  const ref = useRef<HTMLDivElement>(null);
  const [box, setBox] = useState({ w: 0, h: 0 });
  const [x, y, w, h] = region ?? [0, 0, width, height];

  useLayoutEffect(() => {
    const el = ref.current;
    if (!el) return;
    const update = () => setBox({ w: el.clientWidth, h: el.clientHeight });
    update();
    const ro = new ResizeObserver(update);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const scale = box.w && box.h ? Math.max(box.w / w, box.h / h) : 0;
  const tx = -x * scale + (box.w - w * scale) / 2;
  const ty = -y * scale + (box.h - h * scale) / 2;

  return (
    <div ref={ref} className="absolute inset-0 overflow-hidden">
      {scale > 0 && (
        <div style={{ width, height, transform: `translate(${tx}px, ${ty}px) scale(${scale})`, transformOrigin: '0 0' }}>{children}</div>
      )}
    </div>
  );
}

/** A calm surface that says a capture goes here, without pretending to be the product. */
function Placeholder({ label }: { label?: string }) {
  return (
    <div className="l-placeholder absolute inset-0 flex items-end p-[6%]">
      {label && <span className="l-eyebrow text-[#7C8593]">{label}</span>}
    </div>
  );
}
