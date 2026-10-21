@{
    RootModule = 'MotorCarrierTaxFiling.psm1'
    ModuleVersion = '0.12.1'
    GUID = '6f2e5c1a-3b8d-4f7e-9a21-5c0d8e4b7a10'
    Author = 'Roy Ashbrook'
    Copyright = '(c) 2026 Roy Ashbrook. MIT.'
    Description = 'Motor carrier tax filing feeds: validate freight records, write exception reports, format the state return, package it, and for Alabama submit it. Builds the DataAgent 0.4 configuration the feed runs.'
    PowerShellVersion = '7.4'
    RequiredModules = @(
        @{ ModuleName = 'MotorFuelTaxFormats'; RequiredVersion = '0.2.1' }
        @{ ModuleName = 'ImportExcel'; RequiredVersion = '7.8.10' }
        @{ ModuleName = 'Add-PrefixForLogging'; RequiredVersion = '1.0.0.2' }
        @{ ModuleName = 'DataAgent'; RequiredVersion = '0.6.0' }
        @{ ModuleName = 'SqlServer'; RequiredVersion = '22.4.5.1' }
        @{ ModuleName = 'Send-FileViaEmail'; RequiredVersion = '2.0.0.0' }
    )
    FunctionsToExport = @(
        'Invoke-MctfFeed'
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
        'states/MS.json'
        'states/MS.ps1'
        'states/MS.csv'
        'states/NC.json'
        'states/SC.json'
        'states/TN.json'
        'states/TN.ps1'
        'states/VA.json'
        'companytypes.json'
        'defaulttests.json'
        'adapters/skip.ps1'
    )
    PrivateData = @{
        PSData = @{
            Tags = @('motor-carrier', 'tax', 'filing', 'EDI', 'DataAgent')
            LicenseUri = 'https://github.com/royashbrook/MotorCarrierTaxFiling/blob/main/LICENSE'
            ProjectUri = 'https://github.com/royashbrook/MotorCarrierTaxFiling'
            ReleaseNotes = 'Mississippi files both legs by state and city and never a terminal code (MotorFuelTaxFormats 0.2.1), since the state takes one or the other per leg. Its shipper terminal code test is gone: a code that is never filed no longer holds a row back.'
        }
    }
}
