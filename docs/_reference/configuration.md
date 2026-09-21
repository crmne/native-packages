---
title: Configuration reference
description: All native-packages configuration fields, target options, hooks, tokens, and downstream repository settings.
nav_order: 1
---

# Configuration reference

For a first configuration, follow [Getting started](../_guides/getting-started.md).
This page is for looking up individual settings.

## File location

Use `native-packages.yaml` or `native-packages.yml` in your working directory.
To choose another file:

```sh
native-packages --config packaging/native-packages.yaml build --version 1.2.3
```

Configuration paths and hooks resolve from that file's directory. Keep only
one of the auto-discovered filenames, or use `--config` to select one.
The configuration is YAML data; it does not evaluate Ruby or general template
expressions. Use the replacement values listed below.

## Top-level fields

| Field | Purpose |
| --- | --- |
| `schema` | Required. Set to `1`. |
| `tool.version` | Required. Exact native-packages version, such as `'0.7.0'`. |
| `tool.nfpm` | Required. Set to `'2.47.0'`, including in native-only configurations. |
| `nfpm` | Shared package metadata and installed-file mappings, or a relative YAML filename. Requires `name`. |
| `targets` | Required. Named build targets; use `{}` for recipe-only projects. |
| `release` | GitHub repository, checksum filename, and prerelease opt-in. |
| `assets` | Additional files used by recipe templates. Defaults to `{}`. |
| `templates` | Generated recipe paths mapped to source template paths. Defaults to `{}`. |
| `repositories` | Downstream publication destinations. Defaults to `{}`. |
| `libraries` | Additional shared-library dependency mappings for DEB/RPM. |
| `revisions` | Package revision numbers by app version and recipe path. |
| `version_file` | Cargo manifest checked by `check-version`. |
| `version_section` | Cargo section to check; defaults to `package`. |

Quote tool versions so they remain strings. A version mismatch reports the
command needed to install and select the configured gem.

## Package metadata

`nfpm` is named after the helper that writes Linux packages and MSIX files.
It holds the package's metadata, files, dependencies, and package-manager
settings. Native DMG and Inno targets also read the shared metadata.

Every target needs nonempty `maintainer`, `description`, and `license` values.
Non-native targets need a `contents` list. The shared package name may contain
letters, digits, dots, underscores, and hyphens, starting with a letter or digit.

```yaml
nfpm:
  name: hello
  description: A small greeting application
  maintainer: Your Name <you@example.com>
  license: MIT
  contents:
    - src: '@PAYLOAD@/hello'
      dst: /usr/bin/hello
      file_info:
        mode: 0755
```

You can move that mapping to a file and use `nfpm: packaging/package.yml`.
A target can supply an `nfpm` mapping or filename to override shared values.
Maps merge recursively; lists replace in full.

