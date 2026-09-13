# Configuration reference

`native-packages.yaml` (or `.yml`) is discovered in the working directory. `--config FILE` selects a different file; relative paths resolve from that file's directory. The schema uses data only: no Ruby evaluation or general template expressions.

| Field | Purpose |
| --- | --- |
| `schema` | Configuration schema version; currently `1`. |
| `tool.version` | Exact native-packages gem version. A mismatch reports the install/version-selection command. |
| `tool.nfpm` | Supported nFPM version; currently `2.47.0`. |
| `nfpm` | Native nFPM configuration mapping, or a relative YAML filename. Name, contents, dependencies, hooks and signing use nFPM's schema. |
| `targets` | Named platform/architecture/input/format combinations. May be empty for recipe-only projects. |
| `release` | Optional GitHub `repository` and checksum filename (`checksums.txt` by default). |
| `assets` | Additional recipe assets, keyed by uppercase identifiers. |
| `templates` | Output recipe paths mapped to input template paths. |
| `repositories` | The existing downstream registry entries, without the old `version`/`repositories` wrapper. Defaults to empty. |
| `libraries` | Additional shared-library-to-package dependency mappings, keyed by SONAME then format. |
| `revisions` | Per-version/per-template package revisions, preserving the v0.1 format. |
| `version_file`, `version_section` | Existing Cargo manifest version checks used by `check-version`. |

## Targets

A target declares `platform` (`linux` or `windows`), `arch` (nFPM/Go architecture name), `formats`, and `input`. `kind` defaults to `binary`; `data` permits packages without executables, and `source` is required for a separate SRPM target. Linux binaries declare `libc` as `glibc`, `musl` or `static`. IPK also requires an `abi` label identifying the device/distribution baseline.

A target's optional `nfpm` mapping overrides the shared definition. Maps merge recursively; lists replace in full. Package name, version, platform and architecture must not conflict with their canonical declarations. Format-specific architecture overrides belong in the corresponding nFPM section. Distinct target inputs must be supplied for incompatible ABIs or platforms.

`input.local` is a path. `input.release_asset` is a filename; `input.url` can override its GitHub release URL. `input.kind` is `archive` (default), `directory` or `file`. Binary release inputs always require a matching release checksum. Archive extraction and Linux inspection require `bsdtar` and `readelf`, respectively.

`before_build` is an argument array, for example:

```yaml
before_build: [./scripts/build-linux.sh, '@ARCH@']
```

It runs once per selected target in the configuration directory, before copying local inputs. `NATIVE_PACKAGES_TARGET` and `NATIVE_PACKAGES_VERSION` are also set. It is skipped in release mode and never executed by `validate`, `doctor` or a dry run. A shell script remains responsible for complex build operations.

`after_package` is an optional argument array invoked once per generated package, before output hashes are recorded. It additionally receives `@PACKAGE@` and `@FORMAT@`. Use it for existing native signing tools, for example a Windows SDK SignTool script. It runs in local and release mode and must preserve the output filename and file set. The MSIX acceptance test uses SignTool because Windows rejected the signature produced by nFPM 2.47.0's built-in signer in that test.

## Tokens and additional assets

Strings can contain `@NAME@`, `@VERSION@`, `@TAG@`, `@DATE@`, `@SOURCE_DATE_EPOCH@`, `@ROOT@`, `@UPSTREAM@` and `@GIT_VERSION@`. Target definitions additionally receive `@ARCH@`, `@PLATFORM@`, `@TARGET_ID@`, `@TARGET@` and `@PAYLOAD@`. `TARGET` is the explicit `compiler_target` or, if omitted, the target ID. `PAYLOAD` is the extracted/copied input directory. Recipe templates also receive `@PKGREL@`.

Additional `assets` retain the existing `file`, optional `url`, and `checksummed` fields. Local builds require `local` paths for these assets. Release builds download and hash them, checking the published checksum unless `checksummed: false` is explicitly set for a source asset. Each contributes `@KEY_FILE@`, `@KEY_URL@` and `@KEY_SHA256@` to recipe rendering. Unresolved tokens fail validation/build.

Omitting `--version` requires an exact stable release tag at HEAD. `--release` supplies the version and conflicts with a different `--version`. Stable versions currently use `vMAJOR.MINOR.PATCH`; prerelease tags are rejected. Build timestamps use `SOURCE_DATE_EPOCH`, otherwise the relevant Git commit timestamp, otherwise the current time for projects without Git metadata. Supply `SOURCE_DATE_EPOCH` for repeatable builds outside Git.

## Output and publication

`build` writes a fresh `dist/packages/<version>` directory, or the explicit `--output` path. It refuses an existing output. Each target/format gets its own directory and nFPM chooses the native filename. `build.json` records the configuration digest, targets, input/output hashes and validation performed. It does not claim the application was installed or tested on each distro.

`publish --from DIRECTORY --to github,aur` verifies the entire configured target set and file hashes before publishing. `github` means release assets; other names select a configured downstream destination or group. GitHub asset filenames must be unique across variants. Upstream `checksums.txt` is preserved and package upload checksums use `packaging-checksums.txt`.

For builds split across CI jobs:

```sh
native-packages build --version 1.2.3 --target linux-amd64 --output dist/linux
native-packages build --version 1.2.3 --target windows-amd64 --output dist/windows
native-packages aggregate dist/linux dist/windows --output dist/complete
native-packages publish --from dist/complete --to github
```

Each build must use the same configuration, release version and timestamp. Aggregate rejects duplicate target/format outputs, conflicting recipe files and incomplete sets. Publishing recipes can still use the existing reviewed sequence: `stage TARGET DIRECTORY/recipes`, `diff TARGET`, then `publish TARGET --body-file FILE` where required by a submission destination.
