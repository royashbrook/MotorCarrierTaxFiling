using namespace System.Collections.Generic

# Every stage below is a plain function with no DataAgent dependency, so each can be proven on its
# own. New-MctfConfig is the only DataAgent-shaped thing here: it returns the config that
# Invoke-DataAgent takes, and the feed's own job.ps1 makes that call. DataAgent 0.4 runs from the
# calling script's directory, so a module cannot make the call on the feed's behalf without moving
# the log and the package into the module's install folder.

function ConvertTo-MctfHashtable {
    param($Value)
    if ($null -eq $Value) { return @{} }
    if ($Value -is [hashtable]) { return $Value }
    $Value | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
}

function Get-MctfPeriod {
    [CmdletBinding()]
    param(
        [datetime] $RunAt = (Get-Date),
        [string] $Period
    )
    if ($Period) {
        if ($Period -notmatch '^\d{6}$') { throw "Period must be yyyyMM, got '$Period'." }
        $start = [datetime]::ParseExact("${Period}01", 'yyyyMMdd', [cultureinfo]::InvariantCulture)
    } else {
        # the scheduled run reports the month before the run, the same as the feeds always have
        $previous = $RunAt.AddMonths(-1)
        $start = [datetime]::new($previous.Year, $previous.Month, 1)
    }
    [pscustomobject]@{
        Period = $start.ToString('yyyyMM', [cultureinfo]::InvariantCulture)
        Start  = $start
        End    = $start.AddMonths(1).AddDays(-1)
    }
}

function Test-MctfRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Records,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Tests,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $CompanyTypes
    )
    # a freight test names a field and a regex; a row that does not match is an exception
    $freight = [List[object]]::new()
    foreach ($t in @($Tests | Where-Object Type -eq 'Freight')) {
        foreach ($r in $Records) {
            if ($r.$($t.field) -notmatch $t.test) {
                $freight.Add([pscustomobject]@{
                    ord_hdrnumber = $r.ord_hdrnumber
                    fgt_number    = $r.fgt_number
                    test          = $t.name
                    current       = $r.$($t.field)
                })
            }
        }
    }
    # a company type names its key field and the fields that make a company record; each distinct
    # company is tested once, against the tests of that type
    $company = [List[object]]::new()
    foreach ($ctm in $CompanyTypes) {
        $companies = @($Records |
            Where-Object $ctm.k -match '.+' |
            Group-Object $ctm.f |
            ForEach-Object { $_.Group[0] | Select-Object $ctm.f })
        $typeTests = @($Tests | Where-Object Type -eq $ctm.t)
        foreach ($c in $companies) {
            foreach ($t in $typeTests) {
                if ($c.$($t.field) -notmatch $t.test) {
                    $company.Add([pscustomobject]@{
                        type    = $t.type
                        cmp_id  = $c.$($ctm.k)
                        test    = $t.name
                        current = $c.$($t.field)
                    })
                }
            }
        }
    }
    # every row that references a failing company is itself an exception, so it leaves the filing
    $badCompanyFreight = [List[object]]::new()
    foreach ($ctm in $CompanyTypes) {
        foreach ($g in @($company | Where-Object Type -eq $ctm.t | Group-Object Type)) {
            $badIds = [HashSet[string]]::new([string[]]@($g.Group.cmp_id))
            foreach ($r in $Records) {
                if ($badIds.Contains($r.$($ctm.k))) {
                    $badCompanyFreight.Add([pscustomobject]@{
                        ord_hdrnumber = $r.ord_hdrnumber
                        fgt_number    = $r.fgt_number
                        test          = 'Bad {0} Record' -f $ctm.t
                        current       = $r.$($ctm.k)
                    })
                }
            }
        }
    }
    [pscustomobject]@{
        Company = @($company)
        Freight = @($freight) + @($badCompanyFreight)
    }
}

