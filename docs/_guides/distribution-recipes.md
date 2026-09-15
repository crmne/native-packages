---
title: Distribution recipes
description: Generate AUR and Homebrew recipes with release checksums, review downstream changes, and publish repository updates.
nav_order: 7
---

# Distribution recipes

A distribution recipe tells a package manager where to get your app and how
to install or build it. Examples include an AUR `PKGBUILD`, a Homebrew formula
or cask, and a Gentoo ebuild.

native-packages fills in versions, download URLs, and checksums in templates
you keep with the app. It can then stage those files in a downstream Git
repository for review and publication.

This guide uses an AUR package as an example. The same asset and template
settings work for other recipe formats.

## 1. Declare the release asset

Add an asset for the archive your recipe downloads:

```yaml
release:
  repository: your-name/hello
assets:
  AMD64:
    file: hello_@VERSION@_linux_amd64.tar.gz
    local: dist/hello_@VERSION@_linux_amd64.tar.gz
```

For local builds, native-packages hashes `local`. In release mode, it downloads
`file` from the configured release and verifies its entry in `checksums.txt`.
An explicit `url` can point elsewhere.

Each asset provides three values for templates: `@AMD64_FILE@`,
`@AMD64_URL@`, and `@AMD64_SHA256@`. Use uppercase names such as `AMD64`
or `MACOS` for asset keys.

## 2. Write a template

Create `packaging/arch/hello-bin/PKGBUILD.in`:

```sh
pkgname=hello-bin
pkgver=@VERSION@
pkgrel=@PKGREL@
pkgdesc='A small greeting application'
arch=('x86_64')
url='@UPSTREAM@'
license=('MIT')
depends=('glibc')
provides=('hello')
conflicts=('hello')
source=('@AMD64_URL@')
sha256sums=('@AMD64_SHA256@')

package() {
  install -Dm755 hello "$pkgdir/usr/bin/hello"
  install -Dm644 LICENSE "$pkgdir/usr/share/licenses/hello/LICENSE"
}
```

This example expects the archive to contain `hello` and `LICENSE` at its root.
Use dependencies and metadata appropriate to your actual app.

Map the generated path to the template in `native-packages.yaml`:

```yaml
templates:
  arch/hello-bin/PKGBUILD: packaging/arch/hello-bin/PKGBUILD.in
```

The left side is a path under the build's `recipes/` directory. The right side
is a source path relative to your configuration.

For paths matching `arch/<package>/PKGBUILD`, native-packages also generates
`.SRCINFO`, the package metadata used by AUR. This needs `makepkg` or working
Docker. Recipe archives need `tar` and `xz`.

## 3. Generate and test the recipe

Build with your existing package targets and the new settings:

```sh
native-packages build --version 1.2.3 --output dist/with-recipes
```

Look in `dist/with-recipes/recipes/arch/hello-bin/` for `PKGBUILD` and `.SRCINFO`.
Review the rendered URLs, version, checksum, dependencies, and installation
paths. Test the recipe with the destination's normal tooling on a suitable
machine before publishing it.

A project that only generates recipes can use `targets: {}`. It still needs
`schema`, `tool`, `nfpm.name`, and the asset/template configuration.

## 4. Configure a destination

Add the existing downstream repository under `repositories`:

```yaml
repositories:
  aur-bin:
    group: aur
    url: https://aur.archlinux.org/hello-bin.git
    push_url: ssh://aur@aur.archlinux.org/hello-bin.git
    branch: master
    package_path: .
    files:
      arch/hello-bin/PKGBUILD: PKGBUILD
      arch/hello-bin/.SRCINFO: .SRCINFO
    version_file: PKGBUILD
    version_pattern: '^pkgver=(\S+)'
    publish: push
```

Use your actual package repository and configure credentials for it. `files`
maps generated paths under `recipes/` to paths in the downstream repository.
`version_pattern` extracts the existing version so the tool can detect updates
and downgrades.

The `group` lets you operate on related destinations together. For example,
`aur` can select both a binary package and a source package.

## 5. Stage, review, and publish

```sh
native-packages repositories
native-packages stage aur dist/with-recipes/recipes
native-packages diff aur
native-packages publish aur
```

`stage` prepares the update in an independent checkout under
`.cache/packaging/repos/`. `diff` shows what will change. `publish` commits and
pushes the staged update. Add `.cache/` to your application's `.gitignore`.

Each destination has its own checkout. Your app needs no Git submodules or
additional remotes. Updates touch the mapped package paths and preserve other
files; Gentoo updates also preserve older ebuilds and Manifest entries.

Check downstream state with:

```sh
native-packages status
native-packages status aur --offline --json
```

The offline form uses cached information. Normal status checks query upstream
repositories and open requests.

## Homebrew formulae and casks

Keep a formula or cask template in your app, then map it through `templates`
and `repositories.files` just like the AUR example. A tap you own typically
uses `publish: push` and a destination named `homebrew`.

Use a formula for the appropriate command-line package or a cask for a native
app download. Your template owns the package manager's installation logic.
If a cask refers to a DMG created by this release, use
[deferred recipe generation](multi-platform.md#generate-recipes-after-packages-are-built)
so its checksum comes from the completed, signed image.

## Submit a pull request or merge request

Use `publish: github-pr` or `publish: gitlab-mr` for a repository that accepts
contributions through review. Create the fork first and supply its URLs and
submission settings. The [repository reference](../_reference/configuration.md#repositories)
lists these fields.

Staging writes a starting description to `.cache/packaging/submissions/` and
prints its path. Edit it to describe the update and the checks you ran, then
publish that destination by name:

```sh
native-packages diff community
native-packages publish community --body-file .cache/packaging/submissions/community.md
```

The tool can reuse an existing open request. Successful submission means the
request exists; the upstream project still reviews and accepts it.

Use `publish: manual` with `notes` for destinations that need an external
process. The CLI reports those instructions rather than submitting an update.

## Next steps

Once the process is tested, enable destination publication in
[GitHub Actions](github-actions.md#enable-aur-or-homebrew-publication).
For package files themselves, use [Publishing a release](publishing.md).
This tool does not host APT or DNF package indexes.
