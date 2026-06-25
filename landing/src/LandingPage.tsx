import {
  useEffect,
  useRef,
  useState,
  type ReactNode,
  type CSSProperties,
} from "react";

/* ============================================================== *
 *  Long Exposures — instrument/darkroom landing                  *
 *  Register: brand. Photos carry color; blue is a signal only.   *
 * ============================================================== */

const EASE = "cubic-bezier(0.22, 1, 0.36, 1)";

/* --- mechanical entrance: default-visible; only arm + animate elements that
       start below the fold. Anything already in view (or reduced-motion, or no JS)
       keeps the visible default and never gets clipped/faded. --- */
function useRise<T extends HTMLElement>(opts?: { variant?: "rise" | "wipe" }) {
  const ref = useRef<T | null>(null);
  useEffect(() => {
    const el = ref.current;
    if (!el) return;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    if (reduce) return;

    const variant = opts?.variant ?? "rise";
    const rect = el.getBoundingClientRect();
    const belowFold = rect.top > window.innerHeight * 0.9;
    if (!belowFold) return; // visible on load → leave it visible, no animation

    el.classList.add(variant, "arm");
    const reveal = () => el.classList.add("in");
    const obs = new IntersectionObserver(
      (entries) => {
        for (const e of entries) {
          if (e.isIntersecting) {
            reveal();
            obs.unobserve(e.target);
          }
        }
      },
      { threshold: 0.2, rootMargin: "0px 0px -6% 0px" }
    );
    obs.observe(el);
    // Safety net: if the observer never fires (background tab, no scroll),
    // reveal anyway so content is never permanently hidden.
    const fallback = window.setTimeout(reveal, 2500);
    return () => {
      obs.disconnect();
      window.clearTimeout(fallback);
    };
  }, [opts?.variant]);
  return ref;
}

function Rise({
  children,
  className = "",
  variant = "rise",
  style,
}: {
  children: ReactNode;
  className?: string;
  variant?: "rise" | "wipe";
  style?: CSSProperties;
}) {
  const ref = useRise<HTMLDivElement>({ variant });
  return (
    <div ref={ref} className={className} style={style}>
      {children}
    </div>
  );
}

/* ------------------------------- icons ------------------------------- */
/* Hairline, instrument-panel style. */

function ApertureMark({ className = "" }: { className?: string }) {
  return (
    <svg viewBox="0 0 100 100" className={className} aria-hidden>
      <circle cx="50" cy="50" r="45" fill="none" stroke="currentColor" strokeWidth="2" opacity="0.55" />
      {[0, 60, 120, 180, 240, 300].map((a) => (
        <path key={a} d="M50 10 L77 53 L50 53 Z" fill="currentColor" opacity="0.9" transform={`rotate(${a} 50 50)`} />
      ))}
      <polygon points="50,41 57.8,45.5 57.8,54.5 50,59 42.2,54.5 42.2,45.5" fill="#0b0c0e" />
    </svg>
  );
}

function Glyph({ d, className = "" }: { d: string; className?: string }) {
  return (
    <svg viewBox="0 0 24 24" className={className} fill="none" stroke="currentColor" strokeWidth="1.25" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
      <path d={d} />
    </svg>
  );
}

/* ---------------------------- small atoms ---------------------------- */

function Mono({ children, className = "", style }: { children: ReactNode; className?: string; style?: CSSProperties }) {
  return <span className={`font-mono text-[10px] uppercase tracking-[0.14em] ${className}`} style={style}>{children}</span>;
}

/* The page's one set of section markers — a real sequence (the pipeline),
   not a decorative eyebrow on every heading. */
function SectionLabel({ index, name }: { index: string; name: string }) {
  return (
    <div className="flex items-center gap-3 text-ink-3">
      <Mono className="tabular-nums text-signal-soft">{index}</Mono>
      <span className="h-px w-8 bg-line-bright" />
      <Mono>{name}</Mono>
    </div>
  );
}

/* ============================== NAV ============================== */

