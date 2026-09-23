# Alabama: the consignee address carries only letters, digits, spaces, hyphens and slashes, and a
# consignee with no DEP note reports its state there instead
param([object[]] $Rows, $Settings)
foreach ($r in $Rows) {
    $a = $r.PSObject.Properties['consignee.address']
    $v = if ($a.Value -is [DBNull] -or $null -eq $a.Value) { 'No Address' } else { [string]$a.Value }
    # the order matters: each step sees what the one before it left
    foreach ($pair in @(@('&', ' '), @('@', ' '), @('#', ' '), @('.', ' '), @(',', ''), @('(', ''), @(')', ''), @(':', ' '), @("'", ' '), @('  ', ''))) {
        $v = $v.Replace($pair[0], $pair[1])
    }
    # trimmed here, cut to the state's length by max_length in AL.json
    $a.Value = $v.Trim(' ')
    $d = $r.PSObject.Properties['consignee.dep']
    if ($d.Value -is [DBNull] -or $null -eq $d.Value) { $d.Value = $r.PSObject.Properties['consignee.state'].Value }
    $r
}
