import { forwardRef, useEffect, useImperativeHandle, useMemo, useRef, useSyncExternalStore, type CSSProperties } from 'react';
import { drawCompanion, VIEWBOX, type CompanionVariant } from './companion/geometry';
import { restPose } from './companion/expressions';
import { CompanionModel, DEFAULT_AUTO_SLEEP, stateKeyPose, type AutoSleep, type MascotReaction, type MascotState } from './companion/model';
import { prefersReducedMotion, subscribeReducedMotion } from './core/motion';
import { follow } from './core/pointer';
import { catchUp, register, setVisible, wake, type TickerEntry } from './core/ticker';
import { mergePose, type Frame } from './core/types';

export type { MascotReaction, MascotState, AutoSleep, CompanionVariant };

export interface AimMascotProps {
  /** What the app is doing. The mascot never guesses it. */
  state?: MascotState;
  /** A one-off reaction to an app event. A new `key` replays it. */
  reaction?: { type: MascotReaction; key: string | number } | null;
  /** Width in CSS pixels; the height follows the variant. */
  size?: number;
  /** `mark`: the compact sign (navbar, small sizes). `companion`: the standing character. */
  variant?: CompanionVariant;
  /** `auto` follows the OS "reduce motion" setting, live. `none` shows the still drawing. */
  motion?: 'auto' | 'full' | 'reduced' | 'none';
  /** Freeze on the still drawing of the current state. */
  paused?: boolean;
  followPointer?: boolean;
  /** Dozing off after inactivity, only in idle/waiting. `false` disables it. */
  autoSleep?: boolean | AutoSleep;
  /** Any change of this value counts as user activity (typing, scrolling…). */
  activity?: unknown;
  /** Body colour (default `currentColor`) and eye colour (default `var(--aim-mascot-eye, #fafafa)`). */
  bodyColor?: string;
  eyeColor?: string;
  /** Two small feet in the companion variant. */
  feet?: boolean;
  /** Accessible name. Without it the mascot is decorative and hidden from assistive tech. */
  label?: string;
  /** Renders a button: a tap or Enter plays the `poke` reaction. */
  interactive?: boolean;
  onPoke?: () => void;
  /** Deterministic behaviour for tests and recordings. */
  seed?: number;
  /** Playback speed (lab only). */
  timeScale?: number;
  className?: string;
  style?: CSSProperties;
}

export interface AimMascotHandle {
  react(type: MascotReaction): void;
  sleep(): void;
  wake(): void;
  /** Read-only snapshot for debugging and the lab. */
  status(): { state: MascotState; rest: string; reacting: MascotReaction | null; inactive: number };
}

const EYE_DEFAULT = 'var(--aim-mascot-eye, #fafafa)';

// One IntersectionObserver for every instance.
const watchers = new Map<Element, (visible: boolean) => void>();
let io: IntersectionObserver | null = null;
function watchVisibility(el: Element, cb: (visible: boolean) => void) {
  if (typeof IntersectionObserver === 'undefined') return () => {};
  io ??= new IntersectionObserver((list) => list.forEach((e) => watchers.get(e.target)?.(e.isIntersecting)), { rootMargin: '64px' });
  watchers.set(el, cb);
  io.observe(el);
  return () => {
    watchers.delete(el);
    io?.unobserve(el);
  };
}