const LINKS = [
  { label: "Frames", href: "#frames" },
  { label: "Modes", href: "#modes" },
  { label: "Control", href: "#control" },
  { label: "On device", href: "#device" },
];

function Nav() {
  const [open, setOpen] = useState(false);
  const [scrolled, setScrolled] = useState(false);

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 8);
    onScroll();
    window.addEventListener("scroll", onScroll, { passive: true });
    return () => window.removeEventListener("scroll", onScroll);
  }, []);

  return (
    <>
      <header
        className="fixed inset-x-0 top-0 z-[var(--z-nav)] border-b transition-colors duration-500"
        style={{
          transitionTimingFunction: EASE,
          backgroundColor: scrolled ? "rgba(11,12,14,0.86)" : "transparent",
          borderColor: scrolled ? "var(--color-line)" : "transparent",
          backdropFilter: scrolled ? "blur(10px)" : "none",
        }}
      >
        <div className="mx-auto flex max-w-7xl items-center justify-between px-5 py-3.5 sm:px-8">
          <a href="#top" className="flex items-center gap-2.5">
            <ApertureMark className="h-6 w-6 text-signal" />
            <span className="font-display text-xl font-extrabold leading-none text-ink">
              Long Exposures
            </span>
          </a>

          <nav className="hidden items-center gap-7 md:flex">
            {LINKS.map((l) => (
              <a key={l.href} href={l.href} className="text-[13px] text-ink-2 transition-colors duration-300 hover:text-ink">
                {l.label}
              </a>
            ))}
          </nav>

          <div className="hidden md:block">
            <AppStoreBadge size="compact" />
          </div>

          <button
            aria-label="Toggle menu"
            aria-expanded={open}
            onClick={() => setOpen((v) => !v)}
            className="relative flex h-9 w-9 items-center justify-center border border-line-bright bg-panel md:hidden"
          >
            <span className="absolute h-px w-4 bg-ink transition-all duration-500" style={{ transform: open ? "rotate(45deg)" : "translateY(-3px)", transitionTimingFunction: EASE }} />
            <span className="absolute h-px w-4 bg-ink transition-all duration-300" style={{ opacity: open ? 0 : 1 }} />
            <span className="absolute h-px w-4 bg-ink transition-all duration-500" style={{ transform: open ? "rotate(-45deg)" : "translateY(3px)", transitionTimingFunction: EASE }} />
          </button>
        </div>
      </header>

      <div
        className="fixed inset-0 z-[var(--z-overlay)] flex flex-col justify-center gap-2 bg-base/95 px-6 backdrop-blur-md transition-opacity duration-400 md:hidden"
        style={{ opacity: open ? 1 : 0, pointerEvents: open ? "auto" : "none", transitionTimingFunction: EASE }}
      >
        {LINKS.map((l, i) => (
          <a
            key={l.href}
            href={l.href}
            onClick={() => setOpen(false)}
            className="border-b border-line py-4 font-display text-4xl font-bold text-ink transition-all duration-500"
            style={{
              transform: open ? "translateX(0)" : "translateX(-1rem)",
              opacity: open ? 1 : 0,
              transitionDelay: `${open ? 60 + i * 50 : 0}ms`,
              transitionTimingFunction: EASE,
            }}
          >
            <span className="mr-4 font-mono text-sm text-ink-3">0{i + 1}</span>
            {l.label}
          </a>
        ))}
        <a href="#get" onClick={() => setOpen(false)} className="mt-6 inline-flex w-max items-center gap-2 bg-signal px-5 py-3 text-sm font-semibold text-base">
          Get the app
          <Glyph d="M7 17 L17 7 M9 7 H17 V15" className="h-4 w-4" />
        </a>
      </div>
    </>
  );
}

/* ===================== PHOTO PLACEHOLDER ====================== *
 *  Honest, labeled film-frame slot. NOT disguised as final art. *
 *  Swap `src` in PHOTOS[] when real exposures are dropped in.    *
 * ============================================================== */

