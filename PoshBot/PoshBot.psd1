#
# Module manifest for module 'PoshBot'
#

@{

# Script module or binary module file associated with this manifest.
RootModule = 'PoshBot.psm1'

# Version number of this module.
ModuleVersion = '0.14.33'

# Supported PSEditions
# CompatiblePSEditions = @()

# ID used to uniquely identify this module
GUID = '7bfb126c-b432-4921-989a-9802f525693f'

# Author of this module
Author = 'Andrew V. Golubenkoff'

# Company or vendor of this module
CompanyName = 'FUIB'

# Copyright statement for this module
Copyright = '(c) Andrew V. Golubenkoff.'

# Description of the functionality provided by this module
Description = 'FUIB Powershell-based bot. PowerShell modules are loaded into PoshBot and instantly become available as bot commands.'

# Minimum version of the Windows PowerShell engine required by this module
PowerShellVersion = '5.0'

# Name of the Windows PowerShell host required by this module
# PowerShellHostName = ''

# Minimum version of the Windows PowerShell host required by this module
# PowerShellHostVersion = ''

# Minimum version of Microsoft .NET Framework required by this module. This prerequisite is valid for the PowerShell Desktop edition only.
# DotNetFrameworkVersion = ''

# Minimum version of the common language runtime (CLR) required by this module. This prerequisite is valid for the PowerShell Desktop edition only.
# CLRVersion = ''

# Processor architecture (None, X86, Amd64) required by this module
# ProcessorArchitecture = ''

# Modules that must be imported into the global environment prior to importing this module
RequiredModules = @(
    @{ModuleName = 'Configuration'; ModuleVersion = '1.3.1'}
    @{ModuleName = 'PSSlack';       ModuleVersion = '1.0.6'}
)

# Assemblies that must be loaded prior to importing this module
# RequiredAssemblies = @()

# Script files (.ps1) that are run in the caller's environment prior to importing this module.
ScriptsToProcess = @(
    'PoshBotAttribute.ps1'
)

# Type files (.ps1xml) to be loaded when importing this module
# TypesToProcess = @()

# Format files (.ps1xml) to be loaded when importing this module
# FormatsToProcess = @()

# Modules to import as nested modules of the module specified in RootModule/ModuleToProcess
# NestedModules = @()

# Functions to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no functions to export.
FunctionsToExport = @(
    'Get-PoshBot'
    'Get-PoshBotConfiguration'
    'Get-PoshBotStatefulData'
    'New-PoshBotAce'
    'New-PoshBotBackend'
    'New-PoshBotConfiguration'
    'New-PoshBotDiscordBackend'
    'New-PoshBotFileUpload'
    'New-PoshBotInstance'
    'New-PoshBotMiddlewareHook'
    'New-PoshBotScheduledTask'
    'New-PoshBotSlackBackend'
    'New-PoshBotSlackAppSMBackend'
    'New-PoshBotTeamsBackend'
    'New-HelloPlugin'
    'New-PoshBotCardResponse'
    'New-PoshBotTextResponse'
    'Remove-PoshBotStatefulData'
    'Save-PoshBotConfiguration'
    'Set-PoshBotStatefulData'
    'Start-PoshBot'
    'Stop-Poshbot'
)

# Cmdlets to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no cmdlets to export.
CmdletsToExport = @()

# Variables to export from this module
VariablesToExport = @()

# Aliases to export from this module, for best performance, do not use wildcards and do not delete the entry, use an empty array if there are no aliases to export.
AliasesToExport = @()

# DSC resources to export from this module
# DscResourcesToExport = @()

# List of all modules packaged with this module
# ModuleList = @()

# List of all files packaged with this module
# FileList = @()

# Private data to pass to the module specified in RootModule/ModuleToProcess. This may also contain a PSData hashtable with additional module metadata used by PowerShell.
PrivateData = @{

    PSData = @{

        # Tags applied to this module. These help with module discovery in online galleries.
        Tags = @('PoshBot', 'ChatOps', 'Bot')

        # A URL to the license for this module.
        LicenseUri = 'https://raw.githubusercontent.com/golubenkoff/PoshBot/master/LICENSE'

        # A URL to the main website for this project.
        ProjectUri = 'https://github.com/golubenkoff/PoshBot'

        # A URL to an icon representing this module.
        IconUri = 'https://raw.githubusercontent.com/golubenkoff/PoshBot/master/Media/poshbot_logo_thumb_256.png'

        # ReleaseNotes of this module
        ReleaseNotes = 'https://raw.githubusercontent.com/golubenkoff/PoshBot/master/CHANGELOG.md'
    } # End of PSData hashtable

} # End of PrivateData hashtable

# HelpInfo URI of this module
# HelpInfoURI = ''

# Default prefix for commands exported from this module. Override the default prefix using Import-Module -Prefix.
# DefaultCommandPrefix = ''

}
