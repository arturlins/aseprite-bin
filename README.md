# aseprite-bin

Compile [Aseprite][] for yourself using GitHub Actions, for Windows, Linux, or
macOS. No development tools to install and nothing to configure — you click a
button on a web page, wait, and download the result.

> [!IMPORTANT]
> **You need an Aseprite license.** The [EULA][] lets you compile Aseprite from
> source for your own use, but **forbids redistributing the binaries you
> produce**. The workflows here are manual-only and never publish a Release.
> Build artifacts expire after 7 days.
>
> If this repository is public, anyone signed in to GitHub can download the
> artifacts from your runs. If that bothers you, use **Import repository**
> instead of **Fork** and make your copy private — a fork of a public
> repository cannot be made private.

To buy a license, visit the [Aseprite download page][download page].

## What you get

A *workflow* is an automated job that GitHub runs for you on its own computers.
This repository has one per operating system, so you run only the one you need,
and a failure on one platform never affects the others.

| Workflow | Runs on | You download |
|---|---|---|
| `Build (Windows)` | `windows-2025` | a folder with `aseprite.exe`, `data/` and `docs/`, or an installer that sets it up for you |
| `Build (Linux)` | `ubuntu-22.04` | a `.tar.gz` archive with the program, `data/` and `docs/` |
| `Build (macOS)` | `macos-15` (Apple Silicon) | a `.dmg` disk image with `Aseprite.app` |

## How to build

### 1. Make your own copy of this repository

Click `Fork` at the top of the page.

![step1a](images/step1a.png)
![step1b](images/step1b.png)

> To keep your binaries out of reach of other people, use **`+` → Import
> repository** and mark the copy as **Private**, instead of forking.

### 2. Turn Actions on

Open the `Actions` tab and confirm that you want to enable workflows. GitHub
disables them by default on a new copy.

![step2](images/step2.png)

### 3. Run the workflow for your platform

Pick `Build (Windows)`, `Build (Linux)` or `Build (macOS)` from the list on the
left, then click `Run workflow`.

The `version` field is optional:

- **Leave it empty** — builds the **latest published release** of Aseprite.
  Prereleases and drafts are skipped.
- **Fill it in** — builds the version you name, for example `v1.3.18.1` or
  `v1.3.18-beta1`. The full list is on the [Aseprite tags page][versions].

![step3](images/step3.png)

### 4. Wait, then open the run

Compiling takes a while: roughly 20 minutes on Windows, 13 on Linux, 10 on
macOS. You can close the page and come back later.

![step4](images/step4.png)

### 5. Download the artifact at the bottom of the page

An *artifact* is just the file the job produced. GitHub always wraps it in a
`.zip`, whatever is inside.

![step5](images/step5.png)

To build a newer version later, repeat steps 3 to 5.

## After you download

### macOS

You downloaded a `.zip`. Inside it is a `.dmg` — a disk image, the usual way
Mac apps are delivered.

1. **Double-click the `.zip`.** A `.dmg` file appears next to it.

2. **Double-click the `.dmg`.** A window opens showing the Aseprite icon on the
   left and a folder called Applications on the right.

3. **Drag the Aseprite icon onto the Applications folder.** That copies
   Aseprite onto your Mac. When the copy finishes you can close the window and
   eject the disk image.

4. **Allow Aseprite to run.** Open the Terminal app — press Command+Space, type
   `Terminal`, press Return — then paste this line and press Return:

       xattr -dr com.apple.quarantine /Applications/Aseprite.app

   It prints nothing when it works. That is normal.

5. **Open Aseprite** from your Applications folder.

Steps 4 and 5 are only needed once per build.

#### Why is step 4 needed?

macOS refuses to open apps that have not been *notarized* by Apple. Notarizing
requires a paid Apple Developer account, which this project does not use — so
macOS treats Aseprite as untrusted even though you compiled it yourself from
the official source code. It is not a sign that anything is wrong with the
build.

The command in step 4 clears that flag for this one app.

If you would rather not use the Terminal: try to open Aseprite and let macOS
block it, then open System Settings, go to Privacy & Security, scroll to the
bottom, and click **Open Anyway**.

The same instructions are included as `READ ME FIRST.txt` inside the disk
image.

Only **Apple Silicon** (M1 and newer) is supported. Intel Macs are not built
here.

### Windows

The Windows workflow produces **two separate downloads**, so you only get the
one you actually want: `aseprite-<version>-windows-x64` (portable) and
`aseprite-<version>-windows-x64-setup` (installer).

