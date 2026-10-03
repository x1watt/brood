# Third-party licensing and asset policy

## OpenBW (engine core)

This project vendors [OpenBW](https://github.com/OpenBW/openbw) (`engine/vendor/openbw`,
a git submodule pinned to a specific commit) as the simulation core. OpenBW is a
from-scratch, bit-exact reimplementation of the StarCraft: Brood War engine.

**The OpenBW core repository has no LICENSE file** (confirmed via the GitHub API:
`license: null`). That means its legal status for redistribution is unresolved.

- Personal/private use, as planned here, is treated as acceptable risk.
- **Do not publish this repository's source, or distribute any compiled build
  (APK, web bundle, desktop binary) to anyone else**, until either OpenBW's
  maintainers clarify licensing, or that risk is knowingly accepted and
  re-reviewed at that time. This is a standing constraint, not a one-time note.

BWAPI (`github.com/OpenBW/bwapi`), where referenced for its command vocabulary,
is LGPL-3.0 and is not vendored or linked here — only its command/action naming
conventions are reused as a design reference.

## Blizzard game assets (StarDat.mpq, BrooDat.mpq, Patch_rt.mpq, maps)

StarCraft: Brood War's actual game content — sprites, sounds, tilesets, unit
data — is Blizzard Entertainment's copyrighted property, held in proprietary
MPQ archives. This project:

- **Never bundles these files** in the repository or in any build artifact
  (APK, web bundle, desktop package). They are excluded via `.gitignore`.
- **Always loads them from a user-supplied location at runtime** — a folder
  path on desktop/Android, or a one-time client-side upload into
  IndexedDB/OPFS on web — from the user's own legally-owned copy of the game.
- Re-check this policy at every implementation phase, not just once.
