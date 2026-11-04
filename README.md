# StableTraderX — Compete (native app)

Bragging-rights, play-money crypto challenge game. This is the native
iOS/Android client for the Compete service, built with Flutter — a thin consumer
of an existing headless backend. Not financial advice; no real money.

Privacy policy: https://stabletraderx.com/privacy

## Build

- Android: `flutter build apk --release`
- iOS (requires macOS): `flutter build ipa`

## Architecture note

This repository is the client only. The backend (Supabase schema, RLS policies,
and edge functions) and all secrets are proprietary and live in a separate
private system, never in this repo. The client ships only the public anon key.

CI (`.github/workflows/build.yml`) builds + verifies both platforms on every
push for free (public repo → unlimited GitHub Actions minutes).