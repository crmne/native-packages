---
title: macOS and Windows installers
description: Connect your DMG or Inno Setup script to the same build and publication process as your Linux packages.
nav_order: 5
---

# macOS and Windows installers

This guide shows how to connect an existing DMG or Inno Setup script to
native-packages. You supply a built app and a packaging script. The build
command checks the app, runs your script, and records the finished installer's
checksum.

Build **DMGs on macOS** and **Inno installers on Windows**. These targets use
your native tools and do not need an nFPM executable.

## Prepare your app

Build the complete application first, including any libraries and supporting
files. A macOS input can be `dist/Hello.app`. A Windows input can be a directory
such as `dist/windows` containing `hello.exe` and its dependencies.

If your inputs come from another job, download and unpack them before packaging.
Native targets require a local directory and use `build --version`; they do
not accept `build --release` downloads directly.

## Configure the targets

Here is a complete configuration for an ARM64 Mac app and an x86-64 Windows app:

```yaml
schema: 1
tool:
  version: '0.6.0'
  nfpm: '2.47.0'
nfpm:
  name: hello
  description: A small greeting application
  maintainer: Your Name <you@example.com>
  license: MIT
release:
  repository: your-name/hello
targets:
  macos-arm64:
    platform: macos
    arch: arm64
    formats: [dmg]
    input:
      kind: directory
      local: dist/Hello.app
    native:
      command: [ruby, packaging/dmg.rb, '@PAYLOAD@', '@PACKAGE@']
      output: 'hello-@TAG@-macos-arm64.dmg'
  windows-amd64:
    platform: windows
    arch: amd64
    formats: [inno]
    input:
      kind: directory
      local: dist/windows
    native:
      command: [ruby, packaging/setup.rb, '@PAYLOAD@', '@PACKAGE@', '@VERSION@']
      output: 'hello-@TAG@-windows-setup.exe'
```

The `nfpm` section still holds shared package metadata, and `tool.nfpm` keeps
mixed-platform configurations consistent. Native targets use `native.command`
to create their output.

For Intel Macs, use `arch: amd64`. Use `arch: universal` for a build containing
both Intel and ARM64 code. Architecture checks use Apple's `lipo`.

## Write the packaging command

`native.command` is a list of arguments. It must include `@PACKAGE@`:

| Value | What your script receives |
| --- | --- |
| `@PAYLOAD@` | A temporary copy of the input to package. |
| `@PACKAGE@` | The exact, absolute path where the output must be created. |
| `@VERSION@` | App version, such as `1.2.3`. |
| `@TAG@` | Release tag, such as `v1.2.3`. |

Commands run in the configuration directory. They also receive
`NATIVE_PACKAGES_TARGET`, `NATIVE_PACKAGES_VERSION`, and `SOURCE_DATE_EPOCH`.

### A minimal DMG script

For the `Hello.app` input above, create `packaging/dmg.rb`:

```ruby
require "fileutils"
require "tmpdir"

payload, output = ARGV
abort "expected payload and output paths" unless payload && output
abort "output already exists" if File.exist?(output)

Dir.mktmpdir("hello-dmg-") do |staging|
  FileUtils.cp_r(payload, File.join(staging, "Hello.app"), preserve: true)
  File.symlink("/Applications", File.join(staging, "Applications"))
  success = system("hdiutil", "create", "-volname", "Hello",
    "-srcfolder", staging, "-format", "UDZO", output)
  abort "DMG creation failed" unless success
end

abort "DMG verification failed" unless system("hdiutil", "verify", output)
```

This places the app and an Applications shortcut inside a compressed disk
image. Adapt the volume name and app name to your project.

### An Inno Setup script

Keep your app's `.iss` recipe in the repository. Have `packaging/setup.rb`
invoke your installed Inno compiler and pass it the three arguments above.
The wrapper should:

1. Use `@PAYLOAD@` as the source directory for the recipe's files.
2. Map `@VERSION@` to the app and numeric installer version fields.
3. Set the compiler's output directory and filename from `@PACKAGE@`.
4. Fail if compilation fails.

An Inno recipe also owns your app's identity, installation location, shortcuts,
and uninstall behavior. See the
[Inno command-line compiler documentation](https://jrsoftware.org/ishelp/topic_compilercmdline.htm)
for invoking it from your wrapper.

## Build on each host

On the Mac:

```sh
native-packages doctor --target macos-arm64
native-packages build --version 1.2.3 --target macos-arm64 --output dist/macos-packages
```

On Windows:

```sh
native-packages doctor --target windows-amd64
native-packages build --version 1.2.3 --target windows-amd64 --output dist/windows-packages
```

`doctor` checks the host and the command's executable. Your script checks its
additional tools, such as the Inno compiler. `validate` and `build --dry-run`
do not execute it.

The build checks Mach-O or PE architecture, runs the script, and checks that
it produced exactly the declared DMG or EXE. Test installation, startup,
upgrades, and removal separately for your app.

## Preserve the prepared input

Package the copy at `@PAYLOAD@`. A top-level `.app` keeps its basename; other
input directories are copied into a directory named `payload`.

The copy preserves file modes and safe internal relative symlinks, including
framework links. Dangling links, links escaping the input, and special files
are rejected. Your recipe and output hooks must leave the copied input
unchanged. Use your own temporary staging directory when arranging files.

The command must create only its declared output in the destination directory.
Keep logs and temporary files elsewhere.

## Sign before recording checksums

For DMG targets, providing complete Apple credentials enables automatic input
signing and DMG notarization. Follow [Apple signing and notarization](apple-notarization.md).
The DMG script must preserve the signed app when copying it into the image.

For Windows, use an `after_package` hook to sign the output:

```yaml
after_package: [pwsh, -File, packaging/sign.ps1, '@PACKAGE@']
```

This runs before the output hash is recorded. It must preserve the output's
filename and file set. Do not sign or otherwise change the installer after
building; publication would reject the changed hash.

MSIX is a separate Windows format. It uses package metadata and file mappings
instead of `native.command`; see [Supported platforms](../_reference/platforms.md#msix).

## Combine and publish

Use [Building across platforms](multi-platform.md) to combine these directories
with Linux builds. If your configuration also has AUR or Homebrew templates,
that guide explains how to generate recipes after all native packages exist.
