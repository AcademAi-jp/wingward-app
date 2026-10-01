# WingWard

**Get to know yourself before deciding who to meet.**

WingWard is a native iOS app that turns three voice conversations into a profile you can review and edit. Your AI companion, Ward, explores compatibility with another Ward and explains the match. From there, you can express mutual interest, arrange a meeting, and reflect on what you learned about yourself.

## For judges: start here

You can run the app on a **Mac with an iPhone Simulator**. The repository includes the configuration for our hosted judging environment, so you do not need to create a backend, supply API keys, or configure RevenueCat.

You will need:

- macOS, Xcode 16 or later, and an installed iOS 17 or later simulator.
- An internet connection and a working microphone.
- A designated judging account, provided separately in the private judging instructions. Passwords are not included in this repository.

### 1. Open the project

Clone this repository and open the Xcode project:

```sh
git clone https://github.com/AcademAi-jp/wingward-app.git
cd wingward-app
open apps/ios/Wingward.xcodeproj
```

Wait for Xcode to resolve the Swift packages. Select the **Wingward** scheme and an **iPhone Simulator**, then choose **Product → Run** (`⌘R`). The app’s displayed name is **WingWard**. A development team is not required for the simulator.

### 2. Sign in

Use the judging account supplied to you privately. Each reviewer should use a separate account so that profiles and progress remain independent. Complete the age gate truthfully and follow the initial setup prompts; the accounts do not come with completed onboarding answers.

The hosted judging environment is available to designated accounts until **October 13, 2026, at 19:00 UTC (12:00 PDT)**. Downloading the source does not create a hosted account. Voice sessions and requests have usage limits.

### 3. Try the experience

| Step | What to do | What to look for |
| --- | --- | --- |
| **Quiz** | Answer the initial preference questions. | The starting context for your conversations. |
| **Three voice conversations** | Allow microphone access, speak with each interviewer, and use the app’s completion control before moving on. | How spoken answers become an understanding of your preferences. |
| **Your profile** | Read the generated profile, correct anything that feels wrong, and save it. | You control what the app says about you. |
| **Compatibility** | Explore Ward’s conversations and the proposed match. | Explanations of compatibility, rather than a score alone. |
| **Mutual interest and arrangements** | Follow the match prompts, try the Test Store purchase below, and propose or approve meeting details. | The transition from AI introductions to a decision you make yourself. |
| **Reflection** | Use the simulated-meeting completion control when offered, then reflect with Ward and confirm the suggested profile updates. | New insights update your existing profile after your confirmation. |

**The judging counterpart is fictional.** Steps that need another person’s response are simulated; no real person is contacted and no real meeting takes place. The app labels this experience. A real identity-verification provider is not connected, and the demo does not verify anyone’s identity. You do not need to upload identity documents to evaluate the fictional journey.

### Continue from matching to reflection

After confirming your profile, open **Matches**. Use **Preview eligibility**, then **Start matching** if a candidate is eligible. Preview does not create a match. The designated fictional counterparts are prepared for the US matching market. They still go through the normal mutual-preference, market, block, and compatibility checks, so a match is not guaranteed. Keep your own preferences accurate.

When a match is available:

1. Open the match, review the compatibility conversation, then choose **Start Partner Ward** to open a conversation with the other Ward. From there, request a chat. The designated fictional counterpart can accept the request automatically.
2. Open the resulting room in **Chats** and use the meeting controls inside the room. Choose **I'm open to meeting**.
3. Share availability, choose a proposed time, and follow the displayed prompts. The fictional counterpart's planning actions advance automatically. If access requires a purchase, use RevenueCat Test Store as described below.
4. Once the plan is confirmed, choose **Simulate meetup and continue to reflection**. This is an explicitly simulated meeting; you do not need to attend or contact anyone.
5. Start a private voice reflection, generate suggestions from your own words, and choose which changes to save to your profile.

The fictional counterpart simulates acceptance and planning actions; it does not send human chat replies. Ward's AI conversations are a separate feature. If no candidate is eligible, you can still review your own profile and try the available Ward features.

## Try purchases with RevenueCat Test Store

**Test Store purchases are simulated and do not charge money.**

1. Open **You → Plan & Payments**.
2. Select a Premium subscription or meeting arrangement credit.
3. In the **Test Store Purchase** dialog, choose the successful test-purchase option.
4. Wait for the app to refresh and show the access confirmed by the server.
5. Choose **Restore purchases** to try the restore flow, then wait for the refreshed status.

WingWard uses RevenueCat for both a monthly Premium subscription (`wingward_premium_monthly`) and a meeting arrangement credit (`wingward_meetup_credit`). Access is confirmed through the backend after a verified RevenueCat webhook; a successful purchase dialog alone does not unlock it. Test subscriptions may renew or expire on an accelerated schedule.

## If you get stuck

- **No simulator available:** install an iOS runtime in **Xcode → Settings → Components**, then select an iPhone simulator as the run destination.
- **The microphone is silent:** check **System Settings → Privacy & Security → Microphone** on your Mac and the Simulator’s microphone input. Allow access when prompted.
- **Sign-in fails:** use your assigned judging account and check the access window above. A newly registered account does not automatically receive hosted judging access.
- **Voice cannot connect:** check your internet connection and follow the app’s displayed message. If the issue persists, include the visible error and the step you reached in your feedback; do not include your password.
- **Purchase succeeds but access has not changed:** allow time for server confirmation, then reopen **Plan & Payments** and refresh or restore purchases.

### Prefer a physical iPhone?

Connect an iPhone running iOS 17 or later, enable Developer Mode if prompted, and select it as Xcode’s destination. In the app target’s **Signing & Capabilities**, select your own development team and adjust the bundle identifier if your team requires it. Run the app and allow microphone access. No App Store or TestFlight installation is required for this development build.

## Evaluation scope

This is a hosted judging build with a fictional matching journey and Test Store billing. Automated API, database, and native-app checks have been run, but a complete manual pass of the latest hosted voice-to-reflection journey is still pending. Simulated UI tests do not establish that every live provider interaction succeeds.

## Explore the source

The app uses **SwiftUI**, **Supabase**, **Cloudflare Workers**, **OpenAI Realtime**, **Mistral**, and **RevenueCat**.

- [iOS app](apps/ios) — screens, voice transport, and purchase integration.
- [API](apps/api) — authorization, AI services, and server-confirmed purchase access.
- [Database migrations](supabase/migrations) — schema and access controls.
- [Developer guide](docs/development.md) — architecture, checks, and optional self-hosting.

## License

WingWard is licensed under the **GNU Affero General Public License, version 3**. See [LICENSE](LICENSE). Third-party dependencies retain their respective licenses.
