# src adapter: freight rows from a TMW database, with the feed's product mapping applied
param($Data, [hashtable] $Options)
if (-not (Get-Command Get-MctfTmwRow -ErrorAction Ignore)) {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'MotorCarrierTaxFiling.psd1') -ErrorAction Stop
}
Get-MctfTmwRow -Settings $Options.Settings
