# iPhone refresh workload and live tennis recovery

Testers reported a refresh sitting at 99%, missing live tennis, and severe phone
slowdown. Source review and reproducible model tests found related app defects:

- Matching progress counted the primary-channel pass, then held that percentage
  during a second alternative-channel pass. That pass rebuilt normalized guide
  and channel facts the first pass already held.
- Any changed event could invalidate the completed slate as a whole. Tennis
  tournament cards also included the next court's start and round in their saved
  identity. Changing either could hide continuing tournament coverage.
- Combined-catalog signatures included match revisions and readiness flags.
  Updating only match results could recreate all display channels, guide maps
  and the saved ID registry on the UI actor.
- Score refreshes chained complete snapshot writes. Slow writes could retain a
  backlog, and each saved event copied its channels' whole guide day into JSON.
- Disposable matching/index work had no iPhone background-suspension policy.

Matching now joins a single worker and combines follow-up requests. Both scoring
and alternatives count toward progress; alternatives reuse prepared facts.
Publication keeps only results whose own event identity still agrees, retaining
unaffected results when another court/game changes. Provider/index generation
checks still reject superseded source data. Daily preparation uses fresh local
data without causing another full provider download.

Tournament identity follows the tournament, tour and location. A previous exact
saved tournament proof upgrades locally without renewing its timestamp or program
expiry. Individual-player matching, archive exclusions, current-program evidence,
alternative ranking, account isolation and direct saved playback remain in place.
The app does not infer a particular match merely from a Tennis Channel name.

Combined catalog construction and registry encoding run off the UI actor. Only
actual catalog revisions change its display maps; concurrent callers share a
build and cannot publish an obsolete provider subset. Maps and matching state
install before awaiting registry persistence. Snapshot writing retains one active
write plus the newest pending value per account. New evidence stores the relevant
program, while the provider's complete guide remains available for TV Guide.
Existing snapshot evidence is compacted off the UI actor on read and write too.
Backgrounding cancels disposable iPhone preparation without withdrawing saved
playback or changing video/PiP policy.

The shared queue and reconciliation policies retain TV behavior; its regression
tests use aliases to the same implementation. TV Settings and Sports presentation
are unchanged. Shared snapshot/evidence and tennis corrections apply to both apps.

Validation:

- `Tools/check-tv-sports-refresh.py --phone` compiles real Foundation models,
  shared work policies, the combined-catalog builder, and extracted pure scoring
  methods. Eleven XCTest cases cover coalescing/reset, retirement/alternatives,
  cache upgrade/expiry, unrelated event changes, compact evidence, bounded writes,
  stable scoped provider IDs, and cached scoring equivalence.
- Replaying the released tennis identity policy fails the continuing-coverage
  regression; the corrected policy passes. `--identity-from` is a test-only
  replay option and is not used by normal CI.
- Thirty-three repository checks, fifteen existing snapshot checks, platform
  syntax parsing and TV focus checks run locally. The iPhone workflow runs the
  new Foundation preflight before its normal SDK suites. A native regression
  checks background suspension preserves prepared playback.

Full Apple SDK and tester-device validation require the review builds. These are
confirmed code paths and model reproductions, not an on-device CPU/memory trace
of the tester's particular phone or a capture of that provider's live pictures.

Release-note draft: Background refreshes do less repeated matching and catalog
work, save smaller snapshots, and stop disposable preparation when you leave the
iPhone app. Refresh progress includes alternative-feed preparation. Live tennis
tournament coverage stays available as courts and rounds change.

## Broader responsiveness follow-up

The later audit also addresses iPhone Guide filtering, Library launch/cache
work, Settings metadata/diagnostics redraws, and game-selection allocations,
then adds the four requested domestic soccer cups. See
[Responsiveness audit and domestic soccer cups](responsiveness-and-soccer-cups.md)
for the additional changes, local results and pending native/device checks.
The earlier successful iPhone976/TV716 builds cover the initial refresh repair
only; they are not validation of that follow-up.