function Split-MctfRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Records,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $FreightExceptions
    )
    if ($FreightExceptions.Count -eq 0) {
        return [pscustomobject]@{ Good = @($Records); Bad = @() }
    }
    # a plain loop, in input order: a hashtable lookup here once handed the formatter a null on a
    # runner whose PowerShell grouped the keys differently from the machine the tests ran on
    $bad = [HashSet[string]]::new([string[]]@($FreightExceptions.fgt_number))
    $good = [List[object]]::new()
    $badRows = [List[object]]::new()
    foreach ($r in $Records) {
        if ($bad.Contains([string]$r.fgt_number)) { $badRows.Add($r) } else { $good.Add($r) }
    }
    [pscustomobject]@{
        Good = @($good)
        Bad  = @($badRows)
    }
}

function Export-MctfExceptionReport {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Exceptions,
        [Parameter(Mandatory)] $Split,
        [Parameter(Mandatory)][datetime] $RunAt,
        [string] $Directory = (Get-Location).Path
    )
    $stamp = $RunAt.ToString('yyyyMMdd')
    $names = [ordered]@{
        Company = "$stamp-CompanyExceptions.csv"
        Freight = "$stamp-FreightExceptions.csv"
        Good    = "$stamp-FreightItemsGood.csv"
        Bad     = "$stamp-FreightItemsBad.csv"
    }
    $Exceptions.Company | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $Directory $names.Company)
    $Exceptions.Freight | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $Directory $names.Freight)
    $Split.Good | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $Directory $names.Good)
    $Split.Bad | Export-Csv -NoTypeInformation -LiteralPath (Join-Path $Directory $names.Bad)
    $names
}

function Compress-MctfPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Directory,
        [Parameter(Mandatory)][string[]] $Members,
        [Parameter(Mandatory)][string] $DestinationPath
    )
    # members are relative names so the zip entries carry bare filenames
    Push-Location -LiteralPath $Directory
    try { Compress-Archive -Path $Members -Force -DestinationPath $DestinationPath }
    finally { Pop-Location }
}

function Resolve-MctfPath {
    param([Parameter(Mandatory)][string] $Path)
    # .NET resolves a relative path against the process directory, which is not where the runner
    # put PowerShell. the runner's location is the feed, and that is the one the paths mean.
    if ([IO.Path]::IsPathRooted($Path)) { return [IO.Path]::GetFullPath($Path) }
    [IO.Path]::GetFullPath((Join-Path (Get-Location -PSProvider FileSystem).ProviderPath $Path))
}

function Write-MctfLine {
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Message)
    # the feeds' log line is Add-PrefixForLogging's `l`; outside a run (a test calling a stage on
    # its own) there is no logger and the line is plain output
    if (Get-Command l -ErrorAction Ignore) { l $Message } else { $Message }
}

