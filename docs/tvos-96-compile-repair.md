# Apple TV 96 build repair

The user reported Apple TV 95 failed while iPhone 147 was still running. Only
the completed TV run was inspected. It failed during Release app compilation
before any SDK tests, packaging or IPA upload:

- Silo retry callbacks referenced `TVPlaybackController.loading`, a phone-only
  property that does not exist on the TV controller.
- The shared MDBList connection form applied `scrollContentBackground` on tvOS,
  where that modifier is unavailable.

TV callbacks now use the existing `reconnecting` state consumed by the player's
status overlay. Failure clears that state and displays the server error; success
uses the normal existing asset-change/start path. While Silo is replanning, the
old decoder's watchdog cannot reopen its obsolete signed URL. Audio/subtitle
choices, pause intent, source timeline, lease handling and manual retry remain.

The form's iOS modifier is platform guarded; its dark background, row styling,
connection/account controls and tracking options remain on both platforms.
No iPhone engine, visual or tracking implementation changes are included.

An added TV regression uses the actual Silo client/session with a fixture HTTP
transport and the existing mock decoder. It starts one plan, retries with the
old decoder failed, checks that monitor ticks cannot reload the old lease, then
rejects the new plan and requires a visible error with reconnecting cleared.
All existing platform tests remain enabled; no exclusions or extended deadlines.
The test and Apple SDK build require CI because Windows has no Swift/Apple SDK.

This repair is on a separate branch from iPhone 147's ref. Pushing it and manually
dispatching only `build-tvos.yml` cannot trigger the phone workflow's same-ref
cancellation rule. iPhone 147 was not queried, restarted or cancelled. Apple TV's
build version is 96; the iPhone override stays 147. No merge is authorized.
