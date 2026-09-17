# fmt adapter: the whole tax package, written at the path the runner configured
param($Data, [hashtable] $Options)
if (-not (Get-Command Invoke-MctfTransform -ErrorAction Ignore)) {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'MotorCarrierTaxFiling.psd1') -ErrorAction Stop
}
Invoke-MctfTransform -Rows $Data -Settings $Options.Settings -RunAt $Options.RunAt -ArtifactPath $Options.Path
