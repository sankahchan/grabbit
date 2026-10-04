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

A dark, neon "download console" skin inspired by
[Volta — Home Energy OS](https://www.behance.net/gallery/254877083/Volta-Home-Energy-OS-UI-UX-Design-Mobile-App-Design)
on Behance. Name: **Pulse** — short, energy-console feel. Dark-first; no
light variant is planned for this one.

Style language: deep blue-black canvas with cyan/lime ambient glows,
glassy cards with luminous hairline borders and soft outer shadows, one
neon lime accent used like a power meter, cyan for completed data, gold
for paused, monospace numerals with small colored dot markers, micro
monospace labels (`/ ACTIVE ///`).

### Tokens (as rendered)

| Token | Value |
| --- | --- |
| Backdrop | `#07090C` + cyan glow top-left, lime glow bottom-right |
| Canvas | `#0B0F14` (window gradient from `#0D1218`) |
| Sidebar | `#0C1116` with a faint white top wash |
| Card | `rgba(255,255,255,.028)` glass + backdrop blur |
| Border | `rgba(140,220,255,.14)` / soft `.08` |
| Text / secondary / tertiary | `#EDF2F5` / `#93A3AD` / `#5E6C76` |
| Accent (lime) | `#A8FF3B`, glow `rgba(168,255,59,.45)`, ink `#0A1006` |
| Cyan (completed) | `#4FC3E8` |
| Gold (paused) | `#F5B54A` |
| Danger | `#FF6B6B` |
| Numerals | `SF Mono` / `ui-monospace`, tabular, glow on active values |
| Card shadow | `inset 0 1px 0 rgba(255,255,255,.03), 0 14px 40px rgba(0,0,0,.45)` |
| Window shadow | `0 50px 130px rgba(0,0,0,.75), 0 0 90px rgba(79,195,232,.07)` |

Radii: window 22 · cards 20 · inputs 12 · icon buttons 10 · pills 999.

### Files

- `pulse.html` — the mockup (dark only)
- `pulse-dark.png` — 2560×1600 render

Re-render:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1280,800 \
  --screenshot="$PWD/docs/theme-previews/pulse-dark.png" \
  "file://$PWD/docs/theme-previews/pulse.html"
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

Light variant tokens: backdrop `#EAE6E1`, canvas `#F4F1ED`, white cards
with soft plum shadows, ink `#1A151A`; plum and coral stay identical, and
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