function FrameSlot({
  src,
  alt,
  caption,
  mode,
  exposure,
  className = "",
  aspect = "4 / 5",
}: {
  src?: string;
  alt: string;
  caption: string;
  mode: string;
  exposure: string;
  className?: string;
  aspect?: string;
}) {
  return (
    <figure className={`group relative overflow-hidden border border-line bg-panel-2 ${className}`} style={{ aspectRatio: aspect }}>
      {src ? (
        <img src={src} alt={alt} className="h-full w-full object-cover transition-transform duration-[1200ms] group-hover:scale-[1.03]" style={{ transitionTimingFunction: EASE }} loading="lazy" />
      ) : (
        /* placeholder — clearly a slot awaiting a real shot */
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 text-ink-3">
          <div className="absolute inset-0 ticks opacity-30" />
          <div className="pointer-events-none absolute inset-3 border border-dashed border-line-bright" />
          <Glyph d="M4 8 L7 8 L8.5 5.5 L15.5 5.5 L17 8 L20 8 V18 H4 Z M12 12.5 m-3 0 a3 3 0 1 0 6 0 a3 3 0 1 0 -6 0" className="relative h-7 w-7" />
          <Mono className="relative">Your exposure</Mono>
          <span className="relative max-w-[14ch] text-center text-[11px] leading-snug text-ink-3">{alt}</span>
        </div>
      )}

      {/* instrument readout strip */}
      <figcaption className="absolute inset-x-0 bottom-0 flex items-center justify-between border-t border-line/80 bg-base/70 px-3 py-2 backdrop-blur-sm">
        <span className="text-[12px] font-medium text-ink">{caption}</span>
        <span className="flex items-center gap-2">
          <Mono className="text-signal-soft">{mode}</Mono>
          <Mono className="tabular-nums text-ink-3">{exposure}</Mono>
        </span>
      </figcaption>
    </figure>
  );
}

/* ====================== INTERACTIVE TIMELINE ====================== *
 *  The hero proof: "you pick the frames." A real range instrument.  *
 * ================================================================= */

const FRAMES = 32;

