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
