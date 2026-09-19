<#
.SYNOPSIS
    Stamps your tenant's deployed app id into the GraphQL queries.

.DESCRIPTION
    Workday generates the GraphQL schema names from the app id that App Hub assigns
    when you run `wdcli app create`. That id is not knowable until the app exists, so
    the .graphquery files ship with two placeholders:

        __APPID__          ->  equipmentCheckout_ab12cd_     (camelCase, field names)
        __APPIDPASCAL__    ->  EquipmentCheckout_ab12cd_     (PascalCase, type names)

    Run this once after creating the app, and again with -OldId if the id ever changes.

.PARAMETER AppId
    The deployed app id WITHOUT a trailing underscore, e.g. equipmentCheckout_ab12cd.
    Find it with `wdcli app info equipmentCheckout`, or read it off any generated
    query name in App Builder's GraphQL explorer.

.PARAMETER OldId
    Use when the queries were already stamped and you need to re-point them at a
    different id. Pass the previous id, also without a trailing underscore.

.EXAMPLE
    .\scripts\Set-AppId.ps1 -AppId equipmentCheckout_ab12cd

.EXAMPLE
    .\scripts\Set-AppId.ps1 -AppId equipmentCheckout_xy99zz -OldId equipmentCheckout_ab12cd
#>
[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')]
    [string]$AppId,

    [ValidatePattern('^[A-Za-z][A-Za-z0-9_]*$')]
    [string]$OldId
)

$ErrorActionPreference = 'Stop'

$queryDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'presentation\graphQueries'
if (-not (Test-Path $queryDir)) {
    throw "Could not find graphQueries directory at $queryDir"
}

# camelCase prefix for field names, PascalCase for type names; both carry the underscore
$camel  = $AppId + '_'
$pascal = $AppId.Substring(0, 1).ToUpper() + $AppId.Substring(1) + '_'

if ($OldId) {
    $findCamel  = $OldId + '_'
    $findPascal = $OldId.Substring(0, 1).ToUpper() + $OldId.Substring(1) + '_'
} else {
    $findCamel  = '__APPID__'
    $findPascal = '__APPIDPASCAL__'
}

$files   = Get-ChildItem -Path $queryDir -Filter *.graphquery
$touched = 0

foreach ($file in $files) {
    $original = Get-Content -Path $file.FullName -Raw
    $updated  = $original.Replace($findPascal, $pascal).Replace($findCamel, $camel)

    if ($updated -ne $original) {
        if ($PSCmdlet.ShouldProcess($file.Name, "rewrite app id")) {
            # utf8 without BOM keeps the Extend upload parser happy
            [System.IO.File]::WriteAllText($file.FullName, $updated, (New-Object System.Text.UTF8Encoding $false))
        }
        $touched++
        Write-Host "  updated  $($file.Name)"
    } else {
        Write-Host "  skipped  $($file.Name)  (nothing to replace)"
    }
}

Write-Host ""
if ($touched -eq 0) {
    Write-Warning "No files changed. Looked for '$findCamel'. If the queries were already stamped, re-run with -OldId <previous id>."
} else {
    Write-Host "Stamped $touched of $($files.Count) query files with '$camel'." -ForegroundColor Green
    Write-Host "Next: python scripts/validate.py, then wdcli app upload"
}
