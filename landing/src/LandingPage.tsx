import {
  useEffect,
  useRef,
  useState,
  type ReactNode,
  type CSSProperties,
} from "react";

const EASE = "cubic-bezier(0.22, 1, 0.36, 1)";

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
    if (!belowFold) return; 

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


function Mono({ children, className = "", style }: { children: ReactNode; className?: string; style?: CSSProperties }) {
  return <span className={`font-mono text-[10px] uppercase tracking-[0.14em] ${className}`} style={style}>{children}</span>;
}

function SectionLabel({ index, name }: { index: string; name: string }) {
  return (
    <div className="flex items-center gap-3 text-ink-3">
      <Mono className="tabular-nums text-signal-soft">{index}</Mono>
      <span className="h-px w-8 bg-line-bright" />
      <Mono>{name}</Mono>
    </div>
  );
}

const LINKS = [
  { label: "Frames", href: "#frames" },
  { label: "Controls", href: "#control" },
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

function BeforeAfterSlider({
  before,
  after,
  beforeAlt,
  afterAlt,
  beforeLabel,
  afterLabel,
}: {
  before: string;
  after: string;
  beforeAlt: string;
  afterAlt: string;
  beforeLabel: string;
  afterLabel: string;
}) {
  const [pos, setPos] = useState(50); 
  const frameRef = useRef<HTMLDivElement | null>(null);
  const dragging = useRef(false);

  useEffect(() => {
    const setFromClientX = (clientX: number) => {
      const el = frameRef.current;
      if (!el) return;
      const r = el.getBoundingClientRect();
      const t = Math.min(100, Math.max(0, ((clientX - r.left) / r.width) * 100));
      setPos(t);
    };
    const move = (e: PointerEvent) => {
      if (!dragging.current) return;
      e.preventDefault();
      setFromClientX(e.clientX);
    };
    const up = () => (dragging.current = false);
    window.addEventListener("pointermove", move, { passive: false });
    window.addEventListener("pointerup", up);
    return () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
    };
  }, []);

  const onKey = (e: React.KeyboardEvent) => {
    const step = e.shiftKey ? 10 : 4;
    if (e.key === "ArrowLeft") { e.preventDefault(); setPos((p) => Math.max(0, p - step)); }
    if (e.key === "ArrowRight") { e.preventDefault(); setPos((p) => Math.min(100, p + step)); }
  };

  return (
    <div className="border border-line bg-panel">
      <div
        ref={frameRef}
        className="relative w-full touch-none select-none overflow-hidden bg-base"
        style={{ aspectRatio: "9 / 16", maxHeight: "70vh" }}
      >
        <img src={after} alt={afterAlt} draggable={false} className="absolute inset-0 h-full w-full object-contain" />
        <div className="absolute inset-0" style={{ clipPath: `inset(0 ${100 - pos}% 0 0)` }}>
          <img src={before} alt={beforeAlt} draggable={false} className="absolute inset-0 h-full w-full object-contain" />
        </div>

        <span className="pointer-events-none absolute left-3 top-3 bg-base/70 px-2 py-1 backdrop-blur-sm">
          <Mono className="text-ink-2">{beforeLabel}</Mono>
        </span>
        <span className="pointer-events-none absolute right-3 top-3 bg-base/70 px-2 py-1 backdrop-blur-sm">
          <Mono className="text-signal-soft">{afterLabel}</Mono>
        </span>
        <div className="pointer-events-none absolute inset-y-0" style={{ left: `${pos}%`, transform: "translateX(-50%)" }}>
          <div className="absolute inset-y-0 left-1/2 w-px -translate-x-1/2 bg-signal/90 shadow-[0_0_12px_rgba(45,140,255,0.6)]" />
          <button
            role="slider"
            aria-label="Reveal aligned vs unaligned"
            aria-valuemin={0}
            aria-valuemax={100}
            aria-valuenow={Math.round(pos)}
            tabIndex={0}
            onKeyDown={onKey}
            onPointerDown={(e) => {
              (e.target as HTMLElement).setPointerCapture?.(e.pointerId);
              dragging.current = true;
            }}
            className="pointer-events-auto absolute top-1/2 left-1/2 flex h-11 w-11 -translate-x-1/2 -translate-y-1/2 cursor-ew-resize items-center justify-center rounded-full border border-signal bg-base/90 outline-none ring-signal-soft backdrop-blur-sm focus-visible:ring-2"
          >
            <Glyph d="M10 8 L6 12 L10 16 M14 8 L18 12 L14 16" className="h-5 w-5 text-signal-soft" />
          </button>
        </div>
      </div>

      <p className="border-t border-line px-4 py-3 text-[13px] text-ink-2 sm:px-5">
        Drag the divider. Left: frames blended raw — handheld shake smears the whole scene.
        Right: <span className="text-ink">Align frames</span> on — the static background snaps
        sharp while the lights keep their trails.
      </p>
    </div>
  );
}

