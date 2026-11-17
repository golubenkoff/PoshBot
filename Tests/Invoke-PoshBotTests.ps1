# Runs the PoshBot Pester tests in a clean process (called by the psake 'Pester' task).
# Running Pester inside the psake session fails on Windows PowerShell ("Pester\SafeGetCommand is not recognized"),
# so the tests are isolated in their own process.
param(
    [Parameter(Mandatory)][string]$ProjectRoot,
    [Parameter(Mandatory)][string]$OutputDir,
    [Parameter(Mandatory)][string]$ResultsXml,
    [string]$PSSlackPath
)

$ErrorActionPreference = 'Stop'

# Customized PSSlack (PSSlackAG) - same as the production bot uses
if ($PSSlackPath -and (Test-Path -LiteralPath $PSSlackPath)) {
    Import-Module -Name $PSSlackPath -Force -Verbose:$false
}

Import-Module BuildHelpers -Verbose:$false
Set-BuildEnvironment -Path $ProjectRoot -Force | Out-Null

# Tests use Pester 3/4 syntax (Should Be). 4.10.1 is the last 4.x release.
Import-Module Pester -RequiredVersion 4.10.1

$env:PSModulePath = $OutputDir + [IO.Path]::PathSeparator + $env:PSModulePath
$moduleDir = Join-Path -Path $OutputDir -ChildPath $env:BHProjectName
Import-Module -Name $moduleDir -Force -Verbose:$false -WarningAction SilentlyContinue

$result = Invoke-Pester -Path (Join-Path -Path $ProjectRoot -ChildPath 'Tests') -PassThru -OutputFile $ResultsXml -OutputFormat NUnitXml

# Tests start background jobs (bot instances); a plain 'exit' waits for them and hangs, so terminate explicitly
Get-Job -ErrorAction SilentlyContinue | Remove-Job -Force -ErrorAction SilentlyContinue
[Environment]::Exit([int]$result.FailedCount)
