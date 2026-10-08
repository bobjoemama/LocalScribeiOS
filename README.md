# LocalScribe for iOS

An open-source alternative to Wispr Flow. Speech recognition runs on your iPhone, with editable transcripts, a personal dictionary, spoken snippets, notes and history. Requires **iOS 18 or later**. Also available for [Mac](https://github.com/bobjoemama/LocalScribe).

## Install

A public TestFlight invitation is not available yet. For now, [build and install from source](docs/INSTALLATION.md#install-from-source) with a Mac, Xcode 27+ and Apple signing access. The guide covers the app, keyboard and Live Activity extension. [Beta status](tasklist.md#current-ios-beta-status).

## Use

1. Open the **Models** tab, download a model and choose **Use**. Its details show measured load time and app RAM after a load.
2. In **Dictate**, tap **Record**, allow microphone access and speak.
3. Tap **Stop**, edit your transcript, then **Copy** or **Share**.

Realtime and Moonshine stream live text. Phonon-2 gives formatted text with periodic previews; Realtime produces English without punctuation or capitalization. **Library** contains Dictionary, Snippets and Notes; **History** contains saved transcripts.

Optional: [set up the keyboard](docs/INSTALLATION.md#keyboard) or [configure the Action Button](docs/INSTALLATION.md#action-button). Leave **Keep model loaded** On and wait for **Ready** before Action Button dictation. On iOS 26+, **Load in Background** requests permission to finish CPU preparation while you use another app; iOS can decline or stop it. Physical shortcut delivery still needs verification.

Recognition stays local. Model downloads contact Hugging Face; audio is not saved. Text leaves through your copy, share, export or insertion actions. [Privacy details](docs/PRIVACY.md).

[Apache-2.0](LICENSE) · [Model/runtime licenses](NOTICE.md) · [Development](docs/DEVELOPMENT.md) · [Model research](docs/MODEL_RESEARCH.md)
