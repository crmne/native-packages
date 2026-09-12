# Changelog

## 0.1.0

- Extract shared packaging and downstream repository handling from the application repositories.
- Verify published release assets and produce Debian and RPM packages through nFPM.
- Generate native recipe files from application-owned templates and prepare independent downstream Git checkouts.
- Provide a reusable GitHub Actions workflow and a Ruby command-line interface without runtime gem dependencies.
