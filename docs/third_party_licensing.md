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

- **Never commits these files** to the repository. They are excluded via
  `.gitignore`.
- **Bundles them with every build**, taken from BROOD_DATA (default
  ~/box/media/games/BROOD) at build time:
  - Linux: linux/CMakeLists.txt copies StarDat.mpq, BrooDat.mpq,
    Patch_rt.mpq and maps/ into the bundle's data/BROOD.
  - Android: android/app/build.gradle.kts puts the three MPQs and the melee
    maps into the APK's assets/BROOD; MainActivity.kt copies them into the
    app's storage at first start.
  - Web: tool/build_web.sh runs tool/copy_game_files.sh, which copies them
    into build/web/gamedata with a manifest.json; the page imports them into
    IndexedDB at first start.
  Without the files at BROOD_DATA the builds leave them out and the game asks
  the player for their own copy, as before.
- At every start the game asks "I have a copy of the original game files"
  (Yes/No); No quits (the browser page goes blank). That question is not a
  license: handing out any of these builds, or serving the web build,
  still redistributes Blizzard's files, so the distribution warning above
  applies to it twice over.
- Re-check this policy at every implementation phase, not just once.
