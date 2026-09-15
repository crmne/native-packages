---
title: Building packages
description: Choose package contents, input files, dependencies, hooks, and build targets.
nav_order: 2
---

# Building packages

This guide builds on [Getting started](getting-started.md). You will learn how
to include the rest of your app's files and build for more than one target.

## Choose an input

An input is the file or directory containing your compiled app. Paths are
relative to `native-packages.yaml`, even when you select it with `--config`.

| `input.kind` | Use it for | Example `input.local` |
| --- | --- | --- |
| `file` | A single executable | `dist/hello` |
| `directory` | An executable plus supporting files | `dist/linux-amd64` |
| `archive` (default) | A ZIP or tar archive | `dist/hello-linux-amd64.tar.gz` |

For a directory containing `hello`, `LICENSE`, and `hello.desktop`, change the
target's input to:

```yaml
input:
  kind: directory
  local: dist/linux-amd64
```

Those files become `@PAYLOAD@/hello`, `@PAYLOAD@/LICENSE`, and
`@PAYLOAD@/hello.desktop`. Archives are unpacked without removing a top-level
folder: if the archive contains `hello-1.2.3/hello`, use
`@PAYLOAD@/hello-1.2.3/hello` as the source.

## Add installed files

List files under `nfpm.contents`. For example:

```yaml
contents:
  - src: '@PAYLOAD@/hello'
    dst: /usr/bin/hello
    file_info:
      mode: 0755
  - src: '@PAYLOAD@/LICENSE'
    dst: /usr/share/licenses/hello/LICENSE
    file_info:
      mode: 0644
  - src: '@PAYLOAD@/hello.desktop'
    dst: /usr/share/applications/hello.desktop
  - src: packaging/hello.conf
    dst: /etc/hello.conf
    type: config
```

`0755` makes the executable runnable. `0644` is suitable for ordinary data
files. `type: config` marks a file as configuration for the package manager.
Files such as `packaging/hello.conf` can also come directly from your project.

For an installed symbolic link, declare it explicitly:

```yaml
contents:
  - src: /usr/bin/hello
    dst: /usr/bin/hello-cli
    type: symlink
```

Add that entry to your existing list. It makes `hello-cli` point to `hello`
after installation. Regular package inputs currently reject symlinks;
[native macOS and Windows inputs](native-recipes.md) support safe internal links.

## Declare dependencies

Linux binaries must declare the C library they were built for:

| `libc` | Choose this when |
| --- | --- |
| `glibc` | Your executable links to glibc, as on Debian or Fedora. |
| `musl` | Your executable links to musl, as commonly used on Alpine. |
| `static` | Your executable has no dynamic interpreter or shared-library dependencies. |

native-packages inspects the files without running them. For DEB and RPM it
adds known library dependencies and a glibc version requirement where needed.
Declare libraries loaded at runtime and other app requirements yourself.

Dependency names can differ by distribution. Put format-specific lists under
`nfpm.overrides`:

```yaml
overrides:
  deb:
    depends: [ca-certificates]
  rpm:
    depends: [ca-certificates]
  archlinux:
    depends: [glibc, ca-certificates]
```

For Arch, Alpine, and IPK, explicitly list external runtime dependencies.
Check package names against the distribution versions your app supports.
See [library mappings](../_reference/configuration.md#libraries) for extending
DEB/RPM dependency detection.

## Add another target

A **target** gives a name to one platform, architecture, and input. Several
formats can share a target if they use the same compatible files.

Add this next to `linux-amd64` under `targets` after building an ARM64 executable:

```yaml
linux-arm64:
  platform: linux
  arch: arm64
  libc: glibc
  formats: [deb, rpm]
  input:
    kind: directory
    local: dist/linux-arm64
```

Both targets use the shared package metadata and file mappings. A target can
have its own `nfpm` section to override them. Maps merge; lists replace the
whole list, so a target-specific `contents` must list all of that target's files.

Use a separate musl or static build for Alpine. Changing `formats` alone
does not change which systems a binary can run on.

## Select what to build

Build everything, one target, or one format:

```sh
native-packages build --version 1.2.3
native-packages build --version 1.2.3 --target linux-arm64 --output dist/arm64-packages
native-packages build --version 1.2.3 --format deb --output dist/deb-packages
```

Repeat `--target` or `--format` to select several values. Each output directory
must be new. To inspect the plan without running build hooks or downloading
inputs:

```sh
native-packages build --version 1.2.3 --dry-run
```

A selected input must exist when the build reaches that target.

## Run your build script

If you want packaging to invoke your existing build script first, add a hook
to the target:

```yaml
before_build: [./scripts/build-linux.sh, '@ARCH@']
```

This runs once per selected target, in the configuration directory, before
the input is copied. The script must produce the configured input path.
It also receives `NATIVE_PACKAGES_TARGET` and `NATIVE_PACKAGES_VERSION` as
environment variables. Builds using `--release` skip this hook.

Use `after_package` for steps such as Windows signing. It runs once for each
package before checksums are recorded:

```yaml
after_package: [pwsh, -File, packaging/sign.ps1, '@PACKAGE@']
```

Hooks are argument lists. Put shell pipelines or multiple commands in a script.
See [hooks and replacement values](../_reference/configuration.md#hooks).

## Packages containing only data or source

Use target-level `kind: data` for packages containing configuration or data
without compiled executables. This is separate from `input.kind`, which says
how the input is stored.

Source RPMs use a separate target with `kind: source`, `formats: [srpm]`,
and an RPM spec plus its sources. The
[all-formats example](https://github.com/crmne/native-packages/blob/main/examples/native-packages-all-formats.yaml)
shows the full layout.

## Next steps

Follow [Publishing a release](publishing.md) to share the result, or
[macOS and Windows installers](native-recipes.md) to add native installer scripts.
