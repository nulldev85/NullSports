# Build artifacts

Both platform workflows keep preview screenshots for three days, review IPAs
for seven days, and shipping-branch IPAs for fourteen days. These limits apply
to new uploads; changing retention does not remove older stored artifacts.

Screenshot uploads are supplementary and may report a warning without blocking
the remaining build steps. Simulator tests, release/bundle checks, tvOS launch
smoke tests, IPA packaging and IPA upload retain their required status. A run
without its required installable IPA upload does not pass.

On October 17, 2026 UTC, tvOS 77 compiled its release app and passed its simulator
suite, then GitHub refused the screenshot upload because artifact storage was
full. The failed upload prevented launch smoke testing and packaging. iPhone
106 passed its simulator suite and hit the same upload error before release
compilation and packaging. These were artifact-storage failures, not failing
app tests. GitHub documents a six-to-twelve-hour storage-usage update window:
https://docs.github.com/en/billing/concepts/product-billing/github-actions

Removing stored archives requires a scoped cleanup; do not delete current
testers' builds or unrelated artifacts to recover space. A cleanup does not by
itself prove that GitHub has recalculated available upload capacity. Do not poll
CI; dispatch a replacement once and inspect it when the user reports its result.
