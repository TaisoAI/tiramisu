# Security policy

If you've found a security issue in Tiramisu, please report it privately. **Don't open a public GitHub issue for security bugs.**

## How to report

Email **`security@taiso.ai`** with:

- A description of the issue.
- Steps to reproduce, or a proof-of-concept if you have one.
- The version of Tiramisu and macOS where you observed it.
- Any thoughts on impact / scope.

We'll acknowledge within ~3 business days. If the issue is confirmed, we'll work with you on a coordinated disclosure window before publishing the fix.

## Scope — what counts as a security issue

- Anything that lets an attacker run code on a user's Mac via opening a malicious `.tiramisu` file or image.
- Anything that exfiltrates user data over the network without explicit user action (the app should stay local-first by default; cloud calls are user-initiated).
- Privilege escalation through the bootstrap script or the post-build install hook.
- Path-traversal / arbitrary-file-write in the document loader.
- Memory-safety bugs that could lead to crash-on-open exploits.

## Out of scope

- "ControlServer is bound to localhost" — yes, that's by design; it's a debug surface and Release builds default it to off (planned).
- "View Source on the marketing site reveals strategy docs at `internal/`" — known. The internal/ dir is casual privacy via passkey + `robots.txt`; for real protection in deploy we layer nginx basic auth.
- Findings that require an attacker to already have local code execution on the user's Mac.
- Issues in upstream dependencies (mflux, ml-stable-diffusion, RichTextKit) — please report those upstream first.

## Hall of fame

Once we have credited reports, they'll land here. Thanks for helping keep Tiramisu safe for creators.
