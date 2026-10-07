# LocalScribe iOS privacy

Updated October 7, 2026. This describes LocalScribe 0.7.0/build 10, including its keyboard and Live Activity extension.

## Recognition and downloads

Speech recognition runs on your iPhone using downloaded models. LocalScribe has no app account, cloud speech recognition, advertising, tracking or app analytics service. Microphone audio is processed in a bounded memory buffer and discarded; the app does not save audio recordings.

Explicit model downloads contact Hugging Face and its CDN infrastructure. Those hosts receive ordinary connection information, such as your IP address and requested model files, and may keep their own logs. Downloads use pinned model revisions and verify file integrity before cold loading.

## Saved text

History, notes, dictionary rules and snippets are stored locally with iOS file protection and excluded from device backups. Recovery copies have the same protection and backup exclusion. Model files are also excluded from backups. iOS file protection depends on the device’s lock and security state.

History saving is optional. Turning it off stops new entries and leaves existing history intact. Delete entries in History or Library; History also offers Clear all and Settings offers retention controls. Settings → Saved data can reset a collection after confirmation, preserving its previous file as a recovery copy. **Reset is recovery, not erasure of those copies.** Recovery copies can be exported and contain saved text.

## Microphone, keyboard and visible text

The app asks for microphone permission when needed. You can revoke it in iPhone Settings. A keyboard dictation session must be explicitly armed in LocalScribe: the app owns the microphone, and iOS shows its microphone indicator while the session is active. Idle audio is discarded; inactivity ends the session after the configured timeout. End the session in LocalScribe to stop the microphone yourself.

The optional keyboard needs Allow Full Access for commands and results in the local shared container. Its temporary state uses file protection available after the device’s first unlock and is excluded from backups. The keyboard does not save surrounding text from your destination app. Ordinary typing works without Full Access.

An expanded Dynamic Island can display recent transcript text. The Lock Screen Live Activity omits transcript text and shows status. iOS controls presentation; consider who can see your screen during dictation.

Copy, Share, text export, recovery-copy export and keyboard insertion send text to the clipboard or destination you choose. The destination app, share service and system clipboard features then handle that text under their own settings and policies. Action Button dictation copies the completed result to the clipboard.

## Optional diagnostics and beta testing

CPU/memory readings work locally. Developer profiling is manually enabled: the optional USB Mac companion connects to a temporary loopback listener using a connection code and supplies device performance counters. It does not send speech to a recognition service; the session stops when the phone app leaves the foreground. Instruments report import reads the file you select locally. Share diagnostic files only after checking their contents.

If you install through TestFlight, Apple separately collects beta crash, usage and feedback information under its [TestFlight privacy information](https://www.apple.com/legal/privacy/data/en/test-flight/). This is separate from LocalScribe’s local recognition. Sending feedback or opening a public issue is your choice.

## Contact

Ask privacy questions through [GitHub issues](https://github.com/bobjoemama/LocalScribeiOS/issues). Issues are public: describe the problem without posting sensitive speech, transcripts, recovery files, connection codes or personal device identifiers.
