# Delivery state

Current direction: minimalist Apple-style controls and direct functional labels on iPhone and Mac, with light/dark appearance. Finish comparative phone validation before selecting a model profile. Keep Mac Control–Space available throughout. Model evidence lives in `docs/MODEL_RESEARCH.md`.

Implemented:

- Native SwiftUI app: real microphone conversion/capture, editable transcripts with Copy/Share, local history/dictionary, model selection/download, performance/WER screens and System/Light/Dark appearance.
- UIKit typing keyboard with semantic light/dark colors, finite app-owned microphone sessions, shared-container commands and conservative result insertion.
- Pinned FluidAudio 0.17.5 with CPU/Neural Engine configuration, verified offline local loading and integrity manifests for Phonon-2 default/g4/g1, Ultra and Redux. Model-specific engines remain replaceable.
- Debug-only real-audio benchmark runner, protected checkpoint reports, resource sampling and lifecycle validation. New schema 2 pauses setup between operations while inactive and invalidates interrupted timing.
- Mac minimalist renderer/settings redesign and signed candidate in the desktop checkout under `out/ui-minimal-dark-20261004/`. Mac appearance follows the system.
- GitHub source destinations: `bobjoemama/LocalScribeiOS` and `bobjoemama/LocalScribe`. Devesh approved committing/pushing both projects; binary releases and App Store publication are separate.

Verified on 4 October 2026:

- Eleven Swift core tests, 45 keyboard-protocol checks, pinned-model integrity/tamper checks and eleven keyboard storage-failure checks pass. Missing optional keyboard configuration no longer blocks ordinary dictation at startup.
- Latest simulator and signed optimized-Debug iPhone builds pass. The public project omits personal signing-team defaults; the final signed rebuild passes with the team supplied locally. App and embedded keyboard signatures and shared App Group entitlements pass. Latest minimalist build installed on the connected iPhone without bringing it forward.
- Eight actual simulator screenshots cover Dictate, History, Models and Settings in light/dark; key screens visually inspected with no startup alert. Screenshots show actual empty local state, not a speech-recognition demonstration.
- Additional Apple Development certificate created on this Mac; the existing September certificate was not revoked. Both targets and App Group provisioned using the approved developer team.
- Real default Phonon-2 recognition on the iPhone: one 5.855-second human speech fixture, zero errors across 17 reference words, preliminary warm median 70.9 ms, approximately 411 MB process footprint and 1.089 GB preparation peak. See `docs/benchmarks/phonon2-initial.json`. Schema 1 did not record lifecycle interruptions; timing requires a controlled rerun.
- Physical shared-container read/write and backup-exclusion check passed. This does not verify host-app keyboard insertion.
- Mac typecheck/lint, 102 UI tests, 152 packaging tests, eight layout scenarios per appearance, live appearance switching and contrast checks pass. Isolated Mac preview permission/history/model data are mocks.
- Signed Mac candidate passes bundle, helper, identity and resource checks; designated requirement matches the installed app. Installed binary/archive/configuration and protected hotkey/runtime/storage source fingerprints unchanged. A fresh rebuild subsequently replaced the installed app after explicit authorization. Only LocalScribe restarted; macOS did not. Installed signature/archive checks and startup/hold/toggle registration passed; the saved toggle remains Control–Space. The old installed bundle was deleted after verification, with user data/model directories untouched. This update has not been newly notarized; physical microphone-to-target dictation is not claimed by these startup checks.

Remaining:

- Phone availability answer is pending. Do not foreground LocalScribe or restart benchmarks until Devesh confirms the phone is available. The schema-1 variant report is partial, with g4 stopped at loading after foreground was lost; no g4/g1 result or encoder winner is claimed.
- Run schema-2 default/g4/g1 comparisons and broader dictation recordings; compare WER, load/inference latency, file allocation, RAM/CPU and sustained thermal behavior. GPU/Neural Engine execution placement, energy and system-wide memory pressure remain unmeasured because Instruments could not attach to the phone process.
- Verify offline cold launch, actual microphone permission/capture, keyboard Full Access and foreground/background/lock/result handoff on the phone. System permission and keyboard enabling may require Devesh's interaction.


The failed `/tmp/localscribe-ui-preview` launch came from an incomplete temporary Electron preview. Those launch attempts were stopped; later Mac previews use the validated isolated layout harness. No installed-app restart was used to obtain previews. Git publication is authorized; generated builds, signing material and model caches remain outside source control.
