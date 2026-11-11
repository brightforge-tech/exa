# Exa the Executive Assistant — developer guide

> This is the Flutter app. For the project overview, install steps and
> licence, see the [main README](../README.md).

Exa is a local-first, agentic AI personal assistant for Android. You talk (type)
to it; it manages tasks, reminders, and your schedule through a controlled tool
system, builds screens on demand from safe JSON schemas, and learns its own
operating rules over time — with every action logged and every learned rule
versioned, reviewable, and reversible.

All seven phases of the original design are implemented. Google/Microsoft API
integrations are planned in [docs/INTEGRATIONS.md](docs/INTEGRATIONS.md); the
full design is in [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## What works today

- **Assistant chat** — natural language in, agent actions out. The agent runs a
  tool-use loop and can chain multiple tools per request. Providers: Claude,
  DeepSeek, any OpenAI-compatible endpoint (Ollama, LM Studio), or an
  on-device model (Gemma 3 1B, Gemma 3n E2B, Qwen2.5 1.5B).
- **Floating navigation** — no menu bars; a single floating button
  (bottom-left) expands into the labelled destination icons (Exa, Tasks,
  Schedule, Reminders, Browser, Settings).
- **Emails for Exa** — paste emails in Settings → Emails for Exa; the agent
  reads them with `read_email_context`, can extract tasks/meetings/deadlines
  ("digest my emails"), marks them digested, and folds undigested ones into
  the daily review briefing.
- **Mail accounts (IMAP/SMTP)** — Settings → Mail accounts: add any provider
  with host/port/app-password (password in secure storage). Exa fetches the
  inbox on demand (`sync_emails`), on a schedule (`email_sync` job), and
  before every daily review; `send_email` sends over SMTP and every send
  requires your in-chat approval.
- **Voice input** — mic button in the chat (the guide's "speak or type").
- **Device calendar import** — pull-down button on the Schedule tab or the
  `sync_device_calendar` tool / `calendar_sync` job; events dedupe by
  platform id.
- **Full dynamic component set** — forms (submit through the tool registry),
  kanban task board, agenda calendar, and web-preview links, plus the
  earlier card/list/table/chart/button/search components.
- **Notification actions** — reminders get Snooze (10 min) and Done buttons
  that work even with the app closed; tapping any Exa notification
  deep-links to the right screen.
- **Recurring tasks** — daily/weekly/monthly; completing one spawns the next
  occurrence. Background jobs can also run weekly now.
- **Behavior engine complete** — edit rules in the UI; the agent can
  update/evaluate/activate/rollback its own rules (all versioned).
- **Clear browser data** — cookies, site storage, and tabs (Settings).
- **Tasks** — create/edit/complete/delete manually or by asking Exa.
- **Reminders** — one-time and daily/weekly recurring, firing local
  notifications that survive app restarts and reboots.
- **Schedule** — local calendar events with a per-day view.
- **Dynamic screens** — "Create a screen with all overdue tasks" produces a
  validated JSON schema rendered from whitelisted components, openable and
  savable. Invalid schemas are rejected.
- **Behavior memory** — the agent saves Low Risk rules immediately (and tells
  you); Medium/High Risk rules wait for your approval in Settings → Agent
  behaviors. Rules are versioned with one-tap rollback.
- **Background jobs (Phase 3)** — WorkManager wakes the app ~every 15 min and
  runs due jobs: daily summary notifications, AI-written daily reviews, and
  overdue-task cleanup. Jobs are manageable in Settings → Scheduled jobs
  (pause/resume/run-now, per-run history) or by asking Exa.
- **Richer dynamic screens (Phase 4)** — schemas can now use cards, sortable
  data tables, bar charts (`group_by` counts), navigation buttons, and a live
  search box, all whitelist-validated.
- **Secure browser (Phase 5)** — tabbed in-app browser with persisted tabs
  and native cookie sessions. Pages reach Exa only via the ✨ "Send to Exa"
  button after an explicit consent dialog; shared pages are reviewable and
  deletable in Settings → Shared browser pages, and readable by the agent via
  `read_browser_context`.
- **Connected accounts (Phase 6)** — track browser-session accounts and
  toggle what context Exa may use; the daily review folds in shared pages.
  Direct Gmail/Graph API connections are specced in `docs/INTEGRATIONS.md`.
- **Privacy & control (Phase 7)** — per-group agent permission switches
  enforced inside the tool registry, a privacy dashboard, an audit log
  (permission changes, sharing, exports), JSON data export via the share
  sheet, and "Clear all data".
- **Tool activity log** — every tool call (input, output, status, errors) in
  Settings → Tool activity.
- **Safety** — destructive tools (delete task/event, create job) require an
  in-chat confirmation dialog; the agent only acts through the registry; the
  API key lives in Android Keystore-backed secure storage.

## Getting started

1. Install the debug APK: `build/app/outputs/flutter-apk/app-debug.apk`
2. Open **Settings → AI provider** and pick a provider: paste a Claude or
   DeepSeek API key, enter a local server address (e.g.
   `http://10.0.2.2:11434` for Ollama on the emulator's host), or download an
   on-device model. Without a model, tasks/reminders/schedule still work.
3. Ask Exa something: *"Remind me tomorrow at 8 AM to call John."*

The default Claude model is `claude-opus-4-8` (changeable in Settings).

## Development

```powershell
flutter pub get
flutter analyze
flutter test
flutter build apk --debug    # build/app/outputs/flutter-apk/app-debug.apk
flutter build apk --release  # unsigned-for-now release build
```

Min Android: 8.0 (API 26) · Target: API 36 · Package: `com.brightforge.exa`

## Architecture

```
lib/
├── agent/
│   ├── orchestrator/   # tool-use loop, confirmation gating
│   ├── prompts/        # system prompt incl. active behavior rules
│   └── tools/          # AgentTool definitions + ToolRegistry (validates,
│                       #   executes, logs every call)
├── core/               # GoRouter (bottom-nav shell + /screen/:key)
├── data/
│   ├── database/       # sqflite schema (tasks, reminders, schedule_items,
│   │                   #   dynamic_screens, tool_calls, agent_behaviors,
│   │                   #   behavior versions/requests, chat, settings, ...)
│   ├── models/
│   └── repositories/
├── features/
│   ├── assistant/      # chat UI + controller
│   ├── browser/        # tabbed secure browser + "Send to Exa" consent flow
│   ├── tasks/ reminders/ schedule/
│   ├── dynamic_ui/     # schema validator + renderer (whitelist only)
│   └── settings/       # hub, behaviors, jobs, permissions, privacy
│                       #   dashboard, audit, accounts, browser context,
│                       #   tool activity
├── services/
│   ├── ai_client/      # Claude, DeepSeek, OpenAI-compatible and on-device clients
│   ├── background_jobs/ # WorkManager dispatcher + JobRunner executors
│   └── notifications/  # flutter_local_notifications + timezone scheduling
└── shared/             # Riverpod providers
```

Key invariants:

- The agent **never** executes arbitrary code or raw SQL — only registered
  tools, and dynamic screens only query whitelisted tables/columns/operators.
- Every tool call is logged to `tool_calls`.
- Behavior rules are data, not code: stored in `agent_behaviors`, injected
  into the system prompt, versioned in `agent_behavior_versions`.
- High-risk behavior changes require explicit user approval
  (`behavior_change_requests`).

## Roadmap

- Google / Microsoft API integrations (OAuth, Gmail/Graph) — plan in
  `docs/INTEGRATIONS.md`
- Local device calendar import (`device_calendar` plugin)
- Voice input and wake mode
- More dynamic components (forms, task board, calendar view)
- End-to-end encrypted sync / desktop companion (long term)

## Release signing

Release builds are signed with a keystore described by
`android/key.properties` (see Flutter's
[Android signing guide](https://docs.flutter.dev/deployment/android#signing-the-app)).
Both files are gitignored. Without them, `flutter build apk --release` falls
back to the debug key.

## Device-owner provisioning

Optional, for the device-control features: see
[docs/PROVISION_DEVICE.md](docs/PROVISION_DEVICE.md) and
`tools/provision_device.ps1` / `tools/provision_device.sh`.
