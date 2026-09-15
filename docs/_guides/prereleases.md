---
title: Prereleases
description: Build and publish alpha, beta, and release candidate packages with explicit version rules.
nav_order: 9
---

# Prereleases

Use a prerelease to let people test an upcoming version before the stable
release. native-packages supports alpha, beta, and release candidate packages
for **DEB, RPM, DMG, and Inno Setup**.

## Enable preview versions

Add this to your release settings:

```yaml
release:
  repository: your-name/hello
  prereleases: true
```

Then build with a version such as:

```sh
native-packages build --version 1.2.3-alpha.1
```

Accepted suffixes are `-alpha.N`, `-beta.N`, and `-rc.N`, where `N` is a positive
integer. Build metadata suffixes such as `+build.5` are not accepted.
Stable versions such as `1.2.3` continue to work.

DEB and RPM use the packaging helper's version conversion; for example,
`1.2.3-alpha.1` becomes `1.2.3~alpha.1`. Keep the normal SemVer conversion
enabled and do not override the prerelease field.

## Keep distribution recipes for stable releases

The simplest setup is a separate preview configuration with supported formats
and no `templates`:

```sh
native-packages --config native-packages.preview.yaml build \
  --version 1.2.3-beta.1
```

If a native build shares a configuration with stable AUR or Homebrew recipes,
you can use `--defer-recipes` to produce its preview package. Those recipes
cannot be finalized for a prerelease, and the deferred build cannot be passed
to `publish --from`. Collect the native output through your application's
release job, or use a separate preview configuration for normal CLI publication.

## Publish to a GitHub prerelease

Create the matching GitHub release, such as `v1.2.3-alpha.1`, and mark it as a
prerelease. Then publish a complete, non-deferred build:

```sh
native-packages publish --from dist/packages/1.2.3-alpha.1 --to github
```

The command checks that the existing release is marked as a prerelease. It
does not create the release or change its status. Downstream recipe publication
is reserved for stable versions.

## Native installer versions

Your DMG or Inno script receives the app version, including the suffix.
If the installer needs numeric version fields, define that mapping in your
app's script. Test that alpha 2 upgrades alpha 1 and that the stable version
upgrades the previews. The packaging tool does not choose that ordering policy
for your application.
