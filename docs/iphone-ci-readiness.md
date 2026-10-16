# iPhone CI readiness

The official main run 38864902126 compiled, then failed two simulator checks:
the MPEG-2 software fixture did not reach rendered/playing state within 30
seconds, and the 30,000-channel picker did not publish its filtered page within
five seconds. Both then reported an unexpected `InvalidTransition` while failing.
The navigation regression passed. The reviewed run 38861376875 passed these
same checks, all remaining tests and IPA packaging with an identical source tree
(`git diff 2dcc474 01a8b72` is empty). A successful review run does not guarantee
that a later simulator execution will succeed.

The previous workflow selected an existing iPhone UUID and let xcodebuild start
it as part of testing. Each run now selects an available iPhone model/runtime,
creates its own empty simulator, explicitly boots it and waits for `simctl
bootstatus -b` before executing tests. An EXIT trap shuts down and deletes only
that newly created simulator, on success or failure. Existing runner devices
are never erased or removed. Selection is covered by offline Python checks;
the shell step can be syntax-checked separately from Xcode.

The affected tests now await production publications through bounded XCTest
expectations. Playback still requires AetherEngine, a real rendered picture,
playing state and loading complete within the original 30 seconds, then verifies
resume, seeking, subtitles and metadata. The picker still drives the native
editing/Clear targets and requires the newest completed page within five seconds,
then checks actual table rows, editor retention, bounded cell construction and
last-row selection. Missing readiness still fails; a guard after an already
recorded failure avoids continuing into invalid prerequisites.

No test is excluded, no deadline is increased, and failed tests are not
automatically retried. Playback/search production code is unchanged. These
changes isolate simulator state and improve async observation; only a completed
Apple SDK run can confirm their outcome. A failed playback wait also attaches
engine, phase, loading, playing, picture and error state for diagnosis.

The failed run spent another 600 seconds collecting simulator diagnostics after
tests ended. Release build and IPA packaging were skipped as a consequence.
Do not diagnose that packaging omission or diagnostic timeout as the first
failure, and do not poll CI. Inspect the completed run when a result is reported.
