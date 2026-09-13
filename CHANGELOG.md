# Changelog

## 0.2.0

- Add an installable CLI with `init`, `doctor`, `build`, `aggregate` and configuration migration.
- Read one `native-packages.yaml` file without an application Gemfile, lockfile or wrapper.
- Build all seven nFPM formats from explicit local or verified release inputs, including Arch, APK, IPK, MSIX and SRPM.
- Check ELF/PE architecture, Linux libc and linked libraries; retain native nFPM configuration and filenames.
- Verify build manifests and complete target sets before release uploads or downstream publication.
- Add isolated gem installation checks, native Linux package acceptance and Windows MSIX acceptance workflows.
- Prepare RubyGems Trusted Publishing and preserve the existing v0.1 commands and workflow path.

## 0.1.0

- Extract shared packaging and downstream repository handling from the application repositories.
- Verify published release assets and produce Debian and RPM packages through nFPM.
- Generate native recipe files from application-owned templates and prepare independent downstream Git checkouts.
- Provide a reusable GitHub Actions workflow and a Ruby command-line interface without runtime gem dependencies.
