# Changelog

## 0.6.0 (2026-09-14)

- Use one configuration for Linux and native Mac/Windows targets. The reusable
  Linux packaging workflow accepts explicit target IDs and forwards the same
  selection to build and publication.
- Add `publish --target ID`. Publication requires every configured format for
  exactly those targets; the default still requires the whole configuration.
  Configuration identity, recipe completion and package hashes remain checked.
- Allow opted-in native prerelease builds to defer shared stable recipes.
  Deferred output cannot be published or finalize prerelease AUR/Homebrew recipes.

## 0.5.1 (2026-09-13)

- Make imported Apple signing identities usable on clean macOS CI runners by
  registering the temporary keychain in the user search list. Keep existing
  entries and the default keychain; remove only the owned keychain afterward.
  Coordinate parallel signing calls with a shared per-user lock.
- Give each configuration its own reusable-workflow concurrency group so stable,
  alpha and macOS validation calls cannot cancel each other while queued.

## 0.5.0 (2026-09-13)

- Automatically sign and notarize native macOS DMG targets when all six Apple
  environment variables are present. Sign nested code inside out on an owned
  copy, preserve entitlements, validate Apple acceptance and stapled tickets,
  and hash the final package. Incomplete credentials fail before packaging.
- Add `notarize-macos INPUT --output OUTPUT` for signed portable directory
  copies, using a temporary ZIP submission before application-owned archiving.
- Isolate imported certificates and notary credentials in a disposable keychain,
  redact private values from command failures, and retain existing local, Linux
  and Windows packaging behavior when Apple signing is not enabled.

## 0.4.0 (2026-09-13)

- Add opt-in `build --defer-recipes` and `aggregate --finalize-recipes` so native
  targets can build without global recipe assets or AUR tools. Generate stable
  downstream recipes once from the completed packages and locally staged assets.
- Reject publication of unfinished recipes and retain complete target, metadata
  and checksum verification across the deferred build and finalization phases.

## 0.3.1 (2026-09-13)

- Keep checkout-local `ROOT` tokens out of shared release metadata so packages
  built in different directories or operating systems can be aggregated.
- Add a regression that builds two targets in separate checkouts and verifies
  their complete combined manifest.

## 0.3.0 (2026-09-13)

- Add opt-in alpha, beta and release-candidate package versions for DEB/RPM and
  native DMG/Inno targets. Keep legacy/default versions stable-only, and require
  an existing GitHub prerelease before attaching preview packages.
- Coordinate application-owned DMG and Inno Setup commands on their native hosts,
  with copied inputs, architecture checks, output/container validation, signing
  hooks and complete-build manifests, aggregation and checksums.
- Preserve internal bundle symlinks while rejecting escaping or dangling links;
  verify copied payloads and reject native recipes that modify them.
- Handle native command output independently of an SSH session's text locale.
- Add native install, upgrade, rollback and removal fixtures. Fixture results do
  not certify a packaged application or replace its platform acceptance tests.

## 0.2.0

- Add an installable CLI with `init`, `doctor`, `build`, `aggregate` and configuration migration.
- Read one `native-packages.yaml` file without an application Gemfile, lockfile or wrapper.
- Build all seven nFPM formats from explicit local or verified release inputs, including Arch, APK, IPK, MSIX and SRPM.
- Check ELF/PE architecture, Linux libc and linked libraries; retain native nFPM configuration and filenames.
- Verify build manifests and complete target sets before release uploads or downstream publication.
- Add isolated gem installation checks, native Linux package acceptance and Windows MSIX acceptance workflows.
- Follow RubyLLM’s RubyGems token and GitHub release publishing convention and preserve the existing v0.1 commands and workflow path.

## 0.1.0

- Extract shared packaging and downstream repository handling from the application repositories.
- Verify published release assets and produce Debian and RPM packages through nFPM.
- Generate native recipe files from application-owned templates and prepare independent downstream Git checkouts.
- Provide a reusable GitHub Actions workflow and a Ruby command-line interface without runtime gem dependencies.
