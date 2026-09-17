# MotorCarrierTaxFiling

Validate freight records, report the exceptions, format the state return, package it, and for Alabama submit it. The stages of a motor carrier tax filing feed, as a PowerShell module that runs on [DataAgent](https://github.com/royashbrook/DataAgent) 0.4.0.

MCTF is motor carrier tax filing. If you carry fuel in trucks, some states require a monthly report of what you carried, where it came from and where it went. You do not pay tax on it, you declare it. The per-state file formats live in [MotorFuelTaxFormats](https://github.com/royashbrook/motor-fuel-tax-formats); this module is everything around the formatter.

## What a feed looks like

A feed is a directory with `settings.json`, a `get-data.sql` that produces flat freight rows, and this job:

```powershell
param([ValidateSet('Mock','ExportOnly','Live')][string]$Mode = 'Mock', [string]$Period, [switch]$NoSend)
Import-Module DataAgent -RequiredVersion 0.4.0 -ErrorAction Stop
Import-Module MotorCarrierTaxFiling -RequiredVersion 0.2.0 -ErrorAction Stop
$cfg = New-MctfConfig -SettingsPath "$PSScriptRoot/settings.json" -Mode $Mode -Period $Period -NoSend:$NoSend
Invoke-DataAgent -Config $cfg
```

The job makes the `Invoke-DataAgent` call itself, because the runner works from the calling script's directory: that is what puts the log and the package in the feed rather than in a module's install folder.

`New-MctfConfig` returns a source, a formatter and a destination:

```text
get data (sql)  →  csv round trip  →  freight and company tests  →  good / bad split
                →  state return (MotorFuelTaxFormats)  →  four exception reports  →  zip
                →  mail the zip, or for Alabama submit the return then mail the acknowledgement
```

The zip is the one artifact. It holds the return and the four reports: `yyyyMMdd-CompanyExceptions.csv`, `yyyyMMdd-FreightExceptions.csv`, `yyyyMMdd-FreightItemsGood.csv`, `yyyyMMdd-FreightItemsBad.csv`, dated by the run. The raw rowset is written beside them as `yyyyMMdd-FreightItemsAll.csv`. DataAgent writes the daily log, and the run's own receipt is three lines in it:

```text
mctf: state=FL period=202608 rows=16159 good=16111 bad=48 companyexceptions=3
mctf: artifact=202608.csv.zip bytes=919370 sha256=5855805B...
mctf: delivery=email artifact=202608.csv.zip to=filer@example.invalid
```

Rows that fail a test are not filtered out silently. They leave the filing and show up on the exception report, so the person filing can fix the source data and, if it matters, file an amendment.

## Modes

| Mode | Source | Delivery | Where it writes |
| --- | --- | --- | --- |
| Mock (default) | the packaged synthetic rows, or `-FixturePath` | nothing | `rehearsal/` |
| ExportOnly | the configured sql | nothing | `rehearsal/` |
| Live | the configured sql | mail, or the Alabama submission | the feed directory |

A rehearsal writes into `rehearsal/` beside the feed and never mails, so a feed that commits its packages can ignore that directory. `-WhatIf` previews a run without writing anything. `-NoSend` on a Live run generates everything and skips the mail; an Alabama feed still submits when its window is open, and only its mail is skipped.

An empty source is not a failure: the runner logs `No data available`, and nothing is written or sent.

## Periods

The scheduled run reports the month before the run date, the same as these feeds always have. `-Period 202606` reports June 2026 instead. The module passes `$(Period)`, `$(PeriodStart)` and `$(PeriodEnd)` to the sql as variables, and it refuses an explicit period when the sql does not reference them, so a query still anchored on the run date can never produce a mislabeled file.

A period is reported several times before its filing date, and each run replaces the last package for that period.

## Settings

```json
{
  "file_format": "{0:yyyyMM}.csv",
  "sql": { "InputFile": "get-data.sql", "QueryTimeout": 1800 },
  "mail": { "from": "sender@example.invalid", "to": ["filer@example.invalid"], "subject": "FL Taxes" },
  "msgraph": { "tenant_id": "TENANT_GUID", "client_id": "APP_CLIENT_GUID", "client_secret": "" },
  "mctf": { "state": "FL", "filer_id": "012345678" },
  "companytypes": [ { "t": "Consignee", "k": "consignee.cmp_id", "f": ["consignee.cmp_id", "consignee.name", "consignee.tax_id"] } ],
  "tests": [ { "type": "Freight", "name": "BOL is not a 3 to 12 digit number", "field": "bol", "test": "^[0-9]{3,12}$" } ]
}
```

- `file_format` names the return with a .NET date placeholder; it is filled with the period, and the zip is that name plus `.zip`.
- `sql` is the `Invoke-Sqlcmd` arguments, with `InputFile` relative to the settings file. A plain string is taken as the file name. The connection string comes from the `CONNECTION_STRING` environment variable, never from settings.
- `mctf.state` is one of AL, FL, KY, NC, SC, TN, VA. `filer_id`, `state_options` and `template_path` are passed to the formatter; see that module's README for what each state needs. `generated_at` pins the generation timestamp when you need a reproducible file.
- `tests` name a field and a regex. A `Freight` test applies to every row. Any other type applies once per distinct company of that type, and every row that references a failing company becomes an exception too.
- `companytypes` define a company: its type, the key field and the fields that identify it.
- `keepdays` and `purgefiles` drive DataAgent's retention, and are passed through only when the feed sets them. Setting `purgefiles` means the runner needs the `Clear-Files` module installed.

## Alabama

Alabama is the one state whose return is submitted by the feed rather than filed by a person. Add `"submit": { "window": [14, 20] }` under `mctf`. On a run inside the window the return is posted to the state's REST endpoint with basic auth, the acknowledgement is parsed, and the zip goes out with the acknowledgement in the mail body. Outside the window the mail says no filing was done. A test submission (`MCTF_PROCESS_TYPE=T`) ignores the window and stamps the return as a test.

Environment: `MCTF_SUBMIT_URI`, `MCTF_SUBMIT_USER`, `MCTF_SUBMIT_PASSWORD`, `MCTF_PROCESS_TYPE` (`P` by default), and `CLIENT_SECRET` for the mail. A failed submission is mailed as text, as it always has been, and the log records the delivery as submitted rather than confirmed.

## What it does not do

No scheduler, no credential storage, no amendment switch yet, and nothing about any particular company is built in. The formatter, the mail and the sql are the modules they always were.

## Upgrading from 0.1.1

DataAgent 0.4.0 replaced the pipeline API with `Invoke-DataAgent -Config`, so `Invoke-MctfFeed` and `Get-MctfPipelineMode` are gone and the feed's job makes the call. The stage functions take `-Settings`, `-RunAt` and `-ArtifactPath` where they took a pipeline context. Pin both modules in the job: this module's 0.2.0 needs DataAgent 0.4.0 or later.

## Test

```powershell
Invoke-Pester -Path ./tests -CI
```

Every fixture here is synthetic. Equivalence against live feeds is checked privately and stays there: for one filer and one settled period, all seven states produced the same rowset, the same four exception reports and the same return as the running feeds, byte for byte, with the Tennessee workbook compared by cell.

License: [MIT](LICENSE).
