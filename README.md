# LocalScribe for iOS

An open-source alternative to Wispr Flow. Speech recognition runs on your iPhone, with editable transcripts, a personal dictionary, spoken snippets, notes and history. Requires **iOS 18 or later**. Also available for [Mac](https://github.com/bobjoemama/LocalScribe).

## Install

The signed **0.7.0/build 10** beta has been uploaded to Apple. Processing, external beta review and a public invitation are pending. For now, [build and install from source](docs/INSTALLATION.md#install-from-source) with a Mac, Xcode 27+ and Apple signing access. The guide covers the app, keyboard and Live Activity extension.

## Use

1. Open **Models** and download **Parakeet Realtime**. Keep the app open during setup.
2. In **Dictate**, tap **Record**, allow microphone access and speak.
3. Tap **Stop**, edit your transcript, then **Copy** or **Share**.

Choose Phonon-2 for formatted text; Realtime produces English without punctuation or capitalization. **Library** contains Dictionary, Snippets and Notes; **History** contains saved transcripts.

Optional: [set up the keyboard](docs/INSTALLATION.md#keyboard) for dictation in other apps, or [configure the Action Button](docs/INSTALLATION.md#action-button). Background shortcut behavior still needs physical verification; ordinary Dictate remains the foreground fallback.

Recognition stays local. Model downloads contact Hugging Face; audio is not saved. Text leaves through your copy, share, export or insertion actions. [Privacy details](docs/PRIVACY.md).

[Apache-2.0](LICENSE) · [Model/runtime licenses](NOTICE.md) · [Development](docs/DEVELOPMENT.md) · [Model research](docs/MODEL_RESEARCH.md)