function Invoke-MctfTransform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Rows,
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)][datetime] $RunAt,
        [Parameter(Mandatory)][string] $ArtifactPath
    )
    $cfg = $Settings
    $mctf = $cfg.mctf
    $artifact = Resolve-MctfPath $ArtifactPath
    $directory = Split-Path -Parent $artifact
    if (-not (Test-Path -LiteralPath $directory)) { $null = New-Item -ItemType Directory -Path $directory }
    $stamp = $RunAt.ToString('yyyyMMdd')

    # a source that hands back tables rather than rows (Invoke-Sqlcmd -OutputAs DataTables, whose
    # collection does not enumerate) would otherwise be written out as the TABLE's properties,
    # CaseSensitive and Columns and the rest, and filed as if they were freight
    if ($Rows.Count -and ($Rows[0] -is [System.Data.DataTable] -or $Rows[0] -is [System.Data.DataSet] -or $Rows[0] -is [System.Data.DataTableCollection])) {
        throw 'the source returned tables, not rows. drop OutputAs from the sql settings, or take a DataAgent version whose sql source hands back rows.'
    }

    # the rowset goes through a csv round trip first, so every value is the string the report
    # and the filing will show, whatever type the source returned
    Write-MctfLine 'Getting FreightItems'
    $allPath = Join-Path $directory "$stamp-FreightItemsAll.csv"
    $columns = if ($Rows[0] -is [System.Data.DataRow]) {
        @($Rows[0].Table.Columns.ColumnName)
    } else {
        @($Rows[0].PSObject.Properties.Name)
    }
    $Rows | Select-Object -Property $columns | Export-Csv -NoTypeInformation -LiteralPath $allPath
    $records = @(Import-Csv -LiteralPath $allPath)
    Write-MctfLine "FreightItems:`t$($records.Count)"

    Write-MctfLine 'Getting Company and Freight TestResults'
    $exceptions = Test-MctfRecord -Records $records -Tests @($cfg.tests) -CompanyTypes @($cfg.companytypes)
    Write-MctfLine "CompanyTR:`t$($exceptions.Company.Count)"
    Write-MctfLine "FreightTR:`t$($exceptions.Freight.Count)"

    Write-MctfLine 'Getting Good/Bad FreightItems'
    $split = Split-MctfRecord -Records $records -FreightExceptions $exceptions.Freight
    Write-MctfLine "FreightItemsG:`t$($split.Good.Count)"
    Write-MctfLine "FreightItemsB:`t$($split.Bad.Count)"

    Write-MctfLine 'Saving Files'
    $taxFile = Join-Path $directory $mctf.file
    if ($split.Good.Count -eq 0) {
        # nothing passed, the package still goes out so the exception reports reach the filer
        Set-Content -LiteralPath $taxFile -Value '' -NoNewline
    } else {
        $convert = @{ State = $mctf.state; Period = $mctf.period; OutputPath = $taxFile }
        if ($mctf.filer_id) { $convert.FilerId = [string]$mctf.filer_id }
        if ($mctf.state -ne 'TN') {
            $convert.GeneratedAt = if ($mctf.generated_at) { [datetimeoffset]$mctf.generated_at } else { [datetimeoffset]$RunAt }
        }
        $options = ConvertTo-MctfHashtable $mctf.state_options
        if ($options.Count -gt 0) { $convert.StateOptions = $options }
        if ($mctf.template_path) { $convert.TemplatePath = $mctf.template_path }
        $split.Good | ConvertTo-MotorFuelTaxFile @convert
    }
    $names = Export-MctfExceptionReport -Exceptions $exceptions -Split $split -RunAt $RunAt -Directory $directory

    Write-MctfLine 'Zipping Files'
    Compress-MctfPackage -Directory $directory -DestinationPath $artifact `
        -Members @($names.Company, $names.Freight, $names.Good, $names.Bad, $mctf.file)

    $item = Get-Item -LiteralPath $artifact
    # the run's receipt is these lines in the daily log, which the feed commits with the package
    Write-MctfLine ("mctf: state={0} period={1} rows={2} good={3} bad={4} companyexceptions={5}" -f
        $mctf.state, $mctf.period, $records.Count, $split.Good.Count, $split.Bad.Count, $exceptions.Company.Count)
    Write-MctfLine ("mctf: artifact={0} bytes={1} sha256={2}" -f
        $item.Name, $item.Length, (Get-FileHash -LiteralPath $artifact -Algorithm SHA256).Hash)
}

function Resolve-MctfSettings {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SettingsPath,
        [datetime] $RunAt = (Get-Date),
        [string] $Period
    )
    $file = Get-Item -LiteralPath $SettingsPath
    $cfg = Get-Content -LiteralPath $file.FullName -Raw | ConvertFrom-Json -AsHashtable
    if (-not $cfg.mctf -or -not $cfg.mctf.state) { throw 'settings.mctf.state is required: AL, FL, KY, NC, SC, TN or VA.' }
    if (-not $cfg.file_format) { throw 'settings.file_format is required.' }
    $cfg.mctf.state = ([string]$cfg.mctf.state).ToUpperInvariant()
    # the tests and the company types are filtered by property (Where-Object Type -eq), and a
    # hashtable does not answer that: it matches nothing, every test silently passes, and every
    # row is filed. objects, so a missing key is an error rather than an empty filter.
    $cfg.tests = @($cfg.tests | ForEach-Object { [pscustomobject]$_ })
    $cfg.companytypes = @($cfg.companytypes | ForEach-Object { [pscustomobject]$_ })

    $p = Get-MctfPeriod -RunAt $RunAt -Period $Period
    $taxFile = $cfg.file_format -f $p.Start
    $cfg.mctf.file = $taxFile
    $cfg.mctf.period = $p.Period
    # the runner names its one artifact from file_format, so hand it the finished zip name
    $cfg.file_format = "$taxFile.zip"

    if ($cfg.sql -is [string]) { $cfg.sql = @{ InputFile = $cfg.sql; QueryTimeout = 1800 } }
    if ($cfg.sql) {
        if ($cfg.sql.InputFile -and -not [IO.Path]::IsPathRooted($cfg.sql.InputFile)) {
            $cfg.sql.InputFile = Join-Path $file.DirectoryName $cfg.sql.InputFile
        }
        $variables = @(
            "Period=$($p.Period)"
            "PeriodStart=$($p.Start.ToString('yyyy-MM-dd'))"
            "PeriodEnd=$($p.End.ToString('yyyy-MM-dd'))"
        )
        $cfg.sql.Variable = @($variables) + @($cfg.sql.Variable | Where-Object { $_ })
        if ($Period) {
            $text = if ($cfg.sql.InputFile) { Get-Content -LiteralPath $cfg.sql.InputFile -Raw } else { [string]$cfg.sql.Query }
            if ($text -notmatch '\$\(Period') {
                throw 'an explicit period needs period-aware sql: reference $(Period), $(PeriodStart) or $(PeriodEnd) in the query.'
            }
        }
    }

    if ($cfg.mctf.submit) {
        if (-not $cfg.mctf.submit.window) { $cfg.mctf.submit.window = @(14, 20) }
        if (-not $cfg.mctf.state_options) { $cfg.mctf.state_options = @{} }
        if (-not $cfg.mctf.state_options.ProcessType) {
            $cfg.mctf.state_options.ProcessType = if ($env:MCTF_PROCESS_TYPE) { $env:MCTF_PROCESS_TYPE } else { 'P' }
        }
    }
    $cfg
}

function New-MctfConfig {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $SettingsPath,
        [ValidateSet('Mock', 'ExportOnly', 'Live')][string] $Mode = 'Mock',
        [string] $Period,
        [string] $FixturePath,
        [switch] $NoSend,
        [datetime] $RunAt = (Get-Date)
    )
    $loaded = Get-Module DataAgent
    if ($loaded -and $loaded.Version -lt [version]'0.4.0') {
        throw "DataAgent $($loaded.Version) is loaded; this config is the 0.4.0 src/fmt/dst contract. Import DataAgent 0.4.0 or later."
    }
    $settingsFile = Get-Item -LiteralPath $SettingsPath
    $cfg = Resolve-MctfSettings -SettingsPath $settingsFile.FullName -RunAt $RunAt -Period $Period
    $adapters = Join-Path $PSScriptRoot 'adapters'

    # a rehearsal writes beside the feed, because the runner sets its own location, so it writes
    # into a subdirectory the feed does not commit. a Live run writes the package where it always has.
    $artifact = if ($Mode -eq 'Live') { $cfg.file_format } else { Join-Path 'rehearsal' $cfg.file_format }

    $src = if ($Mode -eq 'Mock') {
        $fixture = if ($FixturePath) { (Get-Item -LiteralPath $FixturePath).FullName } else { Join-Path $PSScriptRoot 'synthetic.csv' }
        @{ adapter = 'csv'; args = @{ LiteralPath = $fixture } }
    } else {
        if (-not $cfg.sql) { throw 'settings.sql is required for a run that reads the database.' }
        $sqlArgs = @{} + $cfg.sql
        if ($env:CONNECTION_STRING) { $sqlArgs.ConnectionString = $env:CONNECTION_STRING }
        @{ adapter = 'sql'; args = $sqlArgs }
    }

    $dst = if ($Mode -ne 'Live') {
        @{ adapter = (Join-Path $adapters 'skip.ps1'); args = @{ Reason = "$Mode is a rehearsal" } }
    } elseif ($cfg.mctf.submit) {
        # alabama submits the return itself and mails the state's response as the body, so NoSend
        # skips only that mail: the filing still happens when the window is open
        @{ adapter = (Join-Path $adapters 'alabama.ps1'); args = @{ Settings = $cfg; RunAt = $RunAt; NoSend = [bool]$NoSend } }
    } elseif ($NoSend) {
        @{ adapter = (Join-Path $adapters 'skip.ps1'); args = @{ Reason = 'NoSend' } }
    } else {
        if ($cfg.msgraph.client_secret) { throw 'client_secret belongs in the environment, not settings.' }
        @{ adapter = (Join-Path $adapters 'mail.ps1'); args = @{ Settings = $cfg } }
    }

    $config = @{
        file_format = $artifact
        src         = $src
        fmt         = @{ adapter = (Join-Path $adapters 'package.ps1'); args = @{ Settings = $cfg; RunAt = $RunAt } }
        dst         = @($dst)
    }
    # retention is the feed's choice; set it and the runner needs the Clear-Files module installed
    if ($cfg.keepdays) { $config.keepdays = $cfg.keepdays }
    if ($cfg.purgefiles) { $config.purgefiles = $cfg.purgefiles }
    $config
}

function Send-MctfPackageMail {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)][string] $ArtifactPath
    )
    if (-not $PSCmdlet.ShouldProcess($ArtifactPath, 'Mail the package')) { return }
    if ([string]::IsNullOrWhiteSpace($env:CLIENT_SECRET)) { throw 'CLIENT_SECRET is required.' }
    if ($Settings.msgraph.client_secret) { throw 'client_secret belongs in the environment, not settings.' }
    Import-Module Send-FileViaEmail -ErrorAction Stop
    # the same call the feeds have always made: the path as given is also the attachment's name,
    # and the content type is that module's default
    $cfg = @{ mail = $Settings.mail; msgraph = @{} + $Settings.msgraph }
    $cfg.msgraph.client_secret = $env:CLIENT_SECRET
    $response = Send-FileViaEmail -file $ArtifactPath -cfg $cfg
    if ($response) { Write-MctfLine ([string]$response) }
    Write-MctfLine ("mctf: delivery=email artifact={0} to={1}" -f $ArtifactPath, (@($Settings.mail.to) -join ','))
}

function Test-MctfFilingWindow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][datetime] $Date,
        [int[]] $Window = @(14, 20)
    )
    ($Date.Day -ge $Window[0]) -and ($Date.Day -le $Window[1])
}

function Submit-MctfAlabamaReturn {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][string] $User,
        [Parameter(Mandatory)][string] $Password
    )
    if (-not $PSCmdlet.ShouldProcess($Uri, "Submit $([IO.Path]::GetFileName($Path))")) { return }
    $pair = [System.Text.Encoding]::ASCII.GetBytes("${User}:${Password}")
    $headers = @{ Authorization = 'Basic ' + [Convert]::ToBase64String($pair) }
    $response = Invoke-RestMethod -Uri $Uri -Method Post -Headers $headers -InFile $Path -ContentType 'application/xml'
    if ($response -is [xml]) { $response.OuterXml } else { [string]$response }
}

function Read-MctfAlabamaAcknowledgement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Response)
    $result = [ordered]@{
        IsAcknowledged    = $false
        AcknowledgementId = $null
        TransmissionId    = $null
        ProcessType       = $null
        Errors            = @()
        Message           = $Response
    }
    $xml = $null
    try { $xml = [xml]$Response } catch { $xml = $null }
    if ($xml -and $xml.Transmission) {
        $t = $xml.Transmission
        $result.AcknowledgementId = [string]$t.AcknowledgementID
        $result.TransmissionId = [string]$t.TransmissionId
        $result.ProcessType = [string]$t.ProcessType
        $errors = $t.SelectSingleNode('*[local-name()="Errors"]')
        if ($errors) { $result.Errors = @($errors.ChildNodes | ForEach-Object { $_.OuterXml }) }
        $result.IsAcknowledged = [bool]$result.AcknowledgementId -and $result.Errors.Count -eq 0
    }
    [pscustomobject]$result
}

function Send-MctfAcknowledgementMail {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)][string] $ArtifactPath,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Body
    )
    if (-not $PSCmdlet.ShouldProcess($ArtifactPath, 'Mail the acknowledgement and the package')) { return }
    if ([string]::IsNullOrWhiteSpace($env:CLIENT_SECRET)) { throw 'CLIENT_SECRET is required.' }
    $cfg = $Settings
    if ($cfg.msgraph.client_secret) { throw 'client_secret belongs in the environment, not settings.' }
    $artifact = Resolve-MctfPath $ArtifactPath
    $token = Invoke-RestMethod -Method Post -Uri ('https://login.microsoftonline.com/{0}/oauth2/v2.0/token' -f $cfg.msgraph.tenant_id) -Body @{
        client_id     = $cfg.msgraph.client_id
        scope         = 'https://graph.microsoft.com/.default'
        client_secret = $env:CLIENT_SECRET
        grant_type    = 'client_credentials'
    }
    $message = @{
        message = @{
            subject      = $cfg.mail.subject
            body         = @{ contentType = 'Text'; content = $Body }
            attachments  = @(@{
                '@odata.type' = '#microsoft.graph.fileAttachment'
                name          = [IO.Path]::GetFileName($artifact)
                contentType   = 'application/zip'
                contentBytes  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($artifact))
            })
            toRecipients = @(@($cfg.mail.to) | ForEach-Object { @{ emailAddress = @{ address = $_ } } })
        }
    } | ConvertTo-Json -Depth 6
    $null = Invoke-RestMethod -Method Post -Uri ('https://graph.microsoft.com/v1.0/users/{0}/sendMail' -f $cfg.mail.from) `
        -Headers @{ Authorization = "Bearer $($token.access_token)" } -ContentType 'application/json' -Body $message
}

