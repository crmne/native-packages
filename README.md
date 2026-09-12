# native-packages

Package existing Linux release binaries with [nFPM](https://nfpm.goreleaser.com/), generate native distribution recipes, and prepare updates in downstream repositories.

Applications keep their own configuration and templates. This repository holds the common Ruby code, tests and reusable GitHub Actions workflow. There are no runtime gem dependencies and no copied engine files in application repositories.

## Boundaries

| Layer | Responsibility |
| --- | --- |
| Application build jobs | Compile for each OS and architecture; create compatible binaries, macOS bundles and Windows installers; sign and notarize where required. |
| nFPM | Turn a set of built files and package metadata into native package files. |
| native-packages | Verify release checksums, render recipes, check Linux ELF dependencies, invoke nFPM, attach packaging assets, and stage or publish downstream updates. |
| Distribution infrastructure | Build and review submitted recipes, host package indexes, and make packages available to users. |

**Version 0.1 creates DEB and RPM files for Linux amd64 and arm64.** nFPM itself also supports Arch Linux, Alpine APK, IPK and MSIX, but those output paths are not wired into this release of the shared CLI. An APK needs suitable binaries, usually built against musl; converting a glibc binary into another package format does not make it compatible. [nFPM configuration](https://nfpm.goreleaser.com/docs/configuration/)

Native AUR, Homebrew, Nix, Gentoo, Alpine, Void and other recipes can be supplied as templates. AUR uses `PKGBUILD` and `.SRCINFO`; Homebrew uses formulae or casks. These are distinct from downloadable binary package files. [AUR](https://wiki.archlinux.org/title/Arch_User_Repository), [Homebrew](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap)

Flatpak needs its own runtime, SDK, modules and sandbox permissions. macOS needs application-specific bundle contents and signing settings. Windows needs an appropriate installer and publishing manifest. Keep those native definitions with the app and use their existing tools. This project does not port applications, replace those tools, or claim every application supports every platform. See [platform coverage](docs/platforms.md).

## Add an application

Use the files in [examples](examples/packaging/project.yml) as a starting point:

```text
packaging/
  Gemfile                 # shared tool dependency
  Gemfile.lock            # exact dependency revision
  project.yml             # release assets and template mappings
  nfpm.yml                # nFPM file mappings and target dependencies
  repositories.yml        # registry of downstream destinations
  arch/.../PKGBUILD.in     # only the native recipes this app needs
```

Add `packaging/Gemfile`:

```ruby
source "https://rubygems.org"
gem "native-packages", git: "https://github.com/crmne/native-packages.git", tag: "v0.1.0"
```

From the application root:

```sh
export BUNDLE_GEMFILE="$PWD/packaging/Gemfile"
bundle install
bundle exec native-packages validate
bundle exec native-packages prepare 1.2.3
bundle exec native-packages artifacts dist/packaging/1.2.3
```

Commit the Gemfile and lockfile. Bundler records the exact Git revision. No RubyGems publication is required. Run `bundle update native-packages` after changing the selected tool version.

Requirements: Ruby 3.2 or later (CI tests 3.4 and 4.0), Bundler, Git, curl, GNU tar, xz, bsdtar, readelf, and nFPM 2.47.0. AUR metadata generation additionally needs `makepkg` or accessible Docker. Publishing needs the destination credentials and GitHub CLI where applicable. Packaging currently runs on Linux; native macOS and Windows builds stay in their own jobs.

## Configuration

`project.yml` declares the name, source repository, optional separate `release_repository`, release assets, templates and Linux binary packaging configuration. Stable tags use `vMAJOR.MINOR.PATCH`. `checksums.txt` must contain SHA256 entries for every binary asset. Source archives not present in that list can explicitly use `checksummed: false`; their computed hashes still enter generated recipes.

Template values use `@VERSION@`, `@TAG@`, `@NAME@`, `@UPSTREAM@`, `@DATE@`, `@SOURCE_DATE_EPOCH@`, `@GIT_VERSION@`, and per-asset `@KEY_FILE@`, `@KEY_URL@`, `@KEY_SHA256@`. nFPM templates additionally receive `@ROOT@`, `@PAYLOAD@`, `@ARCH@` and `@TARGET@`. Values in `nfpm.yml` otherwise use nFPM's own schema. `binary.nfpm` may reference this file or contain the configuration directly.

Include `repositories.yml` even when no downstream publication is needed; use `version: 1` and `repositories: {}` for an empty registry.

Files, icons, desktop entries, services, runtime dependencies and platform exceptions remain explicit. ELF inspection checks architecture and raises a glibc dependency floor when needed. It cannot discover every library loaded dynamically or prove compatibility with every distro. Additional shared-library mappings can be supplied under `binary.libraries`; verify dependency names against the target distributions.

Optional `version_file` and `version_section` fields check the package or workspace version in a Cargo manifest with `check-version TAG`.

## GitHub Actions

After the application's stable release job has uploaded binaries and `checksums.txt`, call:

```yaml
packaging:
  needs: release
  if: startsWith(github.ref, 'refs/tags/v') && !contains(github.ref_name, '-')
  permissions:
    contents: write
  uses: crmne/native-packages/.github/workflows/package.yml@v0.1.0
  with:
    version: ${{ github.ref_name }}
    publish: true
  secrets: inherit
```

Use the same tool release as the Gemfile. Pin the workflow to the corresponding commit SHA for an immutable reference. A separate PR job can call the workflow with `publish: false` and no version; it validates local recipes without requiring an existing release. The shared library's tests run in this repository's CI.

With a version supplied, the workflow verifies inputs, builds DEB/RPM files and a recipe archive, and uploads GitHub Actions artifacts. With `publish: true`, it also attaches those package assets and `packaging-checksums.txt` to the existing release. It preserves the original release `checksums.txt`.

Optional downstream publication:

- AUR: set `PUBLISH_AUR=true`, `AUR_SSH_KEY` and `AUR_KNOWN_HOSTS`; configure an `aur` group in the registry.
- Homebrew: set `PUBLISH_HOMEBREW=true` and `HOMEBREW_TAP_GITHUB_TOKEN`; configure the `homebrew` destination.

Publication is disabled unless requested. Test builds and recipes before enabling a destination. Credentials remain in the application repository's secrets. Workflow failure can be retried without intentionally creating duplicate submissions.

If an application already uses GoReleaser's [AUR](https://goreleaser.com/customization/publish/aur/) or [Homebrew](https://goreleaser.com/customization/publish/homebrew_casks/) publisher, continue using it for that destination. Do not configure both publishers for the same package. Use the repository helper for destinations and native recipes those integrations do not cover.

## Downstream repositories

```sh
bundle exec native-packages repositories
bundle exec native-packages stage aur dist/packaging/1.2.3
bundle exec native-packages diff aur
bundle exec native-packages publish aur
bundle exec native-packages status --json
```

Each destination has its own ignored clone under `.cache/packaging/repos`. The source repository needs neither submodules nor additional Git remotes. Mapping exact package paths preserves downstream history and unrelated files.

The registry supports direct Git pushes, GitHub pull requests, GitLab merge requests and manual destinations. Fork-based submissions require the appropriate fork and a reviewed description passed as `publish TARGET --body-file FILE`. Staging can reuse an existing open request. Dirty changes outside the prepared files, unexpected remote advances and downgrades are rejected. Gentoo updates preserve older ebuilds and Manifest entries. See the [registry example](examples/packaging/repositories.yml).

Upstream review and acceptance are separate from successful submission. This tool does not host APT/DNF repositories or configure signing keys for you.

## Development

```sh
bundle install
bundle exec ruby -Ilib -e 'Dir["test/*_test.rb"].sort.each { |path| require_relative path }'
gem build native-packages.gemspec
```

Tests use temporary directories and local Git repositories. With nFPM, a C compiler, readelf and bsdtar available, the integration test creates real DEB/RPM packages and verifies their payloads. It does not install them on the host or publish anything externally.
