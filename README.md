# Parallax QA

Dedicated, bounded production-QA harnesses for Parallax.

This repository is intentionally separate from the Parallax application source. Production admission is fail-closed on the exact repository name `Ryan9876/parallax-qa`, stable GitHub repository ID `1351817336`, exact `refs/heads/main` ref, exact workflow path, GitHub-hosted runner, admitted event name, and the `parallax://qa-production` OIDC audience. Repository name, stable ID, and workflow reference are bound as one server-owned trust record.

## Trust rules

- QA workflows authenticate only as the existing bounded Parallax QA principal.
- No workflow receives normal-user authority, source-publishing authority, deployment authority, or REVIEW approval authority.
- Production replay jobs use disposable or explicitly approved source-only fixtures.
- Trusted executable QA harness code lives in this repository; application source is not executed merely to establish QA authentication.
- The standing production replay requires explicit `workflow_dispatch`; ordinary repository pushes run harness CI but do not automatically exercise production.
- Any temporary trust added for a migration or incident must be removed after acceptance evidence is captured.

## Canonical replay

`.github/workflows/production-replay.yml` runs the routine production acceptance set when explicitly dispatched:

- Python source-only full experience against `Ryan9876/Movies`;
- .NET/OT Time source-only full experience against `Ryan9876/ot-time`.

Both flows must reach the protected `REVIEW` boundary with no failure and validate the authenticated source-only ZIP handoff.

The greenfield W9-S1 Decision Ledger reference trial is intentionally not part of the standing trusted workflow. It can be reintroduced as a separately reviewed, exact workflow only when a fresh approved empty target is available.
