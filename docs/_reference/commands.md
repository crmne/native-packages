---
title: Command reference
description: Look up native-packages commands, options, and examples for building, publishing, and managing recipes.
nav_order: 2
---

# Command reference

Run commands from your application's directory. To select another configuration:

```sh
native-packages --config packaging/native-packages.yaml COMMAND
```

Use `native-packages --help` for a summary and `native-packages --version` for
the installed tool version. The examples below use app version `1.2.3`.

## init

Create `native-packages.yaml`:

```sh
native-packages init
native-packages init --interactive
native-packages init --name hello --input dist/hello.tar.gz --formats deb,rpm
```

The default is a Linux amd64 template. Setup uses available Cargo and Git
metadata. Review the inputs, library type, dependencies, and metadata before
building. Existing configuration is never overwritten. Interactive setup
requires a terminal and is unavailable in CI.

## validate

```sh
native-packages validate
```

Validate the configuration and render templates with placeholder values to
catch unknown tokens. This does not require actual build inputs or run hooks.

## doctor

```sh
native-packages doctor
native-packages doctor --target linux-amd64 --format deb
native-packages doctor --target macos-arm64 --defer-recipes
native-packages doctor --release v1.2.3
```

Check configuration and required tools for selected targets. Repeat `--target`
and `--format` for several selections. `--defer-recipes` omits recipe tools;
`--release` also checks for the download tool. Actual input and package checks
happen during `build`.

## build

```sh
native-packages build --version 1.2.3
native-packages build --release v1.2.3
```

| Option | Effect |
| --- | --- |
| `--version VERSION` | Set app version and use local inputs, unless `--release` is also present. |
| `--release TAG` | Download checked release inputs and use the tag's version. |
| `--target ID` | Select a target; repeat for several. |
| `--format FORMAT` | Select an output format; repeat for several. |
| `--output DIRECTORY` | Choose a new output directory. Default: `dist/packages/<version>`. |
| `--dry-run` | Print the plan without downloading, building, or executing hooks. |
| `--defer-recipes` | Build packages without acquiring global recipe assets or rendering templates. |

With neither version option, an exact supported release tag must exist at
`HEAD`. Supplying both requires matching versions. See
[Building packages](../_guides/building-packages.md).

## aggregate

Combine build directories into a new output:

```sh
native-packages aggregate dist/linux dist/macos dist/windows --output dist/complete
```

`--output` is required. All inputs must have matching configuration, version,
and timestamp. The result must include every configured target and format.

For inputs made with `build --defer-recipes`, add `--finalize-recipes` to
render recipes using completed package hashes and remaining local assets.
See [Building across platforms](../_guides/multi-platform.md).

## publish a build

```sh
native-packages publish --from dist/packages/1.2.3 --to github
native-packages publish --from dist/linux --to github --target linux-amd64
```

`--from` selects the build directory; `--to` lists destinations separated by
commas. `github` uploads release assets. Other names select entries or groups
in `repositories`.

The build must be complete and its recorded files unmodified. Repeated
`--target` options require exactly those targets, with all their formats.
Without target selection, all configured targets are required. There is no
publication `--format` or `--dry-run` option.

See [Publishing a release](../_guides/publishing.md) for release setup and
upload behavior.

## Manage downstream recipes

| Command | Effect |
| --- | --- |
| `repositories` | List configured downstream destinations. |
| `stage TARGET DIRECTORY` | Stage generated recipes in the destination's local checkout. |
| `diff TARGET` | Show the staged changes. |
| `publish TARGET` | Commit and publish the staged update. |
| `status [TARGET]` | Query downstream versions and open requests; defaults to all. |

Here, `TARGET` means a repository destination or group, such as `aur`. It is
different from a build target such as `linux-amd64`.

For example:

```sh
native-packages stage aur dist/packages/1.2.3/recipes
native-packages diff aur
native-packages publish aur
native-packages status aur --offline --json
```

`status --offline` reads cached information; `--json` prints structured output.
Status exits unsuccessfully when a remote or request check fails.

For GitHub PR or GitLab MR destinations, `publish` requires `--body-file FILE`
with the reviewed submission description. It can also be used with
`publish --from ... --to DESTINATION`. Publish submission destinations
individually. See [Distribution recipes](../_guides/distribution-recipes.md).

## notarize-macos

```sh
native-packages notarize-macos portable-input --output signed/hello
```

Copy a prepared macOS directory and, when Apple credentials are configured,
sign and notarize the copy. `--output` is required, must be new, and must be
outside the input. This command needs no project configuration. See
[Apple signing and notarization](../_guides/apple-notarization.md).

## migrate

```sh
native-packages migrate --dry-run
native-packages migrate
```

Preview or create a single configuration from the legacy `packaging/project.yml`
setup. Existing packaging files are preserved. See [Migrating from v0.1](migration.md).

## check-version

```sh
native-packages check-version v1.2.3
```

Validate a stable tag and, when `version_file` is configured, compare it with
the application's Cargo manifest version. Set `version_section` for workspace
manifests.

## Select an installed tool version

If several gem versions are installed, RubyGems lets you select the one required
by the configuration:

```sh
native-packages _0.6.0_ build --version 1.2.3
```

Bundler also works if you prefer to manage the gem in a Gemfile.

## Legacy commands

`prepare`, `check`, `artifacts`, `publish-release`, and `publish-aur` remain
available for older projects. Their original workflow is documented in the
[legacy guide](https://github.com/crmne/native-packages/blob/main/docs/legacy.md).
Use `build` and `publish --from` for new configurations.
