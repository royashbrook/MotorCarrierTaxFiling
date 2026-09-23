# South Carolina: the consignor name is cut to 35 characters
param([object[]] $Rows, $Settings)
foreach ($r in $Rows) {
    $p = $r.PSObject.Properties['consignor.name']
    if ($p.Value -isnot [DBNull] -and $null -ne $p.Value -and ([string]$p.Value).Length -gt 35) { $p.Value = ([string]$p.Value).Substring(0, 35) }
    $r
}
