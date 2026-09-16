param(
    [ValidateSet('Mock', 'ExportOnly', 'Live')][string] $Mode = 'Mock',
    [string] $Period,
    [switch] $NoSend
)
Import-Module MotorCarrierTaxFiling -RequiredVersion 0.1.0 -ErrorAction Stop
Invoke-MctfFeed -SettingsPath "$PSScriptRoot/settings.json" -Mode $Mode -Period $Period -NoSend:$NoSend