function FrameSelector() {
  const [range, setRange] = useState<[number, number]>([7, 23]);
  const trackRef = useRef<HTMLDivElement | null>(null);
  const drag = useRef<null | "lo" | "hi">(null);

  useEffect(() => {
    const frameAt = (clientX: number) => {
      const el = trackRef.current;
      if (!el) return 0;
      const r = el.getBoundingClientRect();
      const t = Math.min(1, Math.max(0, (clientX - r.left) / r.width));
      return Math.round(t * (FRAMES - 1));
    };
    const move = (e: PointerEvent) => {
      if (!drag.current) return;
      const f = frameAt(e.clientX);
      setRange(([lo, hi]) => (drag.current === "lo" ? [Math.min(f, hi - 1), hi] : [lo, Math.max(f, lo + 1)]));
    };
    const up = () => (drag.current = null);
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
    return () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
  }, []);

  const onKey = (side: "lo" | "hi") => (e: React.KeyboardEvent) => {
    const delta = e.key === "ArrowLeft" ? -1 : e.key === "ArrowRight" ? 1 : 0;
    if (!delta) return;
    e.preventDefault();
    setRange(([lo, hi]) =>
      side === "lo" ? [Math.min(Math.max(0, lo + delta), hi - 1), hi] : [lo, Math.max(Math.min(FRAMES - 1, hi + delta), lo + 1)]
    );
  };

  const count = range[1] - range[0] + 1;

  return (
    <div className="border border-line bg-panel">
      {/* header readout */}
      <div className="flex items-center justify-between border-b border-line px-4 py-2.5 sm:px-5">
        <Mono className="text-ink-3">Frame range</Mono>
        <div className="flex items-baseline gap-1.5">
          <span className="font-mono text-lg font-medium tabular-nums text-signal-soft">
            {String(count).padStart(2, "0")}
          </span>
          <Mono className="text-ink-3">frames blended</Mono>
        </div>
      </div>

      <div className="px-4 py-6 sm:px-5">
        <div ref={trackRef} className="relative h-20 w-full touch-none select-none">
          {/* frame bars */}
          <div className="absolute inset-0 flex items-end gap-[2px]">
            {Array.from({ length: FRAMES }).map((_, i) => {
              const on = i >= range[0] && i <= range[1];
              const h = 30 + Math.abs(Math.sin(i * 1.7)) * 60; // pseudo-waveform
              return (
                <div
                  key={i}
                  className="flex-1 transition-colors duration-300"
                  style={{
                    height: `${on ? h : h * 0.55}%`,
                    transitionTimingFunction: EASE,
                    backgroundColor: on ? "var(--color-signal)" : "var(--color-line-bright)",
                    opacity: on ? 0.9 : 0.6,
                  }}
                />
              );
            })}
          </div>

          {/* dimming scrims over excluded frames */}
          <div className="pointer-events-none absolute inset-y-0 left-0 bg-base/55" style={{ width: `${(range[0] / FRAMES) * 100}%` }} />
          <div className="pointer-events-none absolute inset-y-0 right-0 bg-base/55" style={{ width: `${((FRAMES - 1 - range[1]) / FRAMES) * 100}%` }} />

          {/* handles */}
          {(["lo", "hi"] as const).map((side) => {
            const idx = side === "lo" ? range[0] : range[1];
            const pct = side === "lo" ? (idx / FRAMES) * 100 : ((idx + 1) / FRAMES) * 100;
            return (
              <button
                key={side}
                role="slider"
                aria-label={side === "lo" ? "First frame" : "Last frame"}
                aria-valuemin={0}
                aria-valuemax={FRAMES - 1}
                aria-valuenow={idx}
                tabIndex={0}
                onKeyDown={onKey(side)}
                onPointerDown={(e) => {
                  (e.target as HTMLElement).setPointerCapture?.(e.pointerId);
                  drag.current = side;
                }}
                className="absolute top-0 z-10 flex h-full w-4 -translate-x-1/2 cursor-ew-resize items-center justify-center bg-ink outline-none ring-signal-soft transition-transform duration-150 focus-visible:ring-2 active:scale-y-95"
                style={{ left: `${pct}%` }}
              >
                <span className="flex flex-col gap-[3px]">
                  <span className="h-px w-2 bg-base/40" />
                  <span className="h-px w-2 bg-base/40" />
                  <span className="h-px w-2 bg-base/40" />
                </span>
              </button>
            );
          })}
        </div>

        {/* ruler */}
        <div className="mt-3 flex items-center justify-between font-mono text-[10px] tabular-nums text-ink-3">
          <span>00</span>
          <span>{String(Math.floor(FRAMES / 2)).padStart(2, "0")}</span>
          <span>{FRAMES - 1}</span>
        </div>
      </div>

      <p className="border-t border-line px-4 py-3 text-[13px] text-ink-2 sm:px-5">
        Drag the jaws. Only the frames inside blend — the rest are dropped. The composite
        re-renders live, exactly like the timeline inside the app.
      </p>
    </div>
  );
}

/* ============================== MODES ============================== */

const MODES = [
  {
    id: "average",
    name: "Average",
    use: "Silky motion blur",
    body: "Every selected frame averaged in linear light. Flowing water turns to mist, clouds streak, a crowd dissolves to ghosts.",
  },
  {
    id: "lighten",
    name: "Lighten",
    use: "Light trails",
    body: "Keeps the brightest pixel across frames. Headlights become ribbons, sparklers draw, stars arc into trails.",
  },
  {
    id: "darken",
    name: "Darken",
    use: "Subtract motion",
    body: "Keeps the darkest pixel. Strip moving people out of a bright plaza, or carve shadow back into an overlit scene.",
  },
];

