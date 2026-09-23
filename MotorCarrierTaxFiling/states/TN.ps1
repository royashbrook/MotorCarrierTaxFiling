# Tennessee names its schedules in full rather than by the standard 14A / 14B / 14C codes
param([object[]] $Rows, $Settings)
$labels = @{
    '14A' = '1A - Product loaded at a Tennessee terminal, bulk plant, or refinery and delivered to another state'
    '14B' = '2A - Product loaded at an out-of-state terminal, bulk plant, or refinery and delivered to Tennessee'
    '14C' = '3A - Product loaded at a Tennessee refinery and delivered in Tennessee'
}
foreach ($r in $Rows) {
    $p = $r.PSObject.Properties['schedule']
    if ($p.Value -isnot [DBNull] -and $null -ne $p.Value -and $labels.ContainsKey([string]$p.Value)) { $p.Value = $labels[[string]$p.Value] }
    $r
}
