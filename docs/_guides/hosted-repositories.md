---
title: Hosted package repositories
description: Publish signed APT repositories that users add once and update with their package manager.
nav_order: 13
---

# Hosted package repositories

A package attached to a GitHub release is installed once and then forgotten.
Users who add your repository instead get every update through their own
package manager. native-packages writes these repositories as static files
into a directory you choose, such as a checkout of a GitHub Pages site, and
signs them with your OpenPGP key. It only writes files: your release job
commits and pushes the directory afterwards, as it would any website change.

## 1. Make a signing key

Use a key for this repository alone, without an expiry date you might miss,
and keep its secret half out of every repository:

```sh
gpg --quick-gen-key 'Hello packages <packages@example.org>' ed25519 sign never
gpg --list-keys --with-colons packages@example.org | awk -F: '/^fpr/ { print $10; exit }'
```

The second command prints the key's full fingerprint, which goes into the
configuration. Locally, native-packages signs with the key your GnuPG agent
already holds. In CI, export the secret key and store it as a secret:

```sh
gpg --armor --export-secret-keys FINGERPRINT
```

Pass it to the publish step as `NATIVE_PACKAGES_GPG_KEY`, and the key's
passphrase, if it has one, as `NATIVE_PACKAGES_GPG_PASSPHRASE`.
native-packages removes both from its environment before running any other
program, imports the key into a temporary keyring that it deletes
afterwards, and checks every signature against the configured fingerprint
before writing it.

## 2. Configure the repositories

```yaml
apt:
  directory: ../hello-site/apt
  url: https://example.org/apt
  signing_key: 0123456789ABCDEF0123456789ABCDEF01234567
  keep: 3
```

| Field | Purpose |
| --- | --- |
| `directory` | Required. Where the repository is written, relative to the configuration file. |
| `url` | Required. The `https://` URL at which that directory is served. |
| `signing_key` | Required. The signing key's full fingerprint. |
| `keep` | How many versions of each package and architecture to keep. Defaults to `3`. |
| `suite`, `component` | APT only. Default to `stable` and `main`. |

## 3. Publish

Build as usual, then publish the build to the repositories:

```sh
native-packages build --version 1.2.3
native-packages publish --from dist/packages/1.2.3 --to github,apt
```

Each publication adds the build's packages to what the directory already
holds, removes versions beyond `keep`, and rewrites and signs the indexes. A
file that is already published can only be published again unchanged. Then
commit and push the directory.

## APT

`publish --to apt` copies each `.deb` into `pool/main/h/hello/` and writes
`dists/stable/` with `Packages` and `Packages.gz` for every architecture,
`Release`, a clearsigned `InRelease` and a detached `Release.gpg`. These are
written by native-packages itself, so no Debian tools are needed. Beside them
go the public key as `hello.gpg` and a `hello.sources` file. Users install
with:

```sh
sudo install -d -m 0755 /etc/apt/keyrings
sudo curl -fsSLo /etc/apt/keyrings/hello.gpg https://example.org/apt/hello.gpg
sudo curl -fsSLo /etc/apt/sources.list.d/hello.sources https://example.org/apt/hello.sources
sudo apt update && sudo apt install hello
```

The `.sources` file trusts this key for this repository alone. Use it on
apt 1.1 and later (Debian 9, Ubuntu 16.04 and newer).

## GitHub Pages

Serve the site from a branch or folder, and add an empty `.nojekyll` file
at its root so GitHub publishes the repository's files as they are. A
release job can check out the site beside the app:

```yaml
- uses: actions/checkout@v7
  with:
    repository: example/hello-site
    path: hello-site
    token: ${{ secrets.SITE_TOKEN }}
- run: native-packages publish --from dist/native-packages --to apt
  env:
    NATIVE_PACKAGES_GPG_KEY: ${{ secrets.PACKAGES_GPG_KEY }}
- run: |
    cd hello-site
    git add -A
    git commit -m "Publish hello $VERSION"
    git push
```

With `directory: hello-site/apt` in the configuration, the repository lands
in that checkout. GitHub Pages serves sites of up to 1 GB, so keep `keep` low
for large packages.
