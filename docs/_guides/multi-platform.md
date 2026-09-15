---
title: Building across platforms
description: Build targets on their required hosts, combine the results, and generate distribution recipes once all packages are ready.
nav_order: 8
---

# Building across platforms

When a release includes Linux packages, a DMG, and a Windows installer, each
build job can produce its own directory. **Aggregation** combines those
verified directories into one result you can publish.

This guide assumes your configuration already declares the targets. Use
[Building packages](building-packages.md) for Linux and
[macOS and Windows installers](native-recipes.md) for native targets.

## Use the same release inputs

Every job must use the same configuration, app version, and build timestamp.
Check out the same commit with the same Git history depth on every host.
Set `SOURCE_DATE_EPOCH` to the same Unix timestamp in each job, normally the
release commit's timestamp.

For example, in a shell on Linux or macOS:

```sh
export SOURCE_DATE_EPOCH="$(git show -s --format=%ct HEAD)"
```

In PowerShell on Windows:

```powershell
$env:SOURCE_DATE_EPOCH = git show -s --format=%ct HEAD
```

In GitHub Actions, use `fetch-depth: 0` on each checkout so Git-derived recipe
values agree. Native packaging scripts should respect the shared timestamp
where their tools support it.

## Build each target on its host

For a project with exactly these three targets, run the corresponding command
in each job:

```sh
# Linux
native-packages build --version 1.2.3 --target linux-amd64 --output dist/linux

# macOS
native-packages build --version 1.2.3 --target macos-arm64 --output dist/macos

# Windows
native-packages build --version 1.2.3 --target windows-amd64 --output dist/windows
```

Transfer the complete build directories to the machine that will combine
and publish them. Keep `build.json`, the package subdirectories, and any
recipes. Preserve hidden files such as `.SRCINFO` when uploading CI artifacts.

Then run from a checkout with the same configuration:

```sh
native-packages aggregate dist/linux dist/macos dist/windows --output dist/complete
```

The command checks hashes and rejects overlapping target/format outputs,
conflicting recipe files, and missing targets. The destination must be new.
The original build directories are preserved.

After your app's package tests pass:

```sh
native-packages publish --from dist/complete --to github
```

## Generate recipes after packages are built

A Homebrew cask may need the checksum of the DMG produced by this very release.
In that case, **defer recipes**: build the packages first and render recipes
once the final files are available.

On each host, add `--defer-recipes`:

```sh
native-packages doctor --target linux-amd64 --defer-recipes
native-packages build --version 1.2.3 --target linux-amd64 --defer-recipes --output dist/linux
native-packages build --version 1.2.3 --target macos-arm64 --defer-recipes --output dist/macos
native-packages build --version 1.2.3 --target windows-amd64 --defer-recipes --output dist/windows
```

Each job still checks its selected targets and runs signing hooks, but skips
global recipe assets and recipe tools. AUR tooling is therefore needed only
on the finalization host.

Collect the results on Linux, along with any additional recipe assets, and run:

```sh
native-packages aggregate dist/linux dist/macos dist/windows \
  --finalize-recipes --output dist/complete
```

The command verifies all targets, resolves asset hashes, generates the recipes
and recipe archive, and writes a completed build. You can then test and publish:

```sh
native-packages publish --from dist/complete --to github,aur,homebrew
```

Only name destinations you have configured. A deferred build cannot be
published directly, and ordinary and deferred build directories cannot be
mixed in one aggregate.

## Connect a recipe asset to a built package

Declare the asset's `file` to match the native package's output filename:

```yaml
assets:
  MACOS:
    file: hello-@TAG@-macos-arm64.dmg
```

For version 1.2.3, the finalizer finds the verified package named
`hello-v1.2.3-macos-arm64.dmg`. Its hash includes signing and notarization.
A recipe can then use `@MACOS_URL@` and `@MACOS_SHA256@`.

A matching package takes precedence over an asset's `local` path. Package
filenames must be unique. Other assets, such as source or portable archives,
need their configured `local` files on the finalization host. Finalization
does not download those assets, even when the target builds used `--release`.

## Requirements for finalization

All input directories must defer recipes and agree on configuration, version,
timestamp, tool versions, and recipe metadata. Include every configured target
and format. The finalizer needs `tar` and `xz` for recipe archives, and
`makepkg` or working Docker for AUR metadata.

A deferred target can use asset filenames and URLs, but it cannot use an
unknown asset hash such as `@MACOS_SHA256@` in its own input, package definition,
or hooks. Such a target needs an ordinary build with that asset already
available. Release downloads still require checksums when recipes are deferred.

Prerelease recipes cannot be finalized. See [Prereleases](prereleases.md)
for using a shared native configuration with stable recipes.

## Publish Linux targets separately

If your app's own jobs already upload the native installers, you can use the
[reusable Linux workflow](github-actions.md#select-linux-targets-in-a-shared-configuration)
with `targets: linux-amd64,linux-arm64`. That workflow builds and publishes
exactly those complete targets. This is useful when you do not need a combined
release directory or deferred recipe finalization.