function HeroResult({
  src,
  alt,
  frames,
  exposure,
}: {
  src?: string;
  alt: string;
  frames: number;
  exposure: string;
}) {
  return (
    <figure className="group relative overflow-hidden border border-line bg-panel-2">
      <figcaption className="flex items-center justify-between border-b border-line bg-panel px-4 py-2.5 sm:px-5">
        <span className="flex items-center gap-2">
          <Glyph d="M4 7 a2 2 0 0 1 2 -2 h8 a2 2 0 0 1 2 2 v10 a2 2 0 0 1 -2 2 H6 a2 2 0 0 1 -2 -2 Z M18 9 L21 7 V17 L18 15" className="h-4 w-4 text-ink-3" />
          <Mono className="text-ink-3">Live Photo</Mono>
        </span>
        <Glyph d="M5 12 H17 M17 12 L13 8 M17 12 L13 16" className="h-4 w-7 text-signal/70" />
        <span className="flex items-baseline gap-1.5">
          <span className="font-mono text-base font-medium tabular-nums text-signal-soft">{frames}</span>
          <Mono className="text-ink-3">frames blended</Mono>
        </span>
      </figcaption>

      <div className="relative" style={{ aspectRatio: "3 / 4" }}>
        {src ? (
          <img
            src={src}
            alt={alt}
            className="h-full w-full object-cover transition-transform duration-[1400ms] group-hover:scale-[1.03]"
            style={{ transitionTimingFunction: EASE }}
          />
        ) : (
          <div className="absolute inset-0 flex flex-col items-center justify-center gap-3 bg-base text-ink-3">
            <div className="absolute inset-0 ticks opacity-25" />
            <div className="pointer-events-none absolute inset-3 border border-dashed border-line-bright" />
            <Glyph d="M4 8 L7 8 L8.5 5.5 L15.5 5.5 L17 8 L20 8 V18 H4 Z M12 12.5 m-3 0 a3 3 0 1 0 6 0 a3 3 0 1 0 -6 0" className="relative h-8 w-8" />
            <Mono className="relative">Finished exposure</Mono>
            <span className="relative max-w-[22ch] text-center text-[12px] leading-snug text-ink-3">{alt}</span>
          </div>
        )}

        <span className="pointer-events-none absolute bottom-3 right-3 bg-base/70 px-2 py-1 backdrop-blur-sm">
          <Mono className="tabular-nums text-ink-2">{exposure}</Mono>
        </span>
      </div>
    </figure>
  );
}

// modes

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

  return (
    <div className="overflow-hidden border border-line bg-panel">
      <div className="border-b border-line px-7 py-5 sm:px-10">
        <Mono className="text-ink-3">Blend mode</Mono>
      </div>

      <div className="grid gap-px bg-line lg:grid-cols-3">
        {MODES.map((m, i) => {
          const on = i === active;
          return (
            <button
              key={m.id}
              onClick={() => setActive(i)}
              className="flex flex-col gap-4 bg-panel p-7 text-left transition-colors duration-300 sm:p-8"
              style={{ transitionTimingFunction: EASE }}
            >
              <span className="flex items-center gap-3">
                <span
                  className="h-2 w-2 rounded-full transition-all duration-300"
                  style={{ backgroundColor: on ? "var(--color-signal)" : "var(--color-line-bright)", boxShadow: on ? "0 0 10px var(--color-signal)" : "none" }}
                />
                <span
                  className="font-display text-2xl font-bold transition-colors duration-300"
                  style={{ color: on ? "var(--color-ink)" : "var(--color-ink-3)" }}
                >
                  {m.name}
                </span>
                <Mono className="ml-auto" style={{ color: on ? "var(--color-signal-soft)" : "var(--color-ink-3)" }}>{m.use}</Mono>
              </span>
              <p
                className="text-[14px] leading-relaxed transition-colors duration-300"
                style={{ color: on ? "var(--color-ink-2)" : "var(--color-ink-3)" }}
              >
                {m.body}
              </p>
            </button>
          );
        })}
      </div>
    </div>
  );
}

