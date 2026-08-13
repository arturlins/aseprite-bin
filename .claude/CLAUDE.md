# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This is **not** Aseprite's source code. It is a thin automation layer — GitHub
Actions workflows plus shell/batch scripts — that compiles [Aseprite][] from
its official source on GitHub's own runners, for whoever forks/imports this
repo, and hands them the resulting binary as a workflow artifact.

Hard constraints that shape every change here:

- **Never distribute binaries.** Aseprite's EULA permits self-compiling but
  forbids redistribution. Workflows are `workflow_dispatch`-only (manual),
  must never publish a GitHub Release, and artifacts expire after 7 days
  (`retention-days: 7`). Do not add automatic/scheduled/push-triggered builds
  or release publishing.
- **`scripts/resolve-version.sh` is the single source of truth** for turning
  a user-supplied (or empty) version string into a validated Aseprite tag. It
  is wrapped by the composite action `.github/actions/resolve-version` for
  use in workflows, and is also documented for direct local use. Any version
  string handling elsewhere (build.sh, build.cmd) re-validates against the
  same regex (`^v[0-9]+(\.[0-9]+){1,3}(-beta[0-9]+)?$`) because those scripts
  are also usable standalone, bypassing the resolver — don't remove that
  re-validation as "redundant."
- Untrusted input (the version string) always reaches a shell/URL/git
  interpolation point in these scripts. Any change touching version handling
  must keep validation *before* interpolation, using `[[ =~ ]]` (whole-string
  match) rather than `grep` (line-by-line, can be fooled by multi-line input).

[Aseprite]: https://github.com/aseprite/aseprite

## Commands

Run tests (pure bash, no external dependencies, works on any OS with bash):

```bash
bash tests/run-all.sh          # every suite in tests/
bash tests/resolve-version.test.sh   # a single suite
bash tests/make-icns.test.sh
bash tests/make-dmg.test.sh
```

Resolve a version locally (also used by the composite action):

```bash
bash scripts/resolve-version.sh            # latest published release
bash scripts/resolve-version.sh v1.3.18.1  # normalize + validate + confirm it exists
```

Build locally, per platform:

```bash
# Windows (needs VS "Desktop development with C++", Git, 7-Zip, CMake, NSIS)
set ASEPRITE_VERSION=v1.3.18.1
build.cmd

# Linux / macOS
export ASEPRITE_VERSION="$(bash scripts/resolve-version.sh)"
./build.sh
```

There is no linter or formatter configured in this repo; correctness is
enforced by the `.test.sh` suites and by `set -euo pipefail` in every script.

## Architecture

**Three independent workflows**, one per OS
(`.github/workflows/build-{windows,linux,macos}.yml`), each
`workflow_dispatch`-triggered with an optional `version` input. Each does:
checkout → resolve version (composite action) → run the platform build
script → upload the result as an artifact. A failure on one platform doesn't
touch the others (`concurrency` groups are per-platform).

**`build.sh`** (Linux + macOS, `uname`-branches internally) and **`build.cmd`**
(Windows) both do the same four things, independently, since they don't share
a runtime:

1. Re-validate `ASEPRITE_VERSION`, then shallow-clone that exact tag of
   `aseprite/aseprite` (with submodules) into a clean `aseprite/` tree — every
   build starts from scratch.
2. Stamp the real version number into `aseprite/src/ver/CMakeLists.txt`
   (upstream ships `1.x-dev` there), then **assert** the substitution actually
   applied — if upstream ever renames that placeholder, this is a hard
   failure instead of a binary silently reporting the wrong version.
3. Download prebuilt Skia for the resolved Skia tag (read from
   `aseprite/laf/misc/skia-tag.txt` when present, else a hardcoded fallback
   per beta/stable) into `skia-<version>/`, reused across runs. Reuse is
   gated on the presence of `libskia.a` itself, not just the directory, so an
   interrupted download doesn't get treated as cached.
4. `cmake` (Ninja, `LAF_BACKEND=skia`) + build the `aseprite` target only.

**Platform-specific packaging** happens after the build, in `dist/`:

- **Linux**: tar.gz, not a plain directory — `actions/upload-artifact` strips
  the executable bit and symlinks, which would break the binary.
