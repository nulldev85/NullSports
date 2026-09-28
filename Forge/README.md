# Forge

A premium, fully customizable workout app for iPhone (iOS 17+). Everything is
tracked locally on the device, and the storage layer is built so data can't
quietly disappear.

## Get the app

1. In GitHub, open **Actions → Build Forge iPhone IPA** and run it (it also runs
   on every push that touches `Forge/`).
2. Download the **Forge-iPhone-unsigned-IPA** artifact and unzip it.
3. Sign and install `Forge-unsigned.ipa` with your usual sideloading tool
   (AltStore, Sideloadly, …). Bundle ID: `com.nulldev85.Forge`.

To rename the app, change `CFBundleDisplayName` and
`INFOPLIST_KEY_CFBundleDisplayName` in `project.yml`.

> **Keep the same bundle ID when you re-sign.** iOS ties an app's data to its
> bundle ID. Refreshing or reinstalling over the existing app keeps your data;
> installing under a different ID starts empty (you can still restore from a
> backup file — see below).

## Features

**Workout builder (Train tab)**
- Routines organized in folders, nested as deep as you like; drag to reorder,
  move between folders, duplicate, color tags, search.
- Straight sets, supersets and circuits, and timed blocks (AMRAP, EMOM,
  For Time, Tabata, intervals, custom sequences, Death By) in one routine.
- Per-set targets: weight, reps or rep ranges (`8-12`), time, distance, RPE;
  set types (warm-up, working, drop, failure); per-exercise rest times and
  notes.
- Unsaved edits are autosaved as a draft and offered back after a crash.

**Exercise library**
- 821 built-in exercises: barbell, dumbbell, kettlebell, machine, cable,
  Smith, bands, bodyweight, calisthenics, Olympic lifts, strongman,
  plyometrics, cardio, sports and mobility — searchable by name, alias
  (RDL, OHP, T2B…), muscle and equipment.
- Can't find one? Create it from the picker; custom exercises are saved
  permanently. Deleting one that has history only archives it.
- Per-exercise progress charts (estimated 1RM, heaviest, volume, reps, pace),
  full history and personal records.

**Live workout**
- Previous performance next to every set, targets as placeholders, one-tap
  completion, RPE per set (tap the set number), keyboard arrows between
  fields, automatic rest timer (±15 s, skip, notification when it ends),
  warm-up set generator, plate calculator, supersets, reordering, notes.
- Timed blocks run on a full-screen timer with round counting; results become
  real sets in your history.
- Finish screen: adjust times, rating, notes, update the routine with today's
  numbers. New personal records are celebrated.

**Timers**
- Stopwatch (laps), countdown, For Time (cap and rounds), AMRAP, EMOM/E2MOM,
  Tabata, work/rest intervals with multiple sets, custom named sequences,
  Death By. Voice announcements, beeps and haptics, get-ready countdown,
  keeps running with the screen locked (mixes with your music).
- Save any setup as a preset. Sessions are logged to history.

**History & progress**
- Calendar and searchable list, full workout detail, edit past workouts, save
  a workout as a routine, share a text summary.
- Weekly workouts/time/volume/sets charts with a weekly goal, week streaks,
  muscles trained, recent records, body weight and 18 other body measurements.
- Tools: plate calculator (uses your plate inventory), one-rep max table,
  warm-up calculator.

## How your data is protected

- **SQLite with a write-ahead log and full sync.** Every change is written in
  a transaction and synced to disk: a logged set survives force-quits, crashes
  and even a dead battery. The workout in progress is saved continuously and
  resumes exactly where you left off, including a running rest timer or AMRAP.
- **Stored in Application Support**, which iOS never purges and which is
  included in iCloud/computer device backups.
- **Daily snapshots** on the device (plus one before every update and every
  restore), browsable and restorable in Settings › Backups & Export. Restores
  snapshot the current data first, so they can be undone.
- **Automatic backup files** (a complete, human-readable JSON export) are
  written daily and after workouts to Files › On My iPhone › Forge › Backups,
  and optionally to any folder you pick, such as iCloud Drive. Pick a folder
  outside the app: the On My iPhone copy is removed if the app is deleted,
  the picked-folder copy is not. Restore one from Settings › Backups & Export.
- **Corruption recovery.** On launch the database is integrity-checked. If
  SQLite ever reports it damaged, the file is set aside (never deleted) and the
  newest intact snapshot is restored automatically.
- **Nothing is destroyed silently.** Deleted workouts and routines stay in
  Recently Deleted for 30 days; discarding a workout with logged sets keeps
  them there too; schema migrations only ever add.
- **Forward and backward compatible storage.** Stored documents decode with
  defaults for anything missing or unknown.

## Project layout

```
Forge/
  project.yml              XcodeGen spec (app + UI tests)
  Package.swift            SwiftPM package for the platform-independent core
  Sources/ForgeCore/       storage, models, timer engine, analytics (no UIKit)
  App/                     SwiftUI app, stores, services, resources
  Tests/ForgeCoreTests/    core unit tests (swift test on Linux or macOS)
  UITests/                 simulator UI tests that also capture screenshots
  Tools/                   exercise catalog generator, icon renderer
```

## Develop

- Core tests: `cd Forge && swift test` (Linux needs `libsqlite3-dev`).
- App: `cd Forge && xcodegen generate && open Forge.xcodeproj`.
- Exercise library: edit `Tools/generate_exercises.py`, then run
  `python3 Tools/generate_exercises.py`. Never change or remove an existing
  exercise id — history refers to it.
- CI (`.github/workflows/build-forge.yml`) runs the core tests on Linux and
  macOS, builds the unsigned IPA, runs the UI tests on a simulator, and uploads
  the screenshots as an artifact.
