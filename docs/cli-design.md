# Proposal: an installable CLI with one project configuration

The owner approved compatible shared support for RekordFlash's native alpha
packaging on 2026-09-13. Version 0.3's [native recipe and prerelease policy](native-recipes.md)
extends the original stable-only policy explicitly; published 0.2 consumers stay
pinned. DMG/Inno adapters coordinate existing app scripts and retain their
signing/version decisions, without adding a compiler or plugin framework.

Status: accepted, 2026-09-13. Publishing was subsequently aligned with RubyLLM: GitHub release publication triggers the workflow, using `RUBYGEMS_AUTH_TOKEN`. The original Trusted Publishing proposal below is superseded by that decision. The v0.2 implementation follows this design. See the current [configuration reference](configuration.md) and [release setup](releasing.md) for the implemented interface and publication requirements. This document records the original design; it does not describe v0.1.0.

The proposed interface is `gem install native-packages`, `native-packages init`, and `native-packages build`. A project normally needs one `native-packages.yaml` file. The tool should expose every nFPM packager and use the application's declared inputs to decide what to build.

## Why v0.1 stops at DEB/RPM

Version 0.1 extracted working automation from our applications. Its implementation still assumes Linux release archives, amd64/arm64, and DEB/RPM dependency names. These assumptions occur in `Project#binary_packages`, `Project#runtime_dependencies`, and the release-upload filename check in `Support#upload_assets`. It also requires a published GitHub release before packaging and loads configuration from several fixed paths.

Those are implementation limits, not a desirable product boundary. Changing the format loop alone would still reject Windows inputs, attach incorrect dependency metadata, and reject the resulting filenames during publication.

The repository already has a gemspec and an executable. The Git dependency and application Gemfiles were a distribution shortcut before RubyGems publication. They should become optional for consumers; the shared repository keeps its own development Gemfile and lockfile.

## Installation and version selection

After the proposed version is published:

```sh
gem install native-packages
native-packages init
native-packages doctor
native-packages build --version 1.2.3
```

