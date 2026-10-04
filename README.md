# LocalScribe for iOS

Native SwiftUI dictation with speech recognition on your device. Includes a UIKit keyboard, editable transcripts, local history, personal word corrections, explicit model downloads and local resource/accuracy measurements. Source is Apache-2.0; model and runtime licenses are separate (see `NOTICE.md`).

Requires iOS 18 or later. The default candidate is Phonon-2 through exact-version FluidAudio 0.17.5, configured for Core ML CPU + Neural Engine execution. Recognition loads verified local files; missing models produce an error rather than a network fallback. The app supports three exact-weight Phonon-2 encoders, Ultra and Redux. Current research, exact sizes, stack alternatives and evidence limits: [model/runtime comparison](docs/MODEL_RESEARCH.md).

## Use

1. Open Models and explicitly download a model. Keep the app open during setup. First Core ML preparation may take substantially longer than later cached loads.
2. In Dictate, tap Record, then Stop to transcribe an utterance (up to two minutes). Microphone access needs the normal iOS permission. Edit, copy or share the resulting text.
3. For dictation in another app, add LocalScribe under Settings → General → Keyboard → Keyboards, then enable Allow Full Access. Open LocalScribe and start a keyboard microphone session before switching to another app. The app owns the microphone; Apple's custom keyboard API cannot record audio itself.
4. The keyboard can start/stop utterances while the explicitly armed five-minute session remains live. Idle audio is discarded. End the session in LocalScribe to stop the microphone. iOS displays its microphone indicator while the session is armed. Secure fields and apps that disallow custom keyboards use the system keyboard.

Ordinary typing works without Full Access. Full Access is needed to write local shared-container commands, not to send audio to a service. The keyboard never reads or saves surrounding host text. Automatic insertion is bound to the original document and disarmed when the editing context changes; otherwise use Insert dictation. Results expire after 30 seconds. A delivery receipt prevents replay but a crash between receipt and host insertion can lose automatic delivery; the app retains the transcript.

Settings contains local performance and word error rate (WER) measurements. WER compares a supplied reference with raw recognition before dictionary corrections, normalizing case and punctuation. CPU and memory reports cover the whole app process. Requested Core ML compute units do not establish actual execution placement. GPU/Neural Engine utilization, energy and system-wide memory pressure require device profiling; this UI does not manufacture those measurements.

## Privacy and storage

No cloud recognition, account, analytics or updater is implemented. Explicit model setup contacts Hugging Face and its download/CDN infrastructure. Audio samples remain in a bounded in-memory buffer and are not saved as audio files. History is optional; turning it off stops saving subsequent transcripts. Existing history remains available. History and dictionary JSON use complete file protection and are excluded from backups. Temporary keyboard state uses protection after first unlock to support app/keyboard handoff and is also excluded from backups. Model directories are excluded from backups. Transcripts can still leave the app through explicit copy/share or insertion into the chosen host app.

Models are pinned to immutable revisions in `Resources/model-integrity.json`, verified against file sizes and publisher SHA-256/Git object hashes before cold loading. Publisher hashes provide integrity relative to the publisher, not independent signed provenance. Core ML may create additional system-managed compiled caches beyond the listed model bytes.

## Build

Open `LocalScribe.xcodeproj` in Xcode with an iOS 18+ SDK. Select your developer team for both targets and provision `group.com.devesh.localscribe.ios`. Targets use `com.devesh.localscribe.ios` and `com.devesh.localscribe.ios.keyboard`.

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
- `Resources/model-integrity.json`: the authoritative five-profile pinned installation catalog.

The native app follows Apple's containing-app microphone/shared-container pattern, studied against Muesli and platform guidance, with finite explicit sessions and no cloud summarization/sync dependency. Model-specific adapters can implement `LocalTranscriptionEngine`; alternative stacks are researched but not bundled.

See [remaining work and verification](tasklist.md). The Mac redesign is in the separate [LocalScribe desktop repository](https://github.com/bobjoemama/LocalScribe); its screenshots in `docs/previews/mac` use isolated mocked settings data. [iOS light preview](docs/previews/ios-light-dictate.png) and [dark model selection](docs/previews/ios-dark-models.png) are actual simulator renderings. [Mac dark preview](docs/previews/mac/workspace-dark-1220x760-dictation.png) shows the revised candidate. The iOS app offers System/Light/Dark; the Mac candidate follows system appearance. Preview screenshots do not prove physical-device speech recognition.
