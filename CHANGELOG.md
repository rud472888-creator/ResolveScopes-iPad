# 1.25.0 · Scope guide readability

- Strengthened 10 IRE reference lines and added distinct RGB channel boundaries with legible label backings.
- Rebuilt Vectorscope guides using the trace's actual saturation projection: 25/50/75/100 rings, 75/100% target boxes, radial marks, dashed skin line and brighter blue/red labels.
- Includes the existing full-raster native False Color pixel-classification fix and vector display reconstruction from 1.24.6.
- Shared companion guide source is synchronized with Mac 1.26.1. Remote Monitor transport, video presentation and frame pacing remain unchanged.
- This release updates the existing five iPad scopes. The paired-Sender transfer-curve meter and installed macOS Dehancer backend remain Mac-only; the iPad currently receives one Remote Monitor stream.

# 1.24.6 · Shared scope precision

- Shared waveform ticks now use 10 IRE steps (0…100 by default).
- Shared native False Color defaults to per-pixel thresholds without neighbor IRE averaging.
- Shared vectorscope display adds a small spatial density reconstruction; signal coordinates and statistics are unchanged.
- Shared skin overlay helper uses yellow=center, red=redward, green=yellowward. This does not add a new iPad panel.
- The desktop-only reticle, stopped-HQ scheduling and optional installed macOS Dehancer Monitor backend are not included in the iPad target.
- iPad simulator Release build and 48 layout checks passed. No physical-device FPS or live-stream retest is claimed for this source update.

# 1.24.5

- Signal Planes app icon and header mark.
- Existing scope, False Color and layout behavior retained.
- Initial standalone repository snapshot; build outputs, live footage, local logs and unrelated workspace history are excluded.
