# LocalScribe iOS development and technical reference

For installation and everyday use, start with the [README](../README.md). This reference preserves runtime behavior, diagnostics, implementation details and explicit developer verification recipes. Current delivery evidence lives in [tasklist.md](../tasklist.md); model measurements remain in [MODEL_RESEARCH.md](MODEL_RESEARCH.md).

Requires iOS 18 or later. The default is Parakeet Realtime through exact-version FluidAudio 0.17.5, configured for CPU-only Core ML streaming. Phonon-2 remains available for formatted dictation. Cold foreground preparation requests CPU + Neural Engine execution except for the LUT3 encoder, which requests CPU/GPU. Recognition loads verified local files; missing models produce an error rather than a network fallback. The nine-profile catalog includes five exact-weight Phonon-2 encoders, Ultra, Redux, Parakeet Realtime EOU and Moonshine Small Streaming through Moonshine Swift 0.1.5. Core ML Action Button preparation requests CPU-only execution for every component of the selected profile, using the same installed files and weights. Moonshine uses its native CPU runtime. Current research, exact sizes, stack alternatives and evidence limits: [model/runtime comparison](MODEL_RESEARCH.md).

Current interface and verification: [October 7 redesign](UI_REDESIGN.md).

## Use

1. Open Models and download a model, or choose Download all. Bulk downloads preserve the selected model; installed files use storage, and only the selected runtime is prepared. Keep the app open during setup. First Core ML preparation may take substantially longer than later cached loads.
2. Choose a downloaded model directly in Dictate, then tap Record and Stop. Capture starts before cold model preparation finishes; Stop remains available. Live text is provisional until the recording finishes. Edit, copy or share the result. Microphone access needs the normal iOS permission.
3. For dictation in another app, add LocalScribe under Settings → General → Keyboard → Keyboards, then enable Allow Full Access. Open LocalScribe and start a keyboard microphone session before switching to another app. The app owns the microphone; Apple's custom keyboard API cannot record audio itself.
4. The keyboard can start/stop utterances while the explicitly armed session remains live. The session ends after five minutes of inactivity; active dictation renews the deadline. Idle audio is discarded. End the session in LocalScribe to stop the microphone. iOS displays its microphone indicator while the session is armed. Secure fields and apps that disallow custom keyboards use the system keyboard.

Phonon-2, Ultra and Redux use overlapping recognition windows; the first update needs five seconds of audio, with a three-second cadence and fifteen seconds of context. The longer context aims to reduce recognition errors at window boundaries; its results are recorded separately. Parakeet Realtime EOU uses cached streaming state and produces English text without punctuation or capitalization. Moonshine uses cached CPU streaming with bounded native segments and updates every half-second of supplied audio. None of these paths limits a recording to two minutes. The microphone queue holds at most two minutes of unprocessed audio; if recognition falls behind that bound, recording stops with an explicit error. Core ML's first device preparation can still be slow. Realtime and Moonshine use CPU runtimes. Core ML profiles use a CPU-only preparation for Action Button background inference; background microphone activation still depends on iOS permission and runtime conditions.

**Settings → Keep model loaded** defaults to On. It preloads the selected Dictate model while the app is active and retains the single last-used runtime across idle time and ordinary app switching. Keeping references does not keep the microphone active or run inference. Turning it Off disables prewarming and releases the runtime when idle; an active dictation finishes before release. Changing models releases the previous runtime.