export const AimMascot = forwardRef<AimMascotHandle, AimMascotProps>(function AimMascot(
  {
    state = 'idle',
    reaction = null,
    size = 120,
    variant = 'companion',
    motion = 'auto',
    paused = false,
    followPointer = false,
    autoSleep = true,
    activity,
    bodyColor = 'currentColor',
    eyeColor = EYE_DEFAULT,
    feet = false,
    label,
    interactive = false,
    onPoke,
    seed,
    timeScale = 1,
    className,
    style,
  },
  ref,
) {
  const osReduced = useSyncExternalStore(subscribeReducedMotion, prefersReducedMotion, () => false);
  const still = paused || motion === 'none';
  const reduced = motion === 'reduced' || (motion === 'auto' && osReduced);
  const sleepCfg: AutoSleep | null = autoSleep === false ? null : autoSleep === true ? DEFAULT_AUTO_SLEEP : autoSleep;
  const sleepKey = sleepCfg ? `${sleepCfg.drowsyAfter}/${sleepCfg.sleepAfter}` : 'off';

  const svgRef = useRef<SVGSVGElement>(null);
  const fillsRef = useRef<SVGPathElement>(null);
  const eyesRef = useRef<SVGPathElement>(null);
  const entryRef = useRef<TickerEntry | null>(null);
  const sizeRef = useRef(size);
  sizeRef.current = size;

  // eslint-disable-next-line react-hooks/exhaustive-deps
  const model = useMemo(() => new CompanionModel({ seed, variant, feet, autoSleep: sleepCfg }), [seed, variant, feet]);

  const draw = (f: Frame) => {
    if (fillsRef.current) fillsRef.current.setAttribute('d', f.fills);
    if (eyesRef.current) eyesRef.current.setAttribute('d', f.eyes);
  };
  const stillFrame = () => drawCompanion(mergePose(restPose(variant), stateKeyPose(model.state, variant)), { size: sizeRef.current, variant, feet });
  const initial = useMemo(() => stillFrame(), []); // eslint-disable-line react-hooks/exhaustive-deps

  /** Before changing the model: bring a parked clock to the present (see `catchUp`). */
  const sync = () => entryRef.current && catchUp(entryRef.current);
  /** After changing the model: resume frames. */
  const kick = () => entryRef.current && wake(entryRef.current);

  useEffect(() => {
    sync();
    model.setAutoSleep(sleepCfg);
    kick();
  }, [model, sleepKey]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    sync();
    model.setReduced(reduced);
    kick();
  }, [model, reduced]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    sync();
    model.setState(state);
    if (still) draw(stillFrame());
    kick();
  }, [model, state, still]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (!reaction) return;
    sync();
    model.react(reaction.type);
    kick();
  }, [model, reaction?.key]); // eslint-disable-line react-hooks/exhaustive-deps

  const firstActivity = useRef(true);
  useEffect(() => {
    if (firstActivity.current) {
      firstActivity.current = false;
      return;
    }
    sync();
    model.activity();
    kick();
  }, [model, activity]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    if (entryRef.current) entryRef.current.render();
    else draw(stillFrame());
  }, [size]); // eslint-disable-line react-hooks/exhaustive-deps

  useEffect(() => {
    const el = svgRef.current;
    if (still || !el) {
      draw(stillFrame());
      return;
    }
    const entry: TickerEntry = {
      model,
      render: () => draw(drawCompanion(model.pose(), { size: sizeRef.current, variant, feet })),
      timeScale,
      visible: true,
      parkedAt: null,
      timer: null,
    };
    entryRef.current = entry;
    const pointer = followPointer ? follow(el, entry) : null;
    if (pointer) entry.before = () => model.setGaze(pointer.gaze());
    else model.setGaze(null);
    const unregister = register(entry);
    const unwatch = watchVisibility(el, (v) => setVisible(entry, v));
    return () => {
      unregister();
      unwatch();
      pointer?.stop();
      entryRef.current = null;
    };
  }, [model, still, followPointer, timeScale, variant, feet]); // eslint-disable-line react-hooks/exhaustive-deps

  useImperativeHandle(
    ref,
    () => ({
      react: (type) => {
        sync();
        model.react(type);
        kick();
      },
      sleep: () => {
        sync();
        model.sleepNow();
        kick();
      },
      wake: () => {
        sync();
        model.wakeNow();
        kick();
      },
      status: () => ({ state: model.state, rest: model.rest, reacting: model.reacting, inactive: model.inactive }),
    }),
    [model], // eslint-disable-line react-hooks/exhaustive-deps
  );

  const vb = VIEWBOX[variant];
  const height = (size * vb[3]) / vb[2];
  const svg = (
    <svg
      ref={svgRef}
      className={interactive ? undefined : className}
      style={{ display: 'block', overflow: 'visible', pointerEvents: 'none', ...(interactive ? null : style) }}
      width={size}
      height={height}
      viewBox={vb.join(' ')}
      role={label && !interactive ? 'img' : undefined}
      aria-label={interactive ? undefined : label}
      aria-hidden={label && !interactive ? undefined : true}
      focusable="false"
    >
      <path ref={fillsRef} d={initial.fills} fill={bodyColor} />
      <path ref={eyesRef} d={initial.eyes} fill={eyeColor} />
    </svg>
  );
  if (!interactive) return svg;
  return (
    <button
      type="button"
      className={className}
      style={{ all: 'unset', display: 'inline-block', cursor: 'pointer', borderRadius: 12, ...style }}
      aria-label={label ?? 'AIM'}
      onClick={() => {
        sync();
        model.react('poke');
        kick();
        onPoke?.();
      }}
    >
      {svg}
    </button>
  );
});

/** The still sign: a pure render with no engine, timers or listeners (navbar, favicon, SSR). */
export function AimMark({
  size = 32,
  variant = 'mark',
  state = 'idle',
  bodyColor = 'currentColor',
  eyeColor = EYE_DEFAULT,
  knockout = false,
  label,
  className,
  style,
}: {
  size?: number;
  variant?: CompanionVariant;
  state?: MascotState | 'drowsy' | 'asleep';
  bodyColor?: string;
  eyeColor?: string;
  /** One colour, eyes cut out (`evenodd`). */
  knockout?: boolean;
  label?: string;
  className?: string;
  style?: CSSProperties;
}) {
  const f = drawCompanion(mergePose(restPose(variant), stateKeyPose(state, variant)), { size, variant });
  const vb = VIEWBOX[variant];
  return (
    <svg
      className={className}
      style={{ display: 'block', pointerEvents: 'none', ...style }}
      width={size}
      height={(size * vb[3]) / vb[2]}
      viewBox={vb.join(' ')}
      role={label ? 'img' : undefined}
      aria-label={label}
      aria-hidden={label ? undefined : true}
      focusable="false"
    >
      {knockout ? (
        <path d={f.fills + f.eyes} fill={bodyColor} fillRule="evenodd" />
      ) : (
        <>
          <path d={f.fills} fill={bodyColor} />
          <path d={f.eyes} fill={eyeColor} />
        </>
      )}
    </svg>
  );
}
