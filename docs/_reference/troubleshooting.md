---
title: Troubleshooting
description: Resolve missing tools and inputs, architecture errors, recipe issues, and publication failures.
nav_order: 4
---

# Troubleshooting

Start with these commands from your application directory:

```sh
native-packages validate
native-packages doctor
native-packages build --version 1.2.3 --dry-run
```

They check configuration, packaging tools, and the planned inputs respectively.
For a configuration with several native hosts, select the target you are
working on with `doctor --target ID` and `build --target ID --dry-run`.

## The configuration needs another tool version

Install and select the version named in the error:

```sh
gem install native-packages --version 0.7.0
native-packages _0.7.0_ doctor
```

`tool.version` is an exact match. In CI, use the matching released reusable
workflow. To upgrade, update the configuration and workflow together.

## nFPM or an inspection tool is missing

Linux and MSIX packaging require nFPM 2.47.0. Linux binary inspection needs
`readelf`; archive extraction needs `bsdtar`. Install these using the
[setup instructions](../_guides/getting-started.md#1-install-the-tools).

DMG and Inno targets do not require an nFPM executable. If you only intend to
build a native target, select it explicitly so `doctor` does not check Linux
targets from the same configuration.

## An input does not exist

Check the path relative to the configuration file, not your shell's current
directory. Make sure your build script produced the expected file and that
any `@VERSION@` value matches the version you requested.

For a single executable use `input.kind: file`; for a prepared directory use
`directory`. The default is `archive`.

## A package content file is missing

Check the input's internal layout. Archives retain top-level folders. If an
archive contains `hello-1.2.3/hello`, the source is
`@PAYLOAD@/hello-1.2.3/hello`. For a file input, the payload contains the
input file's basename.

A target-specific `nfpm.contents` list replaces the shared list entirely.
Include all the files needed by that target.

## Wrong architecture or C library

Rebuild the application for the platform and architecture declared by the
target, or correct the target to match your intended build. An ARM64 binary
cannot satisfy `arch: amd64`.

If the tool reports a static target containing dynamic binaries, use the
appropriate `libc: glibc` or `musl`, or produce a truly static build. Adding a
new package format does not change the binary's runtime requirements.

## A shared library has no package mapping

For DEB/RPM, add the library's distribution package names under
[`libraries`](configuration.md#libraries). For other formats, declare runtime
dependencies explicitly. If the library is bundled, make sure it is included
in `contents`. Confirm dependency names on your supported distributions.

## The output directory already exists

Choose a new output path:

```sh
native-packages build --version 1.2.3 --output dist/rebuild-1.2.3
```

Builds and aggregation preserve existing outputs. Keep earlier builds until
you have reviewed the replacement.

## There is no exact release tag at HEAD

Pass the app version for a local build:

```sh
native-packages build --version 1.2.3
```

Version inference requires an exact supported release tag on the current
commit. Native installer targets always consume local prepared directories,
even when those files originated in a release job.

## A release checksum is missing or incorrect

The input filename must appear in the release's `checksums.txt` (or configured
`release.checksums`). Generate the hash from the exact archive you upload.
Check that the version and `release_asset` name agree with the release.

Do not bypass checksums for binary inputs. `checksummed: false` is available
for additional source assets intentionally omitted from the release checksum
list. See [Publishing a release](../_guides/publishing.md).

## A recipe value is unresolved

Check the token spelling and asset key. Asset names are uppercase:
`assets.MACOS` supplies `@MACOS_FILE@`, `@MACOS_URL@`, and `@MACOS_SHA256@`.
Target-only values such as `@ARCH@` are not available in global recipes.

During a deferred build, recipe asset hashes are not known yet. If a target
itself needs one of those hashes, use an ordinary build with the asset
available. See [replacement values](configuration.md#replacement-values).

## AUR tools are requested on macOS or Windows

Use `build --defer-recipes` and `doctor --defer-recipes` in native jobs, then
finalize recipes on Linux after collecting all packages. See
[Building across platforms](../_guides/multi-platform.md).

## Aggregation says builds disagree

Use the same configuration, app version, timestamp, and checkout across jobs.
For deferred builds, Git-derived recipe metadata must also agree; use the same
Git history depth. Include all configured targets and formats exactly once.

Use `--finalize-recipes` for deferred inputs. Do not mix ordinary and deferred
build directories. Preserve hidden recipe files while moving CI artifacts.

## Publication rejects the build

Common causes are a changed configuration, missing formats, or files modified
after their hashes were recorded. Signing belongs inside the build's output
hook; rebuild if signing happened afterward.

Use the original configuration and complete output directory. For separate
release jobs, `publish --target ID` requires exactly those complete targets.
It does not allow publishing one format from a target that declares several.

A deferred result needs finalization. A prerelease upload also needs an
existing GitHub release marked as a prerelease.

## A downstream update cannot be staged or pushed

Read `native-packages diff TARGET` and inspect the managed checkout named in
the error under `.cache/packaging/repos/`. The tool rejects unrelated dirty
files, an existing unpublished update, unexpected remote changes, and downgrades.
Resolve the reported state before retrying. PR/MR publication also requires
a reviewed `--body-file` and valid fork credentials.

## Apple signing fails or is skipped

All six [Apple environment variables](../_guides/apple-notarization.md#1-set-up-your-apple-credentials)
are needed. None means an unsigned build; an incomplete set fails explicitly.
Check the exact identity, export password, Team ID, and app-specific password.

A native script must package `@PAYLOAD@` and preserve its signatures. A failure
from Apple's service prevents a completed signed build. Use the submission
information in the error to investigate Apple's result before retrying.

## Get help

If the error persists, [open an issue](https://github.com/crmne/native-packages/issues)
with the command, tool version, host platform, relevant configuration, and
error message. Remove credentials and private download URLs before sharing.
