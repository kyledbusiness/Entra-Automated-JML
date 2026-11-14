# From HR Events to Verified Access Changes | Automated JML with Microsoft Entra ID

**Identity Lifecycle Management (JML) · Microsoft Graph PowerShell · Dynamic Groups · RBAC · TAP · FIDO2 Passkeys · Least Privilege · Audit Evidence**

> **An employee transferring departments should not take yesterday's access into tomorrow's job. And when that employee leaves, their account should not remain a way back in.**

That is the problem I set out to solve for **Cedarbridge Health System (CHS)**, a fictional healthcare organization. Its IT team processes hires, transfers, and terminations while clinical and financial staff need the right access to do their jobs. A missed update can leave a new employee unable to work, a transferred employee holding permissions from two departments, or a terminated employee with an enabled identity.

I built a **supervised, HR-driven Joiner–Mover–Leaver (JML) workflow** using **PowerShell 7, Microsoft Graph, and Microsoft Entra ID**. Then I followed one employee through the entire lifecycle and checked what actually changed in the directory—not just what the script said it changed.

## The business problem: access changes faster than manual processes

For CHS, the risk wasn't creating an account. It was **keeping identity and access aligned with the employee's current role**:

- **Joiners:** Incomplete or inconsistent HR data can create the wrong identity or delay day-one access.
- **Movers:** Granting Finance access without removing Clinical Operations access creates **privilege accumulation** and unnecessary exposure to sensitive business information.
- **Leavers:** An enabled account or lingering sessions after termination increases the risk of unauthorized access.
- **Auditability:** A completed ticket or a successful API response does not prove that the correct identity changed or that obsolete group membership disappeared.

**My objective:** Turn an approved HR event into a controlled identity operation, validate the target before changing it, and independently verify the access state afterward. The healthcare organization, employee, HR approvals, and events in this lab are simulated; **no patient data or production applications were involved**.

## My solution: validate → execute → verify

I used **approved CSV records as simulated HR input**, a shared validator, and three guarded Microsoft Graph PowerShell scripts. **Dynamic user security groups** translate current Entra attributes into department-based *birthright group eligibility*.

```text
Simulated HR event (Joiner / Mover / Leaver)
                  |
                  v
    Input quality + approval checks
                  |
                  v
   Tenant, application, identity and
      account-state verification
                  |
                  v
    Supervised Microsoft Graph change
      /           |             \
  JOINER        MOVER          LEAVER
 Create user  Change role       Disable
 + manager    attributes.    + revoke sessions
      \           |             /
                  v
    Read back account state in Entra
                  |
                  v
 Verify dynamic membership + evidence
```

**Technical foundation:** Four department groups (`SG-JML-ClinicalOps`, `SG-JML-Finance`, `SG-JML-HR`, `SG-JML-IT`) use rules matching the **`CHS-JML-LAB` company marker**, **department**, and **`accountEnabled = true`**. They make department membership responsive to identity attributes without the scripts manually adding or removing group members.

**Evidence:** [Four dynamic groups](Evidence/00-Access-Design/JML-Department-Dynamic-Groups-Overview.png) · [Clinical Operations membership rule](Evidence/00-Access-Design/JML-ClinicalOps-Dynamic-Membership-Rule.png)

---

## The lifecycle test — Avery Reed

### 1. Joiner: get the right person in, not just *someone* in

**The HR request:** Avery Reed (`CHS-1042`) joins **Clinical Operations** as an Integration Coordinator. The submitted record includes department, title, employee identifier, manager, effective date, and an approval reference.

Before any Graph write, `Test-HREvents.ps1` validated the input. I deliberately tested **four bad HR records**—a department with leading/trailing whitespace, an invalid department, an unapproved event, and a duplicate Event ID. **All four were rejected.** The whitespace case matters: a small upstream data defect can prevent a downstream access rule from matching correctly.

For the approved Joiner, `Invoke-EntraJML.ps1` checked the intended tenant/application context, duplicate **UPN and Employee ID**, and an existing enabled manager. It then **created Avery disabled**, assigned the manager, verified the attributes, and enabled the account. Entra's dynamic rule subsequently placed Avery in **`SG-JML-ClinicalOps`**.

I also tested a passwordless first-day experience: an administrator issued a **Temporary Access Pass (TAP)**, Avery registered a **synced FIDO2 passkey in iCloud Keychain**, and I verified a *separate successful passkey sign-in* in Entra logs. The TAP was then deleted. **Passkey registration was an interactive onboarding test, not an automated step of the Joiner script.**

**Evidence:** [HR validation and rejected records](Evidence/01-HR-Validation/JML-HR-Input-Validation.png) · [Joiner attributes and manager](Evidence/02-Joiner/JML-Joiner-Attributes.png) · [Clinical Operations membership](Evidence/02-Joiner/JML-Joiner-Dynamic-Membership.png) · [Successful passkey sign-in](Evidence/03-Passwordless-Onboarding/JML-Passwordless-SignIn.png) · [TAP removed](Evidence/03-Passwordless-Onboarding/JML-Passwordless-Methods.png)

### 2. Mover: prove old access was removed

**The HR request:** Avery transfers from **Clinical Operations to Finance** and becomes a **Financial Operations Analyst**.

