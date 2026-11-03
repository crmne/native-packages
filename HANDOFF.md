# Hand-off: native-packages and the MSI switch

Written 2026-10-15 by the Claude session working in this repo, continued by
Codex the same day. This file is untracked and should not be committed.
Delete it when the remaining work is finished.

## Continuation completed

- native-packages commit `8614122` is pushed to main. The documentation's
  Open Graph and Twitter images now use the existing 1280x720 launch poster,
  with dimensions and alt text. CONTRIBUTING.md documents the configuration.
  The production Jekyll build, all 564 local links, and social metadata on
  all 16 pages pass. Deployment is verified: the live homepage now points
  both social image tags to the poster, and the JPEG returns HTTP 200.
  GitHub's Test run was queued at the last API check; do not confuse the
  passing local suite with a confirmed remote run for this commit.
- Chat with Work Local Agent commit `d4f2cab` is on local main, deliberately
  **not pushed**, because Carmine pushes that repo himself. Both WiX
  Manufacturer fields, both WinGet Publisher fields, and the nFPM vendor
  now say "Plenty". Certificate identities and the MSI UpgradeCode are
  unchanged. Its eight packaging tests, XML/YAML checks, and
  `native-packages _0.8.1_ validate` pass. Windows installation was not run
  locally for this metadata change.
- native-packages: 92 tests, 630 assertions pass with nFPM 2.47.0 selected.
  RubyGems lists 0.9.0. The previous main Test run passed.
- Latest Packaging runs checked for ZapFast, TonePush and Spotifast passed;
  Spotifast CI also passed. All three release workflows still build and
  upload Inno installers alongside MSI. Solco's source checkout was not
  available here, and crmne/solco only exposed automation workflows, so its
  packaging status was not independently reverified.
- No releases, promotional posts or issue replies were published.

## Goal

Every app that uses native-packages should ship a Windows Installer (`.msi`)
instead of the Inno Setup `-setup.exe`, because some antivirus products flag
the Inno installer. In the installers:

- Use "Plenty" as the publisher where possible, and the full name
  "PlentyLabs UG (haftungsbeschränkt) & Co. KG" only where the law requires
  it.
- Only Solco and Chat with Work Local Agent are published by the company.
  Every other app is personal: both publisher and copyright are
  "Carmine Paolino".

## Decision (Carmine, 2026-10-15)

Don't cut special MSI bridge releases. Release ZapFast, TonePush, Solco and
Spotifast normally when each one is due.

## Done

- **native-packages 0.9.0** is released: tag v0.9.0 (83bd46c), published on
  GitHub, gem on RubyGems. It adds `formats: [msi]` for Windows targets. The
  recipe runs `wix build ... -pdbtype none`, and the output is checked to be
  an OLE compound file. The Windows acceptance job builds, installs, upgrades,
  rolls back and removes an MSI fixture (`test/native_windows_acceptance.ps1
  -Format msi`). Docs: `docs/_guides/native-recipes.md`, section "A Windows
  Installer (MSI) project". `main` is clean and pushed.
- **fastframe 0.5.1** is released by its own session. Its updater prefers
  `<slug>-v<version>-<target>.msi` and falls back to `-setup.exe`. It runs
  `msiexec /i ... /qn /norestart INSTALLFOLDER=<app folder>` and treats exit
  codes 0 and 3010 as success.
- **ZapFast** (~/Code/zapfast; commits eef365c, 26846fb, e00e377 on
  origin/main):
  - The new `packaging/windows/zapfast.wxs` is a per-user WiX 5 package with
    UpgradeCode {AC7FEAEC-54FA-4A71-95A5-532EE484B6A9}. It takes over an
    existing Inno install (`..._is1` key) and refuses to install or uninstall
    while ZapFast runs.
  - Also new: `packaging/windows/msi.rb` and
    `packaging/windows/test-installer.ps1`.
  - `native-packages.yaml` has windows-amd64 and windows-arm64 targets with
    `formats: [msi]`.
  - `release.yml` builds and attests the `.msi`, and the Packaging workflow
    has a "Windows installer" job.
  - The fastframe dependency is at v0.5.1.
  - CI and Packaging pass on main.
- **TonePush, Solco and Spotifast** were ported by their own sessions and are
  on their main branches. TonePush and Solco are green; Spotifast's Windows CI
  was still running when last checked. Solco's Manufacturer is "Plenty".

## Left to do

1. **Normal releases** of ZapFast, TonePush, Solco and Spotifast when each is
   due.
   - Each release must still ship `-setup.exe` next to the `.msi`. Installed
     copies run an updater older than fastframe 0.5.1, and that updater only
     looks for `-setup.exe`.
   - Drop Inno in a later release, once most users run a build with
     fastframe 0.5.1.
   - In the ZapFast release that drops Inno, point `docs/_guide/download.md`
     (it still links `-setup.exe`) and the release notes' download line at
     the `.msi`.
2. **Chat with Work Local Agent:** Carmine can push local main (`d4f2cab`)
   after reviewing the publisher changes described above.
3. **ZapFast's app work:** the checkout was left untouched. Its local
   origin/main still reports six commits behind local main, but GitHub now
   shows CI passing on `77fd96d`, so the earlier unpushed warning is stale.
4. **Promotion, from the audit for carmine-f0:**
   - X has no posts yet for 0.8.0, 0.8.1 or 0.9.0.
   - The site's image fix is pushed and verified live.
   - The GitHub repo still has no custom social preview. Upload the existing
     `docs/assets/images/launch-film-poster.jpg` in repository Settings.
   - Issue #1 (Flatpak) is waiting for Carmine's reply.

## How to verify

- native-packages:
  - Run `mise exec nfpm@2.47.0 -- bundle exec ruby -Ilib -e
    'Dir["test/*_test.rb"].sort.each { |path| require_relative path }'`.
    There is no Rake task in the bundle.
  - `gh run list --repo crmne/native-packages --limit 3` should show green
    runs.
  - `gem list -r native-packages` should list 0.9.0.
- Each app:
  - `gh run list --repo crmne/<app> --branch main --limit 5` should show CI
    and Packaging passing. The Packaging run includes the "Windows installer"
    job, which runs `test-installer.ps1`: install the Inno build, take it over
    with the MSI, upgrade, refuse while the app runs, then uninstall.
- A release:
  - The assets should include `<slug>-v<ver>-x86_64-pc-windows-msvc.msi`,
    the aarch64 `.msi`, and the `-setup.exe` files.
  - The `.msi` should be attested: `gh attestation verify <file> --repo
    crmne/<app>`.
- Rules:
  - The GitHub API rate limit is shared by every session, so don't poll it.
  - Never use `pkill -f`.
  - Work on the default branch with linear history.
  - No em dashes in user-facing text.
  - Commit release notes as `packaging/release-notes/vX.Y.Z.md` before
    tagging.
