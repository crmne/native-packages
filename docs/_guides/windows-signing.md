---
title: Windows code signing
description: Sign Windows executables and installers with Azure Artifact Signing, from GitHub Actions through OIDC, with no stored secret.
nav_order: 7
---

# Windows code signing

native-packages can sign your Windows app with
[Azure Artifact Signing](https://learn.microsoft.com/azure/artifact-signing/)
(formerly Trusted Signing). It signs the executables and libraries that go
into your MSI or Inno Setup installer, then the installer itself, before
recording the package checksum. Every signature uses SHA-256 and Microsoft's
RFC 3161 timestamp, and is checked afterwards.

Signed downloads name your organization as the publisher in Windows' security
prompts. A signature does not silence SmartScreen at once: reputation builds as
people download releases signed by the same publisher, so keep signing every
release with the same certificate profile.

This guide assumes a working [MSI or Inno target](native-recipes.md). It also
covers files built outside native-packages, such as a portable ZIP's
executable or a setup program your workflow compiles itself.

## What you need

- An Azure subscription with an Artifact Signing account, and a **Public
  Trust** certificate profile. Creating the profile needs Microsoft's identity
  validation of your organization, which can take several business days.
- An x64 Windows machine or runner for signing, such as GitHub's
  `windows-latest`. The signing tools are x64 builds; sign Arm64 apps on x64.
- No client secret and no certificate file: signing uses your Azure CLI
  sign-in, which in GitHub Actions comes from an OIDC token.

## 1. Set up the account and an identity that may sign

In the Azure portal (or with Terraform or the Azure CLI):

1. Create an Artifact Signing account. Note its endpoint, which depends on
   the region, such as `https://weu.codesigning.azure.net/` for West Europe.
2. Under **Identity validation**, request a Public Trust validation for your
   organization and complete it.
3. Create a certificate profile of type **Public Trust** from that identity.
4. Create a Microsoft Entra app registration for your repository and give its
   service principal the **Artifact Signing Certificate Profile Signer** role
   on the account.

## 2. Trust your GitHub workflow, with the right subject

Add a federated credential to the app registration so that jobs in one GitHub
environment can sign in as it:

| Field | Value |
| --- | --- |
| Issuer | `https://token.actions.githubusercontent.com` |
| Audience | `api://AzureADTokenExchange` |
| Subject | The subject your repository's tokens carry, ending in `:environment:windows-signing` |

The subject must match the token character for character. Many repositories
now present GitHub's **immutable** subject, which names the owner and the
repository by their numeric IDs as well as their names:

```text
repo:OWNER@OWNER_ID/REPOSITORY@REPOSITORY_ID:environment:windows-signing
```

A credential with the familiar `repo:OWNER/REPOSITORY:environment:windows-signing`
then fails with `AADSTS700213: No matching federated identity record found`.
Read the prefix your repository uses and append the environment:

```sh
gh api repos/OWNER/REPOSITORY/actions/oidc/customization/sub --jq .sub_claim_prefix
```

For example, `repo:crmne@106617/zapfast@1350713137` becomes the subject
`repo:crmne@106617/zapfast@1350713137:environment:windows-signing`. The
immutable form is also safer: a renamed or recreated repository cannot take
over the trust.

## 3. Create the GitHub environment

In your repository's **Settings → Environments**, create `windows-signing`.
Under **Deployment branches and tags**, allow only your release tags, such as
`v*`, so that only a release run can get a token. Add these environment
variables. None of them is secret:

| Variable | Value |
| --- | --- |
| `AZURE_CLIENT_ID` | The app registration's application (client) ID. |
| `AZURE_TENANT_ID` | Your Microsoft Entra tenant ID. |
| `AZURE_SUBSCRIPTION_ID` | The subscription holding the signing account. |
| `AZURE_SIGNING_ENDPOINT` | The account's endpoint, such as `https://weu.codesigning.azure.net/`. |
| `AZURE_SIGNING_ACCOUNT` | The Artifact Signing account name. |
| `AZURE_SIGNING_PROFILE` | The certificate profile name. |

With the GitHub CLI:

```sh
gh api -X PUT repos/OWNER/REPOSITORY/environments/windows-signing \
  -F 'deployment_branch_policy[protected_branches]=false' \
  -F 'deployment_branch_policy[custom_branch_policies]=true'
gh api -X POST repos/OWNER/REPOSITORY/environments/windows-signing/deployment-branch-policies \
  -f name='v*' -f type=tag
echo https://weu.codesigning.azure.net/ | gh variable set AZURE_SIGNING_ENDPOINT -R OWNER/REPOSITORY -e windows-signing
```

## 4. Turn signing on in the configuration

```yaml
windows:
  signing:
    provider: azure-artifact-signing
    description: Hello
    description_url: https://example.org/hello
    publisher: Example Ltd
```

`provider` is required. `description` is the program name Windows shows when
an installer asks for permission; it defaults to the package name.
`description_url` defaults to `nfpm.homepage`. With `publisher`, every
signature must name exactly that organization, which catches a wrong
certificate profile before release.

The account itself comes from `AZURE_SIGNING_ENDPOINT`, `AZURE_SIGNING_ACCOUNT`
and `AZURE_SIGNING_PROFILE`, so the same configuration builds unsigned packages
locally and in pull requests. With none of them set, builds stay unsigned. With
all three, signing is automatic. An incomplete set fails with the names of the
missing variables.

## 5. Sign in the release workflow

The Windows job enters the environment, signs in with
[`azure/login`](https://github.com/Azure/login), and passes the environment's
variables to native-packages:

```yaml
jobs:
  windows:
    runs-on: windows-latest
    environment: windows-signing
    permissions:
      contents: read
      id-token: write
    env:
      AZURE_SIGNING_ENDPOINT: ${{ vars.AZURE_SIGNING_ENDPOINT }}
      AZURE_SIGNING_ACCOUNT: ${{ vars.AZURE_SIGNING_ACCOUNT }}
      AZURE_SIGNING_PROFILE: ${{ vars.AZURE_SIGNING_PROFILE }}
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          ruby-version: '4.0'
      - run: gem install native-packages --version 0.11.0 --no-document
      - run: cargo build --locked --release --target x86_64-pc-windows-msvc
      - name: Sign in to Azure for code signing
        if: vars.AZURE_SIGNING_PROFILE != ''
        uses: azure/login@a641126d1b8aa4d1fa005f4f92df94a3a4c4c906 # v3.1.0
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      # Sign before anything packs the executable, so the ZIP, the setup
      # program and the MSI all carry a signed copy.
      - if: vars.AZURE_SIGNING_PROFILE != ''
        run: native-packages sign-windows target/x86_64-pc-windows-msvc/release/hello.exe
      # ... build the portable ZIP and copy the app into the MSI input ...
      - run: native-packages build --version 1.2.3 --target windows-amd64 --output dist/windows-packages
```

`native-packages build` signs the MSI or Inno installer of every Windows
native target. Sign anything else your workflow makes, such as a setup program
it compiles itself, with `sign-windows` before attesting and uploading it:

```sh
native-packages sign-windows dist/hello-v1.2.3-setup.exe
```

The `if:` conditions skip the sign-in and `sign-windows` outside the
environment, where its variables are empty; `build` then leaves the installer
unsigned. Release workflows often run on more than tags. To keep other runs
unsigned, enter the environment only on tag pushes:

```yaml
environment: ${{ github.event_name == 'push' && startsWith(github.ref, 'refs/tags/v') && 'windows-signing' || '' }}
```

## What the build does

For a Windows MSI or Inno target with signing on, `native-packages build`:

1. Copies and checks your prepared input.
2. Signs every executable and library in the copy that has no valid
   signature yet. Code that is already signed, by `sign-windows` or by its
   vendor, keeps its signature.
3. Runs your installer recipe with the signed copy as `@PAYLOAD@`.
4. Runs any `after_package` hook.
5. Signs the installer and checks that it is a valid installer of its format.
6. Checks every new signature: valid, timestamped, and from `publisher` when
   configured.
7. Records the final checksum and the signature in `build.json`.

Your original input stays unchanged. Remove any SignTool `after_package` hook
when adopting this. MSIX targets are not signed automatically: their manifest
must name the certificate's exact subject, so keep signing them in an
`after_package` hook.

`sign-windows FILE...` signs the listed files in place and checks them the
same way. It needs the `windows.signing` section and all three account
variables, and fails rather than leaving a file unsigned.

## Sign on your own computer

On x64 Windows with the [Azure CLI](https://learn.microsoft.com/cli/azure/)
and the .NET 8 or newer runtime:

```powershell
az login
$env:AZURE_SIGNING_ENDPOINT = "https://weu.codesigning.azure.net/"
$env:AZURE_SIGNING_ACCOUNT = "example"
$env:AZURE_SIGNING_PROFILE = "example"
native-packages doctor --target windows-amd64
native-packages sign-windows .\hello.exe
```

Your account needs the Certificate Profile Signer role on the signing account.
`native-packages doctor` checks the variables, the tools and the Azure CLI
sign-in without signing anything. `build --dry-run` shows whether Windows
signing is on under `windows_signing`.

## Tools and network access

Signing uses Microsoft's SignTool and the Artifact Signing client library
(dlib), the versions `azure/artifact-signing-action` 2.0.0 installs:
`Microsoft.Windows.SDK.BuildTools` 10.0.26100.4188 and
`Microsoft.ArtifactSigning.Client` 1.0.128. native-packages downloads them
from nuget.org on first use, checks each against a pinned SHA-256 on every
use, and keeps them under `%LOCALAPPDATA%\native-packages\windows-signing`.
To use local copies instead, for example without network access, set
`NATIVE_PACKAGES_SIGNTOOL` to an x64 `signtool.exe` and
`NATIVE_PACKAGES_ARTIFACT_SIGNING_DLIB` to the client's x64
`Azure.CodeSigning.Dlib.dll`.

The client library authenticates only through the Azure CLI: native-packages
excludes every other credential type, so an environment's client secret or a
developer's cached account can never sign instead. Signing reaches your
account's endpoint and Microsoft's timestamp service,
`http://timestamp.acs.microsoft.com`.

## Check the download

On Windows, check a downloaded installer:

```powershell
Get-AuthenticodeSignature .\hello-v1.2.3-windows-amd64.msi | Format-List Status, SignerCertificate, TimeStamperCertificate
```

`Status` should be `Valid`, with your organization in the signer certificate
and a timestamp. Artifact Signing certificates are valid for only a few days;
the timestamp keeps the signature valid after the certificate expires.
