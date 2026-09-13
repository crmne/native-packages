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
| Homebrew | Hash/render supplied formulae or casks and publish a tap | macOS bundles, signing/notarization, native recipe logic |
| Nixpkgs/Gentoo/Void and similar repositories | Template rendering and configured Git/PR/MR publication | Native recipes, dependency hashes, distro checks and review |
| Flatpak | No build/publication adapter yet | Use flatpak-builder and native manifests/runtime/sandbox settings |
| Other Windows installers | No installer adapter beyond MSIX | Existing Inno Setup/NSIS/WiX and WinGet/Scoop integrations |

nFPM ends at constructing the package file, including its supported signing operations. It does not compile the application or host package indexes. [nFPM configuration](https://nfpm.goreleaser.com/docs/configuration/)

The Windows acceptance test uses Windows SDK SignTool through `after_package`. Windows rejected nFPM 2.47.0's built-in signature with `0x80096010` in the initial acceptance run; do not assume its signing configuration alone produces a Windows-installable result.

The CLI uses known ELF machine/class/endianness mappings and PE machine mappings. Unsupported inspection architectures fail explicitly. Data and source targets do not require an executable. The small DEB/RPM dependency table can be extended in configuration; other formats require explicit runtime dependencies. These checks do not detect every dynamically loaded library or establish compatibility with every version of a distribution.

CI builds fixtures in every format and defines native Linux install/upgrade/remove checks, an SRPM rebuild and a signed MSIX installation on Windows. A build manifest reports `installation: not-tested` unless such testing was actually performed for that application output. Fixture coverage is separate from app-specific validation.

Version 0.1 and its pinned workflow retain their DEB/RPM behavior. The new formats are enabled through the v0.2 single-file configuration and `build` command. Existing v0.1 application configurations do not silently gain more output formats.
