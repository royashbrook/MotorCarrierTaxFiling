BeforeAll {
    $ErrorActionPreference = 'Stop'
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:manifest = Join-Path $script:root 'MotorCarrierTaxFiling/MotorCarrierTaxFiling.psd1'
    $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
    Import-Module $script:manifest -Force
    $script:work = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ('mctf-tests-' + [guid]::NewGuid().ToString('N')))
    $script:records = @(Import-Csv -LiteralPath (Join-Path $script:root 'MotorCarrierTaxFiling/synthetic.csv'))
    $script:fl = Get-Content -LiteralPath (Join-Path $script:fixtures 'settings.fl.json') -Raw | ConvertFrom-Json
    $script:runAt = [datetime]'2026-08-04T11:00:00'
    function New-Case([string] $Name) { (New-Item -ItemType Directory -Path (Join-Path $script:work $Name)).FullName }
    function Get-ZipEntries([string] $Path) {
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        try { @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
    }
    # a feed is a directory with settings.json, its sql and a job.ps1 that calls Invoke-DataAgent.
    # the runner works from the calling script's directory, so the run has to happen in its own
    # process from that directory, exactly as the real feed does it.
    function New-Feed {
        param([string] $Name, [string] $Settings)
        $dir = New-Case $Name
        Copy-Item (Join-Path $script:fixtures $Settings) (Join-Path $dir 'settings.json')
        Copy-Item (Join-Path $script:fixtures 'get-data.sql') (Join-Path $dir 'get-data.sql')
        Set-Content -LiteralPath (Join-Path $dir 'job.ps1') -Value @"
param([string] `$Mode = 'Mock', [string] `$Period, [switch] `$NoSend, [string] `$FixturePath, [switch] `$Preview, [datetime] `$RunAt = (Get-Date))
`$ErrorActionPreference = 'Stop'
Import-Module '$script:manifest' -Force -ErrorAction Stop
`$mctf = @{ SettingsPath = "`$PSScriptRoot/settings.json"; Mode = `$Mode; Period = `$Period; NoSend = `$NoSend; RunAt = `$RunAt }
if (`$FixturePath) { `$mctf.FixturePath = `$FixturePath }
`$cfg = New-MctfConfig @mctf
Invoke-DataAgent -Config `$cfg -WhatIf:`$Preview
"@
        [pscustomobject]@{ Directory = $dir; Job = (Join-Path $dir 'job.ps1') }
    }
    function Invoke-Feed {
        param($Feed, [string[]] $Arguments = @(), [datetime] $RunAt = $script:runAt)
        $output = & pwsh -NoProfile -File $Feed.Job @Arguments -RunAt $RunAt.ToString('o') 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }
}

AfterAll {
    Remove-Item -Recurse -Force $script:work -ErrorAction SilentlyContinue
}

Describe 'Get-MctfPeriod' {
    It 'defaults to the month before the run' {
        $p = Get-MctfPeriod -RunAt ([datetime]'2026-09-15')
        $p.Period | Should -Be '202608'
        $p.Start | Should -Be ([datetime]'2026-08-01')
        $p.End | Should -Be ([datetime]'2026-08-31')
    }
    It 'crosses the year boundary' {
        (Get-MctfPeriod -RunAt ([datetime]'2027-01-05')).Period | Should -Be '202612'
    }
    It 'takes an explicit period' {
        $p = Get-MctfPeriod -RunAt ([datetime]'2026-09-15') -Period '202606'
        $p.Period | Should -Be '202606'
        $p.End | Should -Be ([datetime]'2026-06-30')
    }
    It 'rejects a malformed period' {
        { Get-MctfPeriod -Period '2026-06' } | Should -Throw
    }
}

Describe 'Test-MctfRecord and Split-MctfRecord' {
    BeforeAll {
        $script:exceptions = Test-MctfRecord -Records $script:records -Tests @($script:fl.tests) -CompanyTypes @($script:fl.companytypes)
        $script:split = Split-MctfRecord -Records $script:records -FreightExceptions $script:exceptions.Freight
    }
    It 'flags the freight row whose bol is not numeric' {
        $hit = @($script:exceptions.Freight | Where-Object test -eq 'BOL is not a 3 to 12 digit number')
        $hit.Count | Should -Be 1
        $hit[0].fgt_number | Should -Be '9100004'
        $hit[0].current | Should -Be 'BOL-BAD'
    }
    It 'tests each distinct company once and reports its key' {
        $hit = @($script:exceptions.Company | Where-Object test -eq 'Consignee tax id is not 9 digits')
        $hit.Count | Should -Be 1
        $hit[0].type | Should -Be 'Consignee'
        $hit[0].cmp_id | Should -Be 'CUST003'
        $hit[0].current | Should -Be '44-444'
    }
    It 'turns a failing company into a freight exception for every row that references it' {
        $hit = @($script:exceptions.Freight | Where-Object test -eq 'Bad Consignee Record')
        $hit.Count | Should -Be 1
        $hit[0].fgt_number | Should -Be '9100005'
    }
    It 'lists freight-only exceptions before company-driven ones' {
        $script:exceptions.Freight[0].test | Should -Be 'BOL is not a 3 to 12 digit number'
        $script:exceptions.Freight[-1].test | Should -Be 'Bad Consignee Record'
    }
    It 'keeps the exception column order the reports have always had' {
        @($script:exceptions.Freight[0].PSObject.Properties.Name) | Should -Be @('ord_hdrnumber', 'fgt_number', 'test', 'current')
        @($script:exceptions.Company[0].PSObject.Properties.Name) | Should -Be @('type', 'cmp_id', 'test', 'current')
    }
    It 'splits good from bad by freight number and keeps the input order' {
        $script:split.Good.Count | Should -Be 4
        $script:split.Bad.Count | Should -Be 2
        @($script:split.Good.fgt_number) | Should -Be @('9100001', '9100002', '9100003', '9100006')
        @($script:split.Bad.fgt_number) | Should -Be @('9100004', '9100005')
    }
    It 'returns everything as good when there are no exceptions' {
        $s = Split-MctfRecord -Records $script:records -FreightExceptions @()
        $s.Good.Count | Should -Be $script:records.Count
        $s.Bad.Count | Should -Be 0
    }
}

Describe 'Export-MctfExceptionReport' {
    It 'writes the four dated reports, byte for byte what Export-Csv writes' {
        $dir = New-Case 'reports'
        $exceptions = Test-MctfRecord -Records $script:records -Tests @($script:fl.tests) -CompanyTypes @($script:fl.companytypes)
        $split = Split-MctfRecord -Records $script:records -FreightExceptions $exceptions.Freight
        $names = Export-MctfExceptionReport -Exceptions $exceptions -Split $split -RunAt $script:runAt -Directory $dir
        @($names.Values) | Should -Be @('20260804-CompanyExceptions.csv', '20260804-FreightExceptions.csv', '20260804-FreightItemsGood.csv', '20260804-FreightItemsBad.csv')
        $baseline = Join-Path $dir 'baseline.csv'
        $split.Good | Export-Csv -NoTypeInformation -LiteralPath $baseline
        (Get-FileHash $baseline).Hash | Should -Be (Get-FileHash (Join-Path $dir $names.Good)).Hash
    }
    It 'writes an empty file for an empty set, as the feeds always have' {
        $dir = New-Case 'empty-reports'
        $names = Export-MctfExceptionReport -Exceptions ([pscustomobject]@{ Company = @(); Freight = @() }) -Split ([pscustomobject]@{ Good = $script:records; Bad = @() }) -RunAt $script:runAt -Directory $dir
        (Get-Item (Join-Path $dir $names.Company)).Length | Should -Be 0
    }
}

Describe 'Invoke-MctfTransform on a source that returns tables' {
    BeforeAll {
        $script:table = [System.Data.DataTable]::new('rows')
        foreach ($c in @($script:records[0].PSObject.Properties.Name)) { $null = $script:table.Columns.Add($c, [string]) }
        foreach ($r in $script:records) {
            $row = $script:table.NewRow()
            foreach ($c in $script:table.Columns) { $row[$c.ColumnName] = [string]$r.($c.ColumnName) }
            $script:table.Rows.Add($row)
        }
        $script:settings = Resolve-MctfSettings -SettingsPath (Join-Path $script:fixtures 'settings.fl.json') -RunAt $script:runAt
    }
    It 'refuses a table collection instead of writing the table object as freight' {
        $set = [System.Data.DataSet]::new()
        $set.Tables.Add($script:table)
        $dir = New-Case 'tables'
        { Invoke-MctfTransform -Rows @($set.Tables) -Settings $script:settings -RunAt $script:runAt -ArtifactPath (Join-Path $dir '202607.csv.zip') } |
            Should -Throw '*tables, not rows*'
        @(Get-ChildItem $dir).Count | Should -Be 0
    }
    It 'takes the rows of a single table, which enumerates on its own' {
        $dir = New-Case 'one-table'
        Invoke-MctfTransform -Rows @($script:table) -Settings $script:settings -RunAt $script:runAt -ArtifactPath (Join-Path $dir '202607.csv.zip') | Out-Null
        @(Import-Csv (Join-Path $dir '20260804-FreightItemsAll.csv')).Count | Should -Be $script:records.Count
        @((Import-Csv (Join-Path $dir '20260804-FreightItemsAll.csv'))[0].PSObject.Properties.Name) | Should -Contain 'fgt_number'
    }
}

Describe 'Resolve-MctfSettings' {
    It 'resolves the period into the tax file name and hands the runner the zip name' {
        $cfg = Resolve-MctfSettings -SettingsPath (Join-Path $script:fixtures 'settings.fl.json') -RunAt $script:runAt
        $cfg.mctf.file | Should -Be '202607.csv'
        $cfg.mctf.period | Should -Be '202607'
        $cfg.file_format | Should -Be '202607.csv.zip'
        ($cfg.file_format -f $script:runAt) | Should -Be '202607.csv.zip'
    }
    It 'leaves retention alone unless the feed asked for it' {
        $cfg = Resolve-MctfSettings -SettingsPath (Join-Path $script:fixtures 'settings.fl.json') -RunAt $script:runAt
        $cfg.keepdays | Should -BeNullOrEmpty
        $cfg.purgefiles | Should -BeNullOrEmpty
    }
    It 'normalizes a string sql setting and injects the period variables' {
        $cfg = Resolve-MctfSettings -SettingsPath (Join-Path $script:fixtures 'settings.fl.json') -RunAt $script:runAt
        $cfg.sql.InputFile | Should -Be (Join-Path $script:fixtures 'get-data.sql')
        $cfg.sql.QueryTimeout | Should -Be 1800
        @($cfg.sql.Variable) | Should -Be @('Period=202607', 'PeriodStart=2026-07-01', 'PeriodEnd=2026-07-31')
    }
    It 'accepts an explicit period when the sql is period-aware' {
        $cfg = Resolve-MctfSettings -SettingsPath (Join-Path $script:fixtures 'settings.fl.json') -RunAt $script:runAt -Period '202606'
        $cfg.mctf.file | Should -Be '202606.csv'
        @($cfg.sql.Variable)[0] | Should -Be 'Period=202606'
    }
    It 'refuses an explicit period when the sql still anchors on the run date' {
        $legacy = Join-Path $script:work 'legacy'
        $null = New-Item -ItemType Directory -Path $legacy
        Copy-Item (Join-Path $script:fixtures 'get-data.legacy.sql') (Join-Path $legacy 'get-data.sql')
        Copy-Item (Join-Path $script:fixtures 'settings.fl.json') (Join-Path $legacy 'settings.json')
        { Resolve-MctfSettings -SettingsPath (Join-Path $legacy 'settings.json') -RunAt $script:runAt -Period '202606' } | Should -Throw '*period-aware*'
        { Resolve-MctfSettings -SettingsPath (Join-Path $legacy 'settings.json') -RunAt $script:runAt } | Should -Not -Throw
    }
    It 'defaults the alabama process type and window when submit is configured' {
        $saved = $env:MCTF_PROCESS_TYPE
        try {
            $env:MCTF_PROCESS_TYPE = $null
            $cfg = Resolve-MctfSettings -SettingsPath (Join-Path $script:fixtures 'settings.al.json') -RunAt $script:runAt
            $cfg.mctf.state_options.ProcessType | Should -Be 'P'
            @($cfg.mctf.submit.window) | Should -Be @(14, 20)
            $env:MCTF_PROCESS_TYPE = 'T'
            (Resolve-MctfSettings -SettingsPath (Join-Path $script:fixtures 'settings.al.json') -RunAt $script:runAt).mctf.state_options.ProcessType | Should -Be 'T'
        } finally { $env:MCTF_PROCESS_TYPE = $saved }
    }
}

Describe 'New-MctfConfig' {
    BeforeAll {
        $script:flSettings = Join-Path $script:fixtures 'settings.fl.json'
        $script:alSettings = Join-Path $script:fixtures 'settings.al.json'
        $script:savedSecret = $env:CLIENT_SECRET
        $env:CLIENT_SECRET = 'test-secret'
    }
    AfterAll { $env:CLIENT_SECRET = $script:savedSecret }

    It 'names the live package as the feeds always have, and keeps a rehearsal out of the feed' {
        (New-MctfConfig -SettingsPath $script:flSettings -Mode Live -RunAt $script:runAt).file_format | Should -Be '202607.csv.zip'
        (New-MctfConfig -SettingsPath $script:flSettings -Mode Mock -RunAt $script:runAt).file_format | Should -Be (Join-Path 'rehearsal' '202607.csv.zip')
    }
    It 'reads the packaged synthetic rows in Mock and the database otherwise' {
        $mock = New-MctfConfig -SettingsPath $script:flSettings -Mode Mock -RunAt $script:runAt
        $mock.src.adapter | Should -Be 'csv'
        $mock.src.args.LiteralPath | Should -Be (Join-Path $script:root 'MotorCarrierTaxFiling/synthetic.csv')
        $export = New-MctfConfig -SettingsPath $script:flSettings -Mode ExportOnly -RunAt $script:runAt
        $export.src.adapter | Should -Be 'sql'
        @($export.src.args.Variable) | Should -Be @('Period=202607', 'PeriodStart=2026-07-01', 'PeriodEnd=2026-07-31')
    }
    It 'takes a fixture path for Mock' {
        $fixture = Join-Path $script:work 'fixture.csv'
        $script:records | Export-Csv -NoTypeInformation -LiteralPath $fixture
        (New-MctfConfig -SettingsPath $script:flSettings -Mode Mock -FixturePath $fixture -RunAt $script:runAt).src.args.LiteralPath | Should -Be $fixture
    }
    It 'packages through the module adapter and passes the resolved settings' {
        $cfg = New-MctfConfig -SettingsPath $script:flSettings -Mode Live -RunAt $script:runAt
        $cfg.fmt.adapter | Should -Be (Join-Path $script:root 'MotorCarrierTaxFiling/adapters/package.ps1')
        $cfg.fmt.args.Settings.mctf.file | Should -Be '202607.csv'
        $cfg.fmt.args.RunAt | Should -Be $script:runAt
    }
    It 'mails a live florida run, and keeps the secret out of the config' {
        $cfg = New-MctfConfig -SettingsPath $script:flSettings -Mode Live -RunAt $script:runAt
        @($cfg.dst).Count | Should -Be 1
        $cfg.dst[0].adapter | Should -BeLike '*mail.ps1'
        $cfg.dst[0].args.Settings.mail.subject | Should -Be 'FL Taxes'
        ($cfg | ConvertTo-Json -Depth 20) | Should -Not -Match 'test-secret'
    }
    It 'sends nothing for a rehearsal or a NoSend run that only mails' {
        (New-MctfConfig -SettingsPath $script:flSettings -Mode Mock -RunAt $script:runAt).dst[0].adapter | Should -BeLike '*skip.ps1'
        (New-MctfConfig -SettingsPath $script:flSettings -Mode ExportOnly -RunAt $script:runAt).dst[0].adapter | Should -BeLike '*skip.ps1'
        $nosend = New-MctfConfig -SettingsPath $script:flSettings -Mode Live -NoSend -RunAt $script:runAt
        $nosend.dst[0].adapter | Should -BeLike '*skip.ps1'
        $nosend.dst[0].args.Reason | Should -Be 'NoSend'
    }
    It 'keeps the alabama submission on a NoSend run and only drops its mail' {
        $cfg = New-MctfConfig -SettingsPath $script:alSettings -Mode Live -NoSend -RunAt $script:runAt
        $cfg.dst[0].adapter | Should -BeLike '*alabama.ps1'
        $cfg.dst[0].args.NoSend | Should -BeTrue
        (New-MctfConfig -SettingsPath $script:alSettings -Mode Live -RunAt $script:runAt).dst[0].args.NoSend | Should -BeFalse
    }
    It 'refuses a secret in settings' {
        $bad = Join-Path $script:work 'secret-settings.json'
        $json = Get-Content -LiteralPath $script:flSettings -Raw | ConvertFrom-Json
        $json.msgraph.client_secret = 'in-the-file'
        $json | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $bad
        { New-MctfConfig -SettingsPath $bad -Mode Live -RunAt $script:runAt } | Should -Throw '*environment*'
    }
}

Describe 'A feed run, end to end on DataAgent' {
    It 'runs florida in Mock and packages five files beside the log' {
        $feed = New-Feed -Name 'fl-mock' -Settings 'settings.fl.json'
        $run = Invoke-Feed -Feed $feed
        $run.ExitCode | Should -Be 0
        $rehearsal = Join-Path $feed.Directory 'rehearsal'
        Get-ZipEntries (Join-Path $rehearsal '202607.csv.zip') | Should -Be @('20260804-CompanyExceptions.csv', '20260804-FreightExceptions.csv', '20260804-FreightItemsGood.csv', '20260804-FreightItemsBad.csv', '202607.csv')
        (Get-Item (Join-Path $rehearsal '202607.csv')).Length | Should -BeGreaterThan 0
        @(Import-Csv (Join-Path $rehearsal '20260804-FreightItemsGood.csv')).Count | Should -Be 4
        @(Import-Csv (Join-Path $rehearsal '20260804-FreightItemsAll.csv')).Count | Should -Be 6
        # the log is the runner's, in the feed directory, and it carries the run's receipt lines
        $log = Get-Content (Join-Path $feed.Directory ('{0:yyyyMMdd}.log' -f (Get-Date))) -Raw
        $log | Should -Match 'mctf: state=FL period=202607 rows=6 good=4 bad=2'
        $log | Should -Match 'mctf: artifact=202607.csv.zip bytes=\d+ sha256=[0-9A-F]{64}'
        $log | Should -Match 'mctf: delivery=none reason=Mock is a rehearsal'
    }
    It 'runs alabama through the formatter with its state options' {
        $feed = New-Feed -Name 'al-mock' -Settings 'settings.al.json'
        (Invoke-Feed -Feed $feed).ExitCode | Should -Be 0
        $xml = Get-Content (Join-Path $feed.Directory 'rehearsal/202607-tax-al.xml') -Raw
        $xml | Should -Match '<ProcessType>P</ProcessType>'
        $xml | Should -Match '<ETIN>12345</ETIN>'
    }
    It 'replaces the package from an earlier run of the same period' {
        $feed = New-Feed -Name 'rerun' -Settings 'settings.fl.json'
        (Invoke-Feed -Feed $feed).ExitCode | Should -Be 0
        (Invoke-Feed -Feed $feed -RunAt $script:runAt.AddDays(7)).ExitCode | Should -Be 0
        $rehearsal = Join-Path $feed.Directory 'rehearsal'
        @(Get-ChildItem $rehearsal -Filter '*.zip').Count | Should -Be 1
        Get-ZipEntries (Join-Path $rehearsal '202607.csv.zip') | Should -Contain '20260811-FreightItemsGood.csv'
    }
    It 'writes no package and says so when the source is empty' {
        $feed = New-Feed -Name 'empty' -Settings 'settings.fl.json'
        $empty = Join-Path $script:work 'empty.csv'
        Set-Content -LiteralPath $empty -Value 'fgt_number'
        $run = Invoke-Feed -Feed $feed -Arguments @('-Mode', 'Mock', '-FixturePath', $empty)
        $run.ExitCode | Should -Be 0
        $run.Output | Should -Match 'No data available'
        Test-Path (Join-Path $feed.Directory 'rehearsal') | Should -BeFalse
    }
    It 'previews without writing anything under WhatIf' {
        $feed = New-Feed -Name 'whatif' -Settings 'settings.fl.json'
        $run = Invoke-Feed -Feed $feed -Arguments @('-Mode', 'Mock', '-Preview')
        $run.ExitCode | Should -Be 0
        @(Get-ChildItem $feed.Directory -Exclude 'job.ps1', 'settings.json', 'get-data.sql').Count | Should -Be 0
    }
}

Describe 'Alabama submission stages' {
    It 'opens the filing window on the 14th through the 20th only' {
        Test-MctfFilingWindow -Date ([datetime]'2026-09-13') | Should -BeFalse
        Test-MctfFilingWindow -Date ([datetime]'2026-09-14') | Should -BeTrue
        Test-MctfFilingWindow -Date ([datetime]'2026-09-20') | Should -BeTrue
        Test-MctfFilingWindow -Date ([datetime]'2026-09-21') | Should -BeFalse
    }
    It 'reads a clean acknowledgement' {
        $ack = Read-MctfAlabamaAcknowledgement -Response (Get-Content (Join-Path $script:fixtures 'ack.xml') -Raw)
        $ack.IsAcknowledged | Should -BeTrue
        $ack.AcknowledgementId | Should -Be '123456789'
        $ack.TransmissionId | Should -Be 'AL20260715110604'
        $ack.ProcessType | Should -Be 'T'
        $ack.Errors.Count | Should -Be 0
    }
    It 'does not acknowledge a response carrying errors' {
        $withError = (Get-Content (Join-Path $script:fixtures 'ack.xml') -Raw) -replace '<Errors />', '<Errors><Error><Code>X1</Code></Error></Errors>'
        $ack = Read-MctfAlabamaAcknowledgement -Response $withError
        $ack.IsAcknowledged | Should -BeFalse
        $ack.Errors.Count | Should -Be 1
    }
    It 'treats a non-xml response as not acknowledged' {
        $ack = Read-MctfAlabamaAcknowledgement -Response 'No filing was done. Filing is only done when this job runs from the 14 to the 20.'
        $ack.IsAcknowledged | Should -BeFalse
        $ack.Message | Should -Match 'No filing was done'
    }
    It 'refuses to submit without the environment' {
        $saved = @($env:MCTF_SUBMIT_URI, $env:MCTF_SUBMIT_USER, $env:MCTF_SUBMIT_PASSWORD)
        try {
            $env:MCTF_SUBMIT_URI = $null; $env:MCTF_SUBMIT_USER = $null; $env:MCTF_SUBMIT_PASSWORD = $null
            $cfg = Resolve-MctfSettings -SettingsPath (Join-Path $script:fixtures 'settings.al.json') -RunAt ([datetime]'2026-09-15')
            { Invoke-MctfSubmission -Settings $cfg -ArtifactPath (Join-Path $script:work 'none.zip') -RunAt ([datetime]'2026-09-15') -NoSend } |
                Should -Throw '*MCTF_SUBMIT_URI*'
        } finally { $env:MCTF_SUBMIT_URI, $env:MCTF_SUBMIT_USER, $env:MCTF_SUBMIT_PASSWORD = $saved }
    }
    It 'says no filing was done outside the window, without touching the state' {
        $dir = New-Case 'al-outside-window'
        $cfg = Resolve-MctfSettings -SettingsPath (Join-Path $script:fixtures 'settings.al.json') -RunAt ([datetime]'2026-09-08')
        Set-Content -LiteralPath (Join-Path $dir $cfg.mctf.file) -Value '<Transmission />'
        Set-Content -LiteralPath (Join-Path $dir 'none.zip') -Value ''
        $lines = Invoke-MctfSubmission -Settings $cfg -ArtifactPath (Join-Path $dir 'none.zip') -RunAt ([datetime]'2026-09-08') -NoSend
        ($lines -join "`n") | Should -Match 'No filing was done'
        ($lines -join "`n") | Should -Match 'delivery=alabama state=submitted acknowledgement=none mailed=False'
    }
    It 'reaches the state on an unattended run instead of stopping to ask for confirmation' {
        # a scheduled runner is non-interactive, so a confirmation prompt there is an error and
        # the filing never leaves. nothing listens on the discard port, so a real attempt fails
        # on the connection, which is the proof the call was made.
        $dir = New-Case 'al-unattended'
        $settings = Join-Path $script:fixtures 'settings.al.json'
        $script = @"
Import-Module '$($script:manifest)'
`$env:MCTF_SUBMIT_URI = 'http://127.0.0.1:9/NewSubmission'; `$env:MCTF_SUBMIT_USER = 'u'; `$env:MCTF_SUBMIT_PASSWORD = 'p'; `$env:MCTF_PROCESS_TYPE = 'T'
`$cfg = Resolve-MctfSettings -SettingsPath '$settings' -RunAt ([datetime]'2026-09-08')
Set-Content -LiteralPath (Join-Path '$dir' `$cfg.mctf.file) -Value '<Transmission />'
Set-Content -LiteralPath (Join-Path '$dir' 'none.zip') -Value ''
Invoke-MctfSubmission -Settings `$cfg -ArtifactPath (Join-Path '$dir' 'none.zip') -RunAt ([datetime]'2026-09-08') -NoSend
"@
        $output = & pwsh -NoProfile -NonInteractive -Command $script 2>&1 | Out-String
        $output | Should -Match 'Failed to submit TaxFile'
        $output | Should -Not -Match 'ShouldProcess|NonInteractive'
    }
}
Describe 'The tmw source' {
    BeforeAll {
        $script:kySettings = Join-Path $script:fixtures 'settings.ky.json'
        $script:kyRunAt = [datetime]'2026-09-15'
    }
    It 'maps the product codes the way sql server compares them, and flags what is unmapped' {
        $rows = @(
            [pscustomobject]@{ fgt_number = '1'; cmd_code = '150'; net = '100' }
            [pscustomobject]@{ fgt_number = '2'; cmd_code = '105  '; net = '200' }
            [pscustomobject]@{ fgt_number = '3'; cmd_code = '999'; net = '300' }
            [pscustomobject]@{ fgt_number = '4'; cmd_code = [DBNull]::Value; net = '400' }
        )
        $out = @(ConvertTo-MctfProductCode -Rows $rows -Products @{ '065' = @('150'); 'E10' = @('105') })
        $out.cmd_code[0] | Should -Be '065'
        $out.cmd_code[1] | Should -Be 'E10'
        $out.cmd_code[2] | Should -Be 'nocode-999'
        $out[3].cmd_code | Should -BeOfType [DBNull]
        # the column order is the query's, which the reports keep
        @($out[0].PSObject.Properties.Name) | Should -Be @('fgt_number', 'cmd_code', 'net')
    }
    It 'maps the rows of a sql result, keeping every column' {
        $table = [System.Data.DataTable]::new()
        foreach ($c in 'fgt_number', 'cmd_code') { $null = $table.Columns.Add($c, [string]) }
        $table.Columns['cmd_code'].MaxLength = 3
        $null = $table.Rows.Add('1', '999')
        $out = @(ConvertTo-MctfProductCode -Rows @($table.Rows) -Products @{ '065' = @('150') })
        $out[0].cmd_code | Should -Be 'nocode-999'
        $out[0].fgt_number | Should -Be '1'
    }
    It 'refuses a source code mapped to two products' {
        { ConvertTo-MctfProductCode -Rows @() -Products @{ '065' = @('150'); 'E10' = @('150') } } | Should -Throw '*mapped twice*'
    }
    It 'hands the query every variable it reads, and nothing it does not' {
        $cfg = Resolve-MctfSettings -SettingsPath $script:kySettings -RunAt $script:kyRunAt
        $vars = Get-MctfTmwVariable -Settings $cfg
        $vars | Should -Contain 'State=ky'
        $vars | Should -Contain 'PeriodStart=20260801'
        $vars | Should -Contain 'CommodityClasses=100,200'
        $sql = Get-Content -LiteralPath (Join-Path $script:root 'MotorCarrierTaxFiling/sources/tmw.sql') -Raw
        $used = @([regex]::Matches($sql, '\$\((\w+)\)') | ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
        $given = @($vars | ForEach-Object { ($_ -split '=', 2)[0] } | Sort-Object -Unique)
        $given | Should -Be $used
    }
    It 'refuses a source setting that is not a plain code, since it goes into the query as text' {
        $cfg = Resolve-MctfSettings -SettingsPath $script:kySettings -RunAt $script:kyRunAt
        $cfg.mctf.source.revtype1 = "x'; drop table orderheader --"
        { Get-MctfTmwVariable -Settings $cfg } | Should -Throw '*plain code*'
    }
    It 'takes the state tests and company types from the module when settings carry none' {
        $cfg = Resolve-MctfSettings -SettingsPath $script:kySettings -RunAt $script:kyRunAt
        $state = Get-Content -LiteralPath (Join-Path $script:root 'MotorCarrierTaxFiling/states/KY.json') -Raw | ConvertFrom-Json
        $cfg.tests.Count | Should -Be $state.tests.Count
        $cfg.tests[0].name | Should -Be $state.tests[0].name
        $cfg.companytypes.Count | Should -Be 4
        $state.spec.pinned | Should -Match '^\d{4}-\d{2}-\d{2}$'
    }
    It 'reads the database through the tmw adapter, and still rehearses from the fixture in Mock' {
        (New-MctfConfig -SettingsPath $script:kySettings -Mode Live -NoSend -RunAt $script:kyRunAt).src.adapter | Should -BeLike '*tmw.ps1'
        (New-MctfConfig -SettingsPath $script:kySettings -Mode Mock -RunAt $script:kyRunAt).src.adapter | Should -Be 'csv'
    }
    It 'takes an explicit period, since the tmw query reads the period it is given' {
        $cfg = Resolve-MctfSettings -SettingsPath $script:kySettings -RunAt $script:kyRunAt -Period '202601'
        Get-MctfTmwVariable -Settings $cfg | Should -Contain 'PeriodStart=20260101'
    }
    It 'refuses a source it does not read' {
        $path = Join-Path $script:work 'settings.other.json'
        (Get-Content -LiteralPath $script:kySettings -Raw) -replace '"name": "tmw"', '"name": "other"' | Set-Content -LiteralPath $path
        { Resolve-MctfSettings -SettingsPath $path -RunAt $script:kyRunAt } | Should -Throw '*tmw is*'
    }
}

Describe 'State shaping on the tmw source' {
    BeforeAll {
        function New-ShapeSettings([string] $State, [string] $Period = '202608') { @{ mctf = @{ state = $State; period = $Period } } }
        function New-Row([hashtable] $Values) {
            $row = [ordered]@{ fgt_number = '1'; delivered = '2026-08-15T10:00:00-04:00'; 'consignor.name' = 'A'; 'consignee.address' = 'X'; 'consignee.state' = 'FL'; 'consignee.dep' = [DBNull]::Value; schedule = '14A'; cmd_code = '065'; 'consignee.county' = 'DUVAL' }
            foreach ($k in $Values.Keys) { $row[$k] = $Values[$k] }
            [pscustomobject]$row
        }
    }
    It 'drops the source helper column for every state, shaped or not' {
        $out = @(Invoke-MctfStateShape -Rows @(New-Row @{}) -Settings (New-ShapeSettings 'KY'))
        $out[0].PSObject.Properties.Name | Should -Not -Contain 'consignee.county'
        $out[0].PSObject.Properties.Name | Should -Contain 'cmd_code'
    }
    It 'cuts a value longer than the state takes to fit, and leaves a null or a short value alone' {
        $sc = @(Invoke-MctfStateShape -Rows @((New-Row @{ 'consignor.name' = ('N' * 60) }), (New-Row @{ 'consignor.name' = [DBNull]::Value }), (New-Row @{ 'consignor.name' = ('N' * 40) })) -Settings (New-ShapeSettings 'SC'))
        $sc[0].'consignor.name' | Should -Be ('N' * 50)
        $sc[1].'consignor.name' | Should -BeOfType [DBNull]
        $sc[2].'consignor.name' | Should -Be ('N' * 40)
        $fl = @(Invoke-MctfStateShape -Rows @(New-Row @{ 'consignee.name' = 'FLORIDA STATE OF CHIPLEY DISTRICT OFFICE' }) -Settings (New-ShapeSettings 'FL'))
        $fl[0].'consignee.name' | Should -Be 'FLORIDA STATE OF CHIPLEY DISTRICT O'
        $ky = @(Invoke-MctfStateShape -Rows @(New-Row @{ 'consignee.city' = ('C' * 31) }) -Settings (New-ShapeSettings 'KY'))
        $ky[0].'consignee.city' | Should -Be ('C' * 30)
    }
    It 'spells out the tennessee schedules' {
        $out = @(Invoke-MctfStateShape -Rows @(New-Row @{ schedule = '14B' }) -Settings (New-ShapeSettings 'TN'))
        $out[0].schedule | Should -Be '2A - Product loaded at an out-of-state terminal, bulk plant, or refinery and delivered to Tennessee'
    }
    It 'cleans the alabama address in the order the state query always did' {
        $rows = @(
            (New-Row @{ 'consignee.address' = "12 Main St., Suite #4 (Rear) & Co: O'Neil" })
            (New-Row @{ 'consignee.address' = [DBNull]::Value })
            (New-Row @{ 'consignee.address' = ('A' * 40) })
        )
        $out = @(Invoke-MctfStateShape -Rows $rows -Settings (New-ShapeSettings 'AL'))
        # worked by hand from the query's nested replaces: & @ # . : ' become spaces, , ( ) go, then
        # every pair of spaces goes, then the ends are trimmed and it is cut to 35
        $out[0].'consignee.address' | Should -Be '12 Main StSuite4 Rear CoO Neil'
        $out[1].'consignee.address' | Should -Be 'No Address'
        $out[2].'consignee.address' | Should -Be ('A' * 35)
        $out[0].'consignee.dep' | Should -Be 'FL'
    }
    It 'marks florida rows delivered in the period, right after the delivery date' {
        $out = @(Invoke-MctfStateShape -Rows @((New-Row @{}), (New-Row @{ delivered = '2026-09-01T01:00:00-04:00' }), (New-Row @{ delivered = [DBNull]::Value })) -Settings (New-ShapeSettings 'FL'))
        $names = @($out[0].PSObject.Properties.Name)
        $names.IndexOf('delivered.inperiod') | Should -Be ($names.IndexOf('delivered') + 1)
        @($out.'delivered.inperiod') | Should -Be @('1', '0', '0')
    }
    It 'fills a missing florida DEP number with the county placeholder in state, and the state out of it' {
        $rows = @(
            (New-Row @{})
            (New-Row @{ 'consignee.state' = 'GA'; 'consignee.county' = 'COBB' })
            (New-Row @{ 'consignee.dep' = '160000001' })
            (New-Row @{ 'consignee.county' = 'NOWHERE' })
            (New-Row @{ 'consignee.county' = 'DE SOTO' })
        )
        $out = @(Invoke-MctfStateShape -Rows $rows -Settings (New-ShapeSettings 'FL'))
        @($out.'consignee.dep') | Should -Be @('161111111', 'GA', '160000001', 'FL', '141111111')
    }
    It 'reads the period basis from the state file and the shipper state from the source settings' {
        $cfg = Resolve-MctfSettings -SettingsPath (Join-Path $script:fixtures 'settings.ky.json') -RunAt ([datetime]'2026-09-15')
        Get-MctfTmwVariable -Settings $cfg | Should -Contain 'PeriodBasis=completion'
        Get-MctfTmwVariable -Settings $cfg | Should -Contain 'ShipperState=company'
        $cfg.mctf.state = 'NC'
        $cfg.mctf.source.shipper_state = 'city'
        Get-MctfTmwVariable -Settings $cfg | Should -Contain 'PeriodBasis=start'
        Get-MctfTmwVariable -Settings $cfg | Should -Contain 'ShipperState=city'
        $cfg.mctf.source.shipper_state = 'zip'
        { Get-MctfTmwVariable -Settings $cfg } | Should -Throw '*company or city*'
    }
    It 'ships a state file with tests and a dated spec for every state' {
        foreach ($s in 'AL', 'FL', 'KY', 'NC', 'SC', 'TN', 'VA') {
            $state = Get-MctfState -State $s
            $state.tests.Count | Should -BeGreaterThan 10
            $state.spec.pinned | Should -Match '^\d{4}-\d{2}'
            $state.spec.where | Should -Match '^https?://'
            $state.spec.version | Should -Not -BeNullOrEmpty
            $state.spec.checked | Should -Match '^\d{4}-\d{2}-\d{2}$'
        }
    }
}
