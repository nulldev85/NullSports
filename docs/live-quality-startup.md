# Live quality verification and refresh presentation

Automatic event playback still verifies source dimensions/frame rate before
choosing a channel and retains the exact measured URL. Manual/team choices,
strict event matching, playback-engine selection and player format badges keep
their existing behavior.

Previously a request could queue behind another full scan and then spend up to
30 seconds checking every channel's HLS/TS URLs sequentially. The queue wait was
outside that budget. Candidate-wide caching also repeated previously measured
URLs after incomplete work.

Discovery and quality verification now share a four-second monotonic budget.
New requests cancel superseded scans; the next socket waits for the old probe's
actual teardown, and that wait consumes the new budget. Ordinary URLs get at most
1.25 seconds or the remaining time. iOS can give a selected higher-quality HLS
alternate up to two seconds within the same overall deadline. The pinned Aether 7.36 controlled probe
interrupts its reader and closes native resources before returning; no detached
timeout race leaves a probe open while playback starts.

The verifier reads every cached candidate first, then compares relevant channels
before alternate transports, trying direct TS before HLS where both exist.
Both transports remain eligible and playback receives the winning URL's original
index. On iOS a measured TS shortfall prioritizes that channel's unmeasured
alternate before spending the deadline on other TS copies. Provider labels are
scheduling hints; dimensions still come only from the probe. Duplicate
event/source URLs are measured once per request. Individual
results survive partial scans and relaunch: positive samples last ten minutes,
failures thirty seconds. Unknown/unvisited URLs are never recorded as low quality
or failures. Existing candidate-cache records remain readable. Preferred-language
policy stays ahead of quality; lower-priority language probes cannot improve an
already verified preferred-language result and are skipped.

At the deadline, choose the best valid measurement already available, otherwise
retain the existing strictly matched fallback. This bounds verification work; it
does not promise that every origin can be measured in time, or that provider
buffering/first-frame time itself is four seconds. The user's private feeds have
not been timed directly. Format badges continue to describe actual playback.

Complete event-channel discovery is reused in memory for up to fifteen seconds,
scoped to the provider, index generation and event identity, expiring sooner at
program/event boundaries. Deadline-truncated discovery is never cached for the
full Channels menu. Selection still revalidates the chosen channel immediately.

On iPhone, Refreshing Data retains one constant-height progress bar across all
phases. Unknown work holds its last measured position; completed phases advance
fixed work shares. The bar does not switch into a separate spinner row, reset
on a new matching pass, or advance from an elapsed-time estimate. Current-task
identity, failures, cancellation and completion rules remain enabled.

Regression coverage includes queue cancellation and non-overlap, one shared
deadline, fair URL order, duplicate reuse, partial-cache relaunch, cached fallback
after budget exhaustion, language priority, full Channels menu discovery, stable
refresh geometry and a real localhost origin that never returns HTTP headers.
Existing decoder/playback and tracking tests remain enabled. SDK tests and device
timing are validation steps; Windows-only static checks do not establish them.

The iOS follow-up and measured startup bottlenecks are documented in
[ios-startup-matching.md](ios-startup-matching.md).
