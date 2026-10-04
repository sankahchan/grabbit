# Theme previews

Trial skins for Grabbit, rendered from HTML mockups. These are design
explorations only — nothing here is wired into the app yet.

## FacilityFlow (light + dark)

Reference: [FacilityFlow — Facility SaaS UX/UI Dashboard Design](https://www.behance.net/gallery/254898551/FacilityFlow-Facility-SaaS-UX-UI-Dashboard-Design)
(Neet-Nestor's Behance). The style language: airy modern SaaS — white
cards on a warm off-white canvas, 1px hairline borders, soft layered
shadows, generous radii (12–16px), pill navigation with a black active
pill, mint-green accent used sparingly, small uppercase labels, thin
rounded progress bars.

### Tokens (as rendered)

| Token | Light | Dark |
| --- | --- | --- |
| Canvas | `#F4F4F2` | `#0E1012` |
| Sidebar | `#FAFAF8` | `#121417` |
| Card | `#FFFFFF` | `#17191C` |
| Border | `#E8E8E4` | `#262A2F` |
| Text / secondary | `#17181A` / `#6E747D` | `#F2F3F4` / `#A2A8B0` |
| Active pill | `#17181A` (white text) | `#F2F3F4` (dark text) |
| Accent (mint) | `#3AAE7F` on `#E3F5EC` | `#6FCFA5` on `#1B2B24` |
| Progress track | `#EEF0EE` | `#23272B` |
| Warning amber | `#E8A23D` | `#E2A94E` |
| Danger | `#E0604F` | `#E2756A` |
| Shadow | `0 1px 2px rgba(20,20,15,.04), 0 10px 30px rgba(20,20,15,.05)` | soft black |

### Files

- `facilityflow.html` — the mockup (`#dark` switches variant)
- `facilityflow-light.png`, `facilityflow-dark.png` — 2560×1600 renders

Re-render:

```bash
"/Applications/Google Chrome.app/Contents/MacOS/Google Chrome" \
  --headless=new --disable-gpu --hide-scrollbars \
  --force-device-scale-factor=2 --window-size=1280,800 \
  --screenshot="$PWD/docs/theme-previews/facilityflow-light.png" \
  "file://$PWD/docs/theme-previews/facilityflow.html"
```
