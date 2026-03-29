# SleepWell Release Checklist

## Backend
- Run `composer install` in `cariloker`.
- Run migrations: `php artisan migrate`.
- Seed required SleepWell data:
  - `php artisan db:seed --class=SleepWellHomeFeedSeeder`
  - `php artisan db:seed --class=SleepWellAdPlacementSeeder`
- Verify `/api/v1/sleepwell/auth/register`, `/auth/login`, `/auth/me`, `/home-feed`, `/ad-placements`.

## Flutter app
- Run `flutter pub get`.
- Verify environment API base URL points to production.
- Set Android AdMob App ID via `ADMOB_APPLICATION_ID` manifest placeholder (replace test ID).
- Configure placement unit ids in SleepWell ad placement admin.
- Run smoke checks on Home, Profile, Settings, Saved, Sounds, Routine, Insights.
- Verify bedtime exact alarm permission + notification scheduling works after reboot.

## QA and analytics
- Confirm session lifecycle events: start/event/end.
- Confirm queued offline events flush after reconnect.
- Confirm account login/register/logout and data sync.
- Confirm ad placements render only for enabled slots.

## Go-live checks
- CI passing (`flutter analyze`, `flutter test`, backend tests).
- Crash-free cold start on Android (fresh install + upgrade path).
- Session events sync status reaches `ok` after reconnect from offline mode.
- Rollback plan prepared (DB backup + previous app build).
