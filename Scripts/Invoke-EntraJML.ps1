<#
.SYNOPSIS
    Phase 2: safely provisions ONE approved JOINER from a synthetic HR event feed.
.DESCRIPTION
    DRY RUN BY DEFAULT. Does not require Microsoft Graph until -Execute is supplied.
    The input is validated with Test-HREvents.ps1 first. Live execution requires an
    explicit tenant ID, approval reference, a current delegated Microsoft Graph
    connection, and PowerShell confirmation. Never stores initial passwords or tokens.

    This is a supervised laboratory tool, NOT a production HRIS integration or
    independent verification of HR/manager approvals. MOVER and LEAVER are NOT yet
    implemented in this version. Do not run on production tenants.
.EXAMPLE
    ./Scripts/Invoke-EntraJML.ps1 -InputCsv ./Sample-Data/Sample-HR-Events.csv -UpnDomain chs.example
.EXAMPLE
    ./Scripts/Invoke-EntraJML.ps1 -InputCsv ./Private-Data/HR-Events-Live.csv -UpnDomain actual-tenant.onmicrosoft.com -ExpectedTenantId '00000000-0000-0000-0000-000000000000' -ExpectedClientId '11111111-1111-1111-1111-111111111111' -ApprovedTicket 'HR-APP-1042' -Execute
#>
[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory = $true)][string]$InputCsv,
    [Parameter(Mandatory = $true)][string]$UpnDomain,
    [string]$ConfigPath = (Join-Path $PSScriptRoot '../Config/JML-Configuration.json'),
    [string]$ExpectedTenantId,
    [string]$ExpectedClientId,
    [string]$ApprovedTicket,
    [switch]$Execute,
    [string]$ReportPath = (Join-Path $PSScriptRoot ('../Reports/JML-Joiner_{0}_{1}.csv' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString('N').Substring(0,8)))
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function New-RandomPassword {
    # Password must briefly be a plaintext string to create a cloud-only user via Graph.
    # Never print it, persist it, or include it in a transcript / error message.
    $alphabet = @(
        'ABCDEFGHJKLMNPQRSTUVWXYZ',
        'abcdefghijkmnopqrstuvwxyz',
        '23456789',
        '!#%*+-=?@'
    )
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $alphabet) {
        $chars.Add($set[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)])
    }
    $all = $alphabet -join ''
    while ($chars.Count -lt 32) {
        $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)])
    }
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $t = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $t
    }
    return (-join $chars)
}

function Get-SafeAlias {
    param([string]$FirstName, [string]$LastName, [string]$EmployeeID)
    $first = $FirstName.ToLowerInvariant() -replace '[^a-z0-9]', ''
    $last = $LastName.ToLowerInvariant() -replace '[^a-z0-9]', ''
    $id = $EmployeeID.ToLowerInvariant() -replace '[^a-z0-9]', ''
    if (-not $first -or -not $last -or -not $id) { throw 'An HR name or employee ID cannot form a safe account alias.' }
    return '{0}.{1}.{2}' -f $first, $last, $id
}

$resolvedCsv = (Resolve-Path -LiteralPath $InputCsv).Path
$resolvedConfig = (Resolve-Path -LiteralPath $ConfigPath).Path
if (Test-Path -LiteralPath $ReportPath) { throw 'ReportPath already exists. Provide a unique report path; existing reports must not be overwritten.' }
$config = Get-Content -LiteralPath $resolvedConfig -Raw | ConvertFrom-Json
if ([string]::IsNullOrWhiteSpace([string]$config.ManagedCompanyName)) { throw 'Config missing ManagedCompanyName.' }
$companyMarker = [string]$config.ManagedCompanyName
if ($companyMarker -notmatch '^[A-Za-z0-9-]+$') { throw 'Unsafe company marker.' }
$UpnDomain = $UpnDomain.ToLowerInvariant().Trim()
if ($UpnDomain -notmatch '^[a-z0-9][a-z0-9.-]*\.[a-z]{2,}$') { throw 'Provide a valid verified UPN domain.' }