`gem install` supplies the `native-packages` executable through RubyGems. Application repositories need no Ruby wrapper script, Gemfile, lockfile, or vendored library. Existing Ruby projects can continue to use Bundler if they prefer its dependency resolution. [RubyGems publishing](https://guides.rubygems.org/publishing/)

Use exact tool versions in the project configuration. CI reads those versions and installs them; the local CLI checks the running version and prints the matching install/invocation command when it differs. RubyGems can select an installed executable version with syntax such as `native-packages _0.2.0_ build`. Do not silently change the global installation or fall back to the latest gem. No new application lockfile is needed while the gem has no runtime gem dependencies. If dependencies are introduced, revisit the reproducibility contract rather than pretending a gem version locks its entire dependency tree.

nFPM remains an external executable. RubyGems does not install that Go program as a Ruby dependency. Local users install it once using an existing supported installation method; `doctor` checks it. The shared CI installs the pinned nFPM version and only the additional tools needed by the selected targets. Avoid writing a second package manager or bundling copies of nFPM for every host into the gem.

Publish the gem from this repository's release workflow using RubyGems Trusted Publishing. Configure ownership of the gem name and a pending trusted publisher for the first release, then publish tested tags. This is separate from publishing application packages. [RubyGems Trusted Publishing](https://guides.rubygems.org/trusted-publishing/)

## Commands

| Command | Proposed behavior |
| --- | --- |
| `init` | Detect basic project metadata and write one default configuration. Print fields that still need editing. |
| `init --interactive` | Ask for missing package identity, input locations and desired outputs, then write the same configuration. |
| `doctor` | Check configuration, required executables and version compatibility. Report actionable missing requirements. |
| `validate` | Check configuration and template structure without downloading artifacts, running application build commands or publishing. |
| `build` | Use local inputs, render configured recipes and build every configured package target. |
| `build --release v1.2.3` | Obtain the declared assets from an existing release, verify their checksums, then run the same build path. |
| `build --target linux-amd64` | Build a named target; repeat the option to select several. |
| `build --format apk` | Build that format across configured targets that explicitly include it. Fail if none match. |
| `build --dry-run` | Show selected inputs, commands and outputs without running commands or downloading inputs. |
| `publish --from dist/packages/1.2.3 --to github,aur` | Publish a previously built result to named configured destinations. |
| `status` | Report downstream versions and pending submissions. |

Keep the existing `stage`, `diff` and submission commands for maintainers who need to review native recipes before publication. Retain existing command forms during migration.

`init` generates a template by default, so it also works without a terminal. Interactive prompts are optional and never run in CI. Infer metadata from Git and supported manifests only where unambiguous; never invent dependency names, credentials, publisher identities or unsupported platforms. Do not overwrite existing configuration. Offer migration when the old layout is detected.

`build` means building distribution packages. It normally consumes files made by the application's existing build. An optional `before_build` command, expressed as an argument array, can call an existing script once per selected target. This lets `build` perform the complete local sequence without adding Rust, Go, CMake or cross-compilation implementations to this project. Release-download mode skips that source-build command. Other commands do not execute it.

An omitted version is resolved only from an exact supported release tag at HEAD; otherwise request `--version`. `--release` supplies the version itself and conflicts with a different explicit version. Start with the current stable `vMAJOR.MINOR.PATCH` convention; prerelease publication and format-specific version conversions need a separate explicit policy.

## One YAML file

Use `native-packages.yaml` to match the gem and command name. Accept `.yml` as an alias and an explicit `--config PATH`; error if discovery finds both. Resolve relative paths from the configuration directory. Advanced projects can keep native templates and assets under `packaging/`.

An illustrative configuration for an application with a static Linux binary:

```yaml
schema: 1
tool:
  version: "0.2.0" # Proposed release, not currently published.
  nfpm: "2.47.0"

nfpm:
  name: example-app
  description: An example desktop utility
  maintainer: Example Maintainer <maintainer@example.org>
  homepage: https://github.com/example/example-app
  license: MIT
  contents:
    - src: "@PAYLOAD@/example-app"
      dst: /usr/bin/example-app
      file_info:
        mode: 0755

targets:
  linux-amd64:
    platform: linux
    arch: amd64
    libc: static
    formats: [deb, rpm, archlinux]
    input:
      local: dist/example-app-linux-amd64.tar.gz
      release_asset: example-app_@VERSION@_linux_amd64.tar.gz

release:
  repository: example/example-app
  checksums: checksums.txt
```

Only one target is shown. Static does not imply a complete desktop application has no runtime dependencies; add its actual dependencies, assets and scripts. A second target can use the same package definition with different inputs or per-target nFPM fields.

`nfpm` uses nFPM's existing keys for package metadata, contents, scripts, dependencies, overrides and signing. Avoid renaming them into our own packaging language. Target-specific `nfpm` mappings override shared mappings: maps merge recursively, lists replace in full, and scalar values replace. Resolve release version, architecture and platform once; reject conflicting declarations rather than silently overriding them. nFPM remains responsible for its format-specific semantics.

The outer schema owns only tool versions, input acquisition, targets, optional build commands, templates and destinations. Use a small documented token set, extending the existing `@VERSION@`, `@PAYLOAD@` and `@ARCH@` syntax. Do not add general expression evaluation. Missing tokens fail with their configuration location.

An input can be a local file, directory or archive. Release acquisition is optional and declares asset filenames plus a checksum source. Additional assets used only by recipes, such as source archives and macOS DMGs, can be declared without a binary-package target. Optional `templates` and `repositories` sections incorporate the existing template and downstream mappings; omitted sections mean there are none. A simple project needs no empty repository registry or separate nFPM file. A documented file-reference form can preserve larger configurations without making it the default.

Recommend YAML for this version. A Ruby DSL would introduce another API to maintain and require executing configuration just to inspect it. Existing build scripts and native Homebrew Ruby recipes already cover the immediate need for code. Add a Ruby configuration frontend only if concrete applications cannot be represented cleanly by this model.

## Wire all nFPM formats

Expose all packagers supported by the pinned nFPM version. Use explicit target declarations, not a global attempt to package one archive into every format. `build` builds all configured outputs; missing or incompatible inputs fail instead of being silently skipped.

The installed nFPM 2.47.0 CLI enumerates **seven** packagers, including `srpm`, which the original README's list omitted. It exposes format selection through the same `package --packager` command. [nFPM command implementation](https://github.com/goreleaser/nfpm/blob/v2.47.0/internal/cmd/package.go)

| Packager | Target declaration and validation needed |
| --- | --- |
| `deb` | Appropriate Linux payload, dependencies and installation paths. Preserve current coverage. |
| `rpm` | Same, using the intended RPM distribution's dependency names and baseline. |
| `archlinux` | Arch-compatible payload and metadata. This creates a downloadable package; AUR publication continues to use PKGBUILD and `.SRCINFO`. |
| `apk` | Payload and dependencies for the chosen Alpine target. Select musl/static inputs where appropriate; never reinterpret a glibc payload as musl merely by changing the suffix. |
| `ipk` | Payload for an explicitly named device/distribution ABI and architecture. Do not assume that a desktop archive is suitable. |
| `msix` | Windows payload and package layout, publisher identity, application entries and image assets. Run PE inspection instead of Linux ELF inspection. Signing uses the format's native configuration. |
| `srpm` | Source/spec payload with a separate source target. Do not package an executable under a source-package label. Validate rebuildability through RPM tooling. |

nFPM provides format-specific metadata and override fields; the shared layer should pass them through. MSIX needs Windows-specific identity and application settings. [nFPM configuration](https://nfpm.goreleaser.com/docs/configuration/)

nFPM's SRPM implementation sets source-package metadata and writes the supplied contents. Our assessment is that a useful source package still requires a spec and suitable sources, with native rebuild testing. Generating that recipe remains application-owned. [nFPM RPM/SRPM implementation](https://github.com/goreleaser/nfpm/blob/v2.47.0/rpm/rpm.go)

Use a small table of known formats and validation capabilities, tied to the supported nFPM version. Adding a packager should not require another full packaging implementation. New upstream formats should produce a clear unsupported-version diagnostic until their dispatch and checks are added; do not scrape human-readable help at runtime as a compatibility API.

Remove hardcoded Rust target triples. Carry OS, architecture, libc/ABI and any compiler target string explicitly. Use nFPM's native architecture mapping, including format overrides. Binary inspectors must handle their supported architecture and endianness correctly and report validation coverage separately from the backend's ability to create a package. Data/source packages do not need an executable. An unimplemented inspection path cannot silently count as successful validation.

Keep dependency handling modest. Preserve the existing verified DEB/RPM mappings, make inference format-aware, and allow explicit declarations for other targets. Do not invent a universal distro dependency database. Inspect the selected package contents, including bundled libraries, and document that runtime-loaded dependencies still need declarations.

## Build results and publishing

Let nFPM choose conventional package filenames by giving it a fresh output directory. Do not manufacture extensions such as `.archlinux` or `.srpm`. Separate target output directories prevent collisions when variants produce the same native filename.

Write `dist/packages/<version>/` containing packages, rendered recipes, checksums and a machine-readable build manifest. Record the app/version, selected targets, tool versions, input hashes, configuration digest, output paths/hashes and completed validation. Generate repeatable timestamps from the release or an explicit build epoch. Reject an existing output unless the user explicitly chooses replacement.

Publication reads this manifest instead of using the current DEB/RPM filename regex. Check identity, hashes, unique upload names and package ownership before uploading. Preserve upstream binary checksums. An incomplete target set cannot be published as a complete release. Partial CI jobs retain target manifests and the publish job verifies the combined set against the requested configuration.

Package generation and publication remain separate commands. AUR, Homebrew and distro submissions use the existing downstream manager. No application Git remotes or submodules are needed. Existing GoReleaser publishers can continue to own their configured destinations.

## CI and platforms outside nFPM

The reusable workflow installs the configured gem version and packaging tools, then runs the same CLI as a maintainer. Application repositories keep a short workflow call; no Bundler bootstrap is required. Native build jobs supply local artifacts, or the packaging workflow consumes an existing release. PRs validate configuration; gem CI builds and inspects format fixtures.

Support explicit target selection for separate Linux and Windows jobs, followed by one aggregation/publish job. Packaging host capabilities and the operating system of the packaged application are separate concerns. Do not promise every target can be built or tested on every host.

For Homebrew, reuse existing formula/cask rendering and tap publication. macOS bundle creation, signing and notarization continue to call application-owned scripts. For Windows installers beyond MSIX and for Flatpak, invoke existing tools with their native definitions when those integrations are added. A shared command can coordinate them, but an nFPM format switch cannot replace those tools or port an application.

Keep this implementation to a CLI, a configuration loader, input/build coordination, nFPM invocation and the existing downstream manager. Add shared helpers only where actual consumers repeat work; avoid a plugin framework or a new build language.

## Implementation and acceptance

1. Add the new configuration loader, `init`, `doctor` and `build`; support local inputs and optional release acquisition. Keep legacy commands/configuration readable.
2. Generalize targets, output manifests, upload validation and nFPM dispatch for all seven formats. Add native configuration examples and fixtures for each.
3. Test the built gem in an isolated install directory, outside this checkout, without Bundler or a project Gemfile. Verify `init` works in an empty directory and local `build` works without a published release or GitHub credentials.
4. Exercise package contents and metadata for every format. Test install/remove/upgrade with native package managers in disposable environments, and rebuild an SRPM. Use Windows acceptance tests for MSIX. Track format generation and native installation coverage separately; neither a renamed archive nor an untested binary counts as platform support.
5. Publish the new gem and matching reusable workflow. Provide `native-packages migrate --dry-run`, then an explicit migration that preserves native recipes and platform exceptions. Remove application wrappers and packaging-only Gemfiles after equivalent outputs are verified. Keep existing Git pins working during transition.

The proposed decisions are: one YAML file by default, an installable gem, optional Bundler, package-oriented `init`/`build`/`publish`, all nFPM formats exposed with declared targets, and existing native tools for the remaining platforms. The exact field names and release number can change during review; none of these commands are a promise about v0.1.0.
