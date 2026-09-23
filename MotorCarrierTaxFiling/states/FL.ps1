# Florida validates the period on the delivery date, so each row says whether it was delivered in
# the period (a mismatch goes to the exception report), and a consignee with no DEP facility
# number on file reports its DEP county code followed by seven 1s, per DR-309654, when it is in
# Florida, or its state when it is not. DEP county codes are DEP's own, alphabetical, not FIPS.
param([object[]] $Rows, $Settings)
$counties = @{
    'ALACHUA' = '01'; 'BAKER' = '02'; 'BAY' = '03'; 'BRADFORD' = '04'; 'BREVARD' = '05'; 'BROWARD' = '06'; 'CALHOUN' = '07'
    'CHARLOTTE' = '08'; 'CITRUS' = '09'; 'CLAY' = '10'; 'COLLIER' = '11'; 'COLUMBIA' = '12'; 'MIAMI-DADE' = '13'; 'DESOTO' = '14'
    'DIXIE' = '15'; 'DUVAL' = '16'; 'ESCAMBIA' = '17'; 'FLAGLER' = '18'; 'FRANKLIN' = '19'; 'GADSDEN' = '20'; 'GILCHRIST' = '21'
    'GLADES' = '22'; 'GULF' = '23'; 'HAMILTON' = '24'; 'HARDEE' = '25'; 'HENDRY' = '26'; 'HERNANDO' = '27'; 'HIGHLANDS' = '28'
    'HILLSBOROUGH' = '29'; 'HOLMES' = '30'; 'INDIAN RIVER' = '31'; 'JACKSON' = '32'; 'JEFFERSON' = '33'; 'LAFAYETTE' = '34'
    'LAKE' = '35'; 'LEE' = '36'; 'LEON' = '37'; 'LEVY' = '38'; 'LIBERTY' = '39'; 'MADISON' = '40'; 'MANATEE' = '41'; 'MARION' = '42'
    'MARTIN' = '43'; 'MONROE' = '44'; 'NASSAU' = '45'; 'OKALOOSA' = '46'; 'OKEECHOBEE' = '47'; 'ORANGE' = '48'; 'OSCEOLA' = '49'
    'PALM BEACH' = '50'; 'PASCO' = '51'; 'PINELLAS' = '52'; 'POLK' = '53'; 'PUTNAM' = '54'; 'ST. JOHNS' = '55'; 'ST. LUCIE' = '56'
    'SANTA ROSA' = '57'; 'SARASOTA' = '58'; 'SEMINOLE' = '59'; 'SUMTER' = '60'; 'SUWANNEE' = '61'; 'TAYLOR' = '62'; 'UNION' = '63'
    'VOLUSIA' = '64'; 'WAKULLA' = '65'; 'WALTON' = '66'; 'WASHINGTON' = '67'
    # the spellings some systems use for three of them
    'DE SOTO' = '14'; 'SAINT JOHNS' = '55'; 'SAINT LUCIE' = '56'
}
$state = [string]$Settings.mctf.state
$period = [string]$Settings.mctf.period
function IsNull($v) { $v -is [DBNull] -or $null -eq $v }
foreach ($r in $Rows) {
    $delivered = $r.PSObject.Properties['delivered'].Value
    $inPeriod = if (-not (IsNull $delivered) -and ([string]$delivered).Length -ge 7 -and ([string]$delivered).Substring(0, 4) + ([string]$delivered).Substring(5, 2) -eq $period) { '1' } else { '0' }
    $dep = $r.PSObject.Properties['consignee.dep'].Value
    if (IsNull $dep) {
        $cstate = $r.PSObject.Properties['consignee.state'].Value
        $county = $r.PSObject.Properties['consignee.county'].Value
        $code = if (-not (IsNull $county)) { $counties[[string]$county] }
        $dep = if (-not (IsNull $cstate) -and ([string]$cstate).TrimEnd(' ') -ieq $state -and $code) { $code + '1111111' } else { $cstate }
    }
    # delivered.inperiod sits right after delivered, where the reports have always had it
    $row = [ordered]@{}
    foreach ($p in $r.PSObject.Properties) {
        $row[$p.Name] = if ($p.Name -eq 'consignee.dep') { $dep } else { $p.Value }
        if ($p.Name -eq 'delivered') { $row['delivered.inperiod'] = $inPeriod }
    }
    [pscustomobject]$row
}