function Invoke-MctfSubmission {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory)] $Settings,
        [Parameter(Mandatory)][string] $ArtifactPath,
        [datetime] $RunAt = (Get-Date),
        [switch] $NoSend
    )
    $cfg = $Settings
    $submit = $cfg.mctf.submit
    $processType = [string]$cfg.mctf.state_options.ProcessType
    $artifact = Resolve-MctfPath $ArtifactPath
    $taxFile = Join-Path (Split-Path -Parent $artifact) $cfg.mctf.file
    $uri = $env:MCTF_SUBMIT_URI
    $window = @($submit.window | ForEach-Object { [int]$_ })

    Write-MctfLine "Submitting $($cfg.mctf.file)"
    if ($processType -eq 'T' -or (Test-MctfFilingWindow -Date $RunAt -Window $window)) {
        if ([string]::IsNullOrWhiteSpace($uri) -or [string]::IsNullOrWhiteSpace($env:MCTF_SUBMIT_USER) -or [string]::IsNullOrWhiteSpace($env:MCTF_SUBMIT_PASSWORD)) {
            throw 'MCTF_SUBMIT_URI, MCTF_SUBMIT_USER and MCTF_SUBMIT_PASSWORD are required to submit.'
        }
        try {
            $response = Submit-MctfAlabamaReturn -Path $taxFile -Uri $uri -User $env:MCTF_SUBMIT_USER -Password $env:MCTF_SUBMIT_PASSWORD
        } catch {
            # the failure still goes to the filer in the mail, as it always has
            $response = "Error: Failed to submit TaxFile. Details: $($_.Exception.Message)"
        }
    } else {
        $response = 'No filing was done. Filing is only done when this job runs from the {0} to the {1}.' -f $window[0], $window[1]
    }
    Write-MctfLine "Response: $response"
    $ack = Read-MctfAlabamaAcknowledgement -Response ([string]$response)

    if ($NoSend) {
        Write-MctfLine 'NoSend: skipping the email, the response above is the whole result'
    } else {
        Send-MctfAcknowledgementMail -Settings $cfg -ArtifactPath $artifact -Body ([string]$response)
    }
    $state = if ($ack.IsAcknowledged) { 'confirmed' } else { 'submitted' }
    $id = if ($ack.AcknowledgementId) { $ack.AcknowledgementId } else { 'none' }
    Write-MctfLine ("mctf: delivery=alabama state={0} acknowledgement={1} mailed={2}" -f $state, $id, (-not $NoSend))
}

Export-ModuleMember -Function Get-MctfPeriod, Send-MctfPackageMail, Test-MctfRecord, Split-MctfRecord, Export-MctfExceptionReport, Compress-MctfPackage,
    Invoke-MctfTransform, Resolve-MctfSettings, New-MctfConfig, Write-MctfLine, Test-MctfFilingWindow, Submit-MctfAlabamaReturn,
    Read-MctfAlabamaAcknowledgement, Send-MctfAcknowledgementMail, Invoke-MctfSubmission