`Invoke-EntraJMLMover.ps1` matched Avery by the approved identity attributes, required the **expected source department** and unchanged manager, and updated only the department and job title. The script **did not manually edit security-group memberships**.

The important test came afterward. I verified **both sides of the access transition**:

| Entitlement | Before the transfer | Verified after processing |
|---|---|---|
| `SG-JML-ClinicalOps` | Member | **Not a member** |
| `SG-JML-Finance` | Not a member | **Member** |

The directory update succeeded first; dynamic group membership followed asynchronously. I treated the transfer as complete **only after the old membership disappeared and the new one appeared**.

**Evidence:** [Updated Finance attributes](Evidence/04-Mover/JML-Mover-Attributes.png) · [Finance membership added](Evidence/04-Mover/JML-Mover-Finance-Added.png) · [Clinical Operations membership removed](Evidence/04-Mover/JML-Mover-ClinicalOps-Removed.png)

### 3. Leaver: disable access, revoke sessions, retain evidence

**The HR request:** Avery's employment ends. The approved Leaver event identifies the same employee, now in **Finance**.

`Invoke-EntraJMLLeaver.ps1` verified Avery's identity, lab marker, enabled state, and current department before disabling the account. It **read back `accountEnabled = false`**, then called Microsoft Graph's **`revokeSignInSessions`** endpoint. The API returned success.

Finally, I checked Entra directly: Avery **remained disabled** and was **removed from `SG-JML-Finance`** after dynamic processing. The identity record was retained for audit; the script did not delete the user or automatically remove downstream SaaS permissions.

**Evidence:** [Disabled identity](Evidence/05-Leaver/JML-Leaver-Account-Disabled.png) · [Finance membership removed](Evidence/05-Leaver/JML-Leaver-Finance-Removed.png) · [Revocation API succeeded](Evidence/05-Leaver/JML-Leaver-Session-Revocation.png)

---

## Safeguards I built and tested

| Control | What it protects against |
|---|---|
| **HR data-quality gate** | Invalid departments, whitespace, missing approval, and duplicate event IDs entering execution |
| **Identity correlation** | Modifying the wrong user; scripts check UPN, Employee ID, lab company marker, and state |
| **Least-privilege workflow separation** | Mixing read-only discovery with the deliberately authorized Graph execution context |
| **Supervised execution** | Accidental writes through dry-run defaults, explicit `-Execute`, approval-reference matching, and confirmation |
| **State-based guards** | Overwriting an unexpected department or attempting to offboard an already-disabled identity |
| **Read-after-write verification** | Treating a Graph request as complete without checking updated identity attributes |
| **Private, unique reports** | Overwriting evidence or committing real tenant-specific HR data and raw audit details |

**Negative test:** I attempted to run the approved Leaver record again after Avery had already been disabled. The preflight rejected it with **“Account is already disabled; inspect before retrying.”** No additional Entra write occurred. This demonstrates a **state-based re-execution guard**, not a durable event-ID replay ledger.

**Evidence:** [Repeated Leaver blocked](Evidence/06-Failure-Testing/JML-Leaver-Reexecution-Blocked.png) · [Original Joiner dry run](Evidence/02-Joiner/JML-Joiner-Dry-Run.png)

## Try the safe, offline validation

The sample CSVs use synthetic identities and do not require a Graph connection:

```powershell
pwsh -NoProfile -File ./Scripts/Test-HREvents.ps1 -InputCsv ./Sample-Data/Sample-HR-Events.csv
pwsh -NoProfile -File ./Scripts/Test-HREvents.ps1 -InputCsv ./Sample-Data/Sample-HR-Events-Negative.csv
```

Expected: **1 valid Joiner** in the positive sample; **4 rejected records** in the negative sample (which intentionally returns a nonzero exit code).

For guarded dry runs, live prerequisites, operator approval, partial-failure handling, and recovery, read the [Operations Runbook](Docs/Operations-Runbook.md). Start with [START-HERE.md](START-HERE.md) for repository orientation, or browse the [Evidence Index](Evidence/README.md).

## Findings, limits, and next engineering steps

- **HR approvals were simulated.** `ApprovalID` matching checks consistency; it does not independently validate a ticket or approval in an HRIS.
- **Scope was intentionally controlled:** one synthetic employee, three approved lifecycle events, and negative test records—not an unattended bulk orchestration platform.
- **Dynamic groups represent directory membership, not proven application entitlements.** No EHR, finance application, or third-party SaaS deprovisioning was performed.
- **Session revocation was API-verified, not end-to-end token invalidation-tested.** Existing access tokens and application sessions can require separate controls.
- **Recovery is supervised.** The scripts record failure states for investigation but do not implement transactional rollback, persistent replay protection, concurrency locking, or automatic compensation.
- **Graph execution permissions remain powerful.** A dedicated application and runtime checks reduce accidental misuse; they do not technically restrict `User.ReadWrite.All` to just Avery at the API permission boundary.

**What I took away:** IAM automation isn't finished when a script prints *success*. It is finished when the **right identity** is in the **right state**, the **old access is gone**, and the evidence supports that conclusion.

*CHS and its employee records are fictional. This is a controlled identity-engineering portfolio lab, not a production deployment or a HIPAA compliance certification.*
