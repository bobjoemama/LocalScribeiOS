# Installing LocalScribe on iPhone

The current public delivery is source code. The developer has installed 0.7.0/build 10 using development signing; that installation does not provide public beta access or a generally installable IPA. For everyday use after installation, see the [README](../README.md).

## Install from source

Use a Mac with Xcode 27.0 or newer, an iOS 18+ iPhone, and an Apple team able to provision the required identifiers. A paid Apple Developer Program team is the route verified for this project. Apple’s current [capability matrix](https://developer.apple.com/help/account/reference/supported-capabilities-ios) also lists App Groups for free Apple Developers, so a Personal Team is not categorically excluded by that capability. End-to-end Personal Team installation of this app and its extensions has not been verified. Its profiles expire after seven days, requiring rebuild/reinstallation, and it cannot distribute this app through TestFlight or Ad Hoc. See [Apple’s membership comparison](https://developer.apple.com/support/compare-memberships/).

1. Clone this repository and open the checked-in project:

   ```sh
   git clone https://github.com/bobjoemama/LocalScribeiOS.git
   cd LocalScribeiOS
   open LocalScribe.xcodeproj
   ```

2. In Xcode Settings → Accounts, add your Apple Account. Let Xcode resolve the pinned Swift packages. Select the **LocalScribe** scheme.
3. In **Signing & Capabilities**, select the **same team** and automatic signing for all three targets: **LocalScribe**, **LocalScribeKeyboard** and **LocalScribeActivityWidget**. Apple describes [assigning every target to a team](https://help.apple.com/xcode/mac/current/en.lproj/dev23aab79b4.html).
4. If using your own team, choose a unique base identifier and update **Debug and Release** bundle identifiers for all targets. For example:

   | Target | Example identifier |
   | --- | --- |
   | LocalScribe | `com.yourname.localscribe.ios` |
   | LocalScribeKeyboard | `com.yourname.localscribe.ios.keyboard` |
   | LocalScribeActivityWidget | `com.yourname.localscribe.ios.activity` |

5. Register/select your own shared App Group, such as `group.com.yourname.localscribe.ios`, for the **LocalScribe app and keyboard**. Replace `group.com.devesh.localscribe.ios` consistently in `Configuration/App.entitlements`, `Configuration/Keyboard.entitlements` and `KeyboardProtocol.appGroup` in `SharedKeyboard/KeyboardProtocol.swift`. The widget currently has no App Group entitlement. [Apple’s App Groups guide](https://developer.apple.com/documentation/xcode/configuring-app-groups) explains group registration and target membership. Using another team’s identifier does not grant access to its container.
6. Keep your fork’s generator consistent: `scripts/generate_project.py` contains the original bundle identifier base. Update it before regenerating the project, or regeneration will overwrite your Xcode bundle changes. Pass `--team=YOUR_TEAM_ID` when regenerating to retain the team. Update `CFBundleURLName` in `Configuration/App-Info.plist` to your app’s identifier; the `localscribe` URL scheme is separately used by app/keyboard routing and should remain consistent with the code. Local developer commands in [Development](DEVELOPMENT.md) use the original identifier; substitute yours.
7. Connect and trust the iPhone, select it as the run destination, and enable **Developer Mode** on the phone if Xcode requests it. Build and run. Follow any device signing/trust prompts; see Apple’s [physical-device workflow](https://developer.apple.com/documentation/xcode/running-your-app-in-simulator-or-on-a-device).
8. Confirm LocalScribe opens, then follow [First dictation](../README.md#first-dictation). Add the keyboard separately in iPhone Settings.

Using a new bundle identifier installs a separate app with separate saved data. Preserve the existing identifiers/team when updating an already provisioned installation to retain its identity. Removing entitlements to bypass a signing error is not a complete keyboard installation: the app and keyboard need their shared container.

For simulator builds and developer checks, see [Development](DEVELOPMENT.md#build). Simulator success does not establish physical microphone, keyboard insertion or background shortcut behavior.

## TestFlight (planned)

A public TestFlight link is the preferred planned installation route for people who do not use Xcode. **No public invitation or uploaded beta is currently documented for LocalScribe.** Once one is published, install Apple’s TestFlight app, open the invitation on your iPhone and accept/install the beta.

For maintainers, publication requires an App Store Connect app record, an uploaded eligible build, beta information and an external tester group. Apple reviews the first external build; later builds may also need review. Enable a public invitation link only after the group has an approved available build. Each build expires **90 days after upload**, so an ongoing beta needs replacement builds. See Apple’s [TestFlight overview](https://developer.apple.com/help/app-store-connect/test-a-beta-version/testflight-overview/) and [public invitation workflow](https://developer.apple.com/testflight/). These are release steps, not actions already performed by this repository.

Apple’s TestFlight service collects crash, usage and tester feedback information separately from LocalScribe’s local recognition behavior; see [TestFlight tester information](https://testflight.apple.com/).

## Ad Hoc (limited device testing)

Ad Hoc can distribute a signed IPA without Xcode on each recipient’s Mac, but **only registered devices included in the provisioning profiles can run it**. It requires developer-program signing access, a distribution certificate and profiles for the app and embedded extensions. A development-signed `.app` or an IPA with other devices’ profiles is not a public installation method.

Maintainers must register each intended device, archive the complete app in Xcode, and export using the Ad Hoc distribution method with matching team, identifiers, entitlements and device profiles. Adding a device requires updated provisioning and a newly exported build. See Apple’s [registered-device distribution guide](https://developer.apple.com/documentation/xcode/distributing-your-app-to-registered-devices) and [Ad Hoc profile requirements](https://developer.apple.com/help/account/provisioning-profiles/create-an-ad-hoc-provisioning-profile). No Ad Hoc release has been published here.
