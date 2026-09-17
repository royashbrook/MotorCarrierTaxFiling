param(
    [ValidateSet('Mock', 'ExportOnly', 'Live')][string] $Mode = 'Mock',
    [string] $Period,
    [switch] $NoSend
)
Import-Module DataAgent -RequiredVersion 0.4.1 -ErrorAction Stop
Import-Module MotorCarrierTaxFiling -RequiredVersion 0.2.1 -ErrorAction Stop
$cfg = New-MctfConfig -SettingsPath "$PSScriptRoot/settings.json" -Mode $Mode -Period $Period -NoSend:$NoSend
Invoke-DataAgent -Config $cfg