Dictate and Action Button share this selection and one runtime. A cold foreground load keeps the profile’s accelerator configuration; Action Button prepares that same model for CPU-only background execution. Once that CPU runtime is ready, returning to the app or tapping Record reuses it. An incompatible preparation releases the previous runtime before loading; no second runtime or fallback model is retained. Apple recommends [CPU-only compute units](https://developer.apple.com/documentation/coreml/mlcomputeunits) for apps that may run in the background. The CPU configuration does not change weights or compression; its phone speed, energy and thermal costs remain unmeasured for these paths.

Force quitting LocalScribe terminates its process and releases its microphone/model ownership. Retention cannot prevent iOS from suspending or terminating the app or reclaiming system-managed caches. A real memory warning overrides retention; the next foreground entry or recording prepares the model again. An unfinished foreground warm-up is cancelled on backgrounding so it cannot submit unauthorized GPU/Neural Engine work. See Apple's [app life cycle](https://developer.apple.com/documentation/uikit/managing-your-app-s-life-cycle), [memory-warning response](https://developer.apple.com/documentation/uikit/responding-to-memory-warnings) and [background GPU restrictions](https://developer.apple.com/documentation/metal/preparing-your-metal-app-to-run-in-the-background).

Ordinary typing works without Full Access. Full Access is needed to write local shared-container commands, not to send audio to a service. The keyboard never reads or saves surrounding host text. Automatic insertion is bound to the original document and disarmed when the editing context changes; otherwise use Insert dictation. Results expire after 30 seconds. A delivery receipt prevents replay but a crash between receipt and host insertion can lose automatic delivery; the app retains the transcript.

Word error rate (WER) compares a supplied reference with raw recognition before dictionary corrections, normalizing case and punctuation. Requested Core ML compute units do not establish actual execution placement.

## Live performance

Dictate shows live CPU, app memory and allocation headroom, whether recording or idle. Tap the readout, or open **Settings → Performance**, for recent CPU/memory graphs, peak footprint, CPU core equivalents/count, system CPU per core and VM pages, thermal state and Low Power Mode. These readings work on the phone alone. You can stop an active recording from the performance screen.

Updates run once per second in the foreground and stop when the app becomes inactive. The last 60 samples stay in memory only and reset on return. CPU 100% means one core’s worth of execution, not the entire device. Headroom comes from iOS’s current app allocation allowance; it is not free device RAM. **Memory-pressure alerts** show the last OS event; **No alerts received** does not establish normal pressure. System page categories are separate measurements, not a pressure percentage. Configured processors describe the runtime configuration, not measured processor activity.

Apple's [initial pressure-state query](https://github.com/apple-oss-distributions/xnu/blob/main/bsd/kern/kern_memorystatus_notify.c#L1884) checks `PRIV_VM_PRESSURE` on non-macOS targets. This is source evidence of a privilege requirement, not a measured denial on this phone; the app uses public notifications instead of this privileged query.


Public Mach readings can be denied; failed readings stay unavailable. **Performance → Developer profiling** contains the optional [LocalScribe Metrics companion](../Tools/MetricsCompanionUI/README.md) connection. Connect by USB, select **Enable USB metrics → Copy connection code**, then paste it into the Mac companion and select the USB phone and Start. GPU device/renderer/tiler usage and display FPS come from developer-service counters when supplied. They describe device activity, not LocalScribe-only GPU activity, and appear on the main Performance screen only while a sample is available. Stop, Quit, disconnection or leaving the phone app's foreground ends the session; values expire rather than remaining deceptively live. Occupied GPU cores and live ANE utilization are not exposed to this app; Developer Mode does not grant privileged kernel access.

The companion's **Trace report** tab uses installed Apple Instruments/xctrace to export a selected recording window into a small JSON report. Import it through **Developer profiling → Import Instruments report** for recorded Neural Engine/GPU active time and duty cycle. These are offline, trace-wide measurements; no capacity utilization or occupied-core count is inferred. See [trace processing](../Tools/MetricsTrace/README.md) for supported tables and limits, and [the collector review](../Tools/MetricsCompanion/DEPENDENCY_REVIEW.md) for the restricted connection and package audit.

Completed loading/transcription measurements and word-error-rate comparison remain under **Accuracy**. See Apple’s [app memory allowance](https://developer.apple.com/documentation/os/os_proc_available_memory), [memory-pressure events](https://developer.apple.com/documentation/dispatch/dispatchsourcememorypressure), and [process CPU accounting](https://developer.apple.com/library/archive/documentation/System/Conceptual/ManPages_iPhoneOS/man2/getrusage.2.html).

## Dictionary, snippets and notes

Open **Library → Dictionary → +**. Enter the phrase the model recognizes in **Say**, then the text you want in **Replace with**. For example, `local scape` → `LocalScribe`. Rules match whole phrases without regard to capitalization, prefer longer overlapping phrases, and run once without rewriting replacement text. This changes text after recognition; it does not retrain the speech model. Search, edit, disable or confirm deletion of a rule. A failed save keeps the editor open and preserves the existing library.

In **Library → Snippets**, save a spoken phrase such as `my email signature` and its full expansion. Line breaks, casing and whitespace in the expansion are preserved. A whole-trigger dictation produces the exact expansion, ignoring added trailing sentence punctuation; a trigger inside a longer sentence leaves surrounding text in place. Dictionary and snippet triggers cannot conflict. Personalization applies to live/final text, keyboard delivery and shortcut copying; raw recognition remains separate for WER.

**Library → Notes** supports typing and dictation using the selected model, search, Copy/Share and confirmed deletion. Notes autosave after two seconds and flush when leaving/backgrounding. Only that editor's recording is appended to its note. Save errors retain the pending text for retry. The note title comes from its first line; no model generates it. A completed transcript can also be saved as a note from Dictate's pencil action.

**History** groups transcripts by date, supports safe editing, Copy/Share, confirmed deletion, filtered text export and confirmed Clear all. Settings offers retention of all history, today's calendar day, seven days or thirty days. Retention defaults to Never and requires confirmation before removing older entries. Usage measures only retained history, not lifetime or speech-only timing. Keyboard settings offer an idle timeout of 1, 5, 15 or 30 minutes; active dictation renews it. Recording settings can prefer the built-in microphone and enable start/stop haptics; both are off by default. The keyboard adds Cancel during recording and Copy for a pending result, with receipts preventing later duplicate insertion.

The comparison uses current [official iOS feature evidence](IOS_FEATURE_PARITY.md). It is not a claim of complete Wispr parity: model-backed transformations, cloud/team/account services, fuzzy/automatic learning and unsafe host-context Undo are excluded. Audio is still discarded; failed-recording audio replay is not implemented. Model-specific language support remains visible rather than implying every engine supports every language. The current [native light/dark feature captures](previews/features) use explicit synthetic data in an owned simulator, not personal phone data or real recognition results.

## Privacy and storage

In Settings → Saved data, retry opening files after unlocking, or confirm a reset
of history, dictionary, snippets or notes. Reset preserves a protected recovery
copy of the previous saved file and keeps models and settings. Recovery copies
can be exported from the same screen; they contain saved text. Unreadable library
and history screens link directly to these controls.

No cloud recognition, account, analytics or updater is implemented. Explicit model setup contacts Hugging Face and its download/CDN infrastructure. Audio samples remain in a bounded in-memory buffer and are not saved as audio files. History is optional; turning it off stops saving subsequent transcripts. Existing history remains available. History and dictionary JSON use complete file protection and are excluded from backups. Temporary keyboard state uses protection after first unlock to support app/keyboard handoff and is also excluded from backups. Model directories are excluded from backups. Transcripts can still leave the app through explicit copy/share or insertion into the chosen host app.

Models are pinned to immutable revisions in `Resources/model-integrity.json`, verified against file sizes and publisher SHA-256/Git object hashes before cold loading. Publisher hashes provide integrity relative to the publisher, not independent signed provenance. Core ML may create additional system-managed compiled caches beyond the listed model bytes.

## Build

For device installation, all-target signing and App Group configuration, follow [Installation](INSTALLATION.md). Run the commands below from the repository root.

The project is generated deterministically with Python's standard library:

```sh
python3 scripts/generate_project.py
# To retain a configured development team, add --team=YOUR_TEAM_ID.
xcodebuild -project LocalScribe.xcodeproj -scheme LocalScribe \
  -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=NO build
swift test --jobs 4
swiftc SharedKeyboard/KeyboardProtocol.swift scripts/checks/KeyboardProtocolCheck.swift \
  -o /tmp/localscribe-keyboard-check
/tmp/localscribe-keyboard-check
swiftc LocalScribeApp/ModelIntegrity.swift scripts/checks/ModelIntegrityCheck.swift \
  -o /tmp/localscribe-integrity-check
/tmp/localscribe-integrity-check
swiftc -swift-version 6 SharedKeyboard/KeyboardProtocol.swift \
  LocalScribeApp/KeyboardSessionCoordinator.swift scripts/checks/KeyboardStorageFailureCheck.swift \
  -o /tmp/localscribe-keyboard-storage-check
/tmp/localscribe-keyboard-storage-check
scripts/check_app_controller.sh
scripts/check_action_shortcut.sh
scripts/check_dictation_tail.sh
scripts/check_personalization_controller.sh
```

On this Mac, prefix Xcode commands with `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer`; the global command-line-tools selection is left unchanged. The local Swift package isolates platform-independent correction, storage, capture and WER tests. `--without-fluidaudio` generates a UI-only project whose runtime visibly reports unavailable; it is not a working recognition build.

## Repeatable device inference check

DEBUG builds include a finite benchmark runner, activated only by explicit launch arguments:

```sh
xcrun devicectl device process launch --device YOUR_DEVICE_ID \
  --terminate-existing com.devesh.localscribe.ios \
  --benchmark-models phonon2,phonon2-g4,phonon2-g1 --benchmark-downloads
```

Without `--benchmark-downloads`, missing models fail without networking. Each profile records loading into a fresh runtime, first inference, three warm runs and one second of unload/settling. The bundled 5.855-second LibriSpeech read-speech clip has a pinned hash, reference and CC BY 4.0 attribution in `Resources/benchmark`. Its WER is a smoke check, not a personal-dictation quality score. Reports checkpoint to protected, backup-excluded `Documents/benchmark-*.json`, including raw transcripts, errors, file allocation, RAM, CPU and thermal state. Ordinary controls are disabled and auto-lock is temporarily suppressed during the finite run; microphone remains off. Schema 2 records foreground lifecycle events in the report and a synchronous sidecar. Operations wait for the app to become active; timing is marked invalid if an operation loses focus or enters the background. Interrupted derived timing values are omitted. OS/Core ML caches are not reset. For meaningful speed comparisons compile with `SWIFT_OPTIMIZATION_LEVEL=-O`; the report includes that build setting.

## Implementation

- `Sources/LocalScribeCore`: model interface, bounded audio, protected stores, corrections, WER.
- `LocalScribeApp`: microphone, UI, verified local Core ML adapter and measurements.
- `SharedKeyboard`: atomic command/status/receipt protocol with short leases.
- `LocalScribeKeyboard`: typing and dictation controls, without microphone or network code.
- `Resources/model-integrity.json`: the authoritative nine-profile pinned installation catalog.

The native app follows Apple's containing-app microphone/shared-container pattern, studied against Muesli and platform guidance, with finite explicit sessions and no cloud summarization/sync dependency. Model-specific adapters can implement `LocalTranscriptionEngine`; alternative stacks are researched but not bundled.

See [remaining work and verification](../tasklist.md). The Mac redesign is in the separate [LocalScribe desktop repository](https://github.com/bobjoemama/LocalScribe); its screenshots in `docs/previews/mac` use isolated mocked settings data. [Dictionary light preview](previews/features/ios-light-dictionary.png) and [Snippets dark preview](previews/features/ios-dark-snippets.png) are actual simulator renderings. [Mac dark preview](previews/mac/workspace-dark-1220x760-dictation.png) shows the revised candidate. Both apps offer System/Light/Dark appearance; the linked earlier Mac previews are historical. Preview screenshots do not prove physical-device speech recognition.


## DEBUG microphone and streaming verification

A provisioned DEBUG build can verify the physical microphone and streaming boundaries with explicit launch arguments. Run it when the phone is available: it captures microphone input once for five seconds, counts and discards that PCM through a no-op test engine, and never recognizes or saves personal speech. The normal app controller is disabled during the run. The shared real model subsequently receives only the pinned public LibriSpeech fixture. Models must already be installed; this verifier never downloads them.

For optimized timing, build with the same configured signing team and an explicit optimization setting:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project LocalScribe.xcodeproj -scheme LocalScribe -configuration Debug \
  -destination 'generic/platform=iOS' -derivedDataPath DerivedData \
  SWIFT_OPTIMIZATION_LEVEL=-O build
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl \
  device install app --device YOUR_DEVICE_ID \
  DerivedData/Build/Products/Debug-iphoneos/LocalScribe.app
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl \
  device process launch --device YOUR_DEVICE_ID --terminate-existing \
  com.devesh.localscribe.ios --verify-dictation --verify-models phonon2
```

The hardware check uses the real `AppController` and `AudioRecorder`, with preparation deliberately withheld by a no-op engine. It checks recording, Stop while loading, capture stopping before preparation is released, bounded finalization batches, and return to idle. It uses isolated defaults/history rather than the user's settings or saved transcripts. The recognition checks use the real local engine: the original 5.855-second public clip, then 22 repetitions totaling 128.81 seconds, supplied in sequential batches of at most 32,000 samples. The longer clip is generated batch by batch; no full-length waveform array is created. The report separates empty initialization callbacks from changed nonempty text updates and checks the final short tail.

To compare the optional installed realtime model, use `--verify-models phonon2,eou320`; `parakeet-eou-320ms` is also accepted as its identifier. Requested models run sequentially through the shared engine. The fixture is accelerated rather than paced to speech duration. Its first nonempty-update timing is therefore a processing measurement, not the time a person waits after starting to speak. A passing report confirms the checked workflow and sample boundaries, not a WER quality target or a representative dictation benchmark. Reported caller FIFO/submission bounds do not measure backend internal retained audio.

Reports checkpoint to protected, backup-excluded `Documents/dictation-verification-*.json`. They include hardware sample counts only, public-fixture transcripts/WER, live update counts, load/session resources, build optimization, initial Low Power Mode, and foreground timing validity. Whole-process physical footprint is sampled every 50 ms and can miss spikes; CPU time excludes external compiler services. GPU/Neural Engine utilization, energy and system-wide pressure are not measured. Check thermal states before interpreting timing. Operations wait for the app to become active, and interrupted timing is marked invalid. Auto-lock is suppressed only during the finite developer run and restored afterward.

Inspect and retrieve the report without opening private history files:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl \
  device info files --device YOUR_DEVICE_ID --domain-type appDataContainer \
  --domain-identifier com.devesh.localscribe.ios --subdirectory Documents \
  --search dictation-verification
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl \
  device copy from --device YOUR_DEVICE_ID --domain-type appDataContainer \
  --domain-identifier com.devesh.localscribe.ios \
  --source Documents/REPORT_FILENAME.json --destination /tmp/localscribe-verification.json
```

After the developer run, relaunch normally to restore ordinary dictation controls:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl \
  device process launch --device YOUR_DEVICE_ID --terminate-existing \
  com.devesh.localscribe.ios
```

The verifier now also retains the 22-repeat baseline and runs two seam variants: a 0.75-second silence prefix (129.56 seconds total), and the same prefix with alternating 0.3/0.8-second gaps between repetitions (140.86 seconds total). Each variant still has exactly 374 reference words. Reports record the variant identifier, prefix/gap durations and reference count; WER normalization is unchanged. Preparation reports include time spent releasing the previous model, checking installation, verifying integrity, loading Core ML and initializing the recognizer. These additions are separately reported rather than folded into the original result above.

For an explicit real-time microphone check beyond the former two-minute limit, add the optional flag below. It performs the ordinary five-second Stop-while-loading check and one additional 125-second microphone session through the actual controller and recorder. A ready no-op engine drains and discards PCM while recording, without recognizing or saving personal speech. The report checks that recording continued beyond 120 seconds, live draining occurred, every sample was accounted for, no overflow/conversion failure occurred, and Stop returned to idle. It also records a sampled capture-queue maximum; that maximum can miss peaks between its 250 ms observations. The normal quick verifier omits this longer microphone session.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun devicectl \
  device process launch --device YOUR_DEVICE_ID --terminate-existing \
  com.devesh.localscribe.ios --verify-dictation --verify-models phonon2 \
  --verify-long-microphone
```

The latest [controlled phone results](MODEL_RESEARCH.md#latest-controlled-phone-verification) and [redacted measurements](benchmarks/streaming-final.json) supersede the initial streaming comparison for current configurations. Both CPU-only Realtime and Phonon with 15-second windows completed the short clip and all three long public-fixture variants. The real microphone also recorded for 125.214 seconds, with every sample counted/discarded, zero overflow/conversion failures and a successful Stop. This verifies long hardware capture and public-fixture recognition separately; it does not establish personal long-dictation accuracy. Realtime remains the selected fast live default, with Phonon available for formatted text. Raw WER, phase timings and resource caveats are recorded in the linked research document rather than treated as a broad model ranking.

## Action Button and live preview

Follow [Action Button setup](INSTALLATION.md#action-button) to import the supplied signed **LocalScribe Action Button** workflow and assign it. Its Toggle app action, nonempty-result condition and native Copy to Clipboard use explicit result bindings, with Local Only enabled. The bare app action returns text and does not copy; users do not need to author the condition or clipboard action. The workflow uses the model selected on Dictate for preview and final recognition. There is no separate background selector or automatic model substitution. Import and assign the supplied workflow once; existing assignments remain valid.

The app intents return an empty `ReturnsValue<String>` when starting and the exact owned transcript when stopping. The conditional clipboard action leaves the clipboard unchanged on start. Finishing with the Dynamic Island/widget Stop retains that session’s result; the next Action Button invocation returns it without starting another microphone session, so the configured shortcut can copy it. The intents request background execution, bootstrap the app-owned recorder and require a successful Live Activity before microphone activation. Direct recording in Dictate remains available when Live Activities are off.

The Last run disclosure records app-intent action/outcome, nonempty-result status, timing, app context and cancellation. It excludes speech and clipboard contents and cannot confirm execution of the native Copy to Clipboard action.

Action Button activation uses a mixable `.playAndRecord` session; normal Dictate retains its recording-only session. Apple disallows activating a [nonmixable session in the background](https://developer.apple.com/documentation/coreaudiotypes/avaudiosession/errorcode/cannotinterruptothers), and [.mixWithOthers](https://developer.apple.com/documentation/avfaudio/avaudiosession/categoryoptions-swift.struct/mixwithothers) requires a supporting category. This fixes that configuration gap, not an iOS recording-privilege denial. Errors retain the actual OSStatus code: `!int` means nonmixable activation, `!rec` means recording is not permitted, and `!pri` means another app controls audio. Failed setup stops the engine, removes the tap and deactivates the session. No automatic foreground transition or silent playback is added.

Touch and hold the Dynamic Island for the expanded model name, timer, status and Stop button. True streaming models (Realtime and Moonshine) also show a live tail: the latest three punctuated sentences, bounded to 1 KB, or a rolling 65-word tail for unpunctuated text. Windowed Phonon-2, Ultra and Redux show periodic text in the app, beginning after five seconds of captured audio with a three-second processing cadence; model loading or processing can delay delivery. Their Island remains model/timer/status-only. The in-app transcript follows recognition unless the user is reviewing older text. Lock Screen content is transcript-free. [iOS controls Live Activity presentation](https://developer.apple.com/design/human-interface-guidelines/live-activities), including expansion and collapse. Updates are local and coalesced, with no push service.

Ordinary Island collapse does not end the app’s activity or request a replacement. Cleanup retires prior-session activity work before the next activity starts. This ordering repair does not establish that the user-reported two-second collapse gap is fixed; actual presentation and repeat recording remain phone checks.

Apple requires a Live Activity throughout [audio-recording intents](https://developer.apple.com/documentation/appintents/audiorecordingintent). Its [LiveActivityIntent reference](https://developer.apple.com/documentation/appintents/liveactivityintent) describes starting the app process without opening its UI, but the [runtime guide](https://developer.apple.com/documentation/appintents/configuring-the-runtime-behavior-of-your-app-intents) says intent type and system conditions can override requested modes. Wispr's [current setup guide](https://docs.wisprflow.ai/articles/4500510662-set-up-the-action-button-for-flow-on-iphone) also documents a brief microphone-activation app switch. The user reports that the supplied workflow worked on its first run, then repeated recording failed. Current reproduction, repairs and physical verification limits are recorded in [beta status](../tasklist.md#current-ios-beta-status). Cold-start variations, repeated runs and Dynamic Island rendering require device checks. Builds and platform fixtures do not establish those device workflows. On iOS 27, completion uses Apple's extended background intent API. Ordinary microphone/streaming verification does not establish shortcut or keyboard delivery.
