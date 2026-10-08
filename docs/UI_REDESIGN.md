# LocalScribe UI redesign

Implementation record for the user-supplied Fable brief, checked against the working source on 7 October 2026. The iPhone targets are 0.7.0/build 10. The Mac changes are in the separate [desktop repository](https://github.com/bobjoemama/LocalScribe).

The redesign is implemented in source. Final native build, signing, publication and installation status belong in [tasklist.md](../tasklist.md). LocalScribe 0.7.0/build 10 was installed wirelessly through Device Hub; its Apps panel confirmed 0.7.0 after completion. Mac 0.1.0-dev.21 and Metrics companion 1.1/build 2 are installed with preserved identities and original logos. No physical phone recording or keyboard test was performed. Earlier model measurements are not measurements of this redesign.

## Design and preserved behavior

Both apps use warm paper/ink neutrals, a restrained monochrome accent and a separate recording color. iPhone colors live in [AppTheme.swift](../LocalScribeApp/AppTheme.swift) and its named light/dark assets; Mac colors live in `src/renderer/workspace-theme.css`. Those files are the palette source of truth. The light recording fill was adjusted from the brief to `#D3352A` for a white label; the dark fill uses `#FF5F52` with a dark label. Native green switches remain green. Typography uses system text styles, semantic text colors and tabular timers/readouts.

App identities, App Group, Keychain/encrypted stores, permissions, model files and runtime adapters are preserved. The redesign adds no dependency, model, cloud service, account, analytics or subscription. It does not reset personal data or activate the microphone for visual previews.

Mac window close/⌘W hides the window; Quit/⌘Q ends app-owned capture, workers and models. Control–Space and saved shortcuts remain registered by the existing main-process path. The installed Mac app was not restarted during implementation. iPhone backgrounding is distinct from force quit: Keep model loaded retains the last-used runtime when enabled, while microphone lifetime follows explicit recording/keyboard-session ownership. iOS can still reclaim memory or terminate an app.

## iPhone coverage

The existing four tabs and deep links are retained, with Models added as the fifth tab. Main views were extracted from the former root-view file into separate components; this changes code ownership, not storage or navigation destinations.

| Surface | Implemented behavior and source |
| --- | --- |
| Shell | Dictate, History, Library, Settings and Models; shared appearance, model/recovery/note sheets and global error alert. `LocalScribeRootView.swift`. |
| Dictate | One transcript workspace, direct model chip, accurate mode/loaded caption, editable result, Save as note and keyboard Done. Preparing and recording retain Stop; finishing retains Discard. Copy feedback, Share, keyboard-session End and denied-microphone Open Settings remain available. `DictateView.swift`. |
| Live transcript | Older text dims, the recent tail stays prominent, automatic following detaches while reviewing older text, and Latest restores following. A 24-sample microphone-level waveform has a Reduce Motion alternative. `DictateView.swift`, `DictationTranscriptTail.swift`. |
| Models | Streaming/Periodic text groups; manifest-derived sizes and remaining bulk size; selected/installed/loaded distinctions; per-row progress, cancellation and failure Retry. Selected-model Load/Continue in Background and cancellation controls join CPU preparation. Rows/details expose latest persistent measured load time, whole-app sampled peak RAM, real phase progress, execution configuration, device/OS/date and credits; absent load/RAM measurements and installed disk size say Not measured. `ModelViews.swift`. |
| History | Search, Today/Yesterday/date groups, three-line transcript rows, model/duration metadata, context actions, swipes, export, clear/delete confirmations and unreadable-data recovery. Transcript editor retains Save/Cancel/discard and Copy/Share, with date/model metadata and keyboard Done. Usage is reachable from History actions and Settings. `HistoryViews.swift`. |
| Library | Dictionary, Snippets and Notes with counts from loaded collections. `LibraryView.swift`. |
| Dictionary and Snippets | Search, enabled state, literal phrase/output rows, Add/Edit/Delete, retained drafts/validation/discard confirmations and recovery links. Editors use Say/Replace with or Say/Insert; error text identifies unavailable storage while preserving the existing coupled write policy. `PersonalizationViews.swift`. |
| Notes | Search, matching date headings, title/preview/time rows, create, copy/share/delete and autosave recovery. Editor shows model/save status and an owned Dictate/Stop action. The existing separate live-tail block is retained because TextEditor does not support the requested non-editable attributed suffix. `NotesView.swift`. |
| Settings | Dictation, History, Keyboard, Action Button, Appearance and Performance groups, followed by Saved data and About. The Action Button model label follows Dictate; appearance is segmented, and Accuracy has its own link. `SettingsView.swift`. |
| Action Button setup | Same selected model as Dictate, ready CPU runtime required before audio capture, open-app/wait-for-Ready recovery for cold background invocation, setup instructions, Shortcuts link, required Live Activity and explicit foreground fallback when iOS declines microphone activation. No zero-switch claim is made. `SettingsView.swift`, `DictationShortcuts.swift`. |
| Keyboard setup | Add keyboard, Full Access, explicit app microphone session and idle-timeout instructions. The keyboard cannot acquire a microphone independently. `SettingsView.swift`. |
| Keyboard extension | Meaningful status/primary/secondary controls, themed keys and recording Stop/Cancel; Insert/Copy, stale-result protection, lease expiry, letter/number/symbol layouts, shift, delete-repeat, globe, space and return remain. Setup/failure copy names LocalScribe consistently. `KeyboardViewController.swift`. |
| Performance | Plain always-visible CPU/memory/headroom strip; detail charts, launch peak, pressure events, per-core CPU, VM pages, thermal state, Low Power Mode and requested processor configuration. Preparing/recording retain Stop. `LivePerformanceView.swift`. |
| Developer profiling | Optional Mac connection with colored status, code copy and disconnect; GPU values render only when supplied. Instruments JSON import, active time/duty cycle, removal and import-error feedback remain. `LivePerformanceView.swift`. |
| Accuracy | Reference/raw-text WER evaluation and completed-operation measurements retain their fields and calculation rules. Model-residency explanation now matches Keep model loaded. `PerformanceView.swift`. |
| Saved data | Retry, per-collection availability, confirmed reset, protected recovery copies and export; reset conditions/confirmation behavior are preserved. `SavedDataView.swift`. |
| About and legal text | Existing model/runtime/source credits, dependency licenses and third-party notices, plus bundled Phonon license/attribution and LocalScribe notices. Legal documents use the same appearance. `AboutView.swift`, `Resources/legal`. |
| Dynamic Island/Live Activity | Compact/minimal/expanded and Lock Screen layouts; timer, processing, completed result, cancellation and short failure reason. Expanded view names the model; privacy-sensitive live text appears for Realtime/Moonshine, while windowed models show model/timer/status only. Lock Screen remains transcript-free. Cancelled is distinct from failure and dismisses after four seconds; completion/failure retain ten seconds. `SharedActivity`, `DictationLiveActivity.swift`, `LocalScribeActivityWidget.swift`. |
| Debug tools | Existing benchmarks/verifier remain DEBUG-only. `DesignPreview.swift` adds explicitly synthetic, inert simulator-only screenshots and is excluded from physical-device/Release builds. |

Notes cancellation now rejects ownership after a canceled pending start. A late permission return cannot claim/cancel a newer Action Button recording or append unrelated text to a note. The focused check exercises the production session and actual controllers with the established audio/engine fixtures.

## Mac coverage

Paths below are relative to the desktop repository. Changes are source implementation, not a claim that the installed Mac app has been replaced.

| Surface | Implemented behavior and source |
| --- | --- |
| Shell | Text sidebar: Dictation, Insights, Notes, Dictionary, Snippets, Cleanup, Models and Settings. Content framing is removed. ⌘1–⌘7 and ⌘, are supported; model-operation navigation guards remain. Legacy Style/Transforms navigation resolves to Cleanup. `src/renderer/settings/SettingsApp.tsx`. |
| Dictation history | Compact saved-shortcut/model status, direct Models navigation, search, export, overflow, date groups, transcript rows, Copy/Delete and recovery warnings. The duplicated Today/Summary panel is removed. `HistoryInsights.tsx`. |
| Insights | Existing period controls, measured totals, word chart, app categories and frequent words remain. Writing measurements are incorporated without the personality-style headline. `HistoryInsights.tsx`. |
| Dictionary/Snippets | Search/count, phrase/output rows, Add/Edit/Delete, validation, failed-save drafts and unreadable recovery remain. Editors add unsaved-discard confirmation. Replacement rules remain dictionary terms; Cleanup links to the existing dictionary rather than creating another store. `LibraryNotes.tsx`, `StyleSettings.tsx`. |
| Notes window | Public labels use Notes while the existing scratchpad identity/store/API remain. Search, new/delete/expand/close, autosave/flush, failure recovery, word count and Copy remain; editor uses system typography and Escape hides the window. `src/renderer/scratchpad`. |
| Cleanup | Existing deterministic None/Light/Medium settings, Custom status for nonmatching combinations, immediate filler/command/punctuation changes and app profiles. Profile deletion is confirmed. Disabled model-backed controls are removed. `StyleSettings.tsx`. |
| Models | Dedicated destination retains selection/apply, Live/After I stop, quality, reported memory, catalog/profile sorting, Download/Repair/Remove/Check, bulk Stop after current, progress and technical/source disclosures. Precision labels are readable. Selection/application/dismissal guards remain. `ModelPerformanceSettings.tsx`, `StyleSettings.tsx`. |
| Settings | General/System/Data & Privacy retain shortcut recording, microphone/languages/permissions, login startup, floating bar, automatic paste, history/retention, recovery/export and diagnostics. Appearance adds System/Light/Dark persistence across main, Notes and pill windows; native window backgrounds follow it. Data paths are actionable controls rather than permanently displayed absolute paths. `StyleSettings.tsx`, `src/shared/contracts.ts`, `src/main.ts`. |
| Floating bar | Existing non-focusable black capsule, microphone menu, idle/hover/listening/live/status/error actions and session ownership remain. Adds a recording dot and main-process-derived elapsed timer; live text separates recent/older words and provides Latest. Reduce Motion is preserved. `src/renderer/pill/Pill.tsx`, `src/shared/pillLayout.ts`. |
| Menu bar/app menu | Brand template image replaces the text-only tray mark; navigation/public labels use Notes, Cleanup and Models. Start/Stop, Open and Quit actions remain; window hiding is preserved. `src/main/trayBrand.ts`, `src/main.ts`. |
| Dialogs/errors | Themed editors/popovers, focus/keyboard behavior, native export/reset/confirmation boundaries and failed-operation feedback remain. No new notification service is added. |
| Metrics companion | Live USB and Trace report tabs retain their functions. Adds safe actionable collector-error feedback, consistent connection-code labels, device serial suffixes when supplied, warm appearance and status colors. Arbitrary stderr/paths/secrets are not surfaced. `Tools/MetricsCompanionUI/MetricsCompanion.swift` in the iPhone repository. |

## Exact additions and removals

ADD — iPhone: semantic light/dark assets; single styled live workspace with recent-text emphasis and Latest; measured-level waveform; model-mode/capability captions and grouped catalog presentation and dedicated Models tab with measured loading reports/background-preparation controls; inline microphone-denied recovery; Action Button selected-model label and Accuracy settings; Library counts and History Usage entry; cancelled Live Activity phase/short failure reason; Notes preparation Stop and canceled-start ownership protection; missing bundled legal links; simulator-only design fixtures.

REMOVE — iPhone: duplicate live-preview card, Dictate's repeated audio-privacy caption, model sheet's duplicated global error text. The privacy explanation remains in Settings. Transcription, model, history, library, keyboard, telemetry and recovery capabilities are retained.

ADD — Mac: Appearance preference and native-theme application; dedicated Models destination; consolidated Cleanup destination; destination/search shortcuts; dictionary/snippet discard confirmation and profile-delete confirmation; pill timer/recording dot/recent-text emphasis/Latest; branded tray image; readable precision labels; safe Metrics collector diagnostics and device suffix labels.

REMOVE — Mac: bordered dashboard content frame; Dictation's duplicate Today/Summary panel; voice-profile personality headline; separate Style/Transforms navigation and Writing/Model/Experimental modal tabs; disabled tone cards, Concise rewrite, Experimental switches, and Notes rewrite/formatting tools. Active deterministic cleanup, models and app profiles move to their named destinations; legacy navigation remains compatible. None of these removals deletes stored data.

## Deliberate adjustments and deferrals

- The brief called the absence of Mac paste-consumption confirmation a bug. The native helper posts CGEvent; that does not prove the target consumed the clipboard. The implementation preserves the dictated backup after an unconfirmed paste instead of claiming insertion or restoring the clipboard prematurely. Existing target/session/clipboard checks remain. This is a correction to the brief, not an unimplemented promise of reliable host acknowledgment.
- Mac per-file cancellation is not exposed: the existing worker IPC has no single-file abort operation. Bulk installation retains Stop after current. iPhone cancellation uses its existing download task; installed models are retained.
- Optional keyboard recording timer/protocol expansion and draggable pill snapping are deferred. Existing keyboard session timing and pill positioning remain.
- Notes retains the separate live tail; it appends only the owned final result to the note.
- Dynamic Island expansion is system-managed. Action Button cold/background activation and actual background clipboard delivery remain user-operated physical checks. Foreground Dictate is the supported fallback when iOS declines activation.
- Full Wispr parity is not claimed. Model-backed transforms, cloud/team/account services, automatic learning, failed-audio replay and host-context Undo remain outside this local scope; see [IOS_FEATURE_PARITY.md](IOS_FEATURE_PARITY.md).

## Mode and measurement truth

| Platform/path | UI meaning |
| --- | --- |
| iPhone Realtime and Moonshine | Streaming with cached state; CPU runtimes support background inference. This does not grant background microphone permission. |
| iPhone Phonon/Ultra/Redux profiles | Windowed recognition: first in-app preview after five seconds of captured audio, then three-second processing cadence; Island shows model/timer/status only. Model loading can delay delivered text. |
| iPhone LUT3 | Keep model loaded On prewarms CPU-only for all components. With it Off, cold ordinary Dictate requests CPU/GPU encoder and CPU/Neural Engine for other components; Action Button requires the same profile ready on CPU. Requested configuration is not measured occupancy. |
| Other iPhone Core ML windowed profiles | Keep model loaded On prewarms CPU-only for all components. With it Off, cold ordinary Dictate requests CPU/Neural Engine; Action Button requires the same profile ready on CPU. CPU phone performance remains unmeasured. |
| Mac Parakeet Unified, Phonon 2, Moonshine | Live and After I stop capability, with actual configured runtime/profile shown. |
| Other Mac families | After I stop; no universal streaming claim. |
| Model load statistics | Latest persisted measured loading report, including pauses and whole-app sampled peak RAM (possibly including the previous runtime); no model-only allocation, estimated RAM requirement or installed-disk claim. Missing values say Not measured. |
| Performance | CPU/footprint/headroom are actual process/OS samples. Pressure rows show last delivered events, not inferred initial system pressure. No event does not mean normal pressure. |
| GPU/Neural Engine profiling | GPU counters are device-wide measurements supplied through the optional Mac connection; imported interval duty cycle is active time, not processor-capacity utilization. No GPU/ANE occupied-core count is fabricated. |

## Setup and user-operated checks

1. Choose System/Light/Dark in each app's Settings. On Mac, Save changes applies the preference; all windows follow the saved setting.
2. On iPhone, choose an installed model on Dictate or Models. Keep model loaded defaults On and prewarms the selected CPU runtime; open LocalScribe and wait for Ready before using Action Button from another app. To prepare while switching apps, explicitly tap Load in Background or Continue in Background in the selected model’s controls; automatic prewarming makes no background request. If iOS declines or cancels, return to the app to prepare. Action Button uses that same selection. A ready CPU-only runtime is reused on return to the app and Record; one runtime is retained, with no automatic model substitution. Cold background Action Button use asks you to open the app and wait, before any capture or recording Live Activity. iOS memory reclamation, memory warnings or force quit may require preparation again.
3. Follow [Action Button setup](INSTALLATION.md#action-button) to import and assign the supplied workflow once; existing users keep their assignment. Check [current device-test results](../tasklist.md#current-ios-beta-status); replay at least two consecutive recordings and clipboard deliveries. Also finish with Dynamic Island/widget Stop and invoke the Action Button again: it should return the retained result without starting another microphone session. Last run reports app-intent completion, not native clipboard-action confirmation. Record errors, foreground handoff, model/timer/status and model-appropriate preview behavior; test cold and warm states separately. iOS owns expansion/collapse; prior-session cleanup ordering does not prove the reported two-second gap is repaired.
4. For the keyboard, add LocalScribe in iPhone Settings, grant Full Access, then explicitly enable its microphone session in LocalScribe Settings. Verify host insertion, Copy/Cancel, field/context changes and idle expiry. End the session afterward.
5. Phone-only Performance requires no Mac. Optional GPU profiling uses the existing Mac companion and USB connection code; Instruments import requires an exported report. Clipboard expiry of the copied connection code is two minutes; this is not a claim that the connection token itself expires at that time.
6. Replay personal microphone dictation, interruption, background/lock/return and force quit on the physical phone. Verify capture/resources stop on force quit and that idle residency never starts the microphone. Simulator/fixture checks cannot establish these OS/device outcomes.
7. Verify Mac microphone-to-target delivery and Quit cleanup when a dictation break is available. The implementation session preserves the current installed app and Control–Space; it does not use that active installation as a test harness.

## Verification

Counts below are suite results, not summed into a unique-test total. The fixtures use owned data/processes and do not establish physical microphone or clipboard behavior.

| Completed check | Result |
| --- | --- |
| Swift core | 55 tests |
| AppController lifecycle | 64 checks |
| Production audio-recorder configuration/cleanup | 17 checks |
| Personalization/history/recovery | 31 checks |
| Notes storage/recovery | 14 checks |
| New production NoteDictationSession preparation/ownership | 21 checks; the late canceled-start/new Action Button race failed before the fix and passes afterward |
| Shortcut/bridge/controller | 50 checks |
| Live Activity state/lifecycle | 14 checks |
| Transcript tail | 16 checks, plus eight boundary cases |
| Keyboard protocol | 73 checks |
| Catalog presentation | Nine catalog mappings |
| Mac focused suites | Shell 127, pill 102, history 49, updated UI 34 and platform 43 checks; overlapping suites are not summed |
| Native isolated Mac scenarios | 16 scenarios, 140 actual PNGs/report across light/dark and 1220×760/900×640, including operation guards, apply/failure, editing/focus and appearance persistence |
| Owned iPhone page syntax | Swift frontend parsing and scoped whitespace checks passed |
| Integrated native builds | Optimized signed iPhone and simulator builds passed; all three iPhone targets are 0.7.0/build 10 with strict signatures and preserved intent metadata |
| Mac full source gate | 1,575 tests passed, two existing skips; toolchain/dependency audits, lint and TypeScript passed |
| Cross-platform palette | 80 contrast checks and 48 shared color comparisons passed; reading minimum 4.59:1, graphical boundary minimum 3.32:1 |
| Metrics companion | Process lifecycle/redacted-diagnostic checks, optimized build, strict signature, preserved identity/icon and native installed UI passed |

Current simulator design captures are under [previews/redesign-ios](previews/redesign-ios). Coverage and fixture limits are described in its README. The older October 4 screenshots are historical and do not represent all current screens.

Synthetic simulator captures cover 31 states/pages in each appearance, plus AX3 Dictate/Models/Settings. AX3 exposed metric truncation; the strip now stacks and wraps at accessibility sizes. Form captions and values explicitly use semantic colors. Native Mac fixtures additionally cover Notes/pill interactions. VoiceOver, physical Dynamic Island, Action Button activation/background copy, keyboard host insertion and real microphone routing remain user-operated checks. Fixtures and builds do not establish these device workflows.