The package name, version, platform, and architecture come from the shared
name, build version, and target. Avoid conflicting declarations under `nfpm`.
Format-specific architecture names belong under sections such as `deb.arch`.
For additional metadata, scripts, and format overrides, see the
[nFPM configuration reference](https://nfpm.goreleaser.com/docs/configuration/).

## Targets

Each key under `targets` is an ID such as `linux-amd64`. IDs use lowercase
letters, digits, and hyphens, starting with a letter or digit.

| Target field | Purpose |
| --- | --- |
| `platform` | Required: `linux`, `macos`, or `windows`. |
| `arch` | Required. Architecture, commonly `amd64` or `arm64`. macOS also supports `universal`. |
| `formats` | Required nonempty list of output formats, without duplicates. |
| `kind` | `binary` (default), `data`, or `source`. |
| `libc` | Required for Linux binary targets: `glibc`, `musl`, or `static`. |
| `abi` | Required for IPK: a label identifying the device/distribution baseline. |
| `input` | Required. Local file, directory, or release asset to package. |
| `nfpm` | Package metadata overrides for this target. |
| `compiler_target` | Optional value for `@TARGET@`; otherwise it is the target ID. |
| `before_build` | Command arguments run before copying a local input. |
| `after_package` | Command arguments run on each package before its hash is recorded. |
| `native` | Required for DMG/Inno. Contains `command` and `output`. |

Formats are `deb`, `rpm`, `archlinux`, `apk`, `ipk`, `srpm`, `msix`, `dmg`,
and `inno`. See [Supported platforms](platforms.md) for their requirements.

Windows targets select only `[msix]` or `[inno]`; macOS targets select `[dmg]`.
DMG and Inno each require a separate binary target. SRPM requires a separate
`kind: source` target with only `[srpm]`.

### Inputs

| Input field | Purpose |
| --- | --- |
| `local` | Path used by local builds. |
| `release_asset` | Filename used by `build --release`. |
| `url` | Optional download URL overriding the default GitHub release URL. |
| `kind` | `archive` (default), `directory`, or `file`. |

Declare at least `local` or `release_asset`, and supply the field needed for
your chosen build mode. Native targets require `kind: directory` and `local`.
Binary release inputs always need a matching published checksum.

Regular package inputs reject symbolic links. Use explicit installed symlink
entries in `contents`. Native inputs preserve safe internal relative links.

### Native commands

```yaml
native:
  command: [ruby, packaging/dmg.rb, '@PAYLOAD@', '@PACKAGE@', '@VERSION@']
  output: 'hello-@TAG@-macos-arm64.dmg'
```

The command must be a nonempty argument list containing `@PACKAGE@`, and must
create only that output file. `output` is a filename ending in `.dmg` or `.exe`.
See [macOS and Windows installers](../_guides/native-recipes.md) for the script
contract and a complete DMG example.

## Hooks

`before_build` runs once per selected target before copying local input.
It is skipped in release mode. `after_package` runs once per generated package
in either mode, before checksums are recorded.

```yaml
before_build: [./scripts/build-linux.sh, '@ARCH@']
after_package: [pwsh, -File, packaging/sign.ps1, '@PACKAGE@']
```

Hooks run in the configuration directory with `NATIVE_PACKAGES_TARGET` and
`NATIVE_PACKAGES_VERSION`. They are argument lists, so use a script for shell
pipelines. `validate`, `doctor`, and dry runs never execute build hooks.
The output hook must preserve the package's filename and file set.

For DMGs, automatic Apple input signing finishes before the native command.
DMG signing and notarization run after `after_package`, before the final hash.
See [Apple signing and notarization](../_guides/apple-notarization.md).

## Replacement values

Strings can contain `@KEY@` values. Unknown or unavailable values cause an error.

| Value | Meaning |
| --- | --- |
| `@NAME@` | Shared package name. |
| `@VERSION@` | App version without the leading `v`. |
| `@TAG@` | Version with the leading `v`. |
| `@DATE@` | Build timestamp in UTC ISO 8601 format. |
| `@SOURCE_DATE_EPOCH@` | Build timestamp as Unix seconds. |
| `@ROOT@` | Absolute configuration directory. |
| `@UPSTREAM@` | GitHub URL of `release.repository`. |
| `@GIT_VERSION@` | Git revision value such as `r42.abc1234`; `r0.unknown` without Git metadata. |
| `@ARCH@`, `@PLATFORM@` | Target architecture and platform. |
| `@TARGET_ID@` | Target ID. |
| `@TARGET@` | `compiler_target`, or the target ID if omitted. |
| `@PAYLOAD@` | Copied or extracted input directory, available during packaging. |
| `@PACKAGE@`, `@FORMAT@` | Output path and format, available to native commands and `after_package`. |
| `@PKGREL@` | Recipe revision; defaults to `1`. |
| `@KEY_FILE@`, `@KEY_URL@`, `@KEY_SHA256@` | Filename, URL, and hash for asset `KEY`. |

Target values are available within target definitions and package metadata,
not global recipe templates. `before_build` runs before the payload exists;
use it to produce `input.local`.

## Release

```yaml
release:
  repository: your-name/hello
  checksums: checksums.txt
  prereleases: false
```

`repository` is the GitHub `owner/repository` for downloads and package uploads.
`checksums` is a filename, defaulting to `checksums.txt`.
`prereleases: true` opts into the formats and version rules described in
[Prereleases](../_guides/prereleases.md).

### Version and timestamp

`build --version 1.2.3` uses local inputs. `build --release v1.2.3` supplies the
version and uses release inputs. If both options are given, their versions
must agree. Omitting both requires an exact supported release tag at `HEAD`.

Versions are stable `MAJOR.MINOR.PATCH` unless prereleases are enabled. A leading
`v` is accepted. Build timestamps use `SOURCE_DATE_EPOCH`, then the relevant
Git commit's timestamp, then the current time if Git metadata is unavailable.
Set an explicit epoch for repeatable builds outside Git and for builds split
across hosts.

## Assets and templates

```yaml
assets:
  AMD64:
    file: hello_@VERSION@_linux_amd64.tar.gz
    local: dist/hello_@VERSION@_linux_amd64.tar.gz
templates:
  arch/hello-bin/PKGBUILD: packaging/arch/hello-bin/PKGBUILD.in
```

Asset keys use uppercase letters, digits, and underscores, starting with a
letter. Each asset needs `file`; local builds also need `local`. An optional
`url` overrides its release download location. Downloads are checked against
release checksums by default. For a source archive omitted from the published
checksum list, explicitly set `checksummed: false`; its computed SHA-256 still
appears in the rendered recipe.

`templates` maps output paths under `recipes/` to source paths relative to the
configuration. See [Distribution recipes](../_guides/distribution-recipes.md)
for a complete example.

### Deferred recipe generation

`build --defer-recipes` skips global assets and templates. Use
`aggregate --finalize-recipes` once all package builds and remaining local
assets are available. No additional configuration fields are needed. See
[Building across platforms](../_guides/multi-platform.md) for prerequisites,
asset matching, and publication rules.

## Repositories

Each entry under `repositories` names a destination. These settings apply to
`stage`, `diff`, `publish`, and `status`:

| Field | Purpose |
| --- | --- |
| `publish` | Required: `push`, `github-pr`, `gitlab-mr`, or `manual`. |
| `url` | Required. Upstream clone URL. |
| `push_url` | Push URL; defaults to `url`. Set to your fork for submissions. |
| `fork_url` | Fork clone URL for submissions. |
| `group` | Optional name for selecting several destinations together. |
| `branch` | Upstream branch to start from. Required for managed Git destinations. |
| `package_path` | Package directory to check out; `.` for the whole repository. |
| `files` | Generated recipe paths mapped to downstream repository paths. |
| `version_file` | Downstream file containing the package version. |
| `version_files` | Alternative directory whose filenames contain versions, such as ebuilds. |
| `version_pattern` | Regular expression capturing the version from that file or those filenames. |
| `proposal_branch` | Branch pushed for a PR/MR; can contain `@VERSION@`. |
| `title` | Commit/request title template; defaults to the package name and version. |
| `status_branch` | Optional branch to inspect for upstream status. |
| `sign_commit`, `sign_push` | Enable Git commit or push signing. |
| `signoff` | Add a sign-off to the commit. |
| `notes` | Instructions for a manual destination. |

GitHub PR entries also need `repository` (upstream `owner/repo`) and
`fork_owner`. GitLab MR entries need `repository`, `fork_repository`, `host`,
and `token_env` (the environment variable holding the GitLab token).
Submission destinations need a fork, a `proposal_branch`, and a reviewed
`--body-file` when publishing. GitHub requests use authenticated `gh`; direct
Git pushes use your configured Git credentials.

## Libraries

Add a mapping from a shared library's filename to its distribution package:

```yaml
libraries:
  libexample.so.1:
    deb: libexample1
    rpm: libexample
```

Mappings extend the built-in DEB/RPM table. A mapping for an existing library
replaces that library's mapping, so include both formats if needed. Verify
package names against your supported distribution versions.

## Revisions and version checks

To regenerate a recipe with a new package revision for the same app version:

```yaml
revisions:
  '1.2.3':
    arch/hello-bin/PKGBUILD: 2
```

That template receives `@PKGREL@` as `2`; other versions and templates default
to `1`. This setting controls recipe revisions, not the `nfpm.release` field.

For Cargo version checks:

```yaml
version_file: Cargo.toml
version_section: package
```

Run `native-packages check-version v1.2.3` to compare the manifest version with
the tag. Use `version_section: workspace.package` for a workspace version.

## Output and publication

A build writes to a fresh `dist/packages/<version>/` by default. Packages live
under `packages/<target>/<format>/`. `build.json` records configuration identity,
targets, input/output hashes, and validation results.

Publication verifies the files against the manifest. It requires every format
for all configured targets unless exact complete targets are selected with
`publish --target`. See [Publishing a release](../_guides/publishing.md).

### One configuration across native hosts

Build each native target on its host, then combine results with `aggregate`.
Use the same configuration, version, and timestamp. The Linux reusable workflow
can select Linux targets through its `targets` input. See
[Building across platforms](../_guides/multi-platform.md).
