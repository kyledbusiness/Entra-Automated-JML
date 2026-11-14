<#
.SYNOPSIS
    Safely offboards exactly one approved, cloud-only CHS-JML-LAB user.
.DESCRIPTION
    By default, runs offline HR validation only and makes no Graph calls.
    With -Execute, requires a delegated Graph session on the expected tenant
    and dedicated execution app, a matching approval ID, an expected source
    department, exact HR-to-user correlation, and an interactive confirmation.
    Disables the account first, verifies the disabled state, then requests
    refresh-token/session revocation via Microsoft Graph. DOES NOT delete the
    user, remove authentication methods, or manually modify dynamic groups.
    Retains private audit evidence; does not automatically re-enable users
    if a later step fails. Intended for a synthetic portfolio lab.
.EXAMPLE
    ./Scripts/Invoke-EntraJMLLeaver.ps1 -InputCsv './Private-Data/HR-Leaver-Avery.csv' -UpnDomain $domain
.EXAMPLE
    ./Scripts/Invoke-EntraJMLLeaver.ps1 -InputCsv './Private-Data/HR-Leaver-Avery.csv' -UpnDomain $domain -ExpectedTenantId $expectedTenantId -ExpectedClientId $executionClientId -ExpectedFromDepartment 'Finance' -ApprovedTicket 'HR-APP-1042-LEV' -Execute
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
    [string]$ReportPath = (Join-Path $PSScriptRoot ('../Reports/JML-Leaver_{0}_{1}.csv' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString('N').Substring(0,8)))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-Guid([string]$Value, [string]$Label) {
    $parsed = [guid]::Empty
    if (-not [guid]::TryParse($Value, [ref]$parsed) -or $parsed -eq [guid]::Empty) {
        throw "$Label must be a nonempty GUID."
    }
}
function Get-SafeAlias([string]$FirstName, [string]$LastName, [string]$EmployeeID) {
    $first = $FirstName.ToLowerInvariant() -replace '[^a-z0-9]', ''
    $last  = $LastName.ToLowerInvariant() -replace '[^a-z0-9]', ''
    $empId = $EmployeeID.ToLowerInvariant() -replace '[^a-z0-9]', ''
    if (-not $first -or -not $last -or -not $empId) { throw 'Unsafe or missing HR name/EmployeeID.' }
    return ('{0}.{1}.{2}' -f $first, $last, $empId)
}

$inputFile  = (Resolve-Path -LiteralPath $InputCsv -ErrorAction Stop).Path
$configFile = (Resolve-Path -LiteralPath $ConfigPath -ErrorAction Stop).Path
$config = Get-Content -LiteralPath $configFile -Raw | ConvertFrom-Json
$marker = [string]$config.ManagedCompanyName
if ([string]::IsNullOrWhiteSpace($marker) -or $marker -notmatch '^[A-Za-z0-9-]+$') {
    throw 'Invalid or missing ManagedCompanyName in configuration.'
}
$UpnDomain = $UpnDomain.Trim().ToLowerInvariant()
if ($UpnDomain -eq 'chs.example' -or $UpnDomain -notmatch '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$') {
    throw 'Supply the actual verified tenant UPN domain, not a placeholder.'
}
if (Test-Path -LiteralPath $ReportPath) { throw 'Refusing to overwrite an existing report.' }
$validator = Join-Path $PSScriptRoot 'Test-HREvents.ps1'
if (-not (Test-Path -LiteralPath $validator)) { throw 'Missing existing Test-HREvents.ps1.' }
$reportsDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'Reports'
[void](New-Item -ItemType Directory -Path $reportsDir -Force)
$validationReport = Join-Path $reportsDir ('HR-Validation-Leaver_{0}_{1}.csv' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString('N').Substring(0,8))
& pwsh -NoProfile -File $validator -InputCsv $inputFile -ConfigPath $configFile -ReportPath $validationReport
if ($LASTEXITCODE -ne 0) { throw 'HR validation failed; nothing changed.' }
$rows = @(Import-Csv -LiteralPath $inputFile)
if ($rows.Count -ne 1) { throw 'Exactly one LEAVER event is allowed per execution.' }
$row = $rows[0]
if ($row.EventType.Trim().ToUpperInvariant() -ne 'LEAVER') { throw 'Expected one LEAVER event.' }
if ([string]::IsNullOrWhiteSpace($row.FirstName) -or [string]::IsNullOrWhiteSpace($row.LastName) -or
    [string]::IsNullOrWhiteSpace($row.Department)) {
    throw 'A LEAVER event requires name and source department for additional identity checks.'
}
if ($row.Department -cne $row.Department.Trim() -or $row.Department -cnotin @($config.AllowedDepartments)) {
    throw 'LEAVER source department must be exact and on the approved list.'
}
$effective = [datetime]::ParseExact($row.EffectiveDate.Trim(), 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture)
if ($effective.Date -gt (Get-Date).Date) { throw 'Future-dated HR events cannot be executed.' }
$expectedUpn = ('{0}@{1}' -f (Get-SafeAlias $row.FirstName $row.LastName $row.EmployeeID), $UpnDomain)

