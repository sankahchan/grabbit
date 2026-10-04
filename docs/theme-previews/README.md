# Theme previews

Trial skins for Grabbit, rendered from HTML mockups. These are design
explorations only — nothing here is wired into the app yet.

## Aura

A clean, airy Grabbit skin inspired by
[FacilityFlow](https://www.behance.net/gallery/254898551/FacilityFlow-Facility-SaaS-UX-UI-Dashboard-Design)
on Behance. Name: **Aura** — short and calm, matching the feel.

Style language: white cards on a warm off-white canvas, 1px hairline
borders, two-layer soft shadows, pill navigation with a black active pill
(white in dark mode), a deeper mint accent used sparingly, monochrome SVG
icons, thin gradient progress bars and small uppercase labels.

### Tokens (as rendered)

| Token | Light | Dark |
| --- | --- | --- |
| Backdrop | `#E9E9E4` + mint glow | `#0A0B0D` + mint glow |
| Canvas | `#F5F5F2` | `#0F1113` |
| Sidebar | `#FAFAF8` | `#14171A` |
| Card | `#FFFFFF` | `#191C20` |
| Border | `#E7E7E2` | `#272B30` |
| Text / secondary / tertiary | `#16181A` / `#6D737C` / `#9AA0A6` | `#F3F4F5` / `#A3A9B1` / `#7A818A` |
| Active pill | `#17181A` (white text) | `#F3F4F5` (dark text) |
| Accent (mint) | `#2FA37A`, bar gradient `#4FC793 → #2FA37A` | `#6FCFA5`, gradient `#58B98D → #6FCFA5` |
| Accent wash | `#E4F4EC` | `#1C2B25` |
| Track | `#EEF0EE` | `#24282D` |
| Warning amber | `#DFA03C` on `#FBF1DF` | `#E3AB55` on `#2C2517` |
| Danger | `#DE5B4A` on `#FBEBE8` | `#E57A6E` on `#2C1E1C` |
| Card shadow | `0 1px 2px rgba(22,24,26,.05), 0 10px 28px rgba(22,24,26,.06)` | `0 1px 2px rgba(0,0,0,.35), 0 12px 32px rgba(0,0,0,.42)` |
| Window shadow | `0 40px 90px rgba(22,24,26,.20)` | `0 44px 100px rgba(0,0,0,.60)` |

Radii scale: window 20 · cards 16 · inputs 12 · icon buttons 10 · pills 999.

### Files

- `aura.html` — the mockup (`#dark` on the URL switches variant)
- `aura-light.png`, `aura-dark.png` — 2560×1600 renders

Re-render:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1280,800 \
  --screenshot="$PWD/docs/theme-previews/aura-light.png" \
  "file://$PWD/docs/theme-previews/aura.html"
```

## Pulse

A dark, neon "download console" skin rebuilt from the energy-dashboard
reference (edge-lit icon tiles, dot-matrix numerals, histogram meters,
Tariff-style progress strips). Name: **Pulse**. Ships in **dark
(default)** and **light** (`#light` on the URL).

Style language: every card is lit from its own edge — the glow is the
charge, never a shadow behind the object. Per-item neon icon tiles in
the sidebar, dot-matrix numeral readouts, waveform and histogram
meters, and segmented progress strips with a "now" marker. Deep
blue-black canvas in dark; crisp white cards with deeper accents in
light.

### Tokens (as rendered)

| Token | Value |
| --- | --- |
| Backdrop | dark `#050607` / light `#EEF1F5`, both with cyan + amber radial hints |
| Canvas | dark `#0A0C10` (window from `#0C0F13`) / light `#F5F7FA` (window from `#FDFEFF`) |
| Sidebar | dark `#0B0E12` + cyan wash top / amber wash bottom · light `#FBFDFF → #F1F4F8` |
| Card | edge-lit: `--edge-bg` wash + `--edge-line` border; shadow = soft depth `0 14px 34px rgba(0,0,0,.38)` + edge glow · light white with `0 12px 28px rgba(30,45,70,.08)` |
| Accents (dark) | cyan `#25E3FF` · lime `#A8FF35` · amber `#FFB020` · red `#FF3355` · slate `#DDE8F2` |
| Accents (light) | cyan `#00A9CC` · lime `#7BC300` · amber `#E08900` · red `#E0294A` · slate `#64748B` |
| Text | dark `#EDF2F5` / `#8FA0AC` / `#5A6873` · light `#101418` / `#5A6873` / `#8A97A0` |
| Numerals | 5×7 dot-matrix SVG (`data-v`, `data-cell`) with colored glow |
| Progress | 40 segmented blocks + "now" marker (white in dark, ink in light) |
| Window | radius 26, spectrum hairline cyan→lime→amber, ambient colored shadow |

Radii: window 26 · cards 20 · controls 13 · tiles 9 · mini 11 · pills
999. Signature: per-item sidebar nav tiles with their own edge glow, a
charge bar on the active nav row, LIVE pill, waveform (active) /
histogram (completed, speed) meters, dot-matrix percentages.

### Files

- `pulse.html` — the mockup (`#light` on the URL switches appearance)
- `pulse-dark.png`, `pulse-light.png` — 2560×1600 renders

Re-render:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1280,800 \
  --screenshot="$PWD/docs/theme-previews/pulse-dark.png" \
  "file://$PWD/docs/theme-previews/pulse.html"

"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1280,800 \
  --screenshot="$PWD/docs/theme-previews/pulse-light.png" \
  "file://$PWD/docs/theme-previews/pulse.html#light"
```

## Grove

An earthy "command console" skin inspired by
[TERA — Farm Management SaaS](https://www.behance.net/gallery/251337883/Farm-Management-SaaS-Platform-UIUX-Design-TERA)
on Behance. Name: **Grove** — short, green, grounded. Dark-first.

Style language: dark olive panels on a deep green-black canvas, **warm
gold hero accent** (kept deliberately distinct from Pulse's cool neon
lime), sage for paused, an olive-gold gradient speed card, metric chips
with tiny icons, circular gauges, pill tab navigation (pale cream-gold
active), lowercase chunky logotype.

### Tokens (as rendered)

| Token | Value |
| --- | --- |
| Backdrop | `#0B0D08` + olive/blue ambient glows |
| Canvas | `#14170F` (window gradient from `#171B11`) |
| Sidebar | `#12150D` |
| Card | `#1B1F14` |
| Border | `rgba(232,242,206,.10)` / strong `.16` |
| Text / secondary / tertiary | `#F2F2E8` / `#A9AF9A` / `#6F7663` |
| Accent (warm gold) | `#E0A94E`, pale pill `#F1E3BD`, ink `#1A1508` |
| Sage (paused) | `#9BA189` |
| Speed card | gold radial over `linear-gradient(120deg,#2A2413,#3A3016,#1E1B10)` |
| Danger | `#E06C5B` |
| Card shadow | `inset 0 1px 0 rgba(255,255,255,.03), 0 14px 36px rgba(0,0,0,.45)` |
| Window shadow | `0 56px 130px rgba(0,0,0,.78), 0 0 110px rgba(214,242,78,.05)` |

Radii: window 22 · cards 18 · chips 10 · pills 999. Signature elements:
filled gold gauge circles (dark % text), sage ring gauge for paused,
check gauge for completed, and tiny-icon metric chips
(`⚡ 3.1 MB/s · 🕐 2m 40s · 🔗 16`).

### Files

- `grove.html` — the mockup (dark only)
- `grove-dark.png` — 2560×1600 render

Re-render:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1280,800 \
  --screenshot="$PWD/docs/theme-previews/grove-dark.png" \
  "file://$PWD/docs/theme-previews/grove.html"
```

## Velvet

A luxe plum-on-black skin inspired by
[Vaulta — AI-Powered Trading App](https://www.behance.net/gallery/256357433/Vaulta-AI-Powered-Trading-App-UIUX-Case-Study)
on Behance. Name: **Velvet** — short, soft, premium. Ships in both
**dark (default)** and **light** variants (`#light` on the URL).

Style language: deep black canvas with plum and coral ambient glows, a
three-material card system (dark glass · silver metal · plum gradient
hero), coral accent for active states, very large radii, chevron list
rows, and a plum-gradient app mark.

### Tokens (as rendered)

| Token | Value |
| --- | --- |
| Backdrop | `#070608` + plum glow `rgba(122,46,79,.38)` + coral hint |
| Canvas | `#0B0A0C` (window gradient from `#100D11`) |
| Sidebar | `#0D0C0F` |
| Glass card | `rgba(255,255,255,.035)` |
| Silver card | `linear-gradient(180deg,#F6F4EF,#DFDCD2)` with ink `#17151A` |
| Plum hero | `linear-gradient(135deg,#A8456B,#7A2E4F 55%,#4A1730)` + coral radial |
| Border | `rgba(226,205,220,.10)` / strong `.16` |
| Text / secondary / tertiary | `#F5F2F4` / `#A79BA3` / `#6E646C` |
| Coral (active) | `#F27E93`, deep `#D95C77` |
| Muted mauve (paused) | `#9A8F9E` |
| Champagne (completed) | `#E8E4DA` |
| Danger | `#E06C5B` |
| Card shadow | `inset 0 1px 0 rgba(255,255,255,.04), 0 16px 40px rgba(0,0,0,.5)` |
| Window shadow | `0 60px 140px rgba(0,0,0,.82), 0 0 130px rgba(122,46,79,.16)` |

Radii: window 26 · cards 22 · icon tiles 12 · pills 999. Signature
elements: plum-gradient active pill and brand mark, **segmented progress
meters** (Vaulta portfolio-bar style: 38 segments, lit ones in a coral
gradient with a soft glow; mauve for paused, champagne for completed),
gradient coral status pills, and a silver completed row with a chevron.

Light variant tokens: backdrop `#E7E2DC`, canvas `#EFEAE3`, a lighter
silver sidebar panel (`#F8F5F0` with a plum wash behind the brand), white
cards with two-layer plum shadows and a white inset sheen, ink `#1A151A`,
coral deepened to `#DB5A78`; radii grow to 28 (window) / 24 (cards), and
completed segments turn antique silver (`#DCD6C8 → #B5AD9C`) so they read
on white.

### Files

- `velvet.html` — the mockup (`#light` on the URL switches variant)
- `velvet-dark.png`, `velvet-light.png` — 2560×1600 renders

Re-render:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1280,800 \
  --screenshot="$PWD/docs/theme-previews/velvet-dark.png" \
  "file://$PWD/docs/theme-previews/velvet.html"

"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1280,800 \
  --screenshot="$PWD/docs/theme-previews/velvet-light.png" \
  "file://$PWD/docs/theme-previews/velvet.html#light"
```

## Liquid

Apple's Liquid Glass skin, built from the official material guides
([Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/liquid-glass),
[Adopting Liquid Glass](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass),
[WidgetKit — Implementing Liquid Glass](https://github.com/artemnovichkov/xcode-27-system-prompts/blob/main/AdditionalDocumentation/WidgetKit-Implementing-Liquid-Glass-Design.md))
plus Behance studies ([CodePrism UI Kit](https://www.behance.net/gallery/233250457/CodePrism-Liquid-Glass-UI-Kit-Modern-UI-Components),
[Liquid Glass wallpapers](https://www.behance.net/gallery/242895321/80-Liquid-Glass-Wallpapers-(Phone-Desktop)),
[icon library](https://www.behance.net/gallery/233555941/Liquid-Glass-icons-library-ios-26-Apple-Liquid-Glass),
[iOS 26 recreation](https://www.behance.net/gallery/228170241/Recreated-Liquid-Glass-Apples-iOS-26-Design)).
Name: **Liquid**. Ships in **dark (default)** and **light** (`#light` on
the URL).

