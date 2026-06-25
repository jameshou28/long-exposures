# Ship prep — Long Exposures

Everything needed to submit to the App Store. Code is feature-complete (Phases 0–8);
this is the listing, legal, and release checklist. The $99 Apple Developer enrollment
and the actual submission are manual steps (marked **[you]**).

---

## 1. App icon — DONE

`Assets.xcassets/AppIcon.appiconset` holds a 1024×1024 aperture icon (blue iris on a
dark ground) for light, dark, and tinted appearances. Opaque RGB (no alpha), so it
passes App Store validation. Regenerate with `scratchpad/make_icon.py` if you want to
tweak the design.

---

## 2. App Store listing copy

**Name:** Long Exposures

**Subtitle (30 char max):**
> Frame-perfect long exposures

**Promotional text (170 char, updatable any time):**
> Turn a Live Photo or video into a long exposure. You pick the frames. Smooth water,
> light trails, motion blur — all on your device, nothing uploaded.

**Description:**
> Long Exposures turns the Live Photos and videos you already have into the kind of
> long-exposure shots that usually need a tripod and a DSLR.
>
> Unlike the built-in Long Exposure effect, you choose exactly which frames blend
> together — drag the timeline to trim to the moment you want, and watch the result
> update live.
>
> • Three blend modes — Average for silky motion blur, Lighten for light trails,
>   Darken for the opposite.
> • Pick your frames — a frame-by-frame timeline with draggable handles.
> • Align handheld shots — keeps a static background sharp while motion blurs.
> • Match exposure — evens out brightness flicker across frames.
> • Capture in-app — record a new clip with locked exposure for clean frames.
> • Before/after — hold the preview to compare against a single frame.
> • Save & share — export full-resolution to your Photos library or share anywhere.
>
> Everything runs on your device. No account, no uploads, no data collected.

**Keywords (100 char, comma-separated, no spaces):**
> longexposure,light trail,motion blur,live photo,slow shutter,photography,blend,water,timelapse,DSLR

**Support URL:** **[you]** — a simple page or a mailto. e.g. a GitHub Pages page or
`mailto:james.william.hou@gmail.com`.

**Marketing URL (optional):** **[you]**

**Category:** Photo & Video (Primary). Secondary: none, or Graphics & Design.

**Age rating:** 4+ (no objectionable content).

---

## 3. App Privacy — "No data collected"

This is a genuine selling point — state it plainly. In App Store Connect → App Privacy:

- **Data collection:** No, this app does not collect data.
- No tracking, no analytics, no third-party SDKs.

Because the app touches the photo library and camera, the usage-description strings
must stay accurate (they're already in the project):
- `NSPhotoLibraryUsageDescription` — import Live Photos/videos.
- `NSCameraUsageDescription` — in-app capture.

### Privacy policy (required even with no collection)

App Store Connect requires a privacy-policy URL. Host the text below somewhere stable
(GitHub Pages, a Notion public page, etc.) **[you]**:

> **Long Exposures — Privacy Policy**
> Last updated: 2026-06-25
>
> Long Exposures does not collect, store, transmit, or share any personal data.
>
> All photo and video processing happens entirely on your device. The app accesses
> your photo library and camera only to import or capture the clips you choose to
> edit, and only while you are using those features. Nothing you import, capture, or
> create is uploaded to any server. The app has no accounts, no analytics, and no
> third-party tracking.
>
> Images you save are written to your own device — to your Photos library (with your
> permission) and to the app's private library, which is removed if you delete the app.
>
> Questions: james.william.hou@gmail.com

---

## 4. Screenshots

Required: 6.9" (iPhone 16 Pro Max) and 6.5" (older Pro Max) — App Store Connect needs
at least one set; 6.9" is the modern requirement. Capture on-device or a matching sim.

Shot list (5–6, in order — the first two matter most):
1. **The hook** — editor with a finished long exposure in the preview (silky water or
   light trails). The product in one glance.
2. **Frame selection** — the timeline strip mid-drag, showing the range handles and
   dimmed excluded frames. This is the differentiator.
3. **Blend modes** — same scene, the segmented Average/Lighten/Darken picker visible.
4. **Adjustments** — Align frames + Match exposure toggles, ideally a handheld shot
   sharpened.
5. **Library** — the grid of saved exposures.
6. **(optional) Capture** — the in-app camera with the record button.

Tips: add a one-line caption band over each (e.g. "Pick exactly which frames blend").
Keep them consistent — same device frame, same dark theme.

---

## 5. TestFlight + submission checklist  **[you]**

- [ ] Enroll in the Apple Developer Program ($99/yr) — the only hard cost.
- [ ] In Xcode: set the Team, confirm bundle id `co.jameshou.long-exposures`, bump the
      version/build, set a real signing certificate (currently "Sign to Run Locally").
- [ ] Archive (Product → Archive) on a Release config, validate, upload to App Store
      Connect.
- [ ] Create the app record in App Store Connect; paste the listing copy above.
- [ ] Fill App Privacy ("No data collected") + privacy-policy URL.
- [ ] Upload screenshots (6.9" required).
- [ ] TestFlight: add yourself + any testers, run the **real-device pass** first
      (see below), then submit for App Review.

---

## 6. Pre-submit device pass (do this before submitting)

These paths are coded but were never exercised on hardware (the simulator has no Live
Photos or camera). Confirm each end-to-end on your phone:

- [ ] Import a **Live Photo** → trim → blend (all 3 modes) → export to Photos.
- [ ] Import a **regular video** → confirm it samples down and edits smoothly.
- [ ] **Capture** a clip in-app → edit → export.
- [ ] **Align frames** on a handheld clip (already verified — sharp background).
- [ ] **Match exposure** on a clip that flickers/pulses.
- [ ] **Library**: save several, reopen, share, delete.
- [ ] First-launch **onboarding** shows once; **permission priming** appears before the
      cold prompt.
- [ ] Check **Settings → Documents & Data** isn't ballooning (temp-file purge works).
