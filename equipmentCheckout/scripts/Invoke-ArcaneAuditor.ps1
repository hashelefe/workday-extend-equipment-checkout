<#
.SYNOPSIS
    Runs Arcane Auditor (42 Workday Extend rules) against this app.

.DESCRIPTION
    Arcane Auditor is a third-party static analyser for Workday Extend:
    https://github.com/Developers-and-Dragons/ArcaneAuditor

    It ships as a Windows .exe on the releases page, but this script runs it from
    source so nothing has to be downloaded and trusted as a binary. On first run it
    clones the repo and builds a virtualenv under -ToolRoot; later runs reuse both.

    The published package wants Python 3.12+, but running from source works on 3.11 —
    the pin only applies to installing it as a package.

.PARAMETER ToolRoot
    Where to keep the clone and virtualenv. Defaults to a stable per-user location so
    it survives reboots. Never put this inside the app folder - it must not be uploaded.

.PARAMETER Format
    console (default), json, summary, or excel.

.PARAMETER OutputFile
    Where to write the report when -Format is json or excel.

.PARAMETER FailOnAdvice
    Exit non-zero on ADVICE findings too. Use in CI.

.PARAMETER Update
    Pull the latest ArcaneAuditor before running.

.EXAMPLE
    .\scripts\Invoke-ArcaneAuditor.ps1

.EXAMPLE
    .\scripts\Invoke-ArcaneAuditor.ps1 -Format json -OutputFile audit.json
#>
[CmdletBinding()]
param(
    [string]$ToolRoot = (Join-Path $env:LOCALAPPDATA 'ArcaneAuditor'),
    [ValidateSet('console', 'json', 'summary', 'excel')]
    [string]$Format = 'console',
    [string]$OutputFile,
    [switch]$FailOnAdvice,
    [switch]$Update
)

$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 turns a native command's stderr into a terminating error when
# ErrorActionPreference is Stop - and git writes ordinary progress ("Cloning into...")
# to stderr. Run native tools through here and judge them by their exit code instead.
function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$FailureMessage
    )
    $previous = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        & $Exe @Arguments
    } finally {
        $ErrorActionPreference = $previous
    }
    if ($LASTEXITCODE -ne 0) {
        if ($FailureMessage) { throw $FailureMessage }
        throw "$Exe exited with $LASTEXITCODE"
    }
}

$appPath = Split-Path $PSScriptRoot -Parent
$repoUrl = 'https://github.com/Developers-and-Dragons/ArcaneAuditor.git'
$tag     = 'v1.2.0'
$repoDir = Join-Path $ToolRoot 'ArcaneAuditor'
$venvDir = Join-Path $repoDir '.venv'
$python  = Join-Path $venvDir 'Scripts\python.exe'

# ---- first-run setup -------------------------------------------------------
if (-not (Test-Path $repoDir)) {
    Write-Host "Cloning ArcaneAuditor $tag into $repoDir ..." -ForegroundColor Cyan
    New-Item -ItemType Directory -Force -Path $ToolRoot | Out-Null
    Invoke-Native git @('clone','--depth','1','--branch',$tag,$repoUrl,$repoDir) 'git clone failed'
} elseif ($Update) {
    Write-Host "Updating ArcaneAuditor ..." -ForegroundColor Cyan
    Invoke-Native git @('-C',$repoDir,'fetch','--tags','--depth','1') 'git fetch failed'
    Invoke-Native git @('-C',$repoDir,'checkout',$tag) 'git checkout failed'
}

if (-not (Test-Path $python)) {
    Write-Host "Creating virtualenv ..." -ForegroundColor Cyan
    Invoke-Native python @('-m','venv',$venvDir) 'python -m venv failed - is Python on PATH?'

    # Only what the CLI analysis path actually imports. The full requirements.txt
    # additionally pulls fastapi/uvicorn/pywebview for the web and desktop UIs.
    Write-Host "Installing dependencies ..." -ForegroundColor Cyan
    Invoke-Native $python @('-m','pip','install','--quiet','--upgrade','pip') 'pip upgrade failed'
    Invoke-Native $python @('-m','pip','install','--quiet','typer','lark','openpyxl','requests','aiofiles','pydantic') 'pip install failed'
}

# ---- run -------------------------------------------------------------------
$cliArgs = @('main.py', 'review-app', $appPath, '--format', $Format)
if ($OutputFile)  { $cliArgs += @('--output', $OutputFile) }
if ($FailOnAdvice) { $cliArgs += '--fail-on-advice' }

# The console formatter emits emoji; without this Windows cp1252 throws mid-report.
$env:PYTHONIOENCODING = 'utf-8'

Write-Host "Auditing $appPath ..." -ForegroundColor Cyan
Push-Location $repoDir
$previousPreference = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $python @cliArgs
    $code = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $previousPreference
    Pop-Location
}

Write-Host ""
switch ($code) {
    0 { Write-Host "Clean (exit 0)." -ForegroundColor Green }
    1 { Write-Warning "Findings need attention (exit 1)." }
    2 { Write-Warning "Usage error (exit 2) - check the path and arguments." }
    3 { Write-Warning "Analyzer error (exit 3) - parsing failed." }
}
exit $code
