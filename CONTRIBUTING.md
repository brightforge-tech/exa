# Contributing to Exa the Executive Assistant

Thanks for helping make Exa better. Bug reports, ideas, translations,
documentation and code are all welcome.

## Before you start

- **Questions and ideas:** open a [Discussion](../../discussions).
- **Bugs:** open an [Issue](../../issues/new/choose) with steps to reproduce,
  your Android version, device model and AI provider.
- **Security problems:** do **not** open a public issue — see
  [SECURITY.md](SECURITY.md).
- **Bigger changes:** open an issue or discussion first so we can agree on the
  approach before you spend time on it.

## Development setup

Requirements: Flutter stable (Dart SDK 3.12+), Android SDK, JDK 17+.

```bash
cd exa_mobile
flutter pub get
flutter analyze      # must report no issues
flutter test         # must pass
flutter build apk --debug
```

The architecture, invariants and design decisions are documented in
[exa_mobile/docs/ARCHITECTURE.md](exa_mobile/docs/ARCHITECTURE.md). Please read
the "Key invariants" section of [exa_mobile/README.md](exa_mobile/README.md)
before changing the agent or tool registry.

## Pull requests

1. Fork the repo and create a branch from `main`.
2. Keep each PR focused on one change. Add or update tests for behaviour you
   change — Exa has a large test suite and we want to keep it that way.
3. Run `flutter analyze` and `flutter test` before pushing; CI runs both.
4. Describe *what* changed and *why* in the PR description, and link the
   issue it addresses.
5. Never commit API keys, keystores, `key.properties`, personal data, logs or
   chat exports.

### Rules the agent must keep

- The agent acts only through registered tools — no arbitrary code or raw SQL.
- Outward-facing or destructive actions require user confirmation.
- Every tool call is logged.
- New permissions must be optional and explained to the user.

## Contributor Licence Agreement

Before we can merge your first pull request, you need to agree to the
[Contributor Licence Agreement](CLA.md). The CLA bot will comment on your PR
with a one-line sentence to post; you only do this once.

**Why a CLA?** Exa is offered under the AGPL-3.0 and also under commercial
terms, which funds its development. The CLA lets BrightForge Technologies
include your contribution in both. You keep the copyright in your work.

## Code of conduct

Everyone taking part in this project is expected to follow our
[Code of Conduct](CODE_OF_CONDUCT.md).