function ModeSwitch() {
  const [active, setActive] = useState(0);
  const mode = MODES[active];

  return (
    <div className="grid gap-px overflow-hidden border border-line bg-line md:grid-cols-[minmax(0,1fr)_minmax(0,1.1fr)]">
      {/* left: selector + copy */}
      <div className="flex flex-col bg-panel p-6 sm:p-8">
        <Mono className="text-ink-3">Blend mode</Mono>

        <div className="mt-4 flex flex-col">
          {MODES.map((m, i) => {
            const on = i === active;
            return (
              <button
                key={m.id}
                onClick={() => setActive(i)}
                className="group flex items-center justify-between border-b border-line py-4 text-left transition-colors duration-300"
                style={{ transitionTimingFunction: EASE }}
              >
                <span className="flex items-baseline gap-3">
                  <span
                    className="h-2 w-2 rounded-full transition-all duration-300"
                    style={{ backgroundColor: on ? "var(--color-signal)" : "var(--color-line-bright)", boxShadow: on ? "0 0 10px var(--color-signal)" : "none" }}
                  />
                  <span
                    className="font-display text-3xl font-bold transition-colors duration-300"
                    style={{ color: on ? "var(--color-ink)" : "var(--color-ink-3)" }}
                  >
                    {m.name}
                  </span>
                </span>
                <Mono style={{ color: on ? "var(--color-signal-soft)" : "var(--color-ink-3)" }}>{m.use}</Mono>
              </button>
            );
          })}
        </div>

        <p key={mode.id} className="prose-pretty mt-6 text-[15px] leading-relaxed text-ink-2" style={{ animation: "fadeKey 400ms cubic-bezier(0.22,1,0.36,1)" }}>
          {mode.body}
        </p>
      </div>

      {/* right: the result frame for the active mode */}
      <FrameSlot
        key={mode.id}
        alt={`${mode.name} result — drop a long exposure shot rendered in ${mode.name} mode here`}
        caption={`${mode.name} result`}
        mode={mode.name.toUpperCase()}
        exposure="ƒ/16 · 4.0s"
        aspect="auto"
        className="min-h-[20rem] border-0"
      />
    </div>
  );
}

/* ============================== PAGE ============================== */

const PIPELINE = [
  { d: "M4 12 H20 M20 12 L15 7 M20 12 L15 17", label: "Import a Live Photo or video — or capture a new clip in-app." },
  { d: "M4 7 H20 M4 12 H20 M4 17 H20 M9 4 V20 M15 4 V20", label: "Drag the frame jaws to keep exactly the moment you want." },
  { d: "M5 19 V9 M12 19 V5 M19 19 V13 M3 19 H21", label: "Pick a blend mode and watch the composite resolve live." },
  { d: "M12 4 V14 M12 14 L8 10 M12 14 L16 10 M5 18 H19", label: "Export full-resolution to Photos. Nothing leaves the phone." },
];

