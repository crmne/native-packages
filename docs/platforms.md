# Platform and distribution coverage

All seven nFPM 2.47.0 packagers are exposed by the v0.2 CLI. Each target explicitly declares suitable inputs; enabling an output format does not port an application or guarantee acceptance by a distribution.

| Output/destination | Shared implementation | Application responsibility |
| --- | --- | --- |
| DEB | nFPM, ELF inspection, known dependency inference, release upload | Supported distro baseline, runtime-loaded libraries, services/assets and installation testing |
| RPM | Same, with RPM dependency names | Distribution-specific dependencies and compatibility |
| Arch package | nFPM `archlinux`, native filename, ELF inspection | Arch-compatible files and explicit dependencies |
| Alpine APK | nFPM `apk`, ELF/libc checks | Suitable musl/static inputs and Alpine dependencies |
| IPK | nFPM `ipk`, ELF checks, explicit ABI label | Device/distribution ABI, architecture and dependencies |
| MSIX | nFPM `msix`, PE architecture checks, `after_package` hook for native signing | Windows executables/DLLs, application identity, assets, capabilities and signing certificate |
| SRPM | nFPM `srpm`, source/spec input validation | A correct spec and sources, native rebuild testing |
| AUR | Template rendering, `.SRCINFO`, staged Git publication | Native PKGBUILD source/bin/git variants and build checks |
| Homebrew | Hash/render supplied formulae or casks and publish a tap | Completed macOS assets, native recipe logic |
| Nixpkgs/Gentoo/Void and similar repositories | Template rendering and configured Git/PR/MR publication | Native recipes, dependency hashes, distro checks and review |
| Flatpak | No build/publication adapter yet | Use flatpak-builder and native manifests/runtime/sandbox settings |
| Inno Setup | Native command adapter, PE inspection, copied input and final output hashes | Inno recipe/compiler, application version mapping, signing and installation tests |
| macOS DMG | Native command adapter, Mach-O inspection, automatic Developer ID signing/notarization with Apple credentials, final stapled hashes | Bundle, hdiutil recipe, Apple credentials/entitlements, update/rollback testing |
| Other Windows installers | No adapter for NSIS/WiX yet | Existing native tools and WinGet/Scoop integrations |

The IPK acceptance fixture targets OpenWrt 24.10.8. OpenWrt 25.12 switched to APK, so IPK is not the package format for every OpenWrt release. [OpenWrt 25.12 release notes](https://openwrt.org/releases/25.12/notes-25.12.0)

nFPM ends at constructing the package file, including its supported signing operations. It does not compile the application or host package indexes. [nFPM configuration](https://nfpm.goreleaser.com/docs/configuration/)

The Windows acceptance test uses Windows SDK SignTool through `after_package`. Windows rejected nFPM 2.47.0's built-in signature with `0x80096010` in the initial acceptance run; do not assume its signing configuration alone produces a Windows-installable result.

The CLI uses known ELF machine/class/endianness mappings and PE machine mappings. Unsupported inspection architectures fail explicitly. Data and source targets do not require an executable. The small DEB/RPM dependency table can be extended in configuration; other formats require explicit runtime dependencies. These checks do not detect every dynamically loaded library or establish compatibility with every version of a distribution.

CI builds fixtures in every format and defines native Linux install/upgrade/remove checks, an SRPM rebuild and a signed MSIX installation on Windows. A build manifest reports `installation: not-tested` unless such testing was actually performed for that application output. Fixture coverage is separate from app-specific validation.

The [acceptance run for v0.2 development](https://github.com/crmne/native-packages/actions/runs/34748247545) passed on Debian trixie, Fedora 41, Arch's base image, Alpine 3.24.0, OpenWrt 24.10.8 and the GitHub Windows runner. Linux binary tests use a small static executable; the SRPM rebuilds its C source, and the Windows package contains a compiled Windows executable. These fixtures test package construction and lifecycle, not the compatibility of every application's GUI or device integrations.

Version 0.1 and its pinned workflow retain their DEB/RPM behavior. The new formats are enabled through the v0.2 single-file configuration and `build` command. Existing v0.1 application configurations do not silently gain more output formats.
