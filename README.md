# MotorCarrierTaxFiling

Validate freight records, report the exceptions, format the state return, package it, and for Alabama submit it. The stages of a motor carrier tax filing feed, as a PowerShell module that runs on [DataAgent](https://github.com/royashbrook/DataAgent).

MCTF is motor carrier tax filing. If you carry fuel in trucks, some states require a monthly report of what you carried, where it came from and where it went. You do not pay tax on it, you declare it. The per-state file formats live in [MotorFuelTaxFormats](https://github.com/royashbrook/motor-fuel-tax-formats); this module is everything around the formatter.

## What a feed looks like

A feed is a directory with `settings.json`, a `get-data.sql` that produces flat freight rows, and this job:

```powershell
param([ValidateSet('Mock','ExportOnly','Live')][string]$Mode = 'Mock', [string]$Period, [switch]$NoSend)
Import-Module MotorCarrierTaxFiling -RequiredVersion 0.1.1 -ErrorAction Stop
Invoke-MctfFeed -SettingsPath "$PSScriptRoot/settings.json" -Mode $Mode -Period $Period -NoSend:$NoSend
```

`Invoke-MctfFeed` runs the DataAgent pipeline with these stages:

```text
get data (sql)  →  csv round trip  →  freight and company tests  →  good / bad split
                →  state return (MotorFuelTaxFormats)  →  four exception reports  →  zip
                →  mail the zip, or for Alabama submit the return then mail the acknowledgement
```

The zip is the one artifact. It holds the return and the four reports: `yyyyMMdd-CompanyExceptions.csv`, `yyyyMMdd-FreightExceptions.csv`, `yyyyMMdd-FreightItemsGood.csv`, `yyyyMMdd-FreightItemsBad.csv`, dated by the run. The raw rowset is written beside them as `yyyyMMdd-FreightItemsAll.csv`. DataAgent writes the daily log and a run receipt with the artifact's hash.

Rows that fail a test are not filtered out silently. They leave the filing and show up on the exception report, so the person filing can fix the source data and, if it matters, file an amendment.

## Modes

| Mode | Source | Delivery |
| --- | --- | --- |
| Mock (default) | the packaged synthetic rows, or `-FixturePath` | a local recording, nothing is sent |
| ExportOnly | the configured sql | none |
| Live | the configured sql | mail, or the Alabama submission |

`-WhatIf` previews a run without writing anything. `-NoSend` on a Live run generates everything and skips the mail; a feed that only mails becomes ExportOnly, an Alabama feed still submits when its window is open.

## Periods

The scheduled run reports the month before the run date, the same as these feeds always have. `-Period 202606` reports June 2026 instead. The module passes `$(Period)`, `$(PeriodStart)` and `$(PeriodEnd)` to the sql as variables, and it refuses an explicit period when the sql does not reference them, so a query still anchored on the run date can never produce a mislabeled file.

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
- `keepdays` and `purgefiles` drive DataAgent's retention. They default to 30 days of `*.tmp`, which touches nothing a feed commits. Set them only if you want the feed directory cleaned.

## Alabama

Alabama is the one state whose return is submitted by the feed rather than filed by a person. Add `"submit": { "window": [14, 20] }` under `mctf`. On a run inside the window the return is posted to the state's REST endpoint with basic auth, the acknowledgement is parsed, and the zip goes out with the acknowledgement in the mail body. Outside the window the mail says no filing was done. A test submission (`MCTF_PROCESS_TYPE=T`) ignores the window and stamps the return as a test.

Environment: `MCTF_SUBMIT_URI`, `MCTF_SUBMIT_USER`, `MCTF_SUBMIT_PASSWORD`, `MCTF_PROCESS_TYPE` (`P` by default), and `CLIENT_SECRET` for the mail. A failed submission is mailed as text, as it always has been, and the run receipt records the delivery as submitted rather than confirmed.

## What it does not do

No scheduler, no credential storage, no amendment switch yet, and nothing about any particular company is built in. The formatter, the mail and the sql are the modules they always were.

## Test

```powershell
Invoke-Pester -Path ./tests -CI
```

Every fixture here is synthetic. Equivalence against live feeds is checked privately and stays there: for one filer and one settled period, all seven states produced the same rowset, the same four exception reports and the same return as the running feeds, byte for byte, with the Tennessee workbook compared by cell.

License: [MIT](LICENSE).
