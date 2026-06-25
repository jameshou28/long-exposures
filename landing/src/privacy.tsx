import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import "./index.css";

/* Self-contained logo mark, mirrored from the landing page so this entry
   doesn't import the whole LandingPage module just for one glyph. */
function ApertureMark({ className = "" }: { className?: string }) {
  return (
    <svg viewBox="0 0 100 100" className={className} aria-hidden>
      <circle cx="50" cy="50" r="45" fill="none" stroke="currentColor" strokeWidth="2" opacity="0.55" />
      {[0, 60, 120, 180, 240, 300].map((a) => (
        <path key={a} d="M50 10 L77 53 L50 53 Z" fill="currentColor" opacity="0.9" transform={`rotate(${a} 50 50)`} />
      ))}
      <polygon points="50,41 57.8,45.5 57.8,54.5 50,59 42.2,45.5 42.2,45.5" fill="#0b0c0e" />
    </svg>
  );
}

const LAST_UPDATED = "June 25, 2026";

/* Body copy is the policy text from SHIP.md, kept verbatim so the hosted page,
   the App Store privacy field, and the repo all say the same thing. */
const SECTIONS: { heading: string; body: string }[] = [
  {
    heading: "No data collected",
    body: "Long Exposures does not collect, store, transmit, or share any personal data. There are no accounts, no analytics, and no third-party tracking.",
  },
  {
    heading: "Everything stays on your device",
    body: "All photo and video processing happens entirely on your device. The app accesses your photo library and camera only to import or capture the clips you choose to edit, and only while you are using those features. Nothing you import, capture, or create is uploaded to any server.",
  },
  {
    heading: "Where your images live",
    body: "Images you save are written to your own device — to your Photos library (with your permission) and to the app's private library, which is removed if you delete the app.",
  },
];

function PrivacyPage() {
  return (
    <div className="relative min-h-[100dvh] bg-base text-ink">
      {/* slim top bar with a real back link to the landing page */}
      <header className="border-b border-line">
        <div className="mx-auto flex max-w-3xl items-center justify-between px-5 py-4 sm:px-8">
          <a href="/" className="flex items-center gap-2.5">
            <ApertureMark className="h-6 w-6 text-signal" />
            <span className="font-display text-xl font-extrabold leading-none text-ink">Long Exposures</span>
          </a>
          <a
            href="/"
            className="group inline-flex items-center gap-2 text-[13px] text-ink-2 transition-colors duration-300 hover:text-ink"
          >
            <svg viewBox="0 0 24 24" className="h-3.5 w-3.5" fill="none" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" aria-hidden>
              <path d="M15 6 L9 12 L15 18" />
            </svg>
            Back to site
          </a>
        </div>
      </header>

      <main className="mx-auto max-w-3xl px-5 py-20 sm:px-8 sm:py-28">
        <span className="font-mono text-[10px] uppercase tracking-[0.14em] text-signal-soft">
          Privacy Policy
        </span>
        <h1 className="mt-5 font-display text-[clamp(2.5rem,7vw,4rem)] font-extrabold leading-[0.95] text-ink">
          Your photos never leave your phone.
        </h1>
        <p className="mt-4 font-mono text-[11px] uppercase tracking-[0.14em] text-ink-3">
          Last updated · {LAST_UPDATED}
        </p>

        <div className="mt-14 flex flex-col divide-y divide-line border-y border-line">
          {SECTIONS.map((s) => (
            <section key={s.heading} className="grid gap-3 py-8 sm:grid-cols-[minmax(0,0.8fr)_minmax(0,1.4fr)] sm:gap-10">
              <h2 className="font-display text-2xl font-bold leading-tight text-ink">{s.heading}</h2>
              <p className="text-[15px] leading-relaxed text-ink-2" style={{ textWrap: "pretty", maxWidth: "68ch" }}>
                {s.body}
              </p>
            </section>
          ))}
        </div>

        <div className="mt-12 flex flex-col gap-2">
          <span className="font-mono text-[10px] uppercase tracking-[0.14em] text-ink-3">Questions</span>
          <a
            href="mailto:james.william.hou@gmail.com"
            className="w-max font-display text-xl font-bold text-signal-soft transition-colors duration-300 hover:text-signal"
          >
            james.william.hou@gmail.com
          </a>
        </div>
      </main>

      <footer className="border-t border-line">
        <div className="mx-auto flex max-w-3xl items-center justify-between px-5 py-8 sm:px-8">
          <span className="font-mono text-[10px] uppercase tracking-[0.14em] text-ink-3">
            Photo &amp; Video · iPhone · iOS 17+
          </span>
          <a href="/" className="text-[13px] text-ink-2 transition-colors duration-300 hover:text-ink">
            Long Exposures
          </a>
        </div>
      </footer>
    </div>
  );
}

createRoot(document.getElementById("root")!).render(
  <StrictMode>
    <PrivacyPage />
  </StrictMode>
);
