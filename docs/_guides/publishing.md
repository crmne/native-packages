---
title: Publishing a release
description: Build packages from local files or GitHub release assets and publish the verified result.
nav_order: 3
---

# Publishing a release

Once you have [built and tested your packages](getting-started.md), you can
attach them to a GitHub release. This guide covers both local inputs and
binaries that are already uploaded to a release.

## 1. Choose the release repository

Add your GitHub repository to `native-packages.yaml` before building:

```yaml
release:
  repository: your-name/hello
```

This is where native-packages downloads release inputs and uploads packages.
It can be a separate repository from your application's source code.

## 2. Build your packages

### From local files

Use the same command as during development:

```sh
native-packages build --version 1.2.3
```

This reads each target's `input.local`. You can build and test the packages
before creating a GitHub release.

### From an existing GitHub release

To package binaries your release workflow has already uploaded, declare each
target's release asset name:

```yaml
input:
  kind: archive
  local: dist/hello_@VERSION@_linux_amd64.tar.gz
  release_asset: hello_@VERSION@_linux_amd64.tar.gz
```

The local path remains useful for development. `release_asset` is the exact
filename attached to the GitHub release; `@VERSION@` becomes `1.2.3`.

Upload a `checksums.txt` alongside the input archives. It must contain SHA-256
hashes with the release filenames. For example, run this in the directory
containing the archive, then upload both files through your release workflow:

```sh
sha256sum hello_1.2.3_linux_amd64.tar.gz > checksums.txt
```

For several binary inputs, include all of them in the same checksum file.
If your workflow uses another filename, set `release.checksums` to that name.

Now build from the published release:

```sh
native-packages build --release v1.2.3
```

The command downloads the inputs, verifies their published hashes, and builds
packages in `dist/packages/1.2.3/`. It skips `before_build` hooks. Every binary
release input needs a matching checksum.

DMG and Inno targets use prepared local directories. Download and unpack their
inputs in the native build job, then use `--version`. See
[macOS and Windows installers](native-recipes.md).

## 3. Upload the finished build

Install and authenticate the [GitHub CLI](https://cli.github.com/), and create
release `v1.2.3` in the configured repository using your normal release process.
The release must exist before you publish packages.

```sh
native-packages publish --from dist/packages/1.2.3 --to github
```

Before uploading, native-packages verifies the recorded file hashes, the
configuration, and the required targets and formats. Keep the build directory
intact and use the same configuration you built with.

The upload includes the package files, a recipe archive if one was generated,
and `packaging-checksums.txt`. Your original `checksums.txt` is preserved.
Files with matching names on the release are replaced, so publish the tested
build you intend users to download.

## Publish selected targets

By default, publication requires every configured target and all its formats.
If one configuration includes targets released by separate jobs, name exactly
which complete targets this build contains:

```sh
native-packages build --release v1.2.3 \
  --target linux-amd64 --output dist/linux-packages
native-packages publish --from dist/linux-packages --to github \
  --target linux-amd64
```

All formats for `linux-amd64` must be present, and the directory must contain
no additional targets. A build made with `--format deb` cannot be published
if that target also declares RPM.

To combine builds from several jobs, follow
[Building across platforms](multi-platform.md). Builds with deferred recipes
must be finalized before publication.

## Update distribution recipes

For AUR, Homebrew, or another downstream repository, first configure its
[recipe templates and destination](distribution-recipes.md). Then stage and
review the generated update:

```sh
native-packages stage aur dist/packages/1.2.3/recipes
native-packages diff aur
native-packages publish aur
```

Once this is part of your tested release process, you can publish configured
destinations together:

```sh
native-packages publish --from dist/packages/1.2.3 --to github,aur,homebrew
```

GitHub pull requests and GitLab merge requests require a reviewed description
with `--body-file`. Publish those destinations individually.

## Next steps

Set up [GitHub Actions](github-actions.md) to run packaging for each release.
For alpha and beta versions, read [Prereleases](prereleases.md).