// page

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
        <section className="mx-auto max-w-7xl px-5 pt-28 sm:px-8 sm:pt-32 md:pt-40">
          <div className="grid items-center gap-10 lg:grid-cols-12 lg:gap-12">
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
                  Feed it a clip you already shot. Long Exposures blends the frames you choose into
                  a single photograph — tripod-grade water, light trails, motion blur. The phone
                  does the work, and keeps it.
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

            <div className="lg:col-span-5">
              <Rise style={{ transitionDelay: "160ms" }}>
                <HeroResult
                  src="/exposures/hero.jpg"
                  alt="View of a busy street at night"
                  frames={167}
                  exposure="15s"
                />
              </Rise>
            </div>
          </div>

        </section>

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

        <section id="control" className="mx-auto max-w-7xl px-5 py-28 sm:px-8 md:py-36">
          <Rise className="mb-12 max-w-3xl">
            <SectionLabel index="③" name="The controls" />
            <h2 className="mt-6 font-display text-[clamp(2.25rem,5vw,3.5rem)] font-bold leading-[0.98] text-ink">
              The dials a real long exposure needs.
            </h2>
          </Rise>

          <Rise className="grid items-stretch gap-px border border-line bg-line lg:grid-cols-[1fr_minmax(0,0.85fr)]">
            <div className="flex flex-col justify-center gap-5 bg-panel p-7 sm:p-10">
              <Glyph d="M4 4 H14 V14 H4 Z M10 10 H20 V20 H10 Z" className="h-7 w-7 text-signal-soft" />
              <h3 className="font-display text-[clamp(1.75rem,4vw,2.75rem)] font-bold leading-tight text-ink">
                Align handheld shots without a tripod.
              </h3>
              <p className="prose-pretty text-[15px] leading-relaxed text-ink-2">
                On-device registration locks the static background sharp while moving subjects
                keep their blur. Drag the divider on a real shot — same 67 frames, Align off
                versus on.
              </p>
            </div>
            <div className="bg-panel p-3 sm:p-4">
              <BeforeAfterSlider
                before="/screenshots/align-off.png"
                after="/screenshots/align-on.png"
                beforeAlt="Long Exposures editor with Align frames off — the blended night street is a smeared, doubled blur from handheld shake"
                afterAlt="Long Exposures editor with Align frames on — the same night street is sharp, with clean light trails from the cars"
                beforeLabel="Align off"
                afterLabel="Align on"
              />
            </div>
          </Rise>

          <Rise className="[&>div]:border-t-0">
            <ModeSwitch />
          </Rise>

          <div className="mt-px grid gap-px border border-t-0 border-line bg-line lg:grid-cols-3">
            {[
              { name: "Smooth motion", icon: "M4 16 C8 16 8 8 12 8 C16 8 16 16 20 16 M4 12 C8 12 8 6 12 6 M12 18 C16 18 16 12 20 12", body: "Optical flow fills the gaps between frames, so fast subjects streak in one continuous trail instead of leaving discrete ghost copies." },
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

          <Rise className="mt-px border border-t-0 border-line bg-line">
            <div className="grid gap-px lg:grid-cols-[1fr_minmax(0,0.8fr)]">
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

              <div className="flex flex-col justify-center bg-panel p-7 sm:p-10">
                <Mono className="mb-5 text-ink-3">What locked capture means</Mono>
                <dl className="flex flex-col divide-y divide-line">
                  {[
                    { key: "Exposure", val: "Custom · locked at record", glyph: "M12 2 V6 M12 18 V22 M4.93 4.93 L7.76 7.76 M16.24 16.24 L19.07 19.07 M2 12 H6 M18 12 H22 M4.93 19.07 L7.76 16.24 M16.24 7.76 L19.07 4.93" },
                    { key: "White balance", val: "Locked · no colour shift", glyph: "M12 3 a9 9 0 1 0 0 18 a9 9 0 1 0 0 -18 M12 3 C10 7 10 17 12 21 M12 3 C14 7 14 17 12 21 M3 12 H21" },
                    { key: "Frame format", val: "BGRA · same as import", glyph: "M4 6 H20 V18 H4 Z M4 10 H20 M10 10 V18" },
                    { key: "Flicker", val: "None · pipeline stays clean", glyph: "M5 12 L9 8 L13 14 L17 10 L19 12" },
                  ].map(({ key, val, glyph }) => (
                    <div key={key} className="flex items-center justify-between gap-4 py-3.5">
                      <span className="flex items-center gap-3">
                        <Glyph d={glyph} className="h-4 w-4 shrink-0 text-signal-soft" />
                        <Mono className="text-ink-2">{key}</Mono>
                      </span>
                      <Mono className="text-right text-ink-3">{val}</Mono>
                    </div>
                  ))}
                </dl>
              </div>
            </div>
          </Rise>
        </section>

        {/* get */}
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

        <footer className="border-t border-line">
          <div className="mx-auto flex max-w-7xl flex-col gap-6 px-5 py-10 sm:flex-row sm:items-center sm:justify-between sm:px-8">
            <div className="flex items-center gap-2.5">
              <ApertureMark className="h-5 w-5 text-signal" />
              <span className="font-display text-lg font-bold text-ink">Long Exposures</span>
            </div>
            <Mono className="text-ink-3">Photo &amp; Video · iPhone · iOS 17+</Mono>
            <div className="flex items-center gap-6 text-[13px] text-ink-2">
              <a href="/privacy.html" className="transition-colors hover:text-ink">Privacy</a>
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

function AppStoreBadge({ size = "default" }: { size?: "compact" | "default" | "large" }) {
  const pad = size === "large" ? "px-6 py-4" : size === "compact" ? "px-3 py-1.5" : "px-5 py-3";
  const gap = size === "compact" ? "gap-2" : "gap-3";
  const logo = size === "large" ? "h-8 w-8" : size === "compact" ? "h-5 w-5" : "h-7 w-7";
  const kicker = size === "compact" ? "text-[8px]" : "text-[10px]";
  const word = size === "large" ? "text-2xl" : size === "compact" ? "text-base" : "text-xl";
  return (
    <a
      href="https://github.com/jameshou28/long-exposures/releases/tag/1.0"
      target="_blank"
      rel="noopener noreferrer"
      aria-label="Download Long Exposures from GitHub Releases"
      className={`group inline-flex items-center ${gap} border border-line-bright bg-ink text-base transition-all duration-300 hover:border-signal active:scale-[0.98] ${pad}`}
      style={{ transitionTimingFunction: EASE }}
    >
      <svg viewBox="0 0 24 24" className={logo} fill="currentColor" aria-hidden>
        <path d="M12 2C6.477 2 2 6.477 2 12c0 4.418 2.865 8.166 6.839 9.489.5.092.682-.217.682-.482 0-.237-.009-.868-.013-1.703-2.782.604-3.369-1.342-3.369-1.342-.454-1.154-1.11-1.462-1.11-1.462-.908-.62.069-.608.069-.608 1.003.07 1.531 1.03 1.531 1.03.892 1.529 2.341 1.087 2.91.832.092-.647.35-1.088.636-1.338-2.22-.253-4.555-1.11-4.555-4.943 0-1.091.39-1.984 1.029-2.683-.103-.253-.446-1.27.098-2.647 0 0 .84-.269 2.75 1.025A9.578 9.578 0 0 1 12 6.836a9.59 9.59 0 0 1 2.504.337c1.909-1.294 2.747-1.025 2.747-1.025.546 1.377.202 2.394.1 2.647.64.699 1.028 1.592 1.028 2.683 0 3.842-2.339 4.687-4.566 4.935.359.309.678.919.678 1.852 0 1.336-.012 2.415-.012 2.741 0 .267.18.579.688.481C19.138 20.163 22 16.418 22 12c0-5.523-4.477-10-10-10z" />
      </svg>
      <span className="flex flex-col leading-none">
        <span className={`${kicker} font-medium opacity-70`}>Download from</span>
        <span className={`font-display font-bold ${word}`}>GitHub</span>
      </span>
    </a>
  );
}
