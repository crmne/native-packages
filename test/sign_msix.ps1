param([Parameter(Mandatory = $true)][string]$Package)
$ErrorActionPreference = 'Stop'
$signtool = Get-ChildItem 'C:\Program Files (x86)\Windows Kits\10\bin\*\x64\signtool.exe' | Sort-Object FullName -Descending | Select-Object -First 1
if (-not $signtool) { throw 'Windows SDK SignTool is required' }
& $signtool.FullName sign /fd SHA256 /f $env:MSIX_CERT_PATH /p $env:NFPM_MSIX_PASSPHRASE $Package
if ($LASTEXITCODE -ne 0) { throw 'SignTool signing failed' }
& $signtool.FullName verify /pa $Package
if ($LASTEXITCODE -ne 0) { throw 'SignTool verification failed' }
