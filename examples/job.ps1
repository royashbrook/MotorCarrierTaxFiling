param(
    [ValidateSet('Mock', 'ExportOnly', 'Live')][string] $Mode = 'Mock',
    [string] $Period,
    [switch] $NoSend
)
Import-Module MotorCarrierTaxFiling -RequiredVersion 0.8.1 -ErrorAction Stop
Invoke-MctfFeed -SettingsPath "$PSScriptRoot/settings.json" -Mode $Mode -Period $Period -NoSend:$NoSend