# Independent validation is *not* implied by ApprovalStatus = Approved in the CSV.
$validator = Join-Path $PSScriptRoot 'Test-HREvents.ps1'
if (-not (Test-Path -LiteralPath $validator)) { throw 'Missing Test-HREvents.ps1 validation gate.' }
$privateReportDir = Join-Path (Split-Path $PSScriptRoot -Parent) 'Reports'
[void](New-Item -Path $privateReportDir -ItemType Directory -Force)
$validationPath = Join-Path $privateReportDir ('HR-Validation-Preflight_{0}_{1}.csv' -f (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss-fff'), [guid]::NewGuid().ToString('N').Substring(0,8))
& pwsh -NoProfile -File $validator -InputCsv $resolvedCsv -ConfigPath $resolvedConfig -ReportPath $validationPath
if ($LASTEXITCODE -ne 0) { throw 'HR input validation failed; no changes attempted.' }
$rows = @(Import-Csv -LiteralPath $resolvedCsv)
if ($rows.Count -ne 1) { throw 'Phase 2 restricts execution to exactly ONE JOINER event per run.' }
$row = $rows[0]
if ($row.EventType.Trim().ToUpperInvariant() -ne 'JOINER') { throw 'This phase implements JOINER only. MOVER and LEAVER are not enabled.' }
if ([datetime]::ParseExact($row.EffectiveDate.Trim(), 'yyyy-MM-dd', [System.Globalization.CultureInfo]::InvariantCulture).Date -gt (Get-Date).Date) {
    throw 'Future-dated events are not eligible for execution.'
}
$alias = Get-SafeAlias -FirstName $row.FirstName -LastName $row.LastName -EmployeeID $row.EmployeeID
$upn = '{0}@{1}' -f $alias, $UpnDomain
if ($upn -notmatch '^[a-z0-9._-]+@[a-z0-9.-]+$') { throw 'Generated UPN contains unexpected characters.' }

$state = 'PLANNED'
$note = 'Offline validation passed; directory collisions and manager have NOT been verified.'
$createdId = ''
$password = $null
try {
    if (-not $Execute) {
        Write-Host "DRY RUN — no Graph connection and no Entra changes." -ForegroundColor Cyan
        Write-Host ('JOINER: EmployeeID {0}, Department {1}, CompanyMarker {2}' -f $row.EmployeeID, $row.Department, $companyMarker)
        Write-Host ('Planned account alias: {0}' -f $alias)
        Write-Host 'NOT CHECKED: tenant identity, UPN uniqueness, EmployeeID uniqueness, manager existence, downstream group processing.' -ForegroundColor Yellow
    }
    else {
        if ($ExpectedTenantId -notmatch '^[0-9a-fA-F-]{36}$') { throw '-Execute requires -ExpectedTenantId as a GUID.' }
        if ($ExpectedClientId -notmatch '^[0-9a-fA-F-]{36}$') { throw '-Execute requires -ExpectedClientId for the dedicated execution app.' }
        if ([string]::IsNullOrWhiteSpace($ApprovedTicket) -or $ApprovedTicket -cne $row.ApprovalID) {
            throw 'Explicit -ApprovedTicket must match the HR event ApprovalID. Independently verify approval before running.'
        }
        if ($row.ManagerUPN -match '\.example$') { throw 'Replace example-only ManagerUPN in an ignored Private-Data CSV before execution.' }
        Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
        Import-Module Microsoft.Graph.Users -ErrorAction Stop
        $ctx = Get-MgContext
        if (-not $ctx -or -not $ctx.TenantId) { throw 'Connect to Microsoft Graph first using the approved admin account.' }
        if ($ctx.TenantId -ine $ExpectedTenantId) { throw 'Connected Graph tenant does NOT match ExpectedTenantId. No changes made.' }
        if ($ctx.ClientId -ine $ExpectedClientId) { throw 'Connected Graph client does NOT match ExpectedClientId. No changes made.' }
        $unapprovedScopes = @($ctx.Scopes | Where-Object { $_ -match 'ReadWrite' -and $_ -ne 'User.ReadWrite.All' })
        if ($unapprovedScopes.Count -gt 0) { throw 'Unexpected additional write scope(s) in Graph context. Stop execution.' }
        if ('User.ReadWrite.All' -notin @($ctx.Scopes)) { throw 'Graph context lacks User.ReadWrite.All delegated scope.' }
        # Check collisions before creating anything. UPN uniqueness is ultimately enforced by Entra.
        # Small lab tenant: enumerate needed properties to avoid reliance on advanced-filter prerequisites.
        $knownUsers = @(Get-MgUser -All -Property @('id','userPrincipalName','employeeId') -ErrorAction Stop)
        $duplicateUpn = @($knownUsers | Where-Object { $_.UserPrincipalName -ieq $upn })
        $duplicateId = @($knownUsers | Where-Object { $_.EmployeeId -eq $row.EmployeeID })
        if ($duplicateUpn.Count -gt 0 -or $duplicateId.Count -gt 0) {
            throw 'An existing user matches this UPN or EmployeeID. This run will not change it.'
        }
        $manager = Get-MgUser -UserId $row.ManagerUPN.Trim() -Property @('id','accountEnabled','userPrincipalName') -ErrorAction Stop
        if (-not $manager.Id -or -not $manager.AccountEnabled) { throw 'Manager is missing or disabled; no account will be created.' }
        Write-Host ('Graph connected to expected tenant. Validated manager and no matching EmployeeID or UPN.') -ForegroundColor Green
        Write-Host ('Target: {0}; EmployeeID: {1}; Department: {2}' -f $upn, $row.EmployeeID, $row.Department)
        if (-not $PSCmdlet.ShouldProcess($upn, 'Create disabled user; assign manager; verify attributes; enable user')) {
            $state = 'DECLINED'
            $note = 'Operator declined confirmation; no changes attempted.'
        }
        else {
            $password = New-RandomPassword
            $body = @{
                accountEnabled = $false
                displayName = ('{0} {1}' -f $row.FirstName.Trim(), $row.LastName.Trim())
                givenName = $row.FirstName.Trim()
                surname = $row.LastName.Trim()
                userPrincipalName = $upn
                mailNickname = $alias
                employeeId = $row.EmployeeID.Trim()
                companyName = $companyMarker
                department = $row.Department.Trim()
                jobTitle = $row.JobTitle.Trim()
                employeeType = $row.EmployeeType.Trim()
                passwordProfile = @{ password = $password; forceChangePasswordNextSignIn = $true }
            }
            $newUser = New-MgUser -BodyParameter $body -ErrorAction Stop
            $createdId = $newUser.Id
            $state = 'CREATED_DISABLED'
            $note = 'Created disabled; manager or enable step is pending.'
            $password = $null; $body = $null
            Set-MgUserManagerByRef -UserId $createdId -BodyParameter @{ '@odata.id' = "https://graph.microsoft.com/v1.0/users/$($manager.Id)" } -ErrorAction Stop
            $check = Get-MgUser -UserId $createdId -Property @('id','employeeId','companyName','department','jobTitle','accountEnabled') -ErrorAction Stop
            if ($check.EmployeeId -cne $row.EmployeeID -or $check.CompanyName -cne $companyMarker -or $check.Department -cne $row.Department -or $check.AccountEnabled) {
                throw 'Post-create attribute check failed; user remains disabled for investigation.'
            }
            Update-MgUser -UserId $createdId -BodyParameter @{ accountEnabled = $true } -ErrorAction Stop
            $enabledCheck = Get-MgUser -UserId $createdId -Property @('id','accountEnabled','department','companyName') -ErrorAction Stop
            if (-not $enabledCheck.AccountEnabled) { throw 'Could not verify enabled status.' }
            $state = 'ENABLED'
            $note = 'Entra account created and enabled. Dynamic group and SaaS propagation NOT yet verified.'
            Write-Host ('JOINER SUCCESS — EmployeeID {0}. Verify attributes, group, and authentication in Entra.' -f $row.EmployeeID) -ForegroundColor Green
        }
    }
}
catch {
    $state = if ($createdId) { 'NEEDS_REVIEW' } else { 'FAILED_NO_CREATE' }
    $note = if ($createdId) {
        'Account creation occurred but a later step failed; disable and inspect the account before retrying. No automatic deletion performed.'
    } else {
        'A preflight or create step failed; check terminal errors. No existing account updates were attempted.'
    }
    # Do not log exception objects: SDK exceptions can include request data.
    Write-Warning $note
    throw 'Joiner execution did not complete. Review the error and the private report.'
}
finally {
    $password = $null
    $targetDir = Split-Path -Path $ReportPath -Parent
    if ($targetDir) { [void](New-Item -Path $targetDir -ItemType Directory -Force) }
    [pscustomobject]@{
        EventId = $row.EventId
        EmployeeID = $row.EmployeeID
        Operation = 'JOINER'
        Status = $state
        NewObjectId = $createdId
        Summary = $note
    } | Export-Csv -LiteralPath $ReportPath -Encoding utf8
    Write-Host ('Private execution report: {0}' -f $ReportPath)
}
