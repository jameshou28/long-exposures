# Landing page assets

Files in `public/` are served at the site root and referenced by absolute URL.
A file at `public/exposures/water-avg.jpg` is referenced in code as `/exposures/water-avg.jpg`.

## `exposures/`

Bare long-exposure photographs (no device frame) that fill the `FrameSlot`
placeholders in `src/LandingPage.tsx`. These are the raw exported results from the
app — what sells the product. Drop your shots here.

Suggested names (so wiring them in is mechanical):
- `water-avg.jpg`    — silky water, Average mode (hero)
- `lights-lighten.jpg` — light trails, Lighten mode (hero)
- `stars.jpg`        — star trails, Lighten mode
- `plaza-darken.jpg` — moving subjects removed, Darken mode
- `capture.jpg`      — a clip being captured in-app

Format: JPG or WebP, sRGB, long edge ~1600px is plenty for the web.

## `screenshots/`

App Store UI screenshots (device-framed, 6.9"/6.5") if you want to reuse them on
the site. Not required for the landing page itself.