export function LandingPage() {
  return (
    <div id="top" className="grain relative">
      <Nav />

      <main>
        {/* ============ HERO ============ */}
        <section className="mx-auto max-w-7xl px-5 pt-28 sm:px-8 sm:pt-32 md:pt-40">
          <div className="grid items-end gap-10 lg:grid-cols-12 lg:gap-12">
            {/* headline column */}
            <div className="lg:col-span-7">
              <Rise>
                <SectionLabel index="①" name="A darkroom in your pocket" />
              </Rise>
              <Rise variant="wipe" className="mt-6">
                <h1 className="font-display text-[clamp(3rem,9vw,5.75rem)] font-extrabold leading-[0.92] text-ink">
                  The long exposure
                  <br />
                  was already in
                  <br />
                  <span className="text-signal">your Live Photos.</span>
                </h1>
              </Rise>
              <Rise className="mt-7" style={{ transitionDelay: "120ms" }}>
                <p className="prose-pretty text-[17px] leading-relaxed text-ink-2">
                  Long Exposures pulls the frames out of a clip you already shot and blends the
                  ones you choose — tripod-grade water, light trails, motion blur. You set the
                  range. The phone does the rest, and keeps it.
                </p>
              </Rise>
              <Rise className="mt-9 flex flex-wrap items-center gap-x-7 gap-y-4" style={{ transitionDelay: "200ms" }}>
                <AppStoreBadge />
                <div className="flex items-center gap-2 text-[13px] text-ink-2">
                  <span className="h-1.5 w-1.5 rounded-full bg-signal" />
                  100% on device · no account · nothing uploaded
                </div>
              </Rise>
            </div>

            {/* hero proof: the frame selector instrument */}
            <div className="lg:col-span-5">
              <Rise style={{ transitionDelay: "160ms" }}>
                <FrameSelector />
              </Rise>
            </div>
          </div>

          {/* full-bleed result strip */}
          <Rise className="mt-16 grid grid-cols-2 gap-px border border-line bg-line md:grid-cols-4" style={{ transitionDelay: "120ms" }}>
            <FrameSlot alt="Silky waterfall blurred to mist over wet rock" caption="Falls, long" mode="AVG" exposure="2.5s" className="border-0" />
            <FrameSlot alt="Red and white car light trails on a night highway curve" caption="Highway 1" mode="LTN" exposure="6.0s" className="border-0" />
            <FrameSlot alt="Star trails arcing over a dark ridgeline" caption="North ridge" mode="LTN" exposure="30s" className="border-0" />
            <FrameSlot alt="Empty plaza with moving people subtracted out" caption="Piazza, clear" mode="DRK" exposure="8.0s" className="border-0" />
          </Rise>
        </section>

        {/* ============ FRAMES / why you pick ============ */}
        <section id="frames" className="mx-auto max-w-7xl px-5 py-28 sm:px-8 md:py-36">
          <div className="grid gap-12 lg:grid-cols-12">
            <div className="lg:col-span-5">
              <Rise>
                <SectionLabel index="②" name="You pick the frames" />
                <h2 className="mt-6 font-display text-[clamp(2.25rem,5vw,3.5rem)] font-bold leading-[0.98] text-ink">
                  Apple's effect picks the moment. Here, you do.
                </h2>
                <p className="prose-pretty mt-6 text-[16px] leading-relaxed text-ink-2">
                  The built-in Long Exposure gives you one automatic result and no way to change
                  it. This is the manual control: a frame-by-frame timeline with two jaws. Trim to
                  the exact stretch, choose how the frames combine, and the preview re-renders as
                  you drag.
                </p>
              </Rise>
            </div>

            <div className="lg:col-span-7">
              <ol className="grid gap-px border border-line bg-line sm:grid-cols-2">
                {PIPELINE.map((step, i) => (
                  <Rise key={i} style={{ transitionDelay: `${i * 70}ms` }}>
                    <li className="flex h-full list-none flex-col gap-4 bg-panel p-6 sm:p-7">
                      <div className="flex items-center justify-between">
                        <Glyph d={step.d} className="h-6 w-6 text-signal-soft" />
                        <span className="font-mono text-sm tabular-nums text-ink-3">0{i + 1}</span>
                      </div>
                      <p className="text-[15px] leading-relaxed text-ink-2">{step.label}</p>
                    </li>
                  </Rise>
                ))}
              </ol>
            </div>
          </div>
        </section>

        {/* ============ MODES ============ */}
        <section id="modes" className="mx-auto max-w-7xl px-5 py-28 sm:px-8 md:py-32">
          <Rise className="mb-12 max-w-3xl">
            <SectionLabel index="③" name="Three ways to combine" />
            <h2 className="mt-6 font-display text-[clamp(2.25rem,5vw,3.5rem)] font-bold leading-[0.98] text-ink">
              One clip. Three different photographs.
            </h2>
          </Rise>
          <Rise>
            <ModeSwitch />
          </Rise>
        </section>

        {/* ============ CONTROL / fine adjustments ============ */}
        <section id="control" className="mx-auto max-w-7xl px-5 py-28 sm:px-8 md:py-36">
          <Rise className="mb-12 max-w-3xl">
            <SectionLabel index="④" name="The fine controls" />
            <h2 className="mt-6 font-display text-[clamp(2.25rem,5vw,3.5rem)] font-bold leading-[0.98] text-ink">
              The dials a real long exposure needs.
            </h2>
          </Rise>

          <div className="grid gap-px border border-line bg-line lg:grid-cols-3">
            {[
              { name: "Align handheld shots", icon: "M4 4 H14 V14 H4 Z M10 10 H20 V20 H10 Z", body: "On-device registration locks the static background sharp while moving subjects blur. Shoot without a tripod." },
              { name: "Match exposure", icon: "M12 7 a5 5 0 1 0 0 10 a5 5 0 1 0 0 -10 M12 2 V4 M12 20 V22 M2 12 H4 M20 12 H22", body: "Evens out the brightness flicker the camera bakes in between frames, so the blend stays clean instead of pulsing." },
              { name: "Hold to compare", icon: "M12 4 V20 M4 6 H10 V18 H4 Z M14 6 H20 V18 H14 Z", body: "Press the preview to flip to a single sharp frame and see exactly what the exposure added." },
            ].map((f, i) => (
              <Rise key={f.name} style={{ transitionDelay: `${i * 70}ms` }}>
                <div className="flex h-full flex-col gap-5 bg-panel p-7 sm:p-8">
                  <Glyph d={f.icon} className="h-7 w-7 text-signal-soft" />
                  <h3 className="font-display text-2xl font-bold text-ink">{f.name}</h3>
                  <p className="text-[15px] leading-relaxed text-ink-2">{f.body}</p>
                </div>
              </Rise>
            ))}
          </div>

          {/* capture callout — distinct treatment, not another card in the grid */}
          <Rise className="mt-px grid items-stretch gap-px border border-t-0 border-line bg-line md:grid-cols-[1.4fr_1fr]">
            <div className="flex flex-col justify-center gap-4 bg-panel p-7 sm:p-10">
              <Mono className="text-ink-3">In-app capture</Mono>
              <h3 className="font-display text-[clamp(1.75rem,4vw,2.75rem)] font-bold leading-tight text-ink">
                Or shoot a fresh clip with the exposure locked.
              </h3>
              <p className="prose-pretty text-[15px] leading-relaxed text-ink-2">
                Record inside the app with exposure and white balance pinned, so every frame
                matches before they ever blend. The cleanest possible source — no flicker to fix.
              </p>
            </div>
            <FrameSlot alt="In-app camera capturing a locked-exposure clip at night" caption="Capture · locked" mode="LIVE" exposure="REC" aspect="auto" className="min-h-[16rem] border-0" />
          </Rise>
        </section>

        {/* ============ DEVICE / privacy ============ */}
        <section id="device" className="mx-auto max-w-7xl px-5 py-28 sm:px-8 md:py-36">
          <Rise>
            <div className="border border-line bg-panel p-8 sm:p-12 md:p-16">
              <SectionLabel index="⑤" name="On device" />
              <h2 className="mt-7 max-w-3xl font-display text-[clamp(2.5rem,6vw,4.5rem)] font-extrabold leading-[0.95] text-ink">
                Your photos never leave the phone.
              </h2>
              <p className="prose-pretty mt-7 text-[16px] leading-relaxed text-ink-2">
                Every blend, alignment, and export runs on the device's own Metal GPU. No servers,
                no account, no analytics, no third-party SDKs. There's nothing to upload because
                there's nowhere to upload it — privacy by architecture, not by policy.
              </p>

              <dl className="mt-12 grid gap-px border border-line bg-line sm:grid-cols-3">
                {[
                  ["00", "frames uploaded", "Processing is 100% local."],
                  ["GPU", "Metal compute", "Reduction over N frames in linear light, on-device."],
                  ["—", "accounts required", "Open it and edit. No sign-in, ever."],
                ].map(([big, label, sub]) => (
                  <div key={label} className="bg-panel p-6 sm:p-7">
                    <div className="font-mono text-3xl font-medium tabular-nums text-signal-soft">{big}</div>
                    <div className="mt-2 text-[14px] font-medium text-ink">{label}</div>
                    <div className="mt-1 text-[13px] leading-snug text-ink-3">{sub}</div>
                  </div>
                ))}
              </dl>
            </div>
          </Rise>
        </section>

        {/* ============ GET ============ */}
        <section id="get" className="mx-auto max-w-7xl px-5 py-28 sm:px-8 md:py-40">
          <Rise className="flex flex-col items-start gap-8 border-t border-line pt-16 md:flex-row md:items-end md:justify-between">
            <div>
              <h2 className="font-display text-[clamp(2.75rem,8vw,6rem)] font-extrabold leading-[0.9] text-ink">
                Make the shot
                <br />
                you couldn't take.
              </h2>
              <p className="prose-pretty mt-6 text-[16px] leading-relaxed text-ink-2">
                Free to try, with the Live Photos already in your library. iPhone · iOS 17 and up.
              </p>
            </div>
            <AppStoreBadge size="large" />
          </Rise>
        </section>

        {/* ============ FOOTER ============ */}
        <footer className="border-t border-line">
          <div className="mx-auto flex max-w-7xl flex-col gap-6 px-5 py-10 sm:flex-row sm:items-center sm:justify-between sm:px-8">
            <div className="flex items-center gap-2.5">
              <ApertureMark className="h-5 w-5 text-signal" />
              <span className="font-display text-lg font-bold text-ink">Long Exposures</span>
            </div>
            <Mono className="text-ink-3">Photo &amp; Video · iPhone · iOS 17+</Mono>
            <div className="flex items-center gap-6 text-[13px] text-ink-2">
              <a href="#" className="transition-colors hover:text-ink">Privacy</a>
              <a href="mailto:james.william.hou@gmail.com" className="transition-colors hover:text-ink">Support</a>
            </div>
          </div>
        </footer>
      </main>

      <style>{`
        @keyframes fadeKey { from { opacity: 0; transform: translateY(6px); } to { opacity: 1; transform: translateY(0); } }
      `}</style>
    </div>
  );
}