**Portable.** The artifact is a `.zip` containing the folder
`aseprite-v1.3.18.1-windows-x64`. Unzip it anywhere you like and run:

    aseprite-v1.3.18.1-windows-x64\aseprite.exe

The included `aseprite.ini` makes the program portable, keeping its settings in
that same folder instead of in your user profile. Move the folder and your
settings come along.

**Installer.** The artifact is a `.zip` containing a single `.exe`. Run it and
you'll be asked:

- **Install for all users** or **install for me only.** The first needs
  administrator rights and installs to `C:\Program Files\Aseprite`; the second
  needs no special rights and installs to your own user profile instead. Pick
  the second if you're on a computer where you don't have administrator
  access — for example, a work computer managed by an organization.
- Whether to add a **desktop shortcut** (off by default — a Start Menu
  shortcut is always created) and whether to **open `.aseprite`/`.ase` files
  with Aseprite** by double-clicking them (on by default).

The installed copy keeps its settings in your Windows user profile rather than
next to the program, and adds an entry to Windows' "Add or remove programs" so
you can uninstall it the normal way.

### Linux

The artifact is a `.zip` containing a `.tar.gz`. The extra layer exists because
GitHub strips the executable permission when it packs a directory, and the
program would not start.

    unzip aseprite-v1.3.18.1-linux-x64.zip
    tar -xzf aseprite-v1.3.18.1-linux-x64.tar.gz
    cd aseprite-v1.3.18.1-linux-x64
    ./aseprite

It is compiled on Ubuntu 22.04 (glibc 2.35) and runs on distributions of that
generation or newer.

## Building on your own machine

The same scripts the automated builds use also run locally. First find the
version you want and set it as an environment variable.

**Windows** — needs Visual Studio with "Desktop development with C++", Git,
7-Zip, CMake, and [NSIS][]. All are required — `build.cmd` exits if any is
missing:

    set ASEPRITE_VERSION=v1.3.18.1
    build.cmd

To look up the latest version without opening a browser, use the Git Bash that
comes with Git for Windows:

    bash scripts/resolve-version.sh

**Linux and macOS:**

    export ASEPRITE_VERSION="$(bash scripts/resolve-version.sh)"
    ./build.sh

Every run re-clones Aseprite at the exact version requested, so each build
starts from a clean tree. The Skia download is reused between runs.

Each platform's prerequisites are listed in Aseprite's official [INSTALL.md][].

## How the version is resolved

`scripts/resolve-version.sh` is the single source of truth:

1. With no argument, it queries `GET /repos/aseprite/aseprite/releases/latest`
   — that endpoint already excludes drafts and prereleases.
2. It normalizes the input, adding the `v` prefix if you left it out.
3. It validates against `^v[0-9]+(\.[0-9]+){1,3}(-beta[0-9]+)?$` **before** the
   string reaches any URL or `git` command.
4. It confirms the tag exists in the official repository, failing early and
   clearly if it does not.

The test suite runs with no external dependencies:

    bash tests/run-all.sh

## macOS packaging notes

The macOS build does two things the Aseprite source tree does not do on its
own.

**It gives the app its icon.** Aseprite's `Info.plist` declares an
`Aseprite.icns`, but that file is not in the open-source repository and its
CMake does not generate one — so an app compiled straight from source has no
icon at all. `scripts/make-icns.sh` builds it from the PNGs under
`data/icons/`, which are in the repository, using `iconutil`.

**It builds the disk image with [dmgbuild][], not `create-dmg`.**
`create-dmg` lays out its window by running AppleScript against the Finder,
which fails intermittently on the macOS runners used here. `dmgbuild` writes
the window layout directly, with no Finder involved. Its version is pinned by
hash in `scripts/dmg-requirements.txt`.

The disk image is not signed or notarized, and there is no plan to change that
— see step 4 above.

## Legal

This repository does not distribute or contain any Aseprite code or binaries.
It only automates compiling from the official source. Aseprite is the property
of Igara Studio S.A. and is subject to its [EULA][]. Compile only if you hold a
valid license, and do not redistribute what you build.

[Aseprite]: https://github.com/aseprite/aseprite
[INSTALL.md]: https://github.com/aseprite/aseprite/blob/main/INSTALL.md
[EULA]: https://github.com/aseprite/aseprite/blob/main/EULA.txt
[versions]: https://github.com/aseprite/aseprite/tags
[download page]: https://www.aseprite.org/download/
[dmgbuild]: https://github.com/dmgbuild/dmgbuild
[NSIS]: https://nsis.sourceforge.io/
