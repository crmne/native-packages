---
title: Supported platforms
description: Package formats, required build inputs and tools, architecture checks, and distribution recipe support.
nav_order: 3
---

# Supported platforms

Choose formats for the systems your app already supports. Each target needs
binaries built for the correct operating system, CPU architecture, and runtime
libraries.

## Package formats

| Format | Target | What you supply | Packaging tools |
| --- | --- | --- | --- |
| `deb` | Linux | Compatible Linux files and package metadata. | nFPM, `readelf` for binaries; `gpg` for a hosted APT repository. |
| `rpm` | Linux | Compatible Linux files and RPM-specific dependencies. | nFPM, `readelf` for binaries; `createrepo_c` and `gpg` for a hosted DNF repository. |
| `archlinux` | Linux | Arch-compatible files and explicit dependencies. | nFPM, `readelf` for binaries. |
| `apk` | Linux | Suitable Alpine files, usually musl or static binaries, and dependencies. | nFPM, `readelf` for binaries. |
| `ipk` | Linux | Files for the device/distribution baseline, dependencies, and an `abi` label. | nFPM, `readelf` for binaries. |
| `appimage` | Linux | The same files as the DEB/RPM, including one desktop entry and its icon. | `mksquashfs` (squashfs-tools), `curl`, `readelf`; `zsyncmake` (zsync) with update information. |
| `flatpak` | Linux | The same files as the DEB/RPM, under `/usr`, and a top-level `flatpak` section. | `flatpak`, `readelf`; `ostree` and `gpg` to publish a repository. |
| `snap` | Linux | The same files as the DEB/RPM and a top-level `snap` section. | `mksquashfs` (squashfs-tools), `readelf`; `snapcraft` to upload to the Snap Store. |
| `srpm` | Linux source target | RPM spec and source files. | nFPM; native RPM tooling for rebuild tests. |
| `msix` | Windows | Windows binaries, identity, application assets, and capabilities. | nFPM; Windows tools for signing and installation tests. |
| `dmg` | macOS | Complete app and a DMG script. | macOS, `lipo`, and your script's tools, such as `hdiutil`. |
| `msi` | Windows | Complete app and a Windows Installer recipe/wrapper, such as a WiX project. | Windows and your installed MSI toolset, such as WiX; optional Azure Artifact Signing. |
| `inno` | Windows | Complete app and an Inno Setup recipe/wrapper. | Windows and your installed Inno compiler; optional Azure Artifact Signing. |

The supported nFPM version is **2.47.0**. It writes package files from your
prepared contents. Native DMG, MSI and Inno targets call your scripts instead.
Archive inputs also require `bsdtar`; release downloads require `curl`.

## Linux compatibility

