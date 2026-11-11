# Exa — Google / Microsoft Integration Plan (Phase 6)

Status: **planned**. Today, email/calendar context reaches Exa only through
the consent-based browser sharing flow ("Send to Exa"). This document is the
implementation plan for first-class API integrations.

## Why APIs instead of scraping

Embedded-WebView scraping of Gmail/Outlook is brittle and against most
providers' terms; Google actively blocks logins from suspicious WebViews.
The product spec also prefers official APIs (guide §11). The browser flow
stays as the universal fallback for services without APIs.

## Google

| Item | Plan |
|---|---|
| Auth | OAuth 2.0 Authorization Code + PKCE via `google_sign_in` (or AppAuth) — native flow, no client secret on device |
| Cloud setup | Google Cloud project, OAuth consent screen (External), Android client ID bound to `com.brightforge.exa` + release-keystore SHA-1 |
| Scopes (read-only first) | `gmail.readonly`, `calendar.readonly` — narrow scopes ease verification |
| APIs | Gmail REST (`users.messages.list/get`, metadata first), Calendar v3 (`events.list` with `timeMin/timeMax`) |
| Verification | Gmail scopes are "restricted" — Google security review required before public release; development works with test users |

## Microsoft

| Item | Plan |
|---|---|
| Auth | MSAL (Entra ID) public client app, Authorization Code + PKCE |
| Setup | App registration in Entra portal, Android redirect URI with package + signature hash |
| Scopes | `Mail.Read`, `Calendars.Read` (delegated) |
| API | Microsoft Graph: `/me/messages`, `/me/calendarView` |

## App-side architecture (already scaffolded)

- `connected_accounts` table + `ConnectedAccountRepository` — provider,
  access type, per-capability toggles (email/calendar), sync metadata.
- Tokens will go in `flutter_secure_storage` (never SQLite), refresh handled
  by the auth library.
- New agent tools: `read_email_context`, `read_calendar_context` — registry
  entries gated by (a) the account's capability toggles and (b) the
  `email.read` / `calendar.read` permission groups, like every other tool.
- Sync jobs: new job types `email_sync` / `calendar_sync` in the existing
  scheduler; pulled events land in `schedule_items` with `source` =
  provider and `external_id` for dedupe.
- The daily review job already consumes everything above once present.

## Sequencing

1. Local device calendar (no cloud setup; `device_calendar` plugin +
   `READ_CALENDAR` runtime permission) — fastest win.
2. Microsoft Graph (simpler approval story than Gmail).
3. Google Calendar, then Gmail (restricted-scope review last).

## Prerequisites that need a human

- Google Cloud / Entra accounts and app registrations.
- Release keystore SHA-1 (exists: `android/keystore/exa-release.jks`).
- Privacy policy URL (required by both consent screens).
