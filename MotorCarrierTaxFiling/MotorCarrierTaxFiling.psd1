@{
    RootModule = 'MotorCarrierTaxFiling.psm1'
    ModuleVersion = '0.4.1'
    GUID = '6f2e5c1a-3b8d-4f7e-9a21-5c0d8e4b7a10'
    Author = 'Roy Ashbrook'
    Copyright = '(c) 2026 Roy Ashbrook. MIT.'
    Description = 'Motor carrier tax filing feeds: validate freight records, write exception reports, format the state return, package it, and for Alabama submit it. Builds the DataAgent 0.4 configuration the feed runs.'
    PowerShellVersion = '7.4'
    RequiredModules = @(
        @{ ModuleName = 'MotorFuelTaxFormats'; RequiredVersion = '0.1.1' }
        @{ ModuleName = 'Add-PrefixForLogging'; RequiredVersion = '1.0.0.2' }
    )
    FunctionsToExport = @(
        'Get-MctfPeriod'
        'ConvertTo-MctfProductCode'
        'Get-MctfTmwVariable'
        'Get-MctfTmwRow'
        'Get-MctfState'
        'Invoke-MctfStateShape'
        'Test-MctfRecord'
        'Split-MctfRecord'
        'Export-MctfExceptionReport'
        'Compress-MctfPackage'
        'Send-MctfPackageMail'
        'Invoke-MctfTransform'
        'Resolve-MctfSettings'
        'New-MctfConfig'
        'Write-MctfLine'
        'Test-MctfFilingWindow'
        'Submit-MctfAlabamaReturn'
        'Read-MctfAlabamaAcknowledgement'
        'Send-MctfAcknowledgementMail'
        'Invoke-MctfSubmission'
    )
    CmdletsToExport = @()
    VariablesToExport = @()
    AliasesToExport = @()
    FileList = @(
        'MotorCarrierTaxFiling.psd1'
        'MotorCarrierTaxFiling.psm1'
        'synthetic.csv'
        'adapters/package.ps1'
        'adapters/mail.ps1'
        'adapters/alabama.ps1'
        'adapters/tmw.ps1'
        'sources/tmw.sql'
        'states/AL.json'
        'states/AL.ps1'
        'states/FL.json'
        'states/FL.ps1'
        'states/KY.json'
        'states/NC.json'
        'states/SC.json'
        'states/SC.ps1'
        'states/TN.json'
        'states/TN.ps1'
        'states/VA.json'
        'companytypes.json'
        'adapters/skip.ps1'
    )
    PrivateData = @{
        PSData = @{
            Tags = @('motor-carrier', 'tax', 'filing', 'EDI', 'DataAgent')
            LicenseUri = 'https://github.com/royashbrook/MotorCarrierTaxFiling/blob/main/LICENSE'
            ProjectUri = 'https://github.com/royashbrook/MotorCarrierTaxFiling'
            ReleaseNotes = 'Every state file is checked against the specification the state publishes today and names its version, where it lives, and the date of the check. North Carolina moves to guide 1.0.7, South Carolina to D282 April 2026 with its July 2026 validation rules, Florida to DR-309653 R. 01/26; Kentucky, Alabama, Tennessee and Virginia were already on the current version. Where a test is stricter or looser than the current rule the state file says so. No change to what any feed produces.''s state from its city instead of the company record. All seven states ship their tests with a dated spec.''s tests and the company types now ship with the module, each state file naming the specification its tests were built against. Kentucky is the first state file. Feeds that carry their own sql and tests run as before.'
        }
    }
}
