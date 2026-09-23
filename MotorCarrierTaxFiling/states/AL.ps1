# Alabama: the consignee address carries only letters, digits, spaces, hyphens and slashes, 35
# characters at most, and a consignee with no DEP note reports its state there instead
param([object[]] $Rows, $Settings)
foreach ($r in $Rows) {
    $a = $r.PSObject.Properties['consignee.address']
    $v = if ($a.Value -is [DBNull] -or $null -eq $a.Value) { 'No Address' } else { [string]$a.Value }
    # the order matters: each step sees what the one before it left
    foreach ($pair in @(@('&', ' '), @('@', ' '), @('#', ' '), @('.', ' '), @(',', ''), @('(', ''), @(')', ''), @(':', ' '), @("'", ' '), @('  ', ''))) {
        $v = $v.Replace($pair[0], $pair[1])
    }
    $v = $v.Trim(' ')
    if ($v.Length -gt 35) { $v = $v.Substring(0, 35) }
    $a.Value = $v
    $d = $r.PSObject.Properties['consignee.dep']
    if ($d.Value -is [DBNull] -or $null -eq $d.Value) { $d.Value = $r.PSObject.Properties['consignee.state'].Value }
    $r
}