Linux binary targets declare `libc: glibc`, `musl`, or `static`. The tool checks
ELF architecture, linked libraries, and the declared C library without executing
the binaries. DEB/RPM dependency detection can be extended with
[configuration mappings](configuration.md#libraries).

Supported inspection architectures are `386`, `amd64`, `arm64`, `arm5`, `arm6`,
`arm7`, `mips`, `mipsle`, `mips64`, `mips64le`, `ppc64`, `ppc64le`, `s390x`,
`riscv64`, and `loong64`. Unknown architectures fail explicitly.

Use explicit dependencies for Arch, Alpine, and IPK. Test against the oldest
distribution version you intend to support, including any libraries your app
loads at runtime. Changing a glibc target's format to APK does not turn its
binary into a musl build.

For IPK, check which format your device's distribution release actually uses.
The repository's IPK fixture targets OpenWrt 24.10.8; its coverage should not
be treated as a claim about every OpenWrt version.

## AppImage

An AppImage is one executable file that runs without installation. Add
`appimage` to a Linux binary target's `formats`; it uses the same `contents`
as the other formats, so there is nothing else to describe:

```yaml
linux-amd64:
  platform: linux
  arch: amd64
  libc: glibc
  formats: [deb, rpm, appimage]
```

The package must install exactly one desktop entry under
`/usr/share/applications`. Its `Exec` names the program the AppImage runs
(found in `/usr/bin`, or an absolute path inside the package) and its `Icon`
names an SVG or PNG under `/usr/share/icons` or `/usr/share/pixmaps`. A
contents entry with `packager: appimage` is included only in the AppImage, and
one with another packager is left out. Entries of type `ghost` are skipped.

The output is `NAME-VERSION-ARCH.AppImage`, with AppImage's architecture names
(`x86_64`, `aarch64`, `i686`, `armhf` for `amd64`, `arm64`, `386`, `arm7`).
The file is the pinned AppImage runtime (type2-runtime 20251108, downloaded
once into `.cache/native-packages` and checked against a built-in SHA-256)
followed by a zstd SquashFS image. No `appimagetool` or nFPM is involved, the
build does not run the binary, and an ARM64 AppImage can be built on an x86
host. The same inputs and `SOURCE_DATE_EPOCH` give the same bytes.

**Libraries are not bundled.** The AppImage uses the host's libraries, as the
DEB and RPM do, and `build.json` lists what the binary links under
`required_libraries` with `"libraries": "host"`. It therefore runs where your
binary's glibc floor and those libraries are met, not on every Linux system.
Build on the oldest distribution you support, or link statically, to widen
that. The AppImage is not signed.

### Update information

AppImageUpdate, AppImageLauncher, AM, Gear Lever and other updaters find a
newer AppImage through the update information embedded in it, and download
only the blocks that changed through a `.zsync` file published beside it.
Give the target an `appimage.update_information`:

```yaml
linux-amd64:
  platform: linux
  arch: amd64
  libc: glibc
  formats: [appimage]
  appimage:
    update_information: gh-releases-zsync|owner|app|latest|app-*-x86_64.AppImage.zsync
```

The string goes into the runtime's `.upd_info` section, and the build reads
it back from the finished AppImage. `zsyncmake` then writes
`NAME-VERSION-ARCH.AppImage.zsync` beside it, with the AppImage's file name
as its relative URL, and the build checks the file's name, length and SHA-1
against the AppImage. `build.json` records the `.zsync` file with its
package, and `publish --to github` attaches both. The same inputs give the
same bytes for both files.

Two forms are accepted: `gh-releases-zsync|OWNER|REPOSITORY|TAG|PATTERN`,
where `TAG` is usually `latest` (the newest stable release), and
`zsync|https://URL.zsync`. A GitHub string must name `release.repository`,
and its pattern must match the target's `.zsync` file name, so validation
fails before a release could ship an AppImage whose updaters look for a file
that is not there. Each architecture needs its own target with its own
pattern. An `after_package` hook must leave the AppImage as it is, or the
`.zsync` file no longer describes it and the build fails.

Running an AppImage needs FUSE on the user's system, or
`./App.AppImage --appimage-extract-and-run`.

## Flatpak

Add `flatpak` to a Linux binary target's `formats` (`amd64` or `arm64`) and
describe the app once, at the top level:

```yaml
flatpak:
  id: org.example.Hello
  runtime: org.freedesktop.Platform
  runtime_version: '24.08'
  sdk: org.freedesktop.Sdk
  command: hello
  metainfo: packaging/org.example.Hello.metainfo.xml
  runtime_repo: https://dl.flathub.org/repo/flathub.flatpakrepo
  finish_args:
    - --socket=wayland
    - --socket=fallback-x11
    - --share=ipc
    - --share=network
```

| Field | Purpose |
| --- | --- |
| `id` | Required. The reverse-DNS application ID. |
| `runtime`, `runtime_version` | Required. The runtime the app runs on, such as `org.freedesktop.Platform` `24.08`. |
| `sdk` | Optional. Recorded for `flatpak run --devel`; nothing is built with it. |
| `command` | Required. A program in `/usr/bin` (which becomes `/app/bin`), or an absolute `/app` path. |
| `finish_args` | The app's sandbox permissions, as `flatpak build-finish` options. |
| `metainfo` | Optional AppStream file, installed as `ID.metainfo.xml`. It must declare `<id>ID</id>`. |
| `branch` | Defaults to `stable`. |
| `runtime_repo` | Optional `.flatpakrepo` URL from which `flatpak install` fetches a missing runtime. |
| `repository` | Optional [self-hosted Flatpak repository](../_guides/hosted-repositories.md#flatpak) for `publish --to flatpak`. |

The bundle holds the same `contents` as the other formats, with `/usr`
becoming `/app`; a file installed anywhere else fails the build. A contents
entry with `packager: flatpak` is included only in the Flatpak. Flatpak
exports only files named after the app ID, so the package's one desktop entry
becomes `ID.desktop`, its `Icon` becomes the ID, and the icon files it names
are renamed to match.

The output is `NAME-VERSION-ARCH.flatpak` (`x86_64` or `aarch64`), a
single-file bundle users install with `flatpak install --user FILE`. The app
is already built, so native-packages writes the metadata and runs
`flatpak build-finish`, `build-export` and `build-bundle` on the staged
files. No flatpak-builder, SDK or network is needed, and nothing is compiled
in the sandbox. Runtimes installed on the build host are hidden from
`build-finish`, so they cannot add permissions. The same inputs and
`SOURCE_DATE_EPOCH` give the same OSTree commit, which `build.json` records;
the bundle file around it also records when it was written, so its hash
changes between builds.

**Libraries come from the runtime.** The binary must run against the
runtime's libraries, or the package must install the others under `/usr/lib`.
Test the app in the sandbox with the permissions you declared.

native-packages does not write Flathub manifests or submit apps to Flathub,
because Flathub does not accept AI-assisted manifests or submissions. Write
and submit a Flathub manifest yourself if you want to publish there.

## Snap

Add `snap` to a Linux binary target's `formats` and describe the snap once,
at the top level. The fields follow `snap.yaml`:

```yaml
snap:
  base: core24
  confinement: strict
  grade: stable
  icon: /usr/share/icons/hicolor/scalable/apps/hello.svg
  apps:
    hello:
      command: usr/bin/hello
      desktop: usr/share/applications/hello.desktop
      plugs: [wayland, x11, opengl, network, audio-playback]
  store:
    channels: [stable]
```

| Field | Purpose |
| --- | --- |
| `name` | Defaults to `nfpm.name`. 2 to 40 lowercase letters, digits and hyphens. |
| `base` | Required, such as `core24`. |
| `confinement` | `strict` (default), `classic` or `devmode`. |
| `grade` | `stable` (default) or `devel`. |
| `summary`, `description`, `license`, `title` | Default to the first line of `nfpm.description`, the description and `nfpm.license`. The summary has at most 78 characters. |
| `apps` | Required. Each app's `command` is a path inside the snap, such as `usr/bin/hello`, and may also set `plugs`, `slots`, `environment`, `daemon` and the other `snap.yaml` app fields. |
| `apps.APP.desktop` | Optional desktop entry the package installs. It is copied to `meta/gui/APP.desktop`, launching the app. |
| `icon` | Optional `.png` or `.svg` the package installs; it becomes `meta/gui/icon` and the desktop entries' `Icon`. |
| `plugs`, `slots`, `layout`, `environment` | Optional top-level `snap.yaml` sections, passed through. |
| `store.channels` | Channels for `publish --to snapcraft`, such as `stable` or `latest/edge`. |

The package's `contents` become the snap's root (`/usr/bin/hello` is
`$SNAP/usr/bin/hello`), beside a generated `meta/snap.yaml`. A contents entry
with `packager: snap` is included only in the snap. The output is
`NAME_VERSION_ARCH.snap` with Snap's architecture names (`amd64`, `arm64`,
`armhf`, `ppc64el`, `s390x`, `riscv64`). It is an xz SquashFS image owned by
root, packed with mksquashfs as `snap pack` packs a prime directory. No
snapcraft, LXD or network is involved, and the same inputs and
`SOURCE_DATE_EPOCH` give the same bytes.

**Libraries come from the base snap or the package.** A strictly confined
snap does not see the host's libraries, and no snapcraft extension (such as
`gnome` or `kde-neon`) is applied, so a dynamically linked desktop app needs
its libraries among the contents and an `environment` that points at them.
Static binaries need nothing more. Install the snap with
`snap install --dangerous FILE` and test it under its confinement before
uploading.

