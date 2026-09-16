using namespace System.Collections.Generic

# The stages below are plain functions with no DataAgent dependency, so they can be proven on
# their own. Invoke-MctfFeed is the only place DataAgent is touched, and it pins 0.3.0 at call
# time because the 0.4 candidate replaces the pipeline seam.

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
    $bad = [HashSet[string]]::new([string[]]@($FreightExceptions.fgt_number))
    $groups = $Records | Group-Object { $bad.Contains($_.fgt_number) } -AsHashTable -AsString
    [pscustomobject]@{
        Good = @($groups['False'])
        Bad  = @($groups['True'])
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

function Invoke-MctfTransform {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Rows,
        [Parameter(Mandatory)] $Context
    )
    $cfg = $Context.Config
    $mctf = $cfg.mctf
    $directory = Split-Path -Parent $Context.ArtifactPath
    $stamp = $Context.RunAt.ToString('yyyyMMdd')

    # the rowset goes through a csv round trip first, so every value is the string the report
    # and the filing will show, whatever type the source returned
    l 'Getting FreightItems'
    $allPath = Join-Path $directory "$stamp-FreightItemsAll.csv"
    $columns = if ($Rows[0] -is [System.Data.DataRow]) {
        @($Rows[0].Table.Columns.ColumnName)
    } else {
        @($Rows[0].PSObject.Properties.Name)
    }
    $Rows | Select-Object -Property $columns | Export-Csv -NoTypeInformation -LiteralPath $allPath
    $records = @(Import-Csv -LiteralPath $allPath)
    l "FreightItems:`t$($records.Count)"

    l 'Getting Company and Freight TestResults'
    $exceptions = Test-MctfRecord -Records $records -Tests @($cfg.tests) -CompanyTypes @($cfg.companytypes)
    l "CompanyTR:`t$($exceptions.Company.Count)"
    l "FreightTR:`t$($exceptions.Freight.Count)"

    l 'Getting Good/Bad FreightItems'
    $split = Split-MctfRecord -Records $records -FreightExceptions $exceptions.Freight
    l "FreightItemsG:`t$($split.Good.Count)"
    l "FreightItemsB:`t$($split.Bad.Count)"

    l 'Saving Files'
    $taxFile = Join-Path $directory $mctf.file
    if ($split.Good.Count -eq 0) {
        # nothing passed, the package still goes out so the exception reports reach the filer
        Set-Content -LiteralPath $taxFile -Value '' -NoNewline
    } else {
        $convert = @{ State = $mctf.state; Period = $mctf.period; OutputPath = $taxFile }
        if ($mctf.filer_id) { $convert.FilerId = [string]$mctf.filer_id }
        if ($mctf.state -ne 'TN') {
            $convert.GeneratedAt = if ($mctf.generated_at) { [datetimeoffset]$mctf.generated_at } else { [datetimeoffset]$Context.RunAt }
        }
        $options = ConvertTo-MctfHashtable $mctf.state_options
        if ($options.Count -gt 0) { $convert.StateOptions = $options }
        if ($mctf.template_path) { $convert.TemplatePath = $mctf.template_path }
        $split.Good | ConvertTo-MotorFuelTaxFile @convert
    }
    $names = Export-MctfExceptionReport -Exceptions $exceptions -Split $split -RunAt $Context.RunAt -Directory $directory

    l 'Zipping Files'
    Compress-MctfPackage -Directory $directory -DestinationPath $Context.ArtifactPath `
        -Members @($names.Company, $names.Freight, $names.Good, $names.Bad, $mctf.file)
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

    $p = Get-MctfPeriod -RunAt $RunAt -Period $Period
    $taxFile = $cfg.file_format -f $p.Start
    $cfg.mctf.file = $taxFile
    $cfg.mctf.period = $p.Period
    # the pipeline names its one artifact from file_format, so hand it the finished zip name
    $cfg.file_format = "$taxFile.zip"

    # retention runs every pipeline run; a feed that keeps its artifacts must not lose them here
    if (-not $cfg.keepdays) { $cfg.keepdays = 30 }
    if (-not $cfg.purgefiles) { $cfg.purgefiles = '*.tmp' }

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
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Body
    )
    if (-not $PSCmdlet.ShouldProcess($Context.ArtifactPath, 'Mail the acknowledgement and the package')) { return }
    if ([string]::IsNullOrWhiteSpace($env:CLIENT_SECRET)) { throw 'CLIENT_SECRET is required.' }
    $cfg = $Context.Config
    if ($cfg.msgraph.client_secret) { throw 'client_secret belongs in the environment, not settings.' }
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
                name          = [IO.Path]::GetFileName($Context.ArtifactPath)
                contentType   = 'application/zip'
                contentBytes  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Context.ArtifactPath))
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
        [Parameter(Mandatory)] $Context,
        [switch] $NoSend
    )
    $cfg = $Context.Config
    $submit = $cfg.mctf.submit
    $processType = [string]$cfg.mctf.state_options.ProcessType
    $taxFile = Join-Path (Split-Path -Parent $Context.ArtifactPath) $cfg.mctf.file
    $uri = $env:MCTF_SUBMIT_URI
    $window = @($submit.window | ForEach-Object { [int]$_ })

    l "Submitting $($cfg.mctf.file)"
    if ($processType -eq 'T' -or (Test-MctfFilingWindow -Date $Context.RunAt -Window $window)) {
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
    l "Response: $response"
    $ack = Read-MctfAlabamaAcknowledgement -Response ([string]$response)

    if ($NoSend) {
        l 'NoSend: skipping the email, the response above is the whole result'
    } else {
        Send-MctfAcknowledgementMail -Context $Context -Body ([string]$response)
    }

    $outcome = @{
        adapter     = 'Submit-MctfAlabamaReturn'
        destination = @{ uri = $uri; mail = if ($NoSend) { $null } else { $cfg.mail } }
        state       = if ($ack.IsAcknowledged) { 'confirmed' } else { 'submitted' }
        mock        = $false
    }
    if ($ack.TransmissionId) { $outcome.id = $ack.TransmissionId }
    if ($ack.IsAcknowledged) { $outcome.acknowledgment = $ack.AcknowledgementId }
    $outcome
}

function Get-MctfPipelineMode {
    param(
        [Parameter(Mandatory)][string] $Mode,
        [Parameter(Mandatory)] $Config,
        [switch] $NoSend,
        [datetime] $RunAt = (Get-Date)
    )
    $pipelineMode = if ($Mode -eq 'Live') { 'Run' } else { $Mode }
    if (-not $NoSend -or $pipelineMode -ne 'Run') { return $pipelineMode }
    $submit = $Config.mctf.submit
    if (-not $submit) { return 'ExportOnly' }
    # a test submission always fires; a production one only inside the window. outside it, NoSend
    # leaves nothing to deliver
    $processType = [string]$Config.mctf.state_options.ProcessType
    $window = @($submit.window | ForEach-Object { [int]$_ })
    if ($processType -eq 'T' -or (Test-MctfFilingWindow -Date $RunAt -Window $window)) { 'Run' } else { 'ExportOnly' }
}

function Invoke-MctfFeed {
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
    param(
        [Parameter(Mandatory)][string] $SettingsPath,
        [ValidateSet('Mock', 'ExportOnly', 'Live')][string] $Mode = 'Mock',
        [string] $WorkingDirectory,
        [string] $FixturePath,
        [string] $Period,
        [switch] $NoSend,
        [datetime] $RunAt = (Get-Date)
    )
    $ErrorActionPreference = 'Stop'
    Import-Module DataAgent -RequiredVersion 0.3.0 -ErrorAction Stop
    $settingsFile = Get-Item -LiteralPath $SettingsPath
    $cfg = Resolve-MctfSettings -SettingsPath $settingsFile.FullName -RunAt $RunAt -Period $Period
    $pipelineMode = Get-MctfPipelineMode -Mode $Mode -Config $cfg -NoSend:$NoSend -RunAt $RunAt

    if (-not $WorkingDirectory) {
        $WorkingDirectory = if ($Mode -eq 'Live') {
            $settingsFile.DirectoryName
        } else {
            (New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ('mctf-' + [guid]::NewGuid().ToString('N')))).FullName
        }
    }

    # a period is reported several times before its filing date, and each run replaces the last
    # package for that period, as these feeds always have; version control keeps the earlier one.
    # DataAgent itself refuses an existing artifact, which is why this happens here, first.
    $existing = Join-Path $WorkingDirectory $cfg.file_format
    if (Test-Path -LiteralPath $existing) {
        if ($PSCmdlet.ShouldProcess($existing, 'Replace the package from an earlier run of this period')) {
            Remove-Item -LiteralPath $existing
        }
    }

    $extract = if ($Mode -eq 'Mock') {
        $fixture = if ($FixturePath) { (Get-Item -LiteralPath $FixturePath).FullName } else { Join-Path $PSScriptRoot 'synthetic.csv' }
        { param($context) Import-Csv -LiteralPath $fixture }.GetNewClosure()
    } else {
        { param($context) Invoke-DataAgentSql $context }
    }
    $transform = { param($rows, $context) Invoke-MctfTransform -Rows $rows -Context $context }
    $deliver = if ($Mode -eq 'Mock') {
        { param($context) Write-DataAgentRecording $context }
    } elseif ($cfg.mctf.submit) {
        { param($context) Invoke-MctfSubmission -Context $context -NoSend:$NoSend }.GetNewClosure()
    } else {
        { param($context) Send-DataAgentMail $context }
    }

    # preference variables stop at a module boundary, so WhatIf has to be handed over by name
    Invoke-DataAgentPipeline -Config $cfg -WorkingDirectory $WorkingDirectory -Mode $pipelineMode -RunAt $RunAt `
        -Extract $extract -Transform $transform -Deliver $deliver -StateKeyDirectory $settingsFile.DirectoryName `
        -WhatIf:$WhatIfPreference
}

Export-ModuleMember -Function Get-MctfPeriod, Test-MctfRecord, Split-MctfRecord, Export-MctfExceptionReport, Compress-MctfPackage,
    Invoke-MctfTransform, Resolve-MctfSettings, Invoke-MctfFeed, Test-MctfFilingWindow, Submit-MctfAlabamaReturn,
    Read-MctfAlabamaAcknowledgement, Send-MctfAcknowledgementMail, Invoke-MctfSubmission