Style language, per Apple's guidance: Liquid Glass is a functional layer
for navigation and controls that floats above content — used sparingly,
with content kept clean and in focus. Glass chrome (window, sidebar,
toolbar, search, buttons, segmented control) sits over a wallpaper that
blurs through it; content is a readable sheet beneath. Radii are
concentric with their containers.

### Tokens (as rendered)

| Token | Value |
| --- | --- |
| Wallpaper (dark) | `linear-gradient(140deg,#1C2C5B,#3A3A9E 30%,#6A35A8 58%,#A84590 82%,#C85A76)` + cyan/violet/coral/teal blobs |
| Wallpaper (light) | `linear-gradient(140deg,#DDEAF8,#E5E5F7 32%,#EFE4F3 58%,#F8E7EA 82%,#FBE9E4)` + pastel blobs |
| Window glass (dark) | `rgba(28,28,38,.42)` + blur 64 / sat 170%, border `rgba(255,255,255,.34)` |
| Window glass (light) | `rgba(255,255,255,.52)`, border `rgba(255,255,255,.80)` |
| Sidebar glass | dark `rgba(255,255,255,.15 → .05)` / light `.55 → .26` |
| Content sheet | dark `rgba(23,24,30,.88)` / light `rgba(255,255,255,.74)`, radius 18 |
| Text (dark) | `#FFFFFF` / `.62` / `.38` |
| Text (light) | `#1C1C1E` / `rgba(60,60,67,.62)` / `.34` |
| Accent / completed | `#0A84FF` (prominent tinted-glass CTA) / `#30D158` |
| Hairlines | dark `rgba(255,255,255,.07)` / light `rgba(60,60,67,.10)` |

Radii: window 26 · content 18 · cards 16 · tiles 10 · pills 999. Signature
elements: floating glass window over the wallpaper, two-layer sheen and
edge highlight across the chrome, prominent tinted-glass CTA, glass
segmented control, and flat two-line queue rows with hairline separators.

### Files

- `liquid.html` — the mockup (`#light` on the URL switches appearance)
- `liquid-dark.png`, `liquid-light.png` — 2560×1600 renders

Re-render:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1280,800 \
  --screenshot="$PWD/docs/theme-previews/liquid-dark.png" \
  "file://$PWD/docs/theme-previews/liquid.html"

"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1280,800 \
  --screenshot="$PWD/docs/theme-previews/liquid-light.png" \
  "file://$PWD/docs/theme-previews/liquid.html#light"
```
