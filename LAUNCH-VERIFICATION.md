# iPad launch recovery — 2026-10-23

Version: **1.25.0 (1)**, source `ab80cd3`.

The installed app failed to launch: CoreDevice reported error 10004 (no process
identifier; the application may already have terminated). No new app crash
report was found; available reports predated this incident. The existing build's
provisioning profile had not expired. The exact cause is unconfirmed.

Rebuilt the unchanged source in Release using Xcode 27.1, signed locally and
installed over the existing app without deleting its data. Build and strict
bundle-signature verification passed. Installation restored successful launch.
Two subsequent terminate-and-relaunch checks also passed on a physical iPad Pro
13-inch M4 running iPadOS 27.0.1. Device Hub showed the 1.25.0 connection screen;
no new app crash reports appeared during these checks.

Rebuilt executable SHA-256:
`2eab23f53feba62f7e7b7443dabfef2d1f58565783a90d1d798ea5baf7855de1`

This is installation recovery, not a source-level crash fix. No application
code, version, scope processing or transport behavior changed. Live reception
after the final relaunch was not tested. Signing material, device identifiers
and raw device logs remain outside the repository.
