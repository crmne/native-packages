# Changelog

## Unreleased

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