/* ---- App Store badge ---- */
function AppStoreBadge({ size = "default" }: { size?: "compact" | "default" | "large" }) {
  const pad = size === "large" ? "px-6 py-4" : size === "compact" ? "px-3 py-1.5" : "px-5 py-3";
  const gap = size === "compact" ? "gap-2" : "gap-3";
  const logo = size === "large" ? "h-8 w-8" : size === "compact" ? "h-5 w-5" : "h-7 w-7";
  const kicker = size === "compact" ? "text-[8px]" : "text-[10px]";
  const word = size === "large" ? "text-2xl" : size === "compact" ? "text-base" : "text-xl";
  return (
    <a
      href="#get"
      aria-label="Download Long Exposures on the App Store"
      className={`group inline-flex items-center ${gap} border border-line-bright bg-ink text-base transition-all duration-300 hover:border-signal active:scale-[0.98] ${pad}`}
      style={{ transitionTimingFunction: EASE }}
    >
      <svg viewBox="0 0 24 24" className={logo} fill="currentColor" aria-hidden>
        <path d="M16.36 12.78c-.02-2.2 1.8-3.26 1.88-3.31-1.02-1.5-2.62-1.71-3.19-1.73-1.36-.14-2.65.8-3.34.8-.69 0-1.75-.78-2.88-.76-1.48.02-2.85.86-3.61 2.19-1.54 2.67-.39 6.62 1.11 8.79.73 1.06 1.6 2.25 2.74 2.21 1.1-.04 1.51-.71 2.84-.71 1.32 0 1.7.71 2.86.69 1.18-.02 1.93-1.08 2.65-2.15.84-1.23 1.18-2.42 1.2-2.48-.03-.01-2.29-.88-2.31-3.49zM14.2 6.3c.6-.74 1.01-1.74.9-2.76-.87.04-1.95.59-2.58 1.31-.56.64-1.06 1.69-.93 2.67.98.08 1.99-.49 2.61-1.22z" />
      </svg>
      <span className="flex flex-col leading-none">
        <span className={`${kicker} font-medium opacity-70`}>Download on the</span>
        <span className={`font-display font-bold ${word}`}>App Store</span>
      </span>
    </a>
  );
}
