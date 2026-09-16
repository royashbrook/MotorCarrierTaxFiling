BeforeAll {
    $ErrorActionPreference = 'Stop'
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:fixtures = Join-Path $PSScriptRoot 'fixtures'
    Import-Module (Join-Path $script:root 'MotorCarrierTaxFiling/MotorCarrierTaxFiling.psd1') -Force
    $script:work = New-Item -ItemType Directory -Path (Join-Path ([IO.Path]::GetTempPath()) ('mctf-tests-' + [guid]::NewGuid().ToString('N')))
    $env:DATAAGENT_STATE_ROOT = Join-Path $script:work 'state'
    $script:records = @(Import-Csv -LiteralPath (Join-Path $script:root 'MotorCarrierTaxFiling/synthetic.csv'))
    $script:fl = Get-Content -LiteralPath (Join-Path $script:fixtures 'settings.fl.json') -Raw | ConvertFrom-Json
    $script:runAt = [datetime]'2026-08-04T11:00:00'
    function New-Case([string] $Name) { (New-Item -ItemType Directory -Path (Join-Path $script:work $Name)).FullName }
    function Get-ZipEntries([string] $Path) {
        $zip = [IO.Compression.ZipFile]::OpenRead($Path)
        try { @($zip.Entries | ForEach-Object { $_.FullName }) } finally { $zip.Dispose() }
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

Describe 'Resolve-MctfSettings' {
    It 'resolves the period into the tax file name and hands the pipeline the zip name' {
        $cfg = Resolve-MctfSettings -SettingsPath (Join-Path $script:fixtures 'settings.fl.json') -RunAt $script:runAt
        $cfg.mctf.file | Should -Be '202607.csv'
        $cfg.mctf.period | Should -Be '202607'
        $cfg.file_format | Should -Be '202607.csv.zip'
        ($cfg.file_format -f $script:runAt) | Should -Be '202607.csv.zip'
    }
    It 'supplies retention defaults that cannot touch committed artifacts' {
        $cfg = Resolve-MctfSettings -SettingsPath (Join-Path $script:fixtures 'settings.fl.json') -RunAt $script:runAt
        $cfg.keepdays | Should -Be 30
        $cfg.purgefiles | Should -Be '*.tmp'
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

Describe 'Invoke-MctfFeed in Mock mode' {
    It 'runs florida through the DataAgent pipeline and packages five files' {
        $dir = New-Case 'fl-mock'
        $receipt = Invoke-MctfFeed -SettingsPath (Join-Path $script:fixtures 'settings.fl.json') -Mode Mock -WorkingDirectory $dir -RunAt $script:runAt
        $receipt.status | Should -Be 'completed'
        $receipt.rowCount | Should -Be 6
        $receipt.artifacts[0].name | Should -Be '202607.csv.zip'
        $receipt.deliveries[0].mock | Should -BeTrue
        Get-ZipEntries (Join-Path $dir '202607.csv.zip') | Should -Be @('20260804-CompanyExceptions.csv', '20260804-FreightExceptions.csv', '20260804-FreightItemsGood.csv', '20260804-FreightItemsBad.csv', '202607.csv')
        (Get-Item (Join-Path $dir '202607.csv')).Length | Should -BeGreaterThan 0
        @(Import-Csv (Join-Path $dir '20260804-FreightItemsGood.csv')).Count | Should -Be 4
        @(Import-Csv (Join-Path $dir '20260804-FreightItemsAll.csv')).Count | Should -Be 6
        Test-Path (Join-Path $dir '20260804.log') | Should -BeTrue
    }
    It 'runs alabama through the formatter with its state options' {
        $dir = New-Case 'al-mock'
        $receipt = Invoke-MctfFeed -SettingsPath (Join-Path $script:fixtures 'settings.al.json') -Mode Mock -WorkingDirectory $dir -RunAt $script:runAt
        $receipt.status | Should -Be 'completed'
        $receipt.artifacts[0].name | Should -Be '202607-tax-al.xml.zip'
        $xml = Get-Content (Join-Path $dir '202607-tax-al.xml') -Raw
        $xml | Should -Match '<ProcessType>P</ProcessType>'
        $xml | Should -Match '<ETIN>12345</ETIN>'
    }
    It 'previews without writing anything under WhatIf' {
        $dir = New-Case 'whatif'
        $result = Invoke-MctfFeed -SettingsPath (Join-Path $script:fixtures 'settings.fl.json') -Mode Mock -WorkingDirectory $dir -RunAt $script:runAt -WhatIf
        $result | Should -BeNullOrEmpty
        @(Get-ChildItem $dir).Count | Should -Be 0
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
            $context = [pscustomobject]@{ Config = ($cfg | ConvertTo-Json -Depth 20 | ConvertFrom-Json); RunAt = [datetime]'2026-09-15'; ArtifactPath = (Join-Path $script:work 'none.zip') }
            { Invoke-MctfSubmission -Context $context -NoSend } | Should -Throw '*MCTF_SUBMIT_URI*'
        } finally { $env:MCTF_SUBMIT_URI, $env:MCTF_SUBMIT_USER, $env:MCTF_SUBMIT_PASSWORD = $saved }
    }
}

Describe 'Pipeline mode selection' {
    BeforeAll {
        $script:alCfg = Resolve-MctfSettings -SettingsPath (Join-Path $script:fixtures 'settings.al.json') -RunAt $script:runAt
        $script:flCfg = Resolve-MctfSettings -SettingsPath (Join-Path $script:fixtures 'settings.fl.json') -RunAt $script:runAt
    }
    It 'maps Live to Run and leaves Mock and ExportOnly alone' {
        InModuleScope MotorCarrierTaxFiling -Parameters @{ fl = $script:flCfg } {
            Get-MctfPipelineMode -Mode Live -Config $fl | Should -Be 'Run'
            Get-MctfPipelineMode -Mode Mock -Config $fl | Should -Be 'Mock'
            Get-MctfPipelineMode -Mode ExportOnly -Config $fl | Should -Be 'ExportOnly'
        }
    }
    It 'turns NoSend into ExportOnly for a feed that only mails' {
        InModuleScope MotorCarrierTaxFiling -Parameters @{ fl = $script:flCfg } {
            Get-MctfPipelineMode -Mode Live -Config $fl -NoSend | Should -Be 'ExportOnly'
        }
    }
    It 'keeps a NoSend alabama run inside the window, and drops it outside' {
        InModuleScope MotorCarrierTaxFiling -Parameters @{ al = $script:alCfg } {
            $al.mctf.state_options.ProcessType = 'P'
            Get-MctfPipelineMode -Mode Live -Config $al -NoSend -RunAt ([datetime]'2026-09-15') | Should -Be 'Run'
            Get-MctfPipelineMode -Mode Live -Config $al -NoSend -RunAt ([datetime]'2026-09-08') | Should -Be 'ExportOnly'
            $al.mctf.state_options.ProcessType = 'T'
            Get-MctfPipelineMode -Mode Live -Config $al -NoSend -RunAt ([datetime]'2026-09-08') | Should -Be 'Run'
        }
    }
}
