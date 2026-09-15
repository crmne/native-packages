---
title: Apple signing and notarization
description: Configure Apple credentials, automatically sign and notarize DMGs, and prepare portable macOS archives.
nav_order: 6
---

# Apple signing and notarization

native-packages can sign your macOS app and submit it to Apple's notarization
service before recording the package checksum. For a DMG, it also attaches
Apple's approval ticket to the image, a step called **stapling**.

This guide assumes you already have a working [DMG target](native-recipes.md).
It also covers portable downloads such as a command-line app distributed as a
`.tar.gz` archive.

## 1. Set up your Apple credentials

You need a Developer ID Application certificate and its private key, an Apple
Developer Program team, and an app-specific password for the Apple Account
used for notarization.

Export the certificate and private key as a password-protected PKCS#12 (`.p12`)
file. Base64-encode that file for `APPLE_CERTIFICATE_P12`, and configure all six
values as environment variables in the macOS release job:

| Variable | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | Base64-encoded `.p12` certificate and private key. |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting the `.p12` export. |
| `APPLE_SIGNING_IDENTITY` | Exact identity, such as `Developer ID Application: Your Name (TEAMID)`. |
| `APPLE_ID` | Apple Account email. |
| `APPLE_TEAM_ID` | Developer Program Team ID. |
| `APPLE_APP_PASSWORD` | Apple Account app-specific password. |

Store the values as CI secrets and expose them to your macOS release job.
The tool reads environment variables; it does not retrieve secrets for you.
Apple documents [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/)
and [notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).

With none of these variables set, builds remain unsigned. With all six set,
signing and notarization are automatic. An incomplete set fails with the names
of the missing variables. Linux and Windows targets ignore these variables.

## 2. Build the DMG

Run the normal command on macOS:

```sh
native-packages build --version 1.2.3 --target macos-arm64 --output dist/macos-packages
```

The build performs these steps:

1. Copies and checks your prepared app.
2. Signs code inside the copy, working from nested code outward.
3. Runs your DMG script with the signed copy as `@PAYLOAD@`.
4. Runs any `after_package` hook.
5. Signs the DMG, submits it to Apple, and waits for acceptance.
6. Staples and validates the ticket, then verifies the image.
7. Records the final checksum and notarization result in `build.json`.

Your original app directory stays unchanged. The manifest records Apple
acceptance, the submission ID, and stapling. Failure or timeout prevents a
completed build from being produced. Submissions can wait up to 30 minutes;
Apple may continue processing a submission after a timeout.

## 3. Keep your script focused on the image

Your DMG script should copy `@PAYLOAD@` with its signatures intact and create
the declared image. Remove duplicate Apple signing and notarization steps
from the script or `after_package` hook when adopting the automatic flow.

Signing uses a secure timestamp and hardened runtime. Existing entitlements
and requirements are preserved. Supply the entitlements your app needs in
its build process; native-packages does not add exceptions for you.

## Prepare a portable archive

For a portable executable and its libraries, prepare the complete directory,
including notices and other runtime files. Then run:

```sh
native-packages notarize-macos portable-input --output signed/hello-1.2.3-macos-arm64
tar czf hello-1.2.3-macos-arm64.tar.gz -C signed hello-1.2.3-macos-arm64
```

The destination must be new and outside the input. This command requires no
`native-packages.yaml`.

With credentials, it signs a copy and submits that code through a temporary
ZIP. After Apple accepts it, the command staples any `.app` bundles and makes
the signed directory available. Archive only that returned directory and
preserve its signed contents.

Without credentials, the command copies the input unchanged and reports that
signing and notarization were skipped.

Standalone executables cannot carry a stapled ticket. They rely on Gatekeeper's
online ticket lookup, so a notarized portable executable does not have the same
offline behavior as a stapled app or DMG.

## Check the download

Test a freshly downloaded package on macOS with Gatekeeper enabled. Also test
your app's startup, required entitlements, supported macOS versions, and
upgrade behavior. Apple acceptance is recorded separately from installation
testing; the build manifest still reports installation as `not-tested`.

## How credentials are handled

The tool imports credentials into a temporary keychain. Signing calls under
the same OS user share a lock while updating keychain search entries. Cleanup
removes the temporary keychain and its entry while preserving other entries
and the default keychain. Secret values are excluded from build manifests and
redacted from tool errors.
