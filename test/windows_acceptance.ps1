$ErrorActionPreference = 'Stop'
$root = Join-Path $env:RUNNER_TEMP 'native-packages-msix'
New-Item -ItemType Directory -Force -Path $root | Out-Null
$cert = New-SelfSignedCertificate -Type Custom -Subject 'CN=NativePackagesTest' -KeyUsage DigitalSignature -FriendlyName 'Native Packages CI' -CertStoreLocation 'Cert:\CurrentUser\My' -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.3', '2.5.29.19={text}')
$password = ConvertTo-SecureString 'ephemeral-ci-fixture' -AsPlainText -Force
$env:MSIX_CERT_PATH = Join-Path $root 'test.pfx'
$env:NFPM_MSIX_PASSPHRASE = 'ephemeral-ci-fixture'
$env:MSIX_SIGN_SCRIPT = Join-Path $PSScriptRoot 'sign_msix.ps1'
Export-PfxCertificate -Cert $cert -FilePath $env:MSIX_CERT_PATH -Password $password | Out-Null
$publicCert = Join-Path $root 'test.cer'
Export-Certificate -Cert $cert -FilePath $publicCert | Out-Null
Import-Certificate -FilePath $publicCert -CertStoreLocation 'Cert:\LocalMachine\TrustedPeople' | Out-Null
try {
  ruby -Ilib test/build_acceptance.rb (Join-Path $root 'app') --windows
  if ($LASTEXITCODE -ne 0) { throw 'MSIX build failed' }
  foreach ($version in @('1.2.3', '1.2.4')) {
    $package = Get-ChildItem -Path (Join-Path $root "app/dist/packages/$version/packages/windows-amd64/msix/*.msix")
    Add-AppxPackage -Path $package.FullName
    $installed = Get-AppxPackage -Name 'native-packages-smoke'
    if (-not $installed) { throw 'MSIX registration missing' }
    if ($installed.Version -ne "$version.0") { throw "Unexpected installed version $($installed.Version)" }
    & (Join-Path $installed.InstallLocation 'app.exe')
    if ($LASTEXITCODE -ne 0) { throw 'Installed Windows executable failed' }
  }
  Get-AppxPackage -Name 'native-packages-smoke' | Remove-AppxPackage
  if (Get-AppxPackage -Name 'native-packages-smoke') { throw 'MSIX removal failed' }
} finally {
  Get-AppxPackage -Name 'native-packages-smoke' | Remove-AppxPackage
  Remove-Item "Cert:\CurrentUser\My\$($cert.Thumbprint)" -ErrorAction SilentlyContinue
  Remove-Item "Cert:\LocalMachine\TrustedPeople\$($cert.Thumbprint)" -ErrorAction SilentlyContinue
}