`publish --to snapcraft` uploads each snap in the build with
`snapcraft upload --release=CHANNELS`. The Snap Store login comes from
`SNAPCRAFT_STORE_CREDENTIALS` (from `snapcraft export-login`), never the
configuration, and the snap's name must already be registered.

## MSIX

MSIX targets use `platform: windows`, `formats: [msix]`, and PE binaries with
`arch: 386`, `amd64`, or `arm64`. Supply `nfpm.msix.publisher`, at least one
application under `nfpm.msix.applications`, and the required assets and
capabilities for your app.

The [all-formats example](https://github.com/crmne/native-packages/blob/main/examples/native-packages-all-formats.yaml)
includes an MSIX configuration. The reusable Linux workflow can construct an
MSIX from already-built Windows inputs. Perform signing and installation
checks on Windows.

Use Windows SDK SignTool through an `after_package` hook for signing, as the
project's Windows acceptance tests do. Those tests found that Windows rejected
nFPM 2.47.0's built-in signature with `0x80096010`. An MSIX file built
successfully is not yet evidence that Windows will accept and install it.

## DMG, MSI and Inno Setup

These formats run on their native host and each require a separate binary
target with a local directory input. macOS inspection supports `amd64`,
`arm64`, and `universal`; Windows inspection supports `386`, `amd64`, and
`arm64`. Your script and compiler must also support the chosen architecture.

Follow [macOS and Windows installers](../_guides/native-recipes.md) for setup.
DMG targets can automatically [sign and notarize](../_guides/apple-notarization.md)
when complete Apple credentials are available. MSI and Inno targets can sign
their code and installer with [Azure Artifact Signing](../_guides/windows-signing.md).

## Distribution recipes

[Templates and downstream repository settings](../_guides/distribution-recipes.md)
support AUR, Homebrew taps, Nixpkgs, Gentoo, Void, and other native recipe
repositories. You supply each distribution's recipe and its validation steps.
The tool renders release values and stages or submits the update.

An Arch package file and an AUR recipe are separate outputs: the former can
be installed directly; the latter tells Arch tooling how to obtain and package
your app.

native-packages can also write signed APT, DNF and Flatpak repositories from
your DEB, RPM and Flatpak packages, served as static files; see
[Hosted package repositories](../_guides/hosted-repositories.md). There is no
NSIS adapter. Keep that workflow in your app's release process if you need it.

## What validation establishes

Builds check inputs, architecture, applicable library requirements, package
contents or native containers, and recorded hashes. A `build.json` reports
installation as `not-tested`.

This repository's CI separately builds fixtures in every supported format and
runs Linux install/upgrade/remove checks, an SRPM rebuild, Windows MSIX and
Inno checks, and macOS DMG checks. Your app still needs its own installation
and runtime tests, including services, GUI integrations, entitlements, or
hardware access where applicable.
