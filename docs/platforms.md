# Platform and distribution coverage

nFPM ends at the package file. It uses the files, dependencies, permissions and package scripts supplied in its configuration. It does not compile the application, update a downstream Git repository or obtain distribution acceptance. Some formats support signing options, but credentials, release policy and trust configuration remain the maintainer's responsibility. [nFPM](https://nfpm.goreleaser.com/docs/configuration/)

| Destination | Existing tool or format | Shared code in 0.1 | App-specific work |
| --- | --- | --- | --- |
| Debian/Ubuntu downloads | nFPM DEB | Build from verified Linux release archives and attach assets | File mappings, dependencies, compatible build baseline, install/upgrade testing |
| Fedora/RHEL/openSUSE downloads | nFPM RPM | Same | Target dependency names and supported distro versions |
| Arch binary downloads | nFPM `archlinux` | Not enabled by the CLI yet | Add and test the native output configuration |
| AUR | `makepkg`, Git; GoReleaser can publish `-bin` recipes | Render supplied PKGBUILDs, generate `.SRCINFO`, stage/push | Source/bin/git variants and correct build/install functions |
| Alpine / OpenWrt | nFPM APK/IPK; native build tools for distro submissions | Native templates can be rendered; binary outputs are not enabled yet | Appropriate libc, architecture, dependencies and native recipes |
| Nixpkgs / Gentoo / Void / other source repositories | Nix expressions, ebuilds, native recipe formats | Template generation and configured Git/PR/MR submissions | Native build logic, dependency hashes, repository-specific checks and review |
| Flatpak / Flathub | `flatpak-builder`, Flathub infrastructure | No build or publication adapter yet | Runtime/SDK, modules, sandbox permissions, portals and manifests |
| macOS | Existing bundle scripts, Apple signing/notarization, Homebrew | Hash and render a supplied Homebrew formula/cask; push a configured tap | `.app` contents, entitlements, DMG/PKG creation, signing and notarization |
| Windows | Existing Inno Setup/NSIS/WiX tools, WinGet/Scoop; nFPM also supports MSIX | No installer or store publication adapter yet | Installer configuration, DLLs, signing, application identity and native validation |

Sources: [nFPM formats](https://nfpm.goreleaser.com/), [GoReleaser AUR](https://goreleaser.com/customization/publish/aur/), [Homebrew taps](https://docs.brew.sh/How-to-Create-and-Maintain-a-Tap), [Flatpak manifests](https://docs.flatpak.org/en/latest/manifests.html), [GoReleaser WinGet](https://goreleaser.com/customization/publish/winget/).

The shared layer can serve applications written in Go, Rust, C or another language because it starts with release artifacts. It also allows public binary releases from a private source repository through `release_repository`. Application source and private build settings do not belong in this shared repository.

The practical route to greater reuse is to adopt existing release-tool integrations for the remaining destinations and share repeated workflow steps when two applications have matching requirements. Adding a plugin framework, a second build language, or new installer implementations is unnecessary. Public distro recipes should remain native and inspectable.
