# dst adapter: submit the return to the state, then mail the package with the state's response
param($Data, [hashtable] $Options)
if (-not (Get-Command Invoke-MctfSubmission -ErrorAction Ignore)) {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'MotorCarrierTaxFiling.psd1') -ErrorAction Stop
}
Invoke-MctfSubmission -Settings $Options.Settings -ArtifactPath ([string]$Data) -RunAt $Options.RunAt -NoSend:$Options.NoSend
