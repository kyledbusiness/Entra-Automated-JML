<#
.SYNOPSIS
    Validates synthetic HR JML event CSVs without connecting to Entra ID or changing accounts.
.DESCRIPTION
    This is an intentionally read-only gate for the Entra Automated JML portfolio lab.
    Configuration, CSV input, and report paths are parameterized. No secrets are used.
.EXAMPLE
    pwsh -NoProfile -File ./Scripts/Test-HREvents.ps1 -InputCsv ./Sample-Data/Sample-HR-Events.csv
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $InputCsv,

    [string] $ConfigPath = (Join-Path $PSScriptRoot '../Config/JML-Configuration.json'),

    [string] $ReportPath = (Join-Path $PSScriptRoot ('../Reports/HR-Validation_{0}_{1}.csv' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString('N').Substring(0,8)))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$requiredHeaders = @(
    'EventId', 'EmployeeID', 'EventType', 'FirstName', 'LastName', 'Department',
    'JobTitle', 'ManagerUPN', 'EmployeeType', 'EffectiveDate', 'ApprovalID', 'ApprovalStatus'
)
$validEventTypes = @('JOINER', 'MOVER', 'LEAVER')

$resolvedCsv = (Resolve-Path -LiteralPath $InputCsv).Path
$resolvedConfig = (Resolve-Path -LiteralPath $ConfigPath).Path
$config = Get-Content -LiteralPath $resolvedConfig -Raw | ConvertFrom-Json
$allowedDepartments = @($config.AllowedDepartments)
$allowedEmployeeTypes = @($config.AllowedEmployeeTypes)
$idPattern = [string]$config.EmployeeIdPattern

if ($allowedDepartments.Count -eq 0 -or [string]::IsNullOrWhiteSpace($idPattern)) {
    throw 'Configuration must specify AllowedDepartments and EmployeeIdPattern.'
}

$rows = @(Import-Csv -LiteralPath $resolvedCsv)
if ($rows.Count -eq 0) { throw 'CSV does not contain any HR events.' }

$actualHeaders = @($rows[0].PSObject.Properties.Name)
$missingHeaders = @($requiredHeaders | Where-Object { $_ -notin $actualHeaders })
if ($missingHeaders.Count -gt 0) {
    throw ('Missing CSV headers: ' + ($missingHeaders -join ', '))
}

$seenEvents = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$seenJoiners = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
$results = foreach ($row in $rows) {
    $issues = [System.Collections.Generic.List[string]]::new()
    $eventId = ([string]$row.EventId).Trim()
    $employeeId = ([string]$row.EmployeeID).Trim()
    $eventType = ([string]$row.EventType).Trim().ToUpperInvariant()
    $approvalStatus = ([string]$row.ApprovalStatus).Trim()

    if ([string]::IsNullOrWhiteSpace($eventId)) {
        $issues.Add('EventId is missing')
    } elseif (-not $seenEvents.Add($eventId)) {
        $issues.Add('Duplicate EventId')
    }

    if ($employeeId -cnotmatch $idPattern) {
        $issues.Add('EmployeeID does not match the configured format')
    }
    if ($eventType -notin $validEventTypes) {
        $issues.Add('Unsupported EventType')
    }
    if ($approvalStatus -cne 'Approved') {
        $issues.Add('HR event is not Approved')
    }
    if ([string]::IsNullOrWhiteSpace(([string]$row.ApprovalID).Trim())) {
        $issues.Add('ApprovalID is required')
    }

    try {
        [void][datetime]::ParseExact(
            ([string]$row.EffectiveDate).Trim(), 'yyyy-MM-dd',
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::None
        )
    } catch {
        $issues.Add('EffectiveDate must be a valid yyyy-MM-dd date')
    }

    if ($eventType -in @('JOINER', 'MOVER')) {
        if ([string]::IsNullOrWhiteSpace(([string]$row.FirstName).Trim())) {
            $issues.Add('FirstName is required')
        }
        if ([string]::IsNullOrWhiteSpace(([string]$row.LastName).Trim())) {
            $issues.Add('LastName is required')
        }
        if ([string]::IsNullOrWhiteSpace(([string]$row.JobTitle).Trim())) {
            $issues.Add('JobTitle is required')
        }
        $department = [string]$row.Department
        if ($department -cne $department.Trim()) {
            $issues.Add('Department contains leading or trailing whitespace')
        }
        if ($department -cnotin $allowedDepartments) {
            $issues.Add('Department is not in the approved department list')
        }
        if ([string]$row.EmployeeType -cnotin $allowedEmployeeTypes) {
            $issues.Add('EmployeeType is not in the approved employee-type list')
        }
        if ([string]$row.ManagerUPN -notmatch '^[^\s@]+@[^\s@]+\.[^\s@]+$') {
            $issues.Add('ManagerUPN is missing or malformed')
        }
    }

    if ($eventType -eq 'JOINER' -and -not [string]::IsNullOrWhiteSpace($employeeId)) {
        if (-not $seenJoiners.Add($employeeId)) {
            $issues.Add('Duplicate JOINER EmployeeID in this feed')
        }
    }

    [pscustomobject]@{
        EventId = $eventId
        EmployeeID = $employeeId
        EventType = $eventType
        ValidationResult = if ($issues.Count -eq 0) { 'VALID' } else { 'REJECTED' }
        Issues = $issues -join '; '
    }
}

$targetDir = Split-Path -Path $ReportPath -Parent
if (-not [string]::IsNullOrWhiteSpace($targetDir)) {
    [void](New-Item -ItemType Directory -Path $targetDir -Force)
}
if (Test-Path -LiteralPath $ReportPath) { throw 'ReportPath already exists; refusing to overwrite.' }
$results | Export-Csv -LiteralPath $ReportPath -Encoding utf8
$results | Format-Table EventId, EmployeeID, EventType, ValidationResult, Issues -Wrap -AutoSize
$rejected = @($results | Where-Object ValidationResult -eq 'REJECTED').Count
Write-Host ("Validated {0} HR event(s); {1} rejected. Report: {2}" -f $results.Count, $rejected, $ReportPath)
if ($rejected -gt 0) { exit 2 }