- **Windows**: a plain folder (`aseprite-<version>-windows-x64`) containing
  `aseprite.exe` + `data/` + `docs/`, kept portable via a generated
  `aseprite.ini` so settings live next to the binary. `build.cmd` then feeds
  that folder to `scripts/installer.nsi` (NSIS) to produce a second artifact,
  `aseprite-<version>-windows-x64-setup.exe`:
  - **No third-party NSIS plugins** (no `UAC.dll`) — only what ships with a
    plain `choco install nsis`. Elevation is hand-rolled via `ExecShell
    "runas"`/`ExecShellWait "runas"`, never `RequestExecutionLevel admin`
    (that would force UAC just to *open* the installer, even for a
    per-user-only install — `RequestExecutionLevel user` stays fixed).
  - **Dual scope, decided at runtime** on a custom wizard page, not baked in:
    "all users" (`Program Files`, `HKLM`) vs. "current user only"
    (`%LocalAppData%\Programs`, `HKCU`). The wizard's Next button shows the
    UAC shield (native `BCM_SETSHIELD`, from `WinMessages.nsh` — already
    `!include`d, **never redefine it**, NSIS treats a second `!define` of an
    existing name as a hard compile error, `!error` on line X, that only
    `makensis` catches, not the test suite) when "all users" is selected.
  - **Upgrades fully uninstall the previous version first** (same scope) and
    detect + remove a stray installation left behind in the *other* scope,
    instead of only overwriting files. Two elevation-boundary rules this
    logic depends on, learned from a real privilege-escalation bug caught in
    review and fixed:
    1. Once a process is elevated, **never trust a path read from `HKCU`**
       (a same-privilege-level value any medium-integrity process — or a
       malicious one — can already write) to decide what to execute; that's
       a UAC-bypass pattern. Only act on `HKCU`-sourced paths while still
       unelevated. `HKLM`-sourced paths stay safe to trust even once
       elevated, since only a *previous elevated* process could have written
       them.
    2. A relaunch marker meant to run invisibly while elevated (e.g.
       `/CLEANUPPATH=`) must be handled in `Function .onInit`, which runs
       before any page — handling it inside a page's create function (like
       `PageScope`) deadlocks the parent, which blocks on `ExecShellWait`
       waiting for a child that's actually stuck on `MUI_PAGE_WELCOME`,
       waiting for a click nobody knows to give.
  - **`ExecShellWait` does not reliably push a return value** onto NSIS's
    stack the way `ExecWait` does (confirmed empirically with a minimal
    script) — never `Pop` its result. A `Pop` with nothing to pop corrupts
    the global stack and sets `${Errors}` as a side effect of the failed pop
    itself, which silently aborted the installer right after a successful
    elevated cleanup in one real, shipped bug. Check `${Errors}` alone,
    exactly like the plain `ExecShell "runas"` calls already do.
  - The icon (`setup.exe`/`uninstall.exe`) is sourced from
    `aseprite/data/icons/ase.ico` — the same `.ico` Aseprite's own
    `resources_win32.rc` embeds — passed via a required `/DICONFILE=` define;
    `installer.nsi` hard-fails (`!ifndef`) if it's missing.
  - None of this can be compile-checked by the portable test suite (no
    Windows-only `makensis` dependency assumed) — see Tests below.
- **macOS**: a signed-nothing, notarized-nothing `.dmg` built by
  `scripts/make-dmg.sh`, which:
  - requires `scripts/make-icns.sh` to have already generated
    `Aseprite.icns` from the PNGs under `aseprite/data/icons/` (upstream's
    `Info.plist` references that file but never ships or generates it —
    `iconutil` builds it from a fixed name→PNG mapping, and the script hard
    -fails if upstream moves those PNGs);
  - uses **`dmgbuild`**, not `create-dmg`, specifically because `create-dmg`
    drives the Finder via AppleScript and that's flaky on these runners;
    `dmgbuild` writes the window layout directly. Its dependency is pinned
    by hash in `scripts/dmg-requirements.txt` and installed into a throwaway
    venv with `--require-hashes --only-binary=:all:` (the system Python is
    externally-managed);
  - bakes in a `READ ME FIRST.txt` explaining the
    `xattr -dr com.apple.quarantine` step every user needs once, since the
    app is ad-hoc signed and not notarized (no paid Apple Developer account);
  - verifies its own output on every run (mounts the `.dmg`, checks the app,
    the `Applications` symlink target, the icon, and the readme are all
    present) rather than trusting a clean `dmgbuild` exit code;
  - `aseprite/docs` (the manual) is deliberately left out of the `.dmg` — it
    has no place inside an installer volume and is available online.

## Tests

`tests/*.test.sh` are plain bash, discovered and run by `tests/run-all.sh`.
They test the scripts' *logic* without needing the real toolchain: version
resolution/validation, the icon name→PNG mapping/pairing (not just that
names match), and `make-dmg.sh`'s preconditions. The actual `.dmg` packaging
step is macOS-only and is instead verified at the end of `make-dmg.sh` itself
on every real build, not in the portable test suite.

`tests/make-installer.test.sh` is the same idea for `scripts/installer.nsi`:
static `grep`-based assertions (defines exist, elevation/registry patterns
are present, a handler sits between the right two `Function` markers) since
`makensis` is a Windows-only tool the suite doesn't assume is installed. This
means it **cannot** catch real compile errors (a `!define` collision) or
runtime-only bugs (the `ExecShellWait`/stack, `.onInit`-vs-page issues
above) — those were only found by actually running `build.cmd` end to end on
a real Windows machine and clicking through the installer, which is why any
change to `installer.nsi` should get that manual pass before being trusted,
not just a green test suite.
