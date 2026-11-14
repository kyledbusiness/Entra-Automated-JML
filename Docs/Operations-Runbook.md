# Operations Runbook — Entra Automated JML (Lab)

**Purpose:** Operate and validate the supervised Joiner, Mover, and Leaver PowerShell workflows in a controlled Microsoft Entra lab. This runbook describes the scripts used in the project; it is **not a production standard operating procedure**.

## 1. Preconditions and change authorization

- Use an authorized, **non-production** Entra tenant, PowerShell 7, and the installed Microsoft Graph modules (`Microsoft.Graph.Authentication`, `Microsoft.Graph.Users`, `Microsoft.Graph.Groups` as needed for inspection).
- Verify `Config/JML-Configuration.json` contains the intended `ManagedCompanyName` (`CHS-JML-LAB`) and department allowlist.
- Use only the supplied **synthetic sample CSVs** for public demonstrations. Put real tenant-specific manager UPNs and HR execution records in Git-ignored `Private-Data/`.
- Confirm the source approval **outside the CSV**. Matching `ApprovalID` and `-ApprovedTicket` is a consistency check, not proof that an actual HR authority approved the change.
- Check for unexpected users, group rules, and policy targeting. Break-glass/admin identities are outside the JML user population.
- Do not run live scripts on production users, synced identities, or accounts lacking the `CHS-JML-LAB` marker.

## 2. Repository privacy checks

Ensure `.gitignore` includes:

```gitignore
Private-Data/
Reports/
.env
.env.*
*.log
*.tmp
```

Then run:

```powershell
git check-ignore -v -- Private-Data/HR-Leaver-Avery.csv Reports/JML-Leaver-Test.csv
git ls-files -- Private-Data/ Reports/
git status --short --untracked-files=all
```

The second command should return **no tracked private files**. Manually review `Config/`, `Sample-Data/`, `Scripts/`, and all images before publishing. Avoid `git add .` until that review is complete.

## 3. Offline HR validation (no Graph access)

```powershell
pwsh -NoProfile -File ./Scripts/Test-HREvents.ps1 -InputCsv ./Sample-Data/Sample-HR-Events.csv
pwsh -NoProfile -File ./Scripts/Test-HREvents.ps1 -InputCsv ./Sample-Data/Sample-HR-Events-Negative.csv
```

The first input should produce one valid record; the second should reject four rows (expected validator exit code `2`). Validate the required header set, approved event/department/employee type, identifier format, effective date, approval status, and duplicate events. In particular, a department with leading or trailing whitespace is rejected instead of silently normalized.

A `VALID` result is a **data-quality gate**, not proof of approval authenticity or live directory safety.

## 4. Graph execution context

For directory reads, use only delegated `User.Read.All` and `Group.Read.All` when possible. The **separate lab execution application** used in this project was consented to:

- `User.ReadWrite.All`
- `User.Read.All`
- `User.EnableDisableAccount.All`

These are powerful delegated scopes. Keep the execution application separate from the read-only application/context and review permissions after finishing the lab.

In the same PowerShell session that runs live commands:

```powershell
$expectedTenantId = (Read-Host 'Enter Directory Tenant ID').Trim()
$executionClientId = (Read-Host 'Enter execution app Client ID').Trim()
$domain = (Read-Host 'Enter verified Entra UPN domain').Trim()

Connect-MgGraph -ClientId $executionClientId -TenantId $expectedTenantId -Scopes 'User.ReadWrite.All','User.Read.All','User.EnableDisableAccount.All' -UseDeviceAuthentication -ContextScope Process -NoWelcome

$ctx = Get-MgContext
if (-not $ctx -or $ctx.TenantId -ne $expectedTenantId -or $ctx.ClientId -ne $executionClientId -or $ctx.AuthType -ne 'Delegated') { throw 'Wrong or missing execution context.' }
foreach ($scope in @('User.ReadWrite.All','User.Read.All','User.EnableDisableAccount.All')) {
    if ($scope -notin $ctx.Scopes) { throw "Missing scope: $scope" }
}
Write-Host 'Execution connection verified.'
```

Device codes, TAPs, passwords, and tokens must not be captured in screenshots or committed. `-ContextScope Process` means the connection may need to be recreated after opening a new PowerShell session. The scripts also check the expected tenant/client internally during live execution.

## 5. Joiner — supervised account provisioning

**Private input:** `Private-Data/HR-Events-Live.csv`, containing exactly one approved JOINER and an existing, enabled manager's UPN. Do not run the example-domain sample directly against Entra.

Dry run (offline):

```powershell
./Scripts/Invoke-EntraJML.ps1 -InputCsv './Private-Data/HR-Events-Live.csv' -UpnDomain $domain
```

Live (only after authorization and preflight):

```powershell
./Scripts/Invoke-EntraJML.ps1 -InputCsv './Private-Data/HR-Events-Live.csv' -UpnDomain $domain -ExpectedTenantId $expectedTenantId -ExpectedClientId $executionClientId -ApprovedTicket 'HR-APP-1042' -Execute
```

Before `Y`, verify the employee, approval reference, requested attributes, correct tenant and client, and absence of collisions on **both UPN and Employee ID**. The script creates a disabled cloud-only account with a random initial password that is not logged; assigns the manager; checks attributes; then enables the account. The script does **not** independently verify dynamic group membership or authenticate as the new user.

**Postchecks:** correct attributes, active status, manager, and membership in `SG-JML-ClinicalOps`; separately perform TAP/passkey enrollment where required. Keep the TAP secret and remove it after validating a fresh passwordless sign-in.

## 6. Mover — supervised department transfer

**Private input:** `Private-Data/HR-Mover-Avery.csv`, one approved MOVER event with target department `Finance`, new title, and current manager.

