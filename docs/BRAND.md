# Burrow brand and design system

**Burrow** is a native Mac home for the Mole CLI. Moles burrow, and Burrow digs deep into your disk and comes back with a tidy, healthy Mac. The CLI keeps its name, **Mole**. The app is its companion, and the brand should read that way: warm, crafted, trustworthy, a little playful, never "cleaner-app scary".

## Brand idea: "Lantern in the burrow"

A calm, dark, earthy underground lit by one warm lantern glow. The dark ground stands for your disk, full of hidden things. The warm light stands for Burrow finding and clearing them. A fresh mint accent stands for the "clean" result.

## Palette

The **Core** tokens are the brand colours:

| Token | Hex | Use |
|---|---|---|
| `night-soil` | `#15111B` | Deepest background: icon ground, DMG and hero backgrounds |
| `burrow` | `#231B2B` | Raised dark surfaces |
| `velvet` | `#3A2E45` | Dark highlights, tunnel walls |
| `lantern` | `#FFB23F` | **Primary brand colour**: glow, the app's accent colour, key highlights |
| `ember` | `#F2703A` | Warm depth paired with lantern (gradients from lantern to ember) |
| `mint` | `#3DDC97` | "Clean" and success accent, used sparingly |
| `cream` | `#FFF4E2` | Text on dark, light-mode paper |

The **Mascot** tokens are for Mole the character:

| Token | Hex | Use |
|---|---|---|
| `fur` | `#4A3A34` | Body (warm charcoal-brown) |
| `fur-light` | `#7A625A` | Fur highlight |
| `snout` | `#F4A7B0` | Nose and paws (soft pink) |

**Light mode:** backgrounds use `cream` (`#FFF4E2`) and `#FFFFFF`; ink is `#1E1826`.

**Dark mode:** backgrounds use `night-soil` and `burrow`; ink is `cream`.

The app's feature screens keep their own gradients (see `FeatureTheme`). The brand colours cover the app icon, the global accent colour, onboarding, About, the DMG, README art and the menu bar.

## Typography

- **UI:** SF Pro, the system font. Big numbers use SF Pro Rounded, Bold.
- **Wordmark:** "Burrow" set in SF Pro Rounded, Heavy, with tracking -1%. The first "o" can hold a small lantern glow, used only in the hero and the DMG.
- **Code:** SF Mono.

## App icon

- Classic macOS squircle on the macOS 26 icon grid (1024 canvas, 824 body).
- A dark earthy ground with a glowing burrow entrance, with Mole's friendly face peeking out or being lit by the lantern.
- Real rendered depth: soft volumetric light, ambient occlusion, gentle film grain. No flat clip-art.
- It must read clearly at 16 px: one strong silhouette with high value contrast between the warm glow and the dark ground.

## Menu bar glyph

A monochrome template image (black with alpha, so macOS tints it) of the burrow-arch silhouette with a small dot. It is shown at 18 pt (36 px @2x) and must stay crisp.

## DMG background

- 660×420 pt (1320×840 @2x).
- The night-soil gradient with the lantern glow.
- Burrow's icon on the left and an Applications drop target on the right, with a soft hand-drawn arrow between them.
- A small first-launch hint: "First launch: open System Settings → Privacy & Security → Open Anyway" (the right-click → Open bypass no longer works since macOS Sequoia).

## README hero

- 1600×640 px.
- The icon, the wordmark, and the tagline "A beautiful home for Mole", over the night-soil scene with the lantern glow and faint tunnel strata.

## Motion and tone

- **Motion:** smooth springs; the glow gently breathes while scanning.
- **Copy:** friendly and plain: "Found 7.4 GB you can safely clear", not "SYSTEM JUNK DETECTED".
