# RC1 S84 — Navigator device-link security release gate

Status: **BLOCKING / NO-GO** (2026-11-11). This is a threat-model and implementation contract only, **not** a deployed remediation.

## Verified pinned code paths

Read-only inspection of the pinned FleetOps `NavigatorController` under the QA release candidate (`c806c0798a6793ae2b5f6b1941a373ecb1884517`) found:

1. The protected `getLinkAppUrl()` issues `expires` and `signature`, with 30-minute TTL.
2. `linkSignature(int $expires)` signs **only** `fleet-ops.navigator.link-app|{expires}` using the application key. No company, subject, device, purpose nonce, or token identifier is signed.
3. The unauthenticated `linkApp()` URL rejects an invalid signature/expired timestamp before credential access.
4. After passing that check, `findAdminUser()` calls `User::where('type', 'admin')->first()` without a company constraint or explicit link-to-issuer association.
5. `firstOrCreateNavigatorCredential($adminUser)` selects/creates a credential named `NavigationAppLinker` for **that selected admin's company**, and `linkApp()` embeds the credential `key` in a deep-link URL.
6. `hasValidLinkSignature()` has no nonce consumption or upper-bound issuance-time verification; any currently valid identical signed link is accepted repeatedly until expiry.

The observed HTTP negative tests in S74 (unsigned link 403, forged expired link 403, unauthenticated issuer 401) are useful but **do not prove correct-tenant credential issuance**. The S75 five PHPUnit tests verify HMAC/expiry mechanics only.

## Security impact to resolve before production

**Critical design concern:** A signed link issued by a legitimate admin of company B does not encode B or its issuing admin. On use, the endpoint may select an unrelated first global admin (company A) and return an A-owned Navigator credential in the deep-link response. This is a **source-derived cross-tenant credential selection risk**, not a claim that an attacker has already exploited it. The exact risk must be confirmed with a controlled disposable multi-tenant integration test; production and live QA data must not be used.

**Replay concern:** The link is currently a 30-minute bearer capability. Someone who receives/copies it can reuse it while valid, potentially receiving the reusable API credential. A one-time flow is strongly recommended if the link grants a persistent credential.

## Minimum remediation contract (implement only on reviewed, pinned FleetOps fork)

- Generate a cryptographically random, single-use link identifier. Store **only its hash** server-side with `company_uuid`, `issued_by_user_uuid`, intended audience/purpose, `expires_at`, consumed status, and optional device/session audience.
- Require issuer to be authenticated and authorized for exactly the selected company **when link is generated**. Do not infer company from a globally first admin or from an unauthenticated request parameter at redemption.
- Bind `company_uuid`, issuer/user, purpose, expiry and nonce/token id under a versioned keyed MAC or use a cryptographically secure, opaque random token tied to server-side state. Reject missing/wrong company, cross-tenant substitution, malformed/unknown/expired tokens, and future-expiry manipulation.
- Redeem **atomically and once**; consume the nonce in a database transaction/uniqueness-protected conditional update before credential creation. A concurrent replay must fail deterministically. Define a safe retry/failed-redemption policy without issuing another persistent key.
- Select the admin/organization only by the authenticated issuance record's exact `company_uuid` and `issued_by_user_uuid`; enforce tenant membership and nonrevoked status at redemption. Never use unscoped `User::where('type', 'admin')->first()`.
- Prefer per-device, short-lived and revocable scoped credentials over a shared long-lived admin key. Prevent credential/deep-link leakage through logs, query-string instrumentation, referrers or analytics. Review practical mobile provisioning protocol before committing implementation.
- Use a versioned transition plan for already-generated legacy links: **fail closed** at cutover, rather than accepting both unbound legacy and new audience-bound links indefinitely.
- Set explicit minimum/maximum TTL, constant-time signature comparisons, rate limits and audit events without storing plaintext tokens or keys.
- Write a reversible schema migration and a rollback procedure that cannot silently restore vulnerable legacy credential issuance.

## Required executable security acceptance gates

On an **isolated disposable** multi-company MySQL fixture (no real account or Firebase/production keys):

1. Admin B obtains a link; redeeming it returns only company B's correctly scoped credential even if company A was created first. Deny if B is inactive/removed.
2. Admin A's link cannot redeem against company B, and altered organization/subject/purpose are denied.
3. Invalid/missing/tampered/expired/far-future tokens denied; no credential DB writes on failures.
4. Valid link can be redeemed exactly once. Repeat redemption rejected. Two concurrent redemptions: exactly one wins.
5. Revoked link/disabled issuer/wrong device (when device-bound) denied.
6. Credential scopes, lifetime, tenant foreign keys, audit and redacted logs are verified; no plaintext token in exception, API or CI output.
7. API route authorization and IDOR tests, real PHPUnit, full schema migrations and immutable lock/overlay CI pass on the exact review SHA.
8. QA authenticated tenant-device acceptance and rollback rehearsal pass **after** authorized identities and device access are available.
9. GitHub Actions checks must show a completed success on the **exact** candidate SHA. Stuck old runs never count as approval.

## Governance

- Implement in the reviewed FleetOps fork and pin it in Composer lock/overlay; do **not** patch production vendor files or the running QA image in place.
- Keep [PR #11](https://github.com/gsentsas/fleet/pull/11) **DRAFT** while this blocking issue is open.
- No release GO solely on passing existing HMAC tests, green past CI or service health.
- Track proof, test logs, exceptions, next action and explicit GO/NO-GO in [issue #1](https://github.com/gsentsas/fleet/issues/1).
