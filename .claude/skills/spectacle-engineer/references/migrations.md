# Schema and migrations

- One schema bump per phase, additive `onUpgrade` blocks, cumulative with the earlier ones.
- SQLite foreign keys are not enabled in this database. Every `REFERENCES` clause is documentation. Cascades and restrictions live in Dart, inside one transaction, with a test asserting the row survives a refusal.
- Selections and defaults are absence of a row, never a backfilled value. A fresh install has no host.
- Migration proof, required whenever the version moves, from `build/baseline/faraday-2026-09-01-release.apk`:
  1. Install the baseline on the emulator, seed it, dump `user_version` and every table to `migration-pre-v<old>.txt`.
  2. Install your release apk over it with `install -r`.
  3. Dump again to `migration-post-v<new>.txt`; every old row intact, new tables present and writable.
  4. One screenshot of the old data alive on Home after the upgrade.
- `migration_test.dart` carries a fixture per historical schema and a test for each jump an installed build can make.
