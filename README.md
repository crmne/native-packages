# native-packages

Build native distribution packages with [nFPM](https://nfpm.goreleaser.com/), generate distribution recipes and publish updates from one project configuration.

Applications keep their build scripts, installation assets and native recipes. This gem shares the packaging and downstream repository automation, with no runtime gem dependencies.

## Install and build

```sh
gem install native-packages
```

Install nFPM 2.47.0 separately for local use; the reusable CI workflow installs it for you. Ruby 3.2 or later is required.

From an application directory:

```sh
native-packages init
# Edit native-packages.yaml: metadata, inputs, dependencies and targets.
native-packages doctor
native-packages build --version 1.2.3
```

`init --interactive` offers guided setup. The default generates a Linux amd64 template, using available Cargo/Git metadata. It does not overwrite existing configuration. Applications need no Gemfile, lockfile or Ruby wrapper. Bundler remains available if preferred.

## Configuration

The [example](examples/native-packages.yaml) is a complete configuration for a static Linux application. A typical project contains:

```text
native-packages.yaml
packaging/                 # native recipes, services, icons, etc. when needed
```

Use nFPM's existing metadata, contents, dependencies, scripts and format overrides under `nfpm`. Define inputs and output formats per target:

```yaml
targets:
  linux-amd64:
    platform: linux
    arch: amd64
    libc: static
    formats: [deb, rpm, archlinux]
    input:
      local: dist/my-app-linux-amd64.tar.gz
      release_asset: my-app_@VERSION@_linux_amd64.tar.gz
```

`build` creates all configured outputs. `--target ID` and `--format FORMAT` select a subset; repeat either option for several values. A missing target input fails the build.

Inputs support `kind: archive` (default), `directory` or `file`. Paths resolve from the configuration directory. Targets can add `nfpm` overrides; maps merge recursively and arrays replace. `nfpm` can also reference a separate YAML file. `.yml` and `--config FILE` are supported.

Linux binary targets declare `libc: glibc`, `musl` or `static`. The tool inspects ELF architecture, libc and required libraries without executing the binaries. Known DEB/RPM dependencies are inferred; additional mappings belong under `libraries`. Other formats require explicit dependencies when external libraries are linked. Runtime-loaded libraries and supported distribution baselines still need maintainer declarations and testing.

`kind: data` allows packages with no executable; `kind: source` is reserved for SRPM sources/specs. Windows targets use PE architecture inspection. Input archive symlinks are currently rejected; represent installed symlinks with nFPM's `type: symlink` contents.

See [configuration and commands](docs/configuration.md) for tokens, release assets, hooks, version selection and publishing, and [platform coverage](docs/platforms.md) for each format's requirements.

Version 0.3 adds [native DMG and Inno recipes](docs/native-recipes.md). These run
the application's existing packaging commands on macOS or Windows, using the
same verified build manifests as Linux packages. Native recipes consume prepared
directories and need no nFPM installation. The gem checks Mach-O/PE architecture,
preserves safe internal bundle links and hashes the output after signing hooks.
With complete Apple credentials, macOS DMG builds automatically sign their owned
app copy, notarize the image, staple and validate its ticket before recording
checksums. `notarize-macos INPUT --output OUTPUT` prepares signed, notarized
portable code for an application-owned archive. See [Apple notarization](docs/apple-notarization.md).
App compilation, installer policy and signing identities stay in the application
repository.

Preview package versions are explicit: set `release.prereleases: true` to build
`1.2.3-alpha.N`, `-beta.N` or `-rc.N` for DEB/RPM/DMG/Inno. Other formats and
downstream recipe publication remain stable-only. Uploads require an existing
GitHub release already marked as a prerelease.

The [all-formats example](examples/native-packages-all-formats.yaml) shows separate Linux, OpenWrt, Windows and source inputs, including MSIX identity/assets and an SRPM source/spec layout.

## Release inputs and publication

Build from local files before publishing an application release, or consume an existing release:

```sh
native-packages build --release v1.2.3
native-packages publish --from dist/packages/1.2.3 --to github
```

Release mode verifies the declared binary assets against the release checksum file. Source assets outside that list may explicitly use `checksummed: false`. Local builds do not need a GitHub release or credentials. An optional target `before_build` argument array invokes the application's existing build script once; release mode skips it.

Outputs include packages, prepared recipes, checksums and `build.json`. Publication verifies their hashes, configuration identity and complete target set. Partial builds can be combined with `aggregate DIR... --output DIRECTORY`. Native filenames come from nFPM.

Since 0.4.0, `build --defer-recipes` lets each platform package its
own inputs without acquiring global recipe assets or requiring AUR tools.
Then `aggregate --finalize-recipes` generates the downstream recipes once,
using hashes of the completed packages. This allows a Homebrew cask to reference
the DMG being built in the same release. Deferred builds cannot be published.
See [deferred recipe generation](docs/configuration.md#deferred-recipe-generation)
for the finalizer's inputs and checks.

Optional `repositories` and `templates` sections replace the old separate registries. Existing `stage`, `diff`, `publish TARGET` and `status` commands support reviewed downstream updates. AUR uses PKGBUILD/`.SRCINFO`; Homebrew uses formulae/casks. Each destination has an independent ignored Git clone, with no application submodules or extra remotes. Native source repositories still apply their own validation and review.

## GitHub Actions

After publishing application binaries and checksums, call the reusable workflow from the same released tool version:

```yaml
packaging:
  needs: release
  permissions:
    contents: write
  uses: crmne/native-packages/.github/workflows/package.yml@v0.5.0
  with:
    version: ${{ github.ref_name }}
    publish: true
  secrets: inherit
```

Pin the corresponding commit SHA for an immutable workflow reference. With no version, the workflow validates configuration only. With a version, it installs the configured gem and nFPM, builds packages and uploads an Actions artifact. `publish: true` attaches packages to the existing release.

To consume an Actions artifact instead, set `source-artifact` and, if necessary, `source-directory` (default `dist`). Its files must match the local input paths in the configuration. This workflow packages on Linux, including MSIX creation from Windows binaries; native application builds and platform-specific signing jobs can use the CLI separately.

AUR publication additionally requires `PUBLISH_AUR=true`, `AUR_SSH_KEY` and `AUR_KNOWN_HOSTS`. Homebrew publication requires `PUBLISH_HOMEBREW=true` and `HOMEBREW_TAP_GITHUB_TOKEN`. Keep existing GoReleaser publishers for destinations they already own.

## Migration and development

```sh
native-packages migrate --dry-run
native-packages migrate
```

Migration combines `packaging/project.yml`, its nFPM definition and repository registry while preserving templates and existing files. Compare generated outputs before removing packaging-only Gemfiles or wrappers. App-specific Ruby generators, such as Hyprmoncfg's Nix/source-package logic, require a manual adapter; the generic migrator does not rewrite them. Existing v0.1 configurations and commands remain available. See the [legacy guide](docs/legacy.md).

```sh
bundle install
bundle exec ruby -Ilib -e 'Dir["test/*_test.rb"].sort.each { |path| require_relative path }'
gem build native-packages.gemspec
ruby test/gem_install.rb native-packages-0.5.0.gem
```

Tests build real packages, inspect their payloads and exercise repository publication against local Git fixtures. CI additionally runs disposable Linux install/upgrade/remove checks, SRPM rebuilds and Windows MSIX acceptance. Runtime build manifests report installation as `not-tested`: CI fixture coverage is not a substitute for testing each application's packages.

The [design document](docs/cli-design.md) records the agreed direction. [Gem release setup](docs/releasing.md) explains the RubyLLM-style token setup and GitHub release workflow.
