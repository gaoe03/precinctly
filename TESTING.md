# Regression checks

Install Python 3.12 or newer, then install the test dependencies in a local environment:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install -r requirements-test.txt
.venv/bin/python scripts/test.py --portable
```

Portable checks cover repository hygiene, the scanner's failure cases, and every pipeline test
named either `test_*.py` or `*_test.py`. GitHub Actions runs these checks for pushes and pull
requests. This does not test the iOS app or validate a shipping database.

## Full local check

Use macOS with Xcode, an installed iOS Simulator runtime, and XcodeGen. The full local bundled
database must already exist at `PrecinctWeather/PrecinctKit/Resources/nyc_precincts.sqlite`.
It is intentionally absent from a public clone. The root SQLite file is stale and is never used
by this command. Missing tools or data fail the full check.

```sh
.venv/bin/python scripts/test.py
```

The command creates a disposable iPhone simulator, regenerates the Xcode project, runs Swift
and UI tests serially, and builds the app in Release with the widget embedded. It checks that
the Release app contains the exact database tested. Logs and `.xcresult` bundles stay in the
printed temporary directory. Only the simulator created by the command is deleted afterward.
No source database is rebuilt or patched. Allow roughly ten minutes on the first run.

Use `--output /absolute/new/directory` to keep evidence somewhere specific. Use
`--simulator UUID` only for an existing simulator dedicated to testing. The tests change the
installed app's preferences, authorization and simulated location. A fresh simulator avoids
stale system permission dialogs. The runner never erases an existing simulator.

## Core flows

| Flow | Automated coverage | Manual check |
| --- | --- | --- |
| First launch | Intro precedes location prompt, decline still permits exploration, returning launch skips intro | VoiceOver order and largest text size |
| Location | Movement, manual exploration and Locate regression | Walk across a boundary, return from background, disable Precise Location |
| Map and coverage | All state DB lookups, DMV taps, repeated area switches | Dense polygons and gesture feel on iPhone |
| Search | Popular places, dismissal, exact selection, stale request rejection, Midway City live search | No network, reconnect, cancel while resolving |
| Profile | Comparison labels and data, election-null demographics, ungrouped year footer, maximum text size section access and clipping audits | Long names and VoiceOver |
| Rankings | Exact row navigation, every capped income tie, county and region scopes, maximum text size value frames | Screen reader reading order |
| Share | Render completes, copy confirms, system share sheet opens, null-election card, maximum text size, light/dark/Auto appearance, opaque PNG edge pixels | Photos allow and deny, offline map fallback |
| Settings | Default area and appearance persist through cold launch | Auto appearance after a system theme change |
| Widget | Build, DB concurrent reads, location accuracy and age policy | Home small/medium/large and Lock Screen, movement refresh, denied/outside coverage |
| Data | SQLite integrity, all geometry decodes, hole-aware raster fixtures, supported scopes, nulls, CVAP bounds, selected-election political baselines | Source version and methodology review before replacement |

The Midway City UI case uses Apple Maps and requires network access. A network failure is a
failed run with logs to diagnose, not a silently skipped success. WidgetKit presentation and
refresh need a physical iPhone. Simulator test results do not replace those checks.

Before a feature change, run the relevant flow against the current app. Add a test that fails
for the reproduced defect, make the smallest fix, and rerun that flow and the full suite.
Limit a fix cycle to three passes, then record remaining failures and their evidence.

Visual UI tests retain screenshots in the result bundle. They cover light and dark Settings
and data notes, maximum text size profiles, share actions, rankings, and a real polygon with
an interior hole. Pixel assertions exercise the same hole-aware path used by share rendering.
Export tests render the real card, write its PNG and check opacity, complete map edges, correct
light/dark stock and equal dimensions. The UI tests change system appearance with a preview
open and confirm that the card updates before Copy becomes available. Auto appearance also
checks the return to light and a cold launch in dark mode. Run this on the disposable iPhone selected by the full runner as well as a newer simulator
when investigating failures. The runner provides a loopback-only appearance endpoint to the UI test process and applies
light/dark through simctl using the exact target UUID. XCTest device appearance assignment
can report success while the target scene remains light. Run Auto tests through scripts/test.py
so missing infrastructure fails explicitly instead of silently checking an unchanged theme.
Whole-screen clipping audits run at stable views. Scrolled rankings check the actual value
frames because an audit can flag adjacent rows that are partially outside the viewport.

## Data updates

Build into a fresh output path. The base builder defaults to `p2024` and requires `--out`.
Lean-region rebuilding fails and rolls back on missing, corrupt, invalid or collapsed geometry.
It verifies that every input scope and lean group survives the replacement.

The shared data contract caps CVAP at VAP only when both are known. Derived turnout keeps its
existing denominator and validity rules. Political baselines sum raw two-party votes from each
precinct's selected presidential year, including mixed-year coverage. Demographic weighting is
separate and must not change during a political-only repair.

`pipeline/migrate_data_contract.py` creates a disposable candidate from a hash-verified,
read-only source. Supply `--source`, `--output`, `--report` and `--expected-sha256`. The output
and report must be new paths. Review its complete old/new cell ledger before replacing a local
bundle. The tool verifies unchanged schema, row counts and other cells, plus idempotency.
Use `--recompute-turnout` as a separate pass to repair derived turnout against stored votes
and CVAP while allowing no other cell changes. Preserve a backup before replacing the bundle.

## Before a commit or push

```sh
python3 scripts/check_repository.py
git diff --check
git diff --cached --stat
git diff --cached
git log origin/main..HEAD --format=full
```

The scanner checks tracked and nonignored candidate files plus local commit messages. It rejects
private databases, generated directories, working notes, attribution and high-confidence
credential patterns without printing credential values. It is a guard, not a complete secret
detector. Review the actual staged diff, especially if staging only part of a file. `--base REF`
limits message checks to `REF..HEAD`. It reads local refs and does not fetch remote state.

Never attach the bundled database, private source data, screenshots containing private context,
or local build archives to public CI artifacts. Historical Phase 2B/3 verifiers preserve their
original frozen snapshots. They are not the current full-product regression command.
