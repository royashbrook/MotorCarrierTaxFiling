# Mississippi's carrier report has one schedule, 14B, loads brought into the state, so the other
# schedules leave here. the date shipped has to fall in the filing period, so each row says whether
# it does (a mismatch goes to the exception report).
param([object[]] $Rows, $Settings)
$period = [string]$Settings.mctf.period
foreach ($r in $Rows) {
    if ([string]$r.PSObject.Properties['schedule'].Value -ne '14B') { continue }
    $shipped = [string]$r.PSObject.Properties['shipped'].Value
    $inPeriod = if ($shipped.Length -ge 7 -and $shipped.Substring(0, 4) + $shipped.Substring(5, 2) -eq $period) { '1' } else { '0' }
    # shipped.inperiod sits right after shipped
    $row = [ordered]@{}
    foreach ($p in $r.PSObject.Properties) {
        $row[$p.Name] = $p.Value
        if ($p.Name -eq 'shipped') { $row['shipped.inperiod'] = $inPeriod }
    }
    [pscustomobject]$row
}
