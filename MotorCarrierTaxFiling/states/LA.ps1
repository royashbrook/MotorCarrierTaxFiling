# Louisiana's Schedule G types are its own numbers: 23 into Louisiana, 24 out of it, 25 solely within
# it. the form has one TCN/FEIN column for where the fuel was removed, so each row carries the
# shipper's terminal code, or the supplier's FEIN when the shipper has none.
param([object[]] $Rows, $Settings)
$types = @{ '14B' = '23'; '14A' = '24'; '14C' = '25' }
foreach ($r in $Rows) {
    $p = $r.PSObject.Properties['schedule']
    if ($p.Value -isnot [DBNull] -and $null -ne $p.Value -and $types.ContainsKey([string]$p.Value)) { $p.Value = $types[[string]$p.Value] }
    $tcn = [string]$r.PSObject.Properties['shipper.tcn'].Value
    $fein = [string]$r.PSObject.Properties['supplier.tax_id'].Value
    $r | Add-Member -NotePropertyName 'origin.id' -NotePropertyValue $(if ($tcn) { $tcn } else { $fein })
    $r
}
