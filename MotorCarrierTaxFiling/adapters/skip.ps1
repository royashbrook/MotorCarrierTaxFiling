# dst adapter: the package was built and nothing was sent, and the log says which run this was
param($Data, [hashtable] $Options)
if (-not (Get-Command Write-MctfLine -ErrorAction Ignore)) {
    Import-Module (Join-Path (Split-Path -Parent $PSScriptRoot) 'MotorCarrierTaxFiling.psd1') -ErrorAction Stop
}
Write-MctfLine ("mctf: delivery=none reason={0} artifact={1}" -f $Options.Reason, ([string]$Data))
