# WingWard development and review contract

This repository contains the native iOS app, Hono API on Cloudflare Workers,
Supabase migrations and tests, and UUID-only security registries. The matching
journey can lead to an in-person meeting; authorization is a safety boundary.

Use Node 22 and pnpm 10.34.5. Preserve the frozen lockfile, supply-chain settings,
and pinned GitHub Actions. `pnpm build` and `pnpm test` validate the API; run the
shared `Wingward` Xcode scheme for native tests. These checks do not establish
that the currently deployed hosted environment completed the entire journey.

Never read, print, or commit `.env`, `.dev.vars`, `Local.xcconfig`, private keys,
account credentials, or personal data. Public client values in `Shared.xcconfig`
are explicitly intended for the hosted judging app. Use RevenueCat Test Store.
Do not deploy, publish, change access, or use real-customer data without approval.

Keep server authorization, ownership, admission, expiry, and quotas enforced.
Internal API routes require `requireInternalAuth`; an unset internal token must
return 503. The service-role database client bypasses RLS, so enforce ownership
in API code and retain RLS as a second boundary. Store UTC, validate IANA timezones,
and never silently substitute a timezone. Verify webhook authentication and
signatures; validate external input, including AI output, before use.

## Code Review Rules

Assume an attacker who already holds a valid account. Report concrete reachable
findings and explain the inputs and resulting state before proposing a fix.
If reachability is uncertain, say so. Begin blocking findings with `[P0]` or
`[P1]`; automation uses these tags. Reviews produce findings, not pushed changes.

Report as `[P0]`: authorization gaps, internal routes that fail open, weaker RLS
or grants, secrets or personal data in output, client-only entitlement checks,
unvalidated external input or unauthenticated webhooks, and invalid or fallback
timezones. Report as `[P1]` when confident: missing security tests, unrelated
changes to sensitive boundaries, and security failures silently treated as success.

Do not report style or formatting. Do not introduce dependency changes without
necessity. A log of internal IDs alone is not personal free text; do report logs
that expose secrets or user-controlled content. Preserve independent review;
an author reviewing their own implementation is not an independent check.
