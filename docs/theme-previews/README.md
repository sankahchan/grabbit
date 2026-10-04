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
