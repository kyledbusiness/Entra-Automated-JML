# Evidence index — Entra Automated JML

All identities and approvals are synthetic. Screenshots show observed lab states at capture time; separate terminal evidence shows Graph execution results.

| Evidence | What it demonstrates |
|---|---|
| [JML-ClinicalOps-Dynamic-Membership-Rule.png](00-Access-Design/JML-ClinicalOps-Dynamic-Membership-Rule.png) | Clinical Operations attribute-based rule |
| [JML-Department-Dynamic-Groups-Overview.png](00-Access-Design/JML-Department-Dynamic-Groups-Overview.png) | Four dynamic department groups |
| [JML-HR-Input-Validation.png](01-HR-Validation/JML-HR-Input-Validation.png) | Positive and negative HR CSV validation results |
| [JML-Joiner-Dry-Run.png](02-Joiner/JML-Joiner-Dry-Run.png) | Offline Joiner dry run |
| [JML-Joiner-Attributes.png](02-Joiner/JML-Joiner-Attributes.png) | User attributes, manager, enabled state |
| [JML-Joiner-Dynamic-Membership.png](02-Joiner/JML-Joiner-Dynamic-Membership.png) | Dynamic Clinical Operations group membership |
| [JML-Passwordless-Methods-Before.png](03-Passwordless-Onboarding/JML-Passwordless-Methods-Before.png) | TAP and passkey registered before TAP removal |
| [JML-Passwordless-Methods.png](03-Passwordless-Onboarding/JML-Passwordless-Methods.png) | Passkey retained after TAP deletion |
| [JML-Passwordless-SignIn.png](03-Passwordless-Onboarding/JML-Passwordless-SignIn.png) | Successful synced-passkey authentication log |
| [JML-Mover-Attributes.png](04-Mover/JML-Mover-Attributes.png) | Updated Finance department and title |
| [JML-Mover-ClinicalOps-Removed.png](04-Mover/JML-Mover-ClinicalOps-Removed.png) | Old Clinical Operations group no longer lists Avery |
| [JML-Mover-Finance-Added.png](04-Mover/JML-Mover-Finance-Added.png) | Avery added to Finance dynamic group |
| [JML-Leaver-Account-Disabled.png](05-Leaver/JML-Leaver-Account-Disabled.png) | Avery disabled after termination |
| [JML-Leaver-Finance-Removed.png](05-Leaver/JML-Leaver-Finance-Removed.png) | Avery removed from Finance dynamic group |
| [JML-Leaver-Session-Revocation.png](05-Leaver/JML-Leaver-Session-Revocation.png) | Revocation API returned success |
| [JML-Leaver-Reexecution-Blocked.png](06-Failure-Testing/JML-Leaver-Reexecution-Blocked.png) | Already-disabled re-execution blocked |

**Important:** Dynamic membership is asynchronous. A successful script response is not proof of application-level access removal. The four negative HR rows and the blocked repeated-Leaver test are different kinds of safety evidence.
