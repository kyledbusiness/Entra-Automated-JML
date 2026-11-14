<#
.SYNOPSIS
    Supervised Entra JML MOVER: updates one lab identity's department and job title.
.DESCRIPTION
    Offline DRY RUN BY DEFAULT. -Execute requires a validated HR event, approval ID,
    expected tenant/client IDs, a source-department guard, a signed-in delegated
    Microsoft Graph session, and an interactive confirmation. All existing users
    are read, but only the uniquely matching CHS-JML-LAB account may be changed.
    This script does NOT manually edit dynamic groups, revoke sessions, or verify
    downstream application entitlements. Verify group propagation separately.
    A recorded pre-change snapshot supports supervised manual recovery.
    Designed for a synthetic lab, not production use.
.EXAMPLE
    ./Scripts/Invoke-EntraJMLMover.ps1 -InputCsv './Private-Data/HR-Mover-Avery.csv' -UpnDomain $domain
.EXAMPLE
    ./Scripts/Invoke-EntraJMLMover.ps1 -InputCsv './Private-Data/HR-Mover-Avery.csv' -UpnDomain $domain -ExpectedTenantId $expectedTenantId -ExpectedClientId $executionClientId -ExpectedFromDepartment 'Clinical Operations' -ApprovedTicket 'HR-APP-1042-MOV' -Execute
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string]$InputCsv,
    [Parameter(Mandatory)][string]$UpnDomain,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../Config/JML-Configuration.json'),
    [string]$ExpectedTenantId,
    [string]$ExpectedClientId,
    [string]$ExpectedFromDepartment,
    [string]$ApprovedTicket,
    [switch]$Execute,
    [string]$ReportPath = (Join-Path $PSScriptRoot ('../Reports/JML-Mover_{0}_{1}.csv' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString('N').Substring(0,8)))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Guid([string]$Value, [string]$Label) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$Label must be a valid nonempty GUID."
    }
}
function Get-SafeAlias([string]$FirstName, [string]$LastName, [string]$EmployeeID) {
    $first = $FirstName.ToLowerInvariant() -replace '[^a-z0-9]', ''
    $last = $LastName.ToLowerInvariant() -replace '[^a-z0-9]', ''
    $id = $EmployeeID.ToLowerInvariant() -replace '[^a-z0-9]', ''
    if (-not $first -or -not $last -or -not $id) { throw 'Cannot generate a safe identity alias.' }
    return ('{0}.{1}.{2}' -f $first, $last, $id)
}

