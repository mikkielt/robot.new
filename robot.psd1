@{
    # Script module or binary module file associated with this manifest
    RootModule = 'Robot.psm1'
    
    # Version number of this module
    ModuleVersion = '1.0.0'
    
    # Supported PSEditions
    CompatiblePSEditions = @('Desktop', 'Core')
    
    # ID used to uniquely identify this module
    GUID = '69ca95ec-45b6-43d5-bfa8-6a2eea6ea16b'
    
    # Author of this module
    Author = 'Anward'
    
    # Company or vendor of this module
    CompanyName = 'Nerthus'
    
    # Copyright statement for this module
    Copyright = '(c) 2025 Anward. All rights reserved.'
    
    # Description of the functionality provided by this module
    Description = 'PowerShell module for managing and processing lore and metadata from Nerthus repository'
    
    # Minimum version of the PowerShell engine required by this module
    PowerShellVersion = '5.1'
    
    # Functions to export from this module
    # Wildcard delegates export control to Export-ModuleMember in Robot.psm1,
    # which auto-discovers Verb-Noun functions from .ps1 filenames.
    # This prevents the manifest from silently blocking newly added functions.
    FunctionsToExport = '*'
    
    # Cmdlets to export from this module
    CmdletsToExport = @()
    
    # Variables to export from this module
    VariablesToExport = @()
    
    # Aliases to export from this module
    AliasesToExport = @()
    
    # Private data to pass to the module specified in RootModule/ModuleToProcess
    PrivateData = @{
        PSData = @{
            # Tags applied to this module
            Tags = @('Nerthus', 'RPG', 'Git', 'Markdown')
            
            # A URL to the license for this module
            LicenseUri = ''
            
            # A URL to the main website for this project
            ProjectUri = ''
        }
    }
}
