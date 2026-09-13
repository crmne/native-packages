$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$compiler = & $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (!$compiler) { throw 'Native fixture requires Microsoft C++ Build Tools' }
$vcvars = Join-Path $compiler 'VC\Auxiliary\Build\vcvars64.bat'
$variables = & $env:ComSpec /d /c "call `"$vcvars`" >nul && set"
if ($LASTEXITCODE -ne 0) { throw 'Unable to load the C++ compiler environment' }
foreach ($line in $variables) {
    if ($line -match '^([^=]+)=(.*)$' -and $Matches[1] -notin @('HOME', 'CODEX_HOME')) {
        [Environment]::SetEnvironmentVariable($Matches[1], $Matches[2], 'Process')
    }
}

$installedTool = $null
try {
    if (!$env:NATIVE_PACKAGES_ISCC) {
        $toolsRoot = Join-Path $env:RUNNER_TEMP 'native-inno-tools'
        if (Test-Path $toolsRoot) { throw 'Acceptance tool directory already exists' }
        $null = New-Item -ItemType Directory -Path $toolsRoot
        $download = Join-Path $toolsRoot 'innosetup-6.7.3.exe'
        Invoke-WebRequest -Uri 'https://github.com/jrsoftware/issrc/releases/download/is-6_7_3/innosetup-6.7.3.exe' -OutFile $download
        if ((Get-Item $download).Length -ne 10592232 -or (Get-FileHash -Algorithm SHA256 $download).Hash -ne '9c73c3bae7ed48d44112a0f48e66742c00090bdb5bef71d9d3c056c66e97b732') {
            throw 'Inno installer checksum mismatch'
        }
        $signature = Get-AuthenticodeSignature $download
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'Pyrsys B.V.') {
            throw 'Unexpected Inno publisher signature'
        }
        $installedTool = Join-Path $toolsRoot 'compiler'
        $p = Start-Process -FilePath $download -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/SP-', '/CURRENTUSER', '/NOICONS', ('/DIR=' + $installedTool)) -PassThru
        $null = $p.Handle
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) { throw "Inno installation failed: $($p.ExitCode)" }
        $env:NATIVE_PACKAGES_ISCC = Join-Path $installedTool 'ISCC.exe'
    }
    if (!(Test-Path $env:NATIVE_PACKAGES_ISCC)) { throw 'Inno compiler is missing' }
    & ruby -Ilib test/native_acceptance.rb (Join-Path $env:RUNNER_TEMP 'native-inno-acceptance')
    if ($LASTEXITCODE -ne 0) { throw 'Native Inno acceptance failed' }
} finally {
    if ($installedTool -and (Test-Path (Join-Path $installedTool 'unins000.exe'))) {
        $p = Start-Process -FilePath (Join-Path $installedTool 'unins000.exe') -ArgumentList @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART') -PassThru
        $null = $p.Handle
        $p.WaitForExit()
        if ($p.ExitCode -ne 0) { throw "Acceptance tool removal failed: $($p.ExitCode)" }
    }
}
