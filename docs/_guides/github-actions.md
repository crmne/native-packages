---
title: GitHub Actions
description: Add package building and optional publication to your application's GitHub Actions workflow.
nav_order: 4
---

# GitHub Actions

The reusable workflow installs the tools, builds your packages, and saves the
result as an Actions artifact. It can also upload packages to an existing
GitHub release.

Before adding it, commit `native-packages.yaml` and check that you can
[build locally](getting-started.md).

## Package an existing release

Add this job under `jobs` in your application's release workflow. In this
example, the existing `release` job uploads the application's binary archives
and `checksums.txt` to a release matching the Git tag.

```yaml
packaging:
  needs: release
  permissions:
    contents: write
  uses: crmne/native-packages/.github/workflows/package.yml@v0.7.0
  with:
    version: ${{ github.ref_name }}
    publish: true
  secrets: inherit
```

Set `needs` to your actual release job's name. Use this example in a tag-based
release workflow, where `github.ref_name` is a version such as `v1.2.3`.
For other triggers, pass the release version explicitly.

The configuration must include `release.repository` and a `release_asset`
for each selected target. See [Publishing a release](publishing.md).

Use the same native-packages release for the workflow and `tool.version`.
For an immutable workflow reference, replace `v0.7.0` with that release's
full commit SHA.

## Build without publishing

Set `publish: false` to build and upload the `native-packages` Actions
artifact without attaching anything to the GitHub release. This is useful
while you test the workflow.

With no `version`, the reusable workflow only validates the configuration:

```yaml
name: Check packaging
on: [pull_request]
permissions:
  contents: read
jobs:
  packaging:
    uses: crmne/native-packages/.github/workflows/package.yml@v0.7.0
```

Validation does not compile the app or check that future release inputs exist.

## Use files from an Actions artifact

If a preceding job uploads your compiled app as an Actions artifact, use
`source-artifact` instead of downloading inputs from a GitHub release:

```yaml
packaging:
  needs: build
  permissions:
    contents: write
  uses: crmne/native-packages/.github/workflows/package.yml@v0.7.0
  with:
    version: '1.2.3'
    source-artifact: linux-binaries
    source-directory: dist
    publish: false
```

Here, the existing `build` job must upload an artifact named `linux-binaries`.
The workflow extracts it under `dist`. Its filenames and directory structure
must match your targets' `input.local` paths. This uses local build mode,
which runs any configured `before_build` hook.

## Select Linux targets in a shared configuration

The reusable workflow runs on Linux. If your configuration also has DMG or
Inno targets, select the Linux targets explicitly:

```yaml
with:
  version: ${{ github.ref_name }}
  targets: linux-amd64,linux-arm64
  publish: true
```

The workflow passes the same target selection to build and publication.
It requires every format declared for those targets. An empty selection
means all configured targets.

Build DMG and Inno targets in your own macOS and Windows jobs with the CLI.
See [Building across platforms](multi-platform.md) for combining their outputs
and generating recipes after all packages are available.

## Workflow inputs

| Input | Default | Purpose |
| --- | --- | --- |
| `version` | Empty | App version or tag. Empty means validate only. |
| `publish` | `false` | Upload packages to the existing release; enable configured downstream publishing. |
| `targets` | Empty | Comma-separated target IDs. Empty selects all targets. |
| `config` | Auto-discovered | Path to the configuration file. |
| `source-artifact` | Empty | Artifact containing local inputs. Empty uses GitHub release assets. |
| `source-directory` | `dist` | Where to download that artifact, relative to the checkout. |

## Enable AUR or Homebrew publication

First set up and test the [downstream destination](distribution-recipes.md).
Then configure these repository variables and secrets in your application's
GitHub repository:

| Destination | Repository variable | Secrets |
| --- | --- | --- |
| AUR group `aur` | `PUBLISH_AUR=true` | `AUR_SSH_KEY`, `AUR_KNOWN_HOSTS` |
| Destination or group `homebrew` | `PUBLISH_HOMEBREW=true` | `HOMEBREW_TAP_SSH_KEY` or `HOMEBREW_TAP_GITHUB_TOKEN` |

These steps run only with `publish: true`. For Homebrew, prefer a deploy key
with write access to the tap alone (`gh repo deploy-key add KEY.pub --repo
OWNER/homebrew-tap --allow-write`) stored as `HOMEBREW_TAP_SSH_KEY`: pushes to
GitHub then go over SSH, checked against GitHub's published host keys. A token
in `HOMEBREW_TAP_GITHUB_TOKEN` also works and needs write access to the tap.
The AUR key needs access to the configured repositories.
Use `secrets: inherit` as in the release example, or pass the named secrets
explicitly. If another tool already publishes a destination, keep one
publisher responsible for it.

## Multiple jobs and configurations

The reusable workflow gives different configuration paths and target
selections separate concurrency groups. If you are still using the old
`v0.5.0` workflow, serialize calls with `needs` or upgrade to avoid calls
interfering with one another.

When downloading build outputs from native jobs, preserve the entire build
directory, including hidden files in generated recipes. See
[Building across platforms](multi-platform.md) for the shared timestamp and
checkout requirements.
