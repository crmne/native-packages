---
title: Omarchy packages
description: Turn your AUR binary recipe into an Omarchy package that Omarchy's bot updates after every GitHub release.
nav_order: 9
---

# Omarchy packages

[Omarchy](https://omarchy.org) installs packages from its own repository,
`https://pkgs.omarchy.org`, built from recipes in
[omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs). A recipe is a
`PKGBUILD` plus `.omarchy/package.json`. When that file declares where your
releases come from, Omarchy's bot opens and merges every later version update
itself. You send one pull request, once.

`omarchy-recipe` writes that first recipe from your existing AUR `-bin`
template. It adds to the AUR; keep publishing there as before.

## Before you start

You need:

- an AUR binary recipe template, mapped as `arch/NAME-bin/PKGBUILD` under
  `templates`, that downloads each architecture's release archive with
  `source_x86_64` and `source_aarch64`
  (see [Distribution recipes](distribution-recipes.md));
- a published, stable GitHub release tagged `vX.Y.Z` whose checksum manifest
  (`release.checksums`, `checksums.txt` by default) lists those archives;
- Docker or Podman, to build the package with Omarchy's own tooling.

## 1. Write the recipe

Fork [omacom/omarchy-pkgs](https://github.com/omacom/omarchy-pkgs), clone your
fork, and branch from `master`. Then, from your app's directory:

```sh
native-packages omarchy-recipe ../omarchy-pkgs --release v1.2.3
```

It renders the templates under `arch/NAME-bin/` for that release into
`pkgbuilds/NAME-bin/`, with `pkgrel=1` and the checksums from the release's
manifest. Pass `--package NAME-bin` when you have more than one `-bin`
template. It refuses a recipe directory that already exists: after the first
pull request the recipe is Omarchy's, and the bot maintains it.

The bot only rewrites `pkgver`, `pkgrel` and the checksums, so every source URL
has to follow `pkgver`. A URL your AUR template wrote out in full, such as
`@AMD64_URL@`, is rewritten to use `${pkgver}`. The command then checks the
recipe by setting another version and confirming every URL moves with it, and
stops if one does not, for example when a URL uses its own version variable or
single quotes.

Next to the `PKGBUILD` it writes `.omarchy/package.json`:

```json
{
  "source": "local",
  "auto_merge": true,
  "release_ring": "fast",
  "min_release_age": "24h",
  "upstream": {
    "watch": {
      "github": "your-name/hello",
      "pattern": "v(?P<version>[0-9]+(?:\\.[0-9]+)*)"
    }
  }
}
```

| Field | Meaning |
| --- | --- |
| `upstream.watch` | Where releases come from: your GitHub repository's releases, with a `pattern` that must match the whole tag. For a new release the bot sets `pkgver`, so the source URLs move with it, and takes each archive's SHA-256 from the digest GitHub reports for that release asset, without downloading it. |
| `auto_merge` | Updates go through Omarchy's hourly tracker instead of the six-hourly reviewed sync, and merge themselves once the build checks pass. |
| `min_release_age` | The bot waits until a release is this old (`24h`) before proposing it, so you have a day to pull a bad release. It then takes the newest release that has cleared the window. |
| `release_ring` | `fast` publishes each merge to Omarchy's `edge`, `rc` and `stable` channels at once, not only `edge`. It suits prebuilt binaries and static tools, which do not depend on the exact Arch snapshot. Omarchy's CI checks each fast-ring build on every channel and fails it when a library or symbol is missing there. |

Omarchy uses the same settings for
[superwhisper-bin](https://github.com/omacom/omarchy-pkgs/tree/master/pkgbuilds/superwhisper-bin).
Edit them before you send the pull request if your app needs otherwise: drop
`release_ring` for an app that must be rebuilt when its libraries change, or
`auto_merge` to have a maintainer review every update.

## 2. Check and build it

From the omarchy-pkgs checkout:

```sh
tests/pinned-sources.sh
bin/build --package hello-bin
sudo pacman -U build-output/edge/x86_64/hello-bin-1.2.3-1-x86_64.pkg.tar.zst
```

`bin/build` builds in Omarchy's builder container, as CI does. With Docker it
calls `sudo` once to fix the ownership of its output.

Check that the watch finds your current release:

```sh
python helpers/upstream-watch.py check pkgbuilds/hello-bin
```

On a current recipe it prints `"status": "skipped"` with `"reason": "already current"`.
To see the bot update the recipe, copy the checkout, set an older `pkgver` and
wrong hashes in the copy, and run `bin/sync-upstream hello-bin` there: it should
move the recipe to the newest release older than `min_release_age`, with the
hashes your manifest lists.

## 3. Send the first pull request

Commit only `pkgbuilds/hello-bin/` and open a pull request against `master`
with that one package. Say what the app is, that you maintain it upstream,
which checks you ran, and that its updates come from the `upstream`
declaration.

Omarchy builds pull requests only for trusted authors. Unless you are a
collaborator or listed in the repository's `.github/VOUCHED.td`, the pull
request shows **Awaiting build approval** (on your first one, GitHub's
"workflows awaiting approval") until a maintainer adds the `build-approved`
label. Then CI builds `x86_64` and `aarch64`, the pull request merges itself
once `result`, `self-tests` and `build-isolation` pass, and the package is
published within minutes.

## After it merges

Publish releases as usual. After each GitHub release, once it has cleared
`min_release_age`, the bot opens an update, builds it and merges it. Keep the
`vX.Y.Z` tags and the archive names stable: a renamed asset stops the updates
until the recipe is fixed.

For a packaging change at the same version, such as a new dependency, send a
pull request that edits the recipe and bumps `pkgrel`.
