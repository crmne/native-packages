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
| `deb` | Linux | Compatible Linux files and package metadata. | nFPM, `readelf` for binaries. |
| `rpm` | Linux | Compatible Linux files and RPM-specific dependencies. | nFPM, `readelf` for binaries. |
| `archlinux` | Linux | Arch-compatible files and explicit dependencies. | nFPM, `readelf` for binaries. |
| `apk` | Linux | Suitable Alpine files, usually musl or static binaries, and dependencies. | nFPM, `readelf` for binaries. |
| `ipk` | Linux | Files for the device/distribution baseline, dependencies, and an `abi` label. | nFPM, `readelf` for binaries. |
| `appimage` | Linux | The same files as the DEB/RPM, including one desktop entry and its icon. | `mksquashfs` (squashfs-tools), `curl`, `readelf`. |
| `srpm` | Linux source target | RPM spec and source files. | nFPM; native RPM tooling for rebuild tests. |
| `msix` | Windows | Windows binaries, identity, application assets, and capabilities. | nFPM; Windows tools for signing and installation tests. |
| `dmg` | macOS | Complete app and a DMG script. | macOS, `lipo`, and your script's tools, such as `hdiutil`. |
| `inno` | Windows | Complete app and an Inno Setup recipe/wrapper. | Windows and your installed Inno compiler. |

The supported nFPM version is **2.47.0**. It writes package files from your
prepared contents. Native DMG and Inno targets call your scripts instead.
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
that. The AppImage carries no update information and is not signed.

Running an AppImage needs FUSE on the user's system, or
`./App.AppImage --appimage-extract-and-run`.

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

## DMG and Inno Setup

These formats run on their native host and each require a separate binary
target with a local directory input. macOS inspection supports `amd64`,
`arm64`, and `universal`; Windows inspection supports `386`, `amd64`, and
`arm64`. Your script and compiler must also support the chosen architecture.

Follow [macOS and Windows installers](../_guides/native-recipes.md) for setup.
DMG targets can automatically [sign and notarize](../_guides/apple-notarization.md)
when complete Apple credentials are available.

## Distribution recipes

[Templates and downstream repository settings](../_guides/distribution-recipes.md)
support AUR, Homebrew taps, Nixpkgs, Gentoo, Void, and other native recipe
repositories. You supply each distribution's recipe and its validation steps.
The tool renders release values and stages or submits the update.

An Arch package file and an AUR recipe are separate outputs: the former can
be installed directly; the latter tells Arch tooling how to obtain and package
your app.

There is no Flatpak or Snap build/publication adapter, no NSIS/WiX adapter, and no
hosted APT/DNF index service. Keep those workflows in your app's release
process if you need them.

## What validation establishes

Builds check inputs, architecture, applicable library requirements, package
contents or native containers, and recorded hashes. A `build.json` reports
installation as `not-tested`.

This repository's CI separately builds fixtures in every supported format and
runs Linux install/upgrade/remove checks, an SRPM rebuild, Windows MSIX and
Inno checks, and macOS DMG checks. Your app still needs its own installation
and runtime tests, including services, GUI integrations, entitlements, or
hardware access where applicable.