$state = 'DRY_RUN'
$note = 'Offline validation passed; no Graph lookups or mutations occurred.'
$targetId = ''
$beforeEnabled = ''
$afterEnabled = ''
$sessionRevocation = 'NOT_ATTEMPTED'
$disableAttempted = $false
try {
    if (-not $Execute) {
        Write-Host 'DRY RUN — no Graph connection or Entra changes.' -ForegroundColor Cyan
        Write-Host ('LEAVER: EmployeeID {0}; source department: {1}; EventId: {2}' -f $row.EmployeeID, $row.Department, $row.EventId)
        Write-Host ('Expected account alias: {0}' -f ($expectedUpn -split '@')[0])
        Write-Host 'NOT CHECKED: tenant, unique account matching, enabled state, actual department, session revocation, dynamic group propagation.' -ForegroundColor Yellow
    }
    else {
        Assert-Guid $ExpectedTenantId 'ExpectedTenantId'
        Assert-Guid $ExpectedClientId 'ExpectedClientId'
        if ([string]::IsNullOrWhiteSpace($ExpectedFromDepartment) -or
            $ExpectedFromDepartment -cnotin @($config.AllowedDepartments)) {
            throw '-ExpectedFromDepartment must name an allowed department.'
        }
        if ($row.Department -cne $ExpectedFromDepartment) { throw 'HR department does not match ExpectedFromDepartment.' }
        if ([string]::IsNullOrWhiteSpace($ApprovedTicket) -or $ApprovedTicket -cne $row.ApprovalID) {
            throw 'ApprovedTicket must exactly match the independently confirmed HR event ApprovalID.'
        }
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        Import-Module Microsoft.Graph.Users -ErrorAction Stop
        $ctx = Get-MgContext
        if (-not $ctx -or $ctx.TenantId -ine $ExpectedTenantId -or $ctx.ClientId -ine $ExpectedClientId) {
            throw 'Graph tenant/client does not match the approved execution context.'
        }
        if ($ctx.AuthType -ne 'Delegated') { throw 'Delegated Graph authentication required.' }
        foreach ($scope in @('User.ReadWrite.All','User.Read.All','User.EnableDisableAccount.All')) {
            if ($scope -notin @($ctx.Scopes)) { throw "Required Graph permission missing: $scope" }
        }
        $allowedWriteScopes = @('User.ReadWrite.All','User.EnableDisableAccount.All','User.RevokeSessions.All')
        $extraWrite = @($ctx.Scopes | Where-Object { ($_ -match 'ReadWrite|\.Write|Manage|Revoke') -and ($_ -notin $allowedWriteScopes) })
        if ($extraWrite.Count -gt 0) { throw 'Unexpected broad write scope(s); stop execution.' }

        # Small, lab-only directory: enumerate relevant properties to detect
        # both UPN and EmployeeID collisions before a sensitive action.
        $users = @(Get-MgUser -All -Property @('id','userPrincipalName','employeeId','companyName','department',
            'accountEnabled','givenName','surname','onPremisesSyncEnabled','userType') -ErrorAction Stop)
        $employeeMatches = @($users | Where-Object { $_.EmployeeId -eq $row.EmployeeID })
        if ($employeeMatches.Count -ne 1) { throw 'EmployeeID does not identify exactly one account.' }
        $user = $employeeMatches[0]
        $upnMatches = @($users | Where-Object { $_.UserPrincipalName -ieq $expectedUpn })
        if ($upnMatches.Count -ne 1 -or $upnMatches[0].Id -ne $user.Id) { throw 'UPN does not uniquely match the same EmployeeID.' }
        if ($user.CompanyName -cne $marker) { throw 'Company marker mismatch; this identity is not in the JML lab.' }
        if ($user.UserType -ne 'Member') { throw 'Refusing to modify a non-member account.' }
        if ($user.OnPremisesSyncEnabled -eq $true) { throw 'Synchronized identity is outside the cloud-only lab.' }
        if ($user.GivenName -ine $row.FirstName.Trim() -or $user.Surname -ine $row.LastName.Trim()) {
            throw 'Name does not match the HR record.'
        }
        if ($user.Department -cne $ExpectedFromDepartment) { throw 'Current department differs from approved HR expectation.' }
        if ($user.AccountEnabled -ne $true) { throw 'Account is already disabled; inspect before retrying.' }
        $targetId = $user.Id
        $beforeEnabled = 'True'
        $state = 'PRECHECK_PASSED'
        $note = 'Unique JML lab identity verified, source department matched, account enabled.'
        Write-Host ('READY: {0}; EmployeeID {1}; Department {2}' -f $expectedUpn, $row.EmployeeID, $user.Department) -ForegroundColor Green
        Write-Host 'Action: DISABLE identity, verify disabled state, then REVOKE sign-in sessions.' -ForegroundColor Yellow
        Write-Host 'Dynamic Finance group removal is asynchronous; this script does not delete users or directly change memberships.'
        if (-not $PSCmdlet.ShouldProcess($expectedUpn, 'Disable exactly one approved JML lab user and revoke sign-in sessions')) {
            $state = 'DECLINED_OR_WHATIF'
            $note = 'Operator declined or -WhatIf requested; no change attempted.'
        }
        else {
            $disableAttempted = $true
            Update-MgUser -UserId $targetId -BodyParameter @{ accountEnabled = $false } -ErrorAction Stop
            $verifiedDisabled = $false
            for ($i = 1; $i -le 5; $i++) {
                $check = Get-MgUser -UserId $targetId -Property @('id','employeeId','companyName','department','accountEnabled') -ErrorAction Stop
                if ($check.EmployeeId -eq $row.EmployeeID -and $check.CompanyName -ceq $marker -and
                    $check.Department -ceq $ExpectedFromDepartment -and $check.AccountEnabled -eq $false) {
                    $verifiedDisabled = $true
                    break
                }
                if ($i -lt 5) { Start-Sleep -Seconds 2 }
            }
            if (-not $verifiedDisabled) { throw 'Disable requested, but the disabled state could not be verified.' }
            $afterEnabled = 'False'
            $state = 'DISABLED_VERIFIED'
            Write-Host ('LEAVER DISABLED VERIFIED — EmployeeID {0}' -f $row.EmployeeID) -ForegroundColor Green

            # User.ReadWrite.All is a documented delegated permission for this
            # action. A successful response invalidates refresh tokens/session
            # cookies; some existing access tokens and apps may remain usable
            # until expiration or downstream enforcement.
            $sessionRevocation = 'REQUESTED'
            $uri = 'https://graph.microsoft.com/v1.0/users/{0}/revokeSignInSessions' -f $targetId
            $revokeResult = Invoke-MgGraphRequest -Method POST -Uri $uri -ErrorAction Stop
            if ($revokeResult -is [System.Collections.IDictionary] -and
                $revokeResult.Contains('value') -and $revokeResult['value'] -ne $true) {
                throw 'Session revocation API returned a non-success value.'
            }
            $sessionRevocation = 'API_SUCCESS'
            $state = 'DISABLED_AND_REVOCATION_REQUESTED'
            $note = 'Account disabled and verified; Graph accepted revocation request. Check dynamic group removal and downstream app sessions separately.'
            Write-Host ('LEAVER VERIFIED — EmployeeID {0}; disabled, session revocation API succeeded.' -f $row.EmployeeID) -ForegroundColor Green
            Write-Host 'NEXT: Verify Finance group membership removed after dynamic processing. Preserve account for audit.' -ForegroundColor Yellow
        }
    }
}
catch {
    if ($disableAttempted) {
        $state = 'NEEDS_REVIEW_DISABLED_OR_PARTIAL'
        $note = 'Disable attempt occurred; inspect actual account state and session revocation status. Do NOT re-enable or rerun blindly.'
    }
    else {
        $state = 'FAILED_NO_WRITE'
        $note = 'Preflight failed before any write. Inspect validation and context.'
    }
    Write-Warning $note
    Write-Warning ("Underlying failure: {0}" -f $_.Exception.Message)
    throw 'Leaver execution did not fully complete; inspect tenant and private audit report.'
}
finally {
    $outputDir = Split-Path -Path $ReportPath -Parent
    if ($outputDir) { [void](New-Item -ItemType Directory -Path $outputDir -Force) }
    if (Test-Path -LiteralPath $ReportPath) { throw 'Execution report exists: refusing overwrite.' }
    [pscustomobject]@{
        RecordedAt = [datetimeoffset]::Now.ToString('o')
        EventId = $row.EventId
        EmployeeID = $row.EmployeeID
        Operation = 'LEAVER'
        Status = $state
        TargetUPN = $expectedUpn
        TargetObjectId = $targetId
        FromDepartment = $row.Department
        AccountEnabledBefore = $beforeEnabled
        AccountEnabledAfter = $afterEnabled
        SessionRevocation = $sessionRevocation
        Summary = $note
    } | Export-Csv -LiteralPath $ReportPath -Encoding utf8
    Write-Host ('Private Leaver report: {0}' -f $ReportPath)
}
