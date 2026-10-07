# Vendored third-party source

## OpenBW

`openbw/` is a vendored copy of the OpenBW StarCraft: Brood War simulation
core (<https://github.com/OpenBW/openbw>). It was previously a git submodule;
it is now committed directly into this repository as ordinary files, so a
plain `git clone` gets a complete buildable tree with no submodule step.

The path is unchanged, so nothing in the build system needs to know about
this change. `engine/bridge/CMakeLists.txt`, `engine/web/build_wasm.sh` and the
`engine/tools/*` CMake projects all reference `engine/vendor/openbw` by that
same relative path.

### Provenance

- Upstream: <https://github.com/OpenBW/openbw.git>
- Upstream base commit: `4b046d5` (`Read/set invincible flag on map units.`, the
  tip of `origin/master` when this was vendored).
- Local patch applied on top: `brood-limits.patch`, which raises the supply cap,
  unit pools and selection size. This patch was developed locally and is
  **not** present on any upstream branch.
- Previously pinned as submodule commit `9b2ee085eedb30a809bc2dd9ac89a7f24f9f2a8d`.

### Licensing caveat

**OpenBW ships no LICENSE file.** Its redistribution status is unresolved. It is
vendored here and this repository is published publicly, so that risk has been
knowingly accepted by the project owner. See `docs/third_party_licensing.md`
for the full reasoning and for the constraints that still apply to the game
assets. Re-review that document when OpenBW's licensing is clarified.

### Updating OpenBW

There is no submodule to `git submodule update`. To move to a newer upstream
commit, replace the `openbw/` tree manually and re-apply or drop
`brood-limits.patch`, then confirm the engine still builds.