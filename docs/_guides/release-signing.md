---
title: Release signatures and attestations
description: Share release signing machinery while keeping application keys, approval policy and build identity separate.
nav_order: 10
---

# Release signatures and attestations

Publisher signatures authorize release downloads. Build attestations identify
which repository, workflow and commit produced an artifact. Use both when your
application downloads its own updates. Neither proves the source code is safe.
These features are available in native-packages 0.7.0 and later. Use the
released gem for local commands and pin composite actions to the reviewed
commit behind the corresponding release tag.

## Keep the trust policy in the application

Each application owns its private key, committed public key, updater verification
and release approval rules. Do not share a key between unrelated applications,
store private keys in native-packages, or fetch an updater's trust root from the
same release it is checking. There is no unsigned fallback when signing is used.

Store the private PKCS#8 PEM key in a protected GitHub environment in the
application repository. Restrict that environment to release tags and require
maintainer approval. Keep an encrypted backup outside GitHub. Approval should
cover the exact commit, build results and artifacts, not just a version label.
Only the final signing job needs this secret. PR/build jobs do not.

This uses GitHub-hosted key custody, not an independent offline authority.
Maintain separate Apple notarization and Windows Authenticode credentials where
needed; a checksum signature does not replace either platform's signing system.

## Generate, sign and verify locally

Put only the finished release artifacts in a staging directory. Do not include
private keys, source checkout folders or intermediate build files. Keep the
public key outside this directory too.

```sh
native-packages release-checksums dist/release --output dist/release/checksums.txt
native-packages sign-checksums dist/release/checksums.txt --public-key assets/update-public-key.hex
native-packages verify-checksums dist/release/checksums.txt --public-key assets/update-public-key.hex
```

Provide the private PEM through `NATIVE_PACKAGES_SIGNING_KEY` using your secret
manager. `--key-env VARIABLE` selects another environment variable, not its
value. Never put a private key on a command line or enable shell tracing.
Signing reads the key in-process, removes it from that process's environment,
and creates no private key file. It does not promise secure erasure of Ruby or
OpenSSL memory. Missing, malformed, wrong or non-Ed25519 keys fail closed.

The output is a deterministic, sorted SHA-256 manifest plus a raw 64-byte
Ed25519 signature over its exact bytes. The public-key file is 32 bytes encoded
as 64 hex digits. This is Ed25519, not Ed25519ph. Signing verifies the listed
files first; verification authenticates the manifest before reading its paths.
Metadata is limited to 1 MiB. Filenames must be flat ASCII names beginning with
a letter or digit, using letters, digits, dots, underscores, plus or minus.
Symlinks, directories, duplicate names (including case collisions), path
traversal and self-references are rejected. Existing outputs are not overwritten.
Upload artifacts, `checksums.txt` and `checksums.txt.sig` together.

These are explicit commands. Existing `build --release` and `publish` behavior
is unchanged: they do not silently gain signature verification or signing.
To verify a downloaded release, stage its files and explicitly run
`verify-checksums` with your locally trusted public key before using those files.
Package publication's separate `packaging-checksums.txt` is also unchanged.

## Attest in the application's build job

The examples use `v0.7.0` for readability. For release workflows, replace it
with that release's reviewed full commit SHA, not a mutable branch.
After producing the final package, before uploading it, add this step to the
job that built it:

```yaml
permissions:
  contents: read
  id-token: write
  attestations: write
steps:
  # Existing checkout, build, platform signing and packaging steps go here.
  - uses: crmne/native-packages/.github/actions/attest@v0.7.0
    with:
      subject-path: dist/*.tar.gz
```

`subject-path` accepts a glob or newline-separated list. The composite action
runs inside the calling job, preserving the application's build identity.
It uses GitHub's pinned `actions/attest` implementation and needs no publisher
key. It exposes `bundle-path` and `attestation-url` outputs. Each platform job
attests its own final artifacts. A packaging-only job can attest the package it
made, but that does not establish provenance for an earlier executable build.

Consumers can verify a file with:

```sh
gh attestation verify FILE --repo OWNER/APP
```

For tighter policy, also constrain `--signer-workflow` and `--source-digest`.
See [GitHub's artifact attestation documentation](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations).

## Sign in the approved publication job

After every build passes, download the final artifacts into a flat directory in
a fresh signing job. Set its `environment: release-signing` in the app workflow
and install Ruby 3.2 or later with Ed25519-capable OpenSSL before the signing
step. Then call:

```yaml
- uses: crmne/native-packages/.github/actions/sign-release@v0.7.0
  with:
    directory: dist/release
    public-key: assets/update-public-key.hex
  env:
    NATIVE_PACKAGES_SIGNING_KEY: ${{ secrets.UPDATE_SIGNING_KEY }}
```

The action uses the CLI from its own pinned source commit. It neither installs
the gem nor runs project hooks, builds, tags, publishes or approves deployments.
The caller checks out its committed public key and owns the publication step.
For an existing secret variable name, set the action's `key-env` input.
The action requires a fresh directory without an old checksum/signature pair.

## Updater integration and key changes

Embed the public key in the app. Reject missing or invalid signatures before
accepting a checksum or downloading a package. Bind checksums to exact
version/platform filenames, reject downgrade/replay updates, and retain package
size checks, installation acknowledgement and rollback.

The initial signature-enforcing version needs a trusted installation. Old
hash-only clients are not protected until upgraded. Changing the key requires a
tested compatibility transition in each app; the single-signature format here
does not provide automatic key rotation. If a key is lost or compromised, stop
automatic publication, revoke the secret and use an independently verified
recovery installer. Do not replace an updater's trusted key from unsigned data.
