/**
 * Every media slot on the landing page — the one place to edit when a real capture arrives.
 *
 * Presentation (frames, motion, loading, playback) lives in code; the content of each frame is a
 * replaceable file. A slot's box is fixed by `aspect`, so swapping a placeholder for a capture
 * never changes the layout. Files are served from `public/landing/media/<slot>/`.
 * Capture briefs for each slot: docs/landing-v5/capture-briefs.md.
 */

/**
 * - `scrub`: the video position follows the scroll progress (product story).
 * - `hover`: plays while its trigger is hovered (cursor previews).
 * - `visible`: plays while on screen (use-case cards).
 * - `still`: a fixed capture.
 */
export type MediaMode = 'scrub' | 'hover' | 'visible' | 'still';

export interface MediaSource {
  src: string;
  /** MIME type with codecs, e.g. `video/mp4; codecs="avc1.640028"`. Listed in order of preference. */
  type: string;
}

/** Temporary content until a capture exists: an existing coded mockup, cropped to the slot. */
export interface MediaFallback {
  screen: 'chat' | 'approval' | 'phone' | 'placeholder';
  /** Region of the mockup to show, in its design pixels: [x, y, width, height]. Covers the box. */
  region?: [number, number, number, number];
  /** Short name of what the final capture will show (placeholder only). */
  label?: string;
}

export interface MediaSlot {
  id: string;
  /** Set true only after the real app capture and its sample data are reviewed. */
  verifiedCapture?: boolean;
  /** Width / height of the box. Exports must match it (see the capture briefs). */
  aspect: number;
  mode: MediaMode;
  /** Describes what the media shows; media are decorative only when the page text says the same. */
  alt: string;
  /** Cover image shown at once, while loading, on error and with reduced motion. */
  poster?: string;
  /** Video sources (scrub / hover / visible). */
  sources?: MediaSource[];
  /** Still image (still mode). */
  image?: string;
  /** CSS object-position for cover cropping. */
  position?: string;
  fallback: MediaFallback;
}


const slots = {
  story: {
    id: 'story',
    aspect: 16 / 10,
    mode: 'scrub',
    alt: 'The AIM app on macOS: a chat, the model picker, then an agent task that asks permission before running a command.',
    // Provisional clip for the integration test (Gate A), built from the coded mockups by
    // scripts/media/encode-scrub.sh into the git-ignored _test folder. Without it the poster and
    // the mockup fallback are shown. Replace with the final recording in /landing/media/story/.
    fallback: { screen: 'chat' },
  },

  'feat-models': {
    id: 'feat-models',
    aspect: 4 / 3,
    mode: 'hover',
    alt: 'The model picker in the AIM composer.',
    fallback: { screen: 'chat', region: [500, 390, 480, 360] },
  },
  'feat-history': {
    id: 'feat-history',
    aspect: 4 / 3,
    mode: 'hover',
    alt: 'The AIM sidebar listing chats and agent tasks in one history.',
    fallback: { screen: 'chat', region: [0, 0, 520, 390] },
  },
  'feat-approvals': {
    id: 'feat-approvals',
    aspect: 4 / 3,
    mode: 'hover',
    alt: 'An agent paused on a permission request to run a command.',
    fallback: { screen: 'approval', region: [340, 150, 520, 390] },
  },
  'feat-agents': {
    id: 'feat-agents',
    aspect: 4 / 3,
    mode: 'hover',
    alt: 'OpenClaw and Hermes agents next to AIM’s own agent.',
    fallback: { screen: 'placeholder', label: 'Agents · OpenClaw · Hermes' },
  },
  'feat-remote': {
    id: 'feat-remote',
    aspect: 4 / 3,
    mode: 'hover',
    alt: 'AIM on iPhone following an agent session that runs on a Mac.',
    fallback: { screen: 'phone' },
  },

  'uc-debug': {
    id: 'uc-debug',
    aspect: 16 / 10,
    mode: 'visible',
    alt: 'An agent reading a repository, proposing a fix and asking to run the tests.',
    fallback: { screen: 'approval', region: [0, 0, 900, 562] },
  },
  'uc-docs': {
    id: 'uc-docs',
    aspect: 16 / 10,
    mode: 'visible',
    alt: 'A project with documents, and answers from two models side by side.',
    fallback: { screen: 'placeholder', label: 'Project documents · two models' },
  },
  'uc-delegate': {
    id: 'uc-delegate',
    aspect: 16 / 10,
    mode: 'visible',
    alt: 'A delegated task waiting for approval before its next step.',
    fallback: { screen: 'chat', region: [0, 0, 1200, 750] },
  },
  'uc-iphone': {
    id: 'uc-iphone',
    aspect: 16 / 10,
    mode: 'visible',
    alt: 'Following and approving a Mac agent from the AIM iPhone app.',
    fallback: { screen: 'phone' },
  },
  'uc-every-model': {
    id: 'uc-every-model',
    aspect: 16 / 9,
    mode: 'visible',
    alt: 'The list of models available through OpenRouter, and the OpenClaw and Hermes agents.',
    fallback: { screen: 'placeholder', label: 'Models · OpenRouter · Agents' },
  },

  'cta-1': { id: 'cta-1', aspect: 3 / 4, mode: 'still', alt: '', fallback: { screen: 'chat', region: [0, 0, 300, 400] } },
  'cta-2': { id: 'cta-2', aspect: 3 / 4, mode: 'still', alt: '', fallback: { screen: 'chat', region: [560, 470, 300, 400] } },
  'cta-3': { id: 'cta-3', aspect: 3 / 4, mode: 'still', alt: '', fallback: { screen: 'approval', region: [480, 160, 330, 440] } },
  'cta-4': { id: 'cta-4', aspect: 3 / 4, mode: 'still', alt: '', fallback: { screen: 'chat', region: [340, 50, 420, 560] } },
  'cta-5': { id: 'cta-5', aspect: 3 / 4, mode: 'still', alt: '', fallback: { screen: 'phone' } },
} satisfies Record<string, MediaSlot>;

export type MediaSlotId = keyof typeof slots;

export const MEDIA: Record<MediaSlotId, MediaSlot> = slots;
