# App Store release preparation

The [beta status](../tasklist.md#current-ios-beta-status) records the current source, installed build, upload and public TestFlight availability. TestFlight approval does not publish an App Store version.

## Prepared listing

Name: **LocalScribe – Local Dictation**

Subtitle: **Private, on-device dictation**

Category: **Productivity**

Support URL: https://github.com/bobjoemama/LocalScribeiOS/issues

Privacy policy URL: https://github.com/bobjoemama/LocalScribeiOS/blob/main/docs/PRIVACY.md

Keywords: `dictation,speech to text,offline,transcription,voice,notes,keyboard,local,privacy`

Description:

> Turn speech into editable text on your iPhone or iPad. LocalScribe runs speech recognition on your device. Download a model, then dictate without cloud transcription.
>
> Record, edit, copy and share transcripts. Choose between streaming models and models with periodic text previews. Save notes and history, correct recurring words with a personal dictionary, and expand spoken phrases into saved snippets.
>
> Use the optional keyboard or set up the Action Button to record from another app and copy the finished text. Background dictation keeps the microphone session active between recordings; idle audio is discarded. Pause it directly from Dictate. iOS permissions and Live Activities are required for the Action Button workflow.
>
> Model downloads require internet access and device storage. Languages, download sizes and measured loading information appear in Models. Performance varies by model and device. LocalScribe requires iOS 18 or later.
>
> No account, ads or cloud speech service. Audio is processed in memory and is not saved. History, notes, dictionary and snippets stay on the device. Copying, sharing or inserting text sends it only to the destination the user chooses. LocalScribe is open source.

Copyright ownership must be confirmed by the publisher; a Git author or Apple account name alone does not establish the legal owner. No new public personal contact address is assumed.

## App Review notes

No sign-in or demo account is required. Disable the draft's **Sign-in required** checkbox.

1. Open **Models**, download **Parakeet Realtime** (about 224 MB), and choose **Use**. Wait for the selected model to load. Other models are optional; the app downloads pinned recognition assets, not new native application code.
2. Open **Dictate**, allow microphone permission, tap **Record**, speak, then **Stop**. Edit, Copy or Share the transcript. Realtime streams unpunctuated English; Phonon-2 produces formatted text with periodic in-app previews.
3. Background dictation defaults On with Never auto-stop. **Ready · Mic on** means the app-owned microphone session is active. Idle samples are discarded. **Pause** stops it; explicit pauses persist. iOS interruption, memory reclamation and force quit can end the session. Background inference uses the selected CPU runtime.
4. For Action Button, open **Settings → Action Button → Setup → Add Shortcut**. Import the supplied **LocalScribe Action Button** workflow, then assign it in **iPhone Settings → Action Button → Shortcut**. Allow Live Activities. Open LocalScribe and wait for **Ready · Mic on**, switch apps, hold/release once to start and again to finish, then paste. The shortcut's native Copy to Clipboard action copies a nonempty result. Action Button hardware is optional.
5. For the optional keyboard, use **iPhone Settings → General → Keyboard → Keyboards → Add New Keyboard**, add LocalScribe and enable **Allow Full Access** for its local shared-container dictation commands. The containing app owns the microphone. Ordinary typing does not require Full Access.

About & credits provides privacy, support and the distinct app/runtime/model licenses. Optional developer profiling is a manually enabled local Mac connection or an imported Instruments report; it is not cloud recognition or analytics.

## Complete the draft, then submit separately

The saved factual fields, current draft/build and remaining declarations are recorded in [beta status](../tasklist.md#current-ios-beta-status). Production submission is a separate step. Keep **Manually release this version** selected when approval should precede publication.

- Upload current representative iPhone and 13-inch iPad screenshots. The app supports both device families. [Apple's screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/) determine accepted slots and sizes; simulator captures with example text do not establish model performance.
- Complete age rating, content rights, price and availability from the actual app and publisher's choices. The app has no account, purchases, ads, community feed or generated-content service. Do not infer EU trader status or publish private contact details from development records.
- Provide the publisher's copyright name on the version page. In **App Information → Content Rights**, confirm the rights to the app's licensed third-party models/runtime resources. In **Pricing and Availability → Set Up Availability**, choose countries/regions after resolving any applicable trader requirements. The source licenses and [About credits](../LocalScribeApp/AboutView.swift) identify the third-party materials.
- Add the privacy URL and review App Privacy answers. Source inspection supports local audio/text processing with no app analytics or tracking. Anonymous model downloads expose an IP address and file request to Hugging Face/CDNs. The [policy](PRIVACY.md) discloses this; the exact retention/classification remains unconfirmed. “Data Not Collected” is a provisional draft, not a declaration established by the privacy manifest alone. [Apple's definitions](https://developer.apple.com/app-store/app-privacy-details/) govern the final answers.
- Confirm export-compliance status for the uploaded build. Source declares `ITSAppUsesNonExemptEncryption = false` and uses system networking, hashes and iOS file protection.
- The Account Holder must personally review any updated Developer Program agreement at [Apple Developer Account](https://developer.apple.com/account/). If the notice is absent, check the selected team and [App Store Connect → Business](https://appstoreconnect.apple.com/business). Agreement acceptance is legal consent and is not performed by the release agent.

When the publisher authorizes production submission, open [LocalScribe's Distribution page](https://appstoreconnect.apple.com/apps/6820165376/distribution/ios/version/inflight), confirm all required fields and the intended build, then use **Add for Review → Submit for Review**. Apple reviews the submission; manual release keeps publication under the publisher's control after approval. [Apple's submission workflow](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/).