$inputFile = (Resolve-Path -LiteralPath $InputCsv -ErrorAction Stop).Path
$configFile = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
$config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
$marker = [string]$config.ManagedCompanyName
if ([string]::IsNullOrWhiteSpace($marker) -or $marker -notmatch '^[a-zA-Z0-9-]+$') {
    throw 'Invalid ManagedCompanyName in configuration.'
}
$UpnDomain = $UpnDomain.Trim().ToLowerInvariant()
if ($UpnDomain -eq 'chs.example' -or $UpnDomain -notmatch '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$') {
    throw 'Provide the verified tenant UPN domain, not a placeholder.'
}
if (Test-Path -LiteralPath $ReportPath) { throw 'Report already exists. Refusing to overwrite.' }
$validator = Join-Path $PSScriptRoot 'Test-HREvents.ps1'
if (-not (Test-Path -LiteralPath $validator)) {
    throw 'Expected existing Scripts/Test-HREvents.ps1; copy only this new Mover script into that directory.'
}
$reportsDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'Reports'
[void](New-Item -Path $reportsDir -ItemType Directory -Force)
$validationReport = Join-Path $reportsDir ('HR-Validation-Mover_{0}_{1}.csv' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString('N').Substring(0,8))
& pwsh -NoProfile -File $validator -InputCsv $inputFile -ConfigPath $configFile -ReportPath $validationReport
if ($LASTEXITCODE -ne 0) { throw 'HR data validation rejected the Mover event; nothing changed.' }
$rows = @(Import-Csv -LiteralPath $inputFile)
if ($rows.Count -ne 1) { throw 'Exactly one MOVER event is permitted per run.' }
$row = $rows[0]
if ($row.EventType.Trim().ToUpperInvariant() -ne 'MOVER') { throw 'This script only executes MOVER events.' }
$date = [datetime]::ParseExact($row.EffectiveDate.Trim(), 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
if ($date.Date -gt (Get-Date).Date) { throw 'Future-dated HR events cannot be executed.' }
$expectedUpn = ('{0}@{1}' -f (Get-SafeAlias $row.FirstName $row.LastName $row.EmployeeID), $UpnDomain)
$newDepartment = $row.Department.Trim()
$newJobTitle = $row.JobTitle.Trim()
if ($newDepartment -notin @($config.AllowedDepartments)) { throw 'Target department not on allowlist.' }

$state = 'DRY_RUN'
$note = 'Offline HR validation passed. Tenant, source account and group memberships not checked.'
$beforeDepartment = ''
$beforeTitle = ''
$targetId = ''
$writeAttempted = $false
try {
    if (-not $Execute) {
        Write-Host 'DRY RUN — no Graph connection or Entra changes.' -ForegroundColor Cyan
        Write-Host ('MOVER: EmployeeID {0}; target department: {1}; target title: {2}' -f $row.EmployeeID, $newDepartment, $newJobTitle)
        Write-Host ('Expected account alias: {0}' -f ($expectedUpn -split '@')[0])
        Write-Host 'NOT CHECKED: actual tenant, user uniqueness, current department, manager, group propagation.' -ForegroundColor Yellow
    }
    else {
        Assert-Guid $ExpectedTenantId 'ExpectedTenantId'
        Assert-Guid $ExpectedClientId 'ExpectedClientId'
        if ([string]::IsNullOrWhiteSpace($ExpectedFromDepartment)) { throw '-ExpectedFromDepartment is required to execute a Mover.' }
        if ($ExpectedFromDepartment -cnotin @($config.AllowedDepartments)) { throw 'Source department not in the allowed list.' }
        if ($ExpectedFromDepartment -ceq $newDepartment) { throw 'Target and source department are identical.' }
        if ([string]::IsNullOrWhiteSpace($ApprovedTicket) -or $ApprovedTicket -cne $row.ApprovalID) {
            throw 'ApprovedTicket must match the independently approved HR event.'
        }
        if ($row.ManagerUPN -match '\.example$') { throw 'Placeholder manager UPN prohibited in live execution.' }
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        Import-Module Microsoft.Graph.Users -ErrorAction Stop
        $ctx = Get-MgContext
        if (-not $ctx -or $ctx.TenantId -ine $ExpectedTenantId -or $ctx.ClientId -ine $ExpectedClientId) {
            throw 'Graph context does not match expected tenant and dedicated execution application.'
        }
        if ($ctx.AuthType -ne 'Delegated') { throw 'Delegated Graph authentication is required.' }
        if ('User.ReadWrite.All' -notin @($ctx.Scopes)) { throw 'Missing required User.ReadWrite.All scope.' }
        $allowedWriteScopes = @('User.ReadWrite.All', 'User.EnableDisableAccount.All')
        $additionalWrite = @($ctx.Scopes | Where-Object { ($_ -match 'Write|Manage') -and ($_ -notin $allowedWriteScopes) })
        if ($additionalWrite.Count -gt 0) { throw 'Unexpected additional write scopes detected; stop execution.' }

        # Enumeration is intentional for the small, isolated lab to check uniqueness by both ID and UPN.
        $users = @(Get-MgUser -All -Property @('id','userPrincipalName','employeeId','companyName','department','jobTitle','accountEnabled','onPremisesSyncEnabled','givenName','surname') -ErrorAction Stop)
        $employeeMatches = @($users | Where-Object { $_.EmployeeId -eq $row.EmployeeID })
        if ($employeeMatches.Count -ne 1) { throw 'Expected exactly one existing user with the HR EmployeeID; no changes attempted.' }
        $user = $employeeMatches[0]
        $sameUpn = @($users | Where-Object { $_.UserPrincipalName -ieq $expectedUpn })
        if ($sameUpn.Count -ne 1 -or $sameUpn[0].Id -ne $user.Id) { throw 'Expected UPN is missing or belongs to a different identity.' }
        if ($user.CompanyName -cne $marker) { throw 'Company marker mismatch; refusing to modify an unrelated user.' }
        if (-not $user.AccountEnabled) { throw 'User is disabled; stop Mover execution.' }
        if ($user.OnPremisesSyncEnabled -eq $true) { throw 'Synchronized user is outside this cloud-only lab.' }
        if ($user.GivenName -ine $row.FirstName.Trim() -or $user.Surname -ine $row.LastName.Trim()) {
            throw 'Name mismatch; recheck HR-to-directory identity correlation.'
        }
        if ($user.Department -cne $ExpectedFromDepartment) { throw 'Source department no longer matches expected state. Stop; do not overwrite.' }
        $manager = Get-MgUser -UserId $row.ManagerUPN.Trim() -Property @('id','accountEnabled') -ErrorAction Stop
        if (-not $manager.Id -or -not $manager.AccountEnabled) { throw 'HR manager not found or disabled.' }
        $existingManager = Get-MgUserManager -UserId $user.Id -ErrorAction Stop
        if (-not $existingManager.Id -or $existingManager.Id -ne $manager.Id) {
            throw 'Manager changed unexpectedly; this Mover event does not authorize manager reassignment.'
        }
        $targetId = $user.Id
        $beforeDepartment = [string]$user.Department
        $beforeTitle = [string]$user.JobTitle
        $state = 'PRECHECK_PASSED'
        $note = 'Verified unique identity, lab ownership, source department, enabled state and unchanged manager.'
        Write-Host ('READY: {0}; EmployeeID {1}' -f $expectedUpn, $row.EmployeeID) -ForegroundColor Green
        Write-Host ('Department: {0} -> {1}' -f $beforeDepartment, $newDepartment)
        Write-Host ('Job title:  {0} -> {1}' -f $beforeTitle, $newJobTitle)
        Write-Host 'Dynamic groups will update asynchronously. No direct group membership changes will be made.'
        if (-not $PSCmdlet.ShouldProcess($expectedUpn, 'Update department and jobTitle of exactly one approved JML lab user')) {
            $state = 'DECLINED_OR_WHATIF'
            $note = 'Operator declined or -WhatIf was used; no changes attempted.'
        }
        else {
            $writeAttempted = $true
            Update-MgUser -UserId $targetId -BodyParameter @{ department = $newDepartment; jobTitle = $newJobTitle } -ErrorAction Stop
            $verified = $false
            for ($i = 1; $i -le 5; $i++) {
                $check = Get-MgUser -UserId $targetId -Property @('id','employeeId','companyName','department','jobTitle','accountEnabled') -ErrorAction Stop
                if ($check.EmployeeId -eq $row.EmployeeID -and $check.CompanyName -ceq $marker -and $check.Department -ceq $newDepartment -and $check.JobTitle -ceq $newJobTitle -and $check.AccountEnabled) {
                    $verified = $true
                    break
                }
                if ($i -lt 5) { Start-Sleep -Seconds 2 }
            }
            if (-not $verified) { throw 'Update submitted, but immediate attribute verification failed. Inspect account before any retry or rollback.' }
            $state = 'ATTRIBUTES_VERIFIED'
            $note = 'Department/title update verified. Old/new dynamic group membership is pending independent verification.'
            Write-Host ('MOVER ATTRIBUTES VERIFIED — EmployeeID {0}; {1} -> {2}' -f $row.EmployeeID, $beforeDepartment, $newDepartment) -ForegroundColor Green
            Write-Host 'NEXT: Confirm removal from old group AND membership in new group. Treat propagation as pending until observed.' -ForegroundColor Yellow
        }
    }
}
catch {
    $state = if ($writeAttempted) { 'NEEDS_REVIEW' } else { 'FAILED_NO_WRITE' }
    $note = if ($writeAttempted) {
        'A write was attempted; state may be partial. Do not rerun. Inspect account and private before-state snapshot; recovery is supervised.'
    } else {
        'Preflight failed. No write attempted.'
    }
    Write-Warning $note
    throw 'Mover run did not complete. Review the private report and the tenant before further action.'
}
finally {
    $reportDir = Split-Path -Path $ReportPath -Parent
    if ($reportDir) { [void](New-Item -Path $reportDir -ItemType Directory -Force) }
    if (Test-Path -LiteralPath $ReportPath) { throw 'Refusing to overwrite existing execution report.' }
    [pscustomobject]@{
        RecordedAt = [datetimeoffset]::Now.ToString('o')
        EventId = $row.EventId
        EmployeeID = $row.EmployeeID
        Operation = 'MOVER'
        Status = $state
        TargetUPN = $expectedUpn
        TargetObjectId = $targetId
        BeforeDepartment = $beforeDepartment
        AfterDepartment = $newDepartment
        BeforeJobTitle = $beforeTitle
        AfterJobTitle = $newJobTitle
        Summary = $note
    } | Export-Csv -LiteralPath $ReportPath -Encoding utf8
    Write-Host ('Private Mover report: {0}' -f $ReportPath)
}
