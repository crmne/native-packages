# Native DMG and Inno recipes (0.3)

The shared build command can coordinate existing macOS and Windows packaging
scripts. These are native command adapters, separate from nFPM. They do not
generate an installer recipe, compile an app, supply signing identities or
automatically notarize anything. The application retains those decisions.

```yaml
schema: 1
tool:
  version: '0.3.0'
  nfpm: '2.47.0'
nfpm:
  name: example-app
  maintainer: Example <example@example.org>
  description: Example application
  license: MIT
release:
  repository: example/example-app
  prereleases: true
targets:
  macos-arm64:
    platform: macos
    arch: arm64
    formats: [dmg]
    input:
      kind: directory
      local: Example.app
    native:
      command: [ruby, packaging/dmg.rb, '@PAYLOAD@', '@PACKAGE@', '@VERSION@']
      output: 'example-app-@TAG@-macos-arm64.dmg'
  windows-amd64:
    platform: windows
    arch: amd64
    formats: [inno]
    input:
      kind: directory
      local: dist/windows
    native:
      command: [ruby, packaging/setup.rb, '@PAYLOAD@', '@PACKAGE@', '@VERSION@']
      output: 'example-app-@TAG@-windows-setup.exe'
```

Run each target on its own host using `build --version VERSION --target ID`.
Use the normal `aggregate` command to combine complete target results later.
Use the same configuration and `SOURCE_DATE_EPOCH` across jobs. No nFPM binary
is required when only native targets are selected; its version remains part of
the configuration for compatibility with mixed Linux/native builds.

`native.command` is a nonempty argument array, including `@PACKAGE@`, which
resolves to the exact output filename in a fresh directory. `@PAYLOAD@` is an
owned copy of the input directory's contents. It does not retain the original
directory's basename: a DMG script should copy it into its own temporary
`Example.app` folder before calling hdiutil. Other existing target tokens apply.
Commands run in the application configuration directory and receive the same
target/version environment as other build hooks.

DMG requires a macOS binary target; Inno requires a Windows binary target. Both
use one format per target and `input.kind: directory` with `input.local`.
Release-download mode cannot supply a directory: prepare or download/unpack
the app in its build job, then use local mode. `validate` and dry runs do not
execute commands. `doctor` checks the host and recipe executable; the recipe
must check its own additional tools. Mac architecture inspection also needs
Apple's `lipo`. Supported Mac targets are `amd64`, `arm64` and `universal` (both).

Input copying preserves file modes and internal relative symlinks, including
framework links. Escaping, dangling and special-file entries fail. The staged
tree must match the original digest and remain unchanged after packaging and
signing hooks. Package only this staged input; do not read another application
build from a global location. Recipes should preserve existing destinations,
clean only their own temporary files and use argument arrays for subprocesses.

The command must create exactly its declared `.dmg` or `.exe` file. The adapter
checks a UDIF trailer or PE container respectively. This is a container check,
not proof of a valid installer, signature or application. The existing
`after_package` hook can sign/notarize the output in place before the final hash
is recorded. Do not modify a package after building its manifest: signature
stapling changes bytes and must run inside that hook if the manifest is to verify.

Applications should invoke hdiutil's verification, platform signature checks and
their normal installer compiler checks in their recipes. Preserve native numeric
version ordering across alpha and stable releases; a SemVer suffix cannot be
passed directly to a numeric Windows/macOS version field. The gem does not infer
that policy from an application's release numbering.

## Prerelease policy

`release.prereleases: true` explicitly enables `MAJOR.MINOR.PATCH-alpha.N`,
`-beta.N` and `-rc.N`, with a positive sequence number and no build suffix.
Default/legacy commands continue to require stable versions. Preview builds
support DEB, RPM, DMG and Inno only and cannot contain downstream recipes.
nFPM's normal SemVer conversion produces, for example, `1.2.3~alpha.1` in DEB/RPM;
overriding that prerelease or disabling conversion is rejected. Other package
formats need their own reviewed version policy before being enabled.

Preview publication only attaches to an existing GitHub release marked as a
prerelease. It never creates a release or changes one from stable to prerelease.
All configured targets must be aggregated and their hashes must verify first.
This opt-in cannot affect applications still pinned to the published 0.2.0 gem.

## Acceptance scope

`ruby -Ilib test/native_acceptance.rb NEW_DIRECTORY` builds a small real native
executable and packages alpha 1, alpha 2 and stable versions. It installs into an
owned disposable directory, checks the executable/version and model fixture,
rolls back to alpha 1 and removes the installation. Mac images are attached
read-only and detached; Windows uses a unique per-user fixture identity and
uninstaller. On Windows, run with a C compiler environment and set
`NATIVE_PACKAGES_ISCC` to the actual Inno compiler path.

These are gem fixtures, not application installation evidence. They do not
exercise a DJ library, USB export, licensing, notarization or OS-store acceptance.
The generated application build manifest continues to say `installation:
not-tested`; do not turn that into a success claim merely because gem CI passed.

The [2026-09-13 native record](acceptance/0.3.0-native.json) records successful
DMG lifecycle checks on an ARM64 Mac and Inno lifecycle checks on Windows x64.
Both covered alpha 1 → alpha 2 → stable → alpha 1 and final removal, preserving
the fixture model and exact executable bytes. The native Mac run exposed the
SSH-locale command-output bug, fixed before the successful run. Inno Setup
6.7.3's official installer was verified against its SHA-256 and Pyrsys B.V.
signature; fixtures compiled with MSVC 14.51. Linux passed 49 tests and 287
assertions, including all existing package formats; the isolated gem install
and build check passed. These local results precede hosted CI for this version.

References: [nFPM version conversion](https://nfpm.goreleaser.com/docs/configuration/),
[Inno command-line compiler](https://jrsoftware.org/ishelp/topic_compilercmdline.htm).
