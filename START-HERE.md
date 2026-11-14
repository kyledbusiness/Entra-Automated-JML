# Phase 1 — HR event validation (read-only)

This stage **does not connect to Microsoft Graph or modify Entra ID**. It checks an approved synthetic HR event against configurable data-quality rules before any account creation.

1. Upload `Config/`, `Sample-Data/`, `Scripts/`, and `.gitignore` to the repository root in your Codespace. Keep the repository private for now.
2. In the Codespaces terminal, run:

   ```bash
   pwsh -NoProfile -File ./Scripts/Test-HREvents.ps1 -InputCsv ./Sample-Data/Sample-HR-Events.csv
   ```

   Expected: `1` event validated, `0` rejected, exit code `0`.
3. Run the deliberately invalid feed:

   ```bash
   pwsh -NoProfile -File ./Scripts/Test-HREvents.ps1 -InputCsv ./Sample-Data/Sample-HR-Events-Negative.csv
   ```

   Expected: `4` events rejected. Exit code `2` means validation found invalid events; this is **expected** for the negative test.
4. Capture the terminal showing the **negative test rejection reasons** as `Evidence/02-HR-Validation/JML-HR-Input-Validation.png`. The feed uses fictional names and an example-only domain.

Reports appear in `Reports/`, which is ignored by Git. Do **not** commit unsanitized real UPNs, tenant IDs, passwords, TAPs, access tokens, or session data. An `Approved` field in a CSV is *not* independent approval verification; the later execution workflow must verify the source and authorization before changes.

The next stage will implement a separate guarded, parameterized Microsoft Graph execution script; keep this validation gate read-only.
