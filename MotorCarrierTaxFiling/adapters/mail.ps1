# dst adapter: mail the package to the filing distribution list
param($Data, [hashtable] $Options)
if (-not (Get-Command Send-MctfPackageMail -ErrorAction Ignore)) {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'MotorCarrierTaxFiling.psd1') -ErrorAction Stop
}
Send-MctfPackageMail -Settings $Options.Settings -ArtifactPath ([string]$Data)
