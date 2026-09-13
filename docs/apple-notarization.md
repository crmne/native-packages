# Apple signing and notarization

Since native-packages 0.5.0, a native macOS DMG build automatically signs and
notarizes when all six environment variables below are present. No variables
preserves existing local/unsigned behavior. Any incomplete set fails with the
missing variable names before packaging. Linux and Windows targets ignore these
Apple variables. `validate` and `build --dry-run` remain offline.

| Environment variable | Value |
| --- | --- |
| `APPLE_CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate and private key, exported as PKCS#12 |
| `APPLE_CERTIFICATE_PASSWORD` | Password protecting that export |
| `APPLE_SIGNING_IDENTITY` | Exact `Developer ID Application: Name (TEAMID)` identity |
| `APPLE_ID` | Apple Account email |
| `APPLE_TEAM_ID` | Developer Program Team ID |
| `APPLE_APP_PASSWORD` | Apple Account app-specific password |

Store these in CI secrets and expose them as environment variables only in the
trusted macOS release job. The gem does not fetch secrets from a password manager
or GitHub. A free Apple account cannot replace Developer Program membership and
a valid Developer ID Application certificate.

## Native DMG builds

Build the application's complete `.app` and prepare its configured native input
first, then run the normal command on macOS:

```sh
native-packages --config native-packages.macos.yaml build \
  --version 1.2.3 --target macos-universal --output dist/macos-packages
```

The gem imports the certificate and notary credentials into a fresh, temporary
keychain. It never replaces the default keychain or its search list, and deletes
its keychain after success or failure. Credential values are excluded from
manifests and redacted from tool errors.

The input is copied and checked before signing. All Mach-O code and nested
frameworks/app bundles in the owned copy are signed from the inside out with a
secure timestamp and hardened runtime. Existing entitlements and requirements
are preserved; the gem does not invent exceptions such as disabling library
validation. The application remains responsible for any required entitlements.

Signing finishes **before `native.command`**. Its recipe must copy `@PAYLOAD@`
unchanged, create the configured DMG, and avoid replacing signatures with ad-hoc
ones. The original application input remains unchanged. `after_package` still
runs, then the gem signs the DMG, submits it with `notarytool`, waits for Apple's
`Accepted` result, staples and validates the ticket, and verifies the image.
Only then are package hashes and the build manifest written. The manifest's
package validation records Apple acceptance, submission ID and stapling.

Remove redundant Apple signing and notarization from application hooks when
adopting this flow. Existing Inno/MSIX signing hooks remain independent.
Submission waits up to 30 minutes; failure or timeout prevents publication of a
completed build. Apple may continue processing a timed-out submission.

## Portable macOS archives

A standalone executable cannot carry a stapled ticket, and Apple does not accept
`.tar.gz` as a submission. Prepare the entire portable tree, including binaries,
dylibs, models and notices, then use:

```sh
native-packages notarize-macos portable-input \
  --output signed/Example-1.2.3-macos-arm64
tar czf Example-1.2.3-macos-arm64.tar.gz \
  -C signed Example-1.2.3-macos-arm64
```

The destination must be new and outside the input directory. This command needs
no application configuration. With credentials, it signs only its copy, submits
that exact code through a temporary ZIP, waits for acceptance, and staples and
validates any `.app` bundles. It then publishes the signed directory atomically.
Archive only that returned tree; do not modify its signed contents. Without
credentials it copies the input unchanged and explicitly reports that signing
and notarization were skipped.

Standalone binaries rely on Gatekeeper's online ticket lookup. An accepted
portable submission does not claim offline stapling support for raw executables.
Notarization also does not replace app startup, model/GPU, entitlement, OS-version
or installation testing. Test a fresh downloaded package with Gatekeeper before
announcing the first notarized release.

Apple references: [Developer ID certificates](https://developer.apple.com/help/account/certificates/create-developer-id-certificates/),
[signing distribution code](https://developer.apple.com/documentation/xcode/creating-distribution-signed-code-for-the-mac/),
[notarization](https://developer.apple.com/documentation/security/notarizing-macos-software-before-distribution).
