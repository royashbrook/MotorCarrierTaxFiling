param([string]$Period, [switch]$NoSend, [ValidateSet('Mock', 'ExportOnly', 'Live')][string]$Mode = 'Mock')
Import-Module MotorCarrierTaxFiling -RequiredVersion 0.13.0
Invoke-MctfFeed "$PSScriptRoot/settings.json" -Period $Period -Mode $Mode -NoSend:$NoSend
