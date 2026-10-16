# LocalScribe for iOS

An open-source alternative to Wispr Flow. Speech recognition runs on your iPhone, with editable transcripts, a personal dictionary, spoken snippets, notes and history. Requires **iOS 18 or later**. Also available for [Mac](https://github.com/bobjoemama/LocalScribe).

## Install

[Install the beta with TestFlight](https://testflight.apple.com/join/sdqBktQV). Open the link on your iPhone, install Apple’s TestFlight if prompted, then accept the invitation and tap **Install**. No Mac or Developer Mode is required.

[Installation and setup](docs/INSTALLATION.md) · [Build from source](docs/INSTALLATION.md#install-from-source) · [Beta status](tasklist.md#current-ios-beta-status) · [App Store preparation](docs/APP_STORE.md).

## Use

1. Open the **Models** tab, download a model and choose **Use**. Its details show measured load time and app RAM after a load.
2. In **Dictate**, tap **Record**, allow microphone access and speak.
3. Tap **Stop**, edit your transcript, then **Copy** or **Share**.

Realtime and Moonshine stream live text. Phonon-2 gives formatted text with periodic previews; Realtime produces English without punctuation or capitalization. **Library** contains Dictionary, Snippets and Notes; **History** contains saved transcripts.

Optional: [set up the keyboard](docs/INSTALLATION.md#keyboard) or [configure the Action Button](docs/INSTALLATION.md#action-button). Leave **Keep model loaded** On and wait for **Ready · Mic on** before Action Button dictation. On iOS 26+, **Load in Background** requests permission to finish CPU preparation while you use another app; iOS can decline or stop it.

Recognition stays local. Model downloads contact Hugging Face; audio is not saved. Text leaves through your copy, share, export or insertion actions. [Privacy details](docs/PRIVACY.md).

[Apache-2.0](LICENSE) · [Model/runtime licenses](NOTICE.md) · [Development](docs/DEVELOPMENT.md) · [Model research](docs/MODEL_RESEARCH.md)
