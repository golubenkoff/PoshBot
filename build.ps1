
[cmdletbinding(DefaultParameterSetName = 'task')]
param(
    # Build task(s) to execute
    [parameter(ParameterSetName = 'task', Position = 0)]
    [ValidateSet('default','Init','Test','Analyze','Pester','Build','Compile','Clean','Publish','Build-Docker','Publish-Docker','RegenerateHelp','UpdateMarkdownHelp','CreateExternalHelp')]
    [string[]]$Task = 'default',

    # Bootstrap dependencies
    [switch]$Bootstrap,

    [hashtable]$Properties = @{},

    # Manifest of the customized PSSlack (PSSlackAG 1.0.6a) that production uses.
    # It is imported by path before build/tests, so PoshBot is built and tested against it
    # (RequiredModules asks for PSSlack 1.0.6, which this build satisfies).
    [string]$PSSlackPath = (Join-Path -Path $PSScriptRoot -ChildPath '..\..\FUIB\ospbot\Modules\PSSlackAG\1.0.6a\PSSlack.psd1'),

    # List available build tasks
    [parameter(ParameterSetName = 'Help')]
    [switch]$Help
)

$ErrorActionPreference = 'Stop'

# Bootstrap dependencies
if ($Bootstrap.IsPresent) {
    Get-PackageProvider -Name Nuget -ForceBootstrap > $null
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
    if (-not (Get-Module -Name PSDepend -ListAvailable)) {
        Install-Module -Name PSDepend -Repository PSGallery -Scope CurrentUser -Force
    }
    Import-Module -Name PSDepend -Verbose:$false
    Invoke-PSDepend -Path './requirements.psd1' -Install -Import -Force -WarningAction SilentlyContinue
}

# Use the customized PSSlack (not the PSGallery one)
if (Test-Path -LiteralPath $PSSlackPath) {
    Import-Module -Name (Resolve-Path -LiteralPath $PSSlackPath).Path -Force -Verbose:$false
    $pssModule = Get-Module -Name PSSlack
    Write-Host "Using PSSlack [$($pssModule.Version)] from [$($pssModule.ModuleBase)]"
} else {
    Write-Warning "Customized PSSlack not found at [$PSSlackPath]. The PSGallery version will be used. Pass -PSSlackPath <path to PSSlack.psd1>."
}

# Execute psake task(s)
$psakeFile = './psakeFile.ps1'
if ($PSCmdlet.ParameterSetName -eq 'Help') {
    Get-PSakeScriptTasks -buildFile $psakeFile  |
        Format-Table -Property Name, Description, Alias, DependsOn
} else {
    Set-BuildEnvironment -Force

    Invoke-psake -buildFile $psakeFile -taskList $Task -properties $properties -nologo
    exit ( [int]( -not $psake.build_success ) )
}
