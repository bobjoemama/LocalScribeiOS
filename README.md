# LocalScribe for iOS

Local speech recognition in a native iPhone app, with editable transcripts and a custom keyboard. Requires **iOS 18 or later**. The separate [Mac app](https://github.com/bobjoemama/LocalScribe) has its own installation instructions.

**Distribution status:** source is available; 0.7.0/build 10 has been installed on the developer’s provisioned iPhone. There is currently no published App Store release, public TestFlight invitation or general-install IPA. A public TestFlight beta is the planned easiest installation route; its link will appear here once available.

## Install

Today, developers can [build and install with Xcode](docs/INSTALLATION.md#install-from-source). You need a Mac, Xcode and signing access for the app and both extensions. Follow the guide when using your own Apple team: changing only the app bundle identifier leaves the keyboard and shared container misconfigured.

[TestFlight](docs/INSTALLATION.md#testflight-planned) will allow installation without Xcode once a beta is published. [Ad Hoc distribution](docs/INSTALLATION.md#ad-hoc-limited-device-testing) would work only on devices registered in its provisioning profiles; the current development build is not a universal download.

## First dictation

1. Open **Models**, download **Parakeet Realtime**, and keep LocalScribe open until setup finishes. It is the default fast live model. Its required files are about **224 MB**; initial preparation can take longer than later loads.
2. In **Dictate**, choose your downloaded model and tap **Record**. Allow microphone access when prompted, then speak.
3. Tap **Stop**, edit the finished transcript, then **Copy** or **Share** it. Live text may change before completion. The pencil action saves a transcript as a note.

Realtime produces English text without punctuation or capitalization. Choose **Phonon-2** for formatted dictation; its first live update needs about five seconds of speech. Other models and their language support are listed in Models. Downloading every model is optional.

## Library and history

- **Library → Dictionary:** replace a recognized phrase with your preferred spelling, such as `local scape` → `LocalScribe`.
- **Library → Snippets:** expand a spoken phrase such as `my email signature` into saved text.
- **Library → Notes:** type or dictate into searchable notes, then copy or share them.
- **History:** review, edit, copy, share or delete saved transcripts. Settings controls whether new history is saved and how long it is kept.

Dictionary and snippets correct text after recognition; they do not train the model. **Settings → Saved data** offers retry and confirmed recovery for unreadable collections, preserving a recovery copy and keeping models/settings.

## Keyboard

1. Add LocalScribe in **iPhone Settings → General → Keyboard → Keyboards → Add New Keyboard**.
2. Enable **Allow Full Access** for dictation. This permits local shared-container commands; speech recognition stays on the phone.
3. Open LocalScribe and start a **keyboard microphone session**, then switch to your destination app and select the LocalScribe keyboard.
4. Use the keyboard’s recording controls and insert the result. End the microphone session in LocalScribe when finished.

The app owns the microphone because custom keyboards cannot record audio. An armed session keeps the iOS microphone indicator on; idle audio is discarded. The default idle timeout is five minutes and can be changed in Settings; active dictation renews it. Results expire after 30 seconds. Secure fields and apps that disallow custom keyboards use the system keyboard. Physical host-app insertion remains a verification item.

## Action Button

Set **iPhone Settings → Action Button → Shortcut → LocalScribe → Dictate and Copy**. Allow microphone access in LocalScribe, enable Live Activities, and choose a downloaded CPU background model in **LocalScribe Settings → Action Button**. Hold and release to start; hold and release again to finish and copy. Touch and hold Dynamic Island to view its expanded preview.

Cold background recording, Dynamic Island presentation and background clipboard delivery still need physical verification. If the shortcut cannot start recording, open LocalScribe and use **Dictate → Record / Stop / Copy** as the foreground fallback.

## Models and performance

Downloaded models occupy storage; only one runtime is loaded at a time. **Keep model loaded** defaults to **On** for quicker reuse. Turning it Off releases the idle runtime and prepares it on demand; model retention does not keep the microphone on. iOS can still suspend or terminate the app. Action Button uses its separately selected model.

The required-file catalog ranges from about 142–632 MB per model. These download sizes are not RAM use, and Core ML can create additional caches. Exact sizes, measurements and limitations are in [model research](docs/MODEL_RESEARCH.md).

Dictate’s CPU/memory readout and **Settings → Performance** work on the phone alone. Optional USB Mac profiling adds device GPU/display counters when supplied; recorded Instruments reports can add trace-wide GPU/Neural Engine activity. See [developer profiling](docs/DEVELOPMENT.md#live-performance) for setup and measurement limits.

## Privacy and license

Recognition uses verified local models, with no cloud recognition, account or app analytics. Explicit model downloads contact Hugging Face and its CDN. Audio stays in a bounded memory buffer and is not saved as audio files. Saved text stays local until you copy, share, export or insert it into another app. See [storage details](docs/DEVELOPMENT.md#privacy-and-storage).

Source: [Apache-2.0](LICENSE). Model/runtime licenses and attribution: [NOTICE.md](NOTICE.md). Developer builds, tests and debug recipes: [Development](docs/DEVELOPMENT.md). Current interface and verification: [UI redesign](docs/UI_REDESIGN.md).
