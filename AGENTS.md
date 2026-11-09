# Project Conventions

StupidChatKit is the chat framework from stupid social (`../stupid-social`, `https://github.com/stephancill/stupid-social`) as a Swift package: one chat screen and Chats list for any number of networks, with an adapter per network. Apps depend on it by URL at a tagged version.

## Required Context

- Read `README.md` (how apps use the kit) and `docs/DESIGN.md` (the design and the reasons) before changing anything.
- `docs/DESIGN.md` is the source of truth for the design. Update it in the same change when behavior, the public API or a rule changes.
- Before changing the public API, look at how stupid social uses it (`../stupid-social`, especially `Sources/StupidSocialCore/Models/ChatDestination.swift`, its adapters in `Sources/StupidSocialCore/Sources/*ChatAdapter.swift` and `Sources/StupidSocial/Views/ChatsView.swift`).

## Stack

- Swift 6.2 package, iOS 18 or later, SwiftUI and UIKit (the message list and composer are UIKit). No dependencies: prefer Apple frameworks over adding one.
- One library product, `StupidChatKit`; resources in `Sources/StupidChatKit/Resources` (`Bundle.module`).

## Rules

- The kit never names a network, casts to a network's type or knows any app. A network's need becomes an optional ability protocol any network could adopt (`ChatEditing`, `ChatReactionSending`, `ChatTyping`, …), and the UI offers it exactly when the adapter conforms. Never add a flag that can disagree with the code.
- Adapters only translate; behavior users expect to match across chats (connecting, polling, paging, unread counting, read markers, snapshots, drafts, optimistic sending) belongs to the framework. If shared behavior doesn't fit a network, extend the framework.
- What the kit needs from an app goes through `ChatKit` (launch settings) or a protocol (`ChatReminders`, `ChatNotConnectedError`), never by reaching into an app.
- Public API is what apps compile against: keep it small, and treat a breaking change as a minor version bump while below 1.0 (major after), listed in the release notes.
- Never put anything identifying in the kit: usage events (`ChatEvent`) carry networks and outcomes only, never names, ids, text or URLs.
- Add comments only when code is not self-explanatory.

## Testing

- Framework behavior is tested in `Tests/StupidChatKitTests` with fake adapters and providers; add a test with each behavior change. Run: `xcodebuild test -scheme StupidChatKit -destination 'id=<simulator udid>' -collect-test-diagnostics never`.
- After changing `Sources/StupidChatKit/Stickers/`, compare against the references on a corpus of real stickers (from stupid social's `scripts/telegram-client.py sticker-corpus`, never committed): `scripts/lottie-compare.py` (Telegram's rlottie) and `scripts/webm-compare.sh` (ffmpeg). Tools and output go under `logs/` and `third-party/`, both ignored.
- Check a change in stupid social before releasing it: point its dependency at this checkout (`.package(path: "../stupid-chatkit")`), build and run it with `stupid-app run --simulator`, then put the URL dependency back; never commit the path dependency there.

## Formatting

- Run `swiftformat Sources/ Tests/`.

## Releasing

1. Update `README.md` and `docs/DESIGN.md` for the change, and commit with a conventional commit message (`feat:`, `fix:`, …).
2. Tag and push: `git tag -a X.Y.Z -m "StupidChatKit X.Y.Z"`, `git push origin main X.Y.Z`. Tags are plain semantic versions (no `v`), which SwiftPM resolves.
3. Create the GitHub release with notes: `gh release create X.Y.Z --notes "…"`.
4. Bump the app: in stupid social, `swift package update stupid-chatkit` (raise `from:` in `Package.swift` when it needs the new API), build, and commit `Package.resolved`.