Dry run:

```powershell
./Scripts/Invoke-EntraJMLMover.ps1 -InputCsv './Private-Data/HR-Mover-Avery.csv' -UpnDomain $domain
```

Live:

```powershell
./Scripts/Invoke-EntraJMLMover.ps1 -InputCsv './Private-Data/HR-Mover-Avery.csv' -UpnDomain $domain -ExpectedTenantId $expectedTenantId -ExpectedClientId $executionClientId -ExpectedFromDepartment 'Clinical Operations' -ApprovedTicket 'HR-APP-1042-MOV' -Execute
```

Preflight requires a uniquely correlated lab user who is enabled, cloud-only, in the **expected source department**, and still assigned to the expected manager. The script changes **department and job title**, not the UPN, manager, password, passkey, or groups directly.

**Postchecks:** confirm target title/department, Avery **present** in `SG-JML-Finance`, and Avery **absent** from `SG-JML-ClinicalOps`. Dynamic group processing is asynchronous. Do not claim access remediation complete until both membership outcomes are observed.

## 7. Leaver — supervised offboarding

**Private input:** `Private-Data/HR-Leaver-Avery.csv`, one approved LEAVER event identifying the currently enabled Finance employee.

Dry run:

```powershell
./Scripts/Invoke-EntraJMLLeaver.ps1 -InputCsv './Private-Data/HR-Leaver-Avery.csv' -UpnDomain $domain
```

Live:

```powershell
./Scripts/Invoke-EntraJMLLeaver.ps1 -InputCsv './Private-Data/HR-Leaver-Avery.csv' -UpnDomain $domain -ExpectedTenantId $expectedTenantId -ExpectedClientId $executionClientId -ExpectedFromDepartment 'Finance' -ApprovedTicket 'HR-APP-1042-LEV' -Execute
```

The script verifies account correlation, current department, company marker, enabled state, and Graph context; disables the user; reads back disabled state; then sends a **revokeSignInSessions** API request. It does **not** delete the user, remove passkeys, or directly change group membership. A successful API response does not guarantee immediate expiry of every access token or third-party app session.

**Postchecks:** Avery's account is disabled, Avery is absent from `SG-JML-Finance` after dynamic processing, and the private report records the Graph session-revocation request outcome. Retain the account record for lab audit evidence.

## 8. Failure states, recovery and retry policy

| Condition / status | Meaning | Operator action |
|---|---|---|
| HR `REJECTED` | Invalid or unapproved input | Fix/reauthorize source data; never bypass the validator |
| Joiner `FAILED_NO_CREATE` | No account was created according to script state | Check failed preflight and directory before any new attempt |
| Joiner `NEEDS_REVIEW` | Account creation occurred; later step failed | **Do not rerun**; verify the user is disabled or disable manually if needed, inspect manager and attributes, then plan a supervised recovery |
| Mover `FAILED_NO_WRITE` | Preflight did not modify user | Correct authorization or state mismatch only after review |
| Mover `NEEDS_REVIEW` | Update attempted and final state uncertain | Inspect live attributes and pending dynamic memberships; decide on an authorized corrective action, **not** an automatic rollback |
| Leaver `FAILED_NO_WRITE` | Preflight rejected action | Inspect original reason and current identity state |
| Leaver `NEEDS_REVIEW_DISABLED_OR_PARTIAL` | Disable may have happened, but verification or revocation incomplete | Keep account disabled; investigate Graph/audit results and downstream access before any further action |
| Repeated Leaver blocked | Existing account was already disabled | Treat as state-based protection; investigate rather than re-execute |

The scripts do **not** implement an automatic transactional rollback, a durable event ledger, or concurrency locks. A failed Mover may leave dynamic groups in transition. A Leaver should never re-enable an identity just because a later session-revocation request failed.

`-WhatIf` is useful for protected operations, but the present script implementations also apply it to report-writing cmdlets in some paths. As demonstrated in the repeated-Leaver test, **a `-WhatIf` run might not create the expected report CSV**. Use sanitized terminal evidence where appropriate; don't claim every simulation produces a durable report.

## 9. Evidence and operational closure

Suggested sanitized evidence categories:

1. **Input validation:** accepted JOINER and rejected negative HR records.
2. **Joiner:** user attributes and manager; Clinical Operations dynamic membership.
3. **Passwordless:** passkey registered, successful FIDO2 sign-in, TAP removed.
4. **Mover:** updated department/title, Finance membership added, old department membership removed.
5. **Leaver:** account disabled, Finance membership removed, session-revocation API success.
6. **Safety:** already-disabled user rejected on a repeated Leaver invocation.

Name files `Descriptive-Name_YYYY-MM-DD_HH-mm-ss.png`. Redact **actual UPN/domain**, tenant/client/object IDs where unnecessary, administrator details, TAP values, device codes, secrets, and tokens. Raw `Reports/` CSVs stay private; reports may contain object IDs and UPNs.

Before publishing:

```powershell
git status --short --untracked-files=all
git ls-files -- Private-Data/ Reports/
```

Do not publish private data or raw reports. Review every image manually. Once all evidence is sanitized, stage explicit paths, inspect `git diff --cached`, and only then commit. Finally, disconnect the privileged Graph session and review whether execution-application consent should be retained in the lab.

## 10. Explicit limitations

The workflow models HR-driven requests **through CSV input**, not direct HRIS integration. The execution path is one employee/event at a time and requires an operator. Approval IDs can be matched but are not verified against an independent ticketing/HR authority. The tests demonstrate Entra account state and dynamic group changes, **not end-to-end SaaS entitlement removal**. No automated replay ledger, bulk orchestration, production secrets system, or transactional rollback is implemented. These are follow-on design opportunities, not features of the tested scripts.
