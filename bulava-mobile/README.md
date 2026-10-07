# Bulava on the phone

Android and iPhone, one Compose Multiplatform codebase. The phone is a window onto Bulava on the
Mac: it shows what the Mac sends, and asks the Mac to act. It runs no work and keeps no product
state of its own beyond drafts and the pairing.

- How the two talk, and the rules that keep an older phone working with a newer Mac:
  [`../link-protocol/README.md`](../link-protocol/README.md)
- What the phone can do, next to the Mac: [`../link-protocol/PARITY.md`](../link-protocol/PARITY.md)
- How to build a feature for both: [`../docs/mobile/SYNC.md`](../docs/mobile/SYNC.md)

## Layout

| | |
|---|---|
| `shared/src/commonMain/.../link/` | the wire types (`Wire.kt`) and the connection (`LinkClient.kt`) |
| `shared/src/commonMain/.../state/` | `AppController`: what the phone holds — home, open chats, drafts, the outbox |
| `shared/src/commonMain/.../ui/` | the screens, in the desktop's palette |
| `shared/src/commonMain/.../demo/` | "Try it without a Mac": a Mac simulated on the phone, with its own in-memory stores, for App Review and first-time users |
| `shared/src/androidMain/` | pinned TLS on OkHttp, the Keystore-backed credential store, notifications, Bonjour (NSD) |
| `shared/src/iosMain/` | the bridge to Swift (`IosHost`) |
| `androidApp/` | the activity, the QR scanner (CameraX + ML Kit), the service that keeps the link up in the background, the answer screen that has the phone unlocked before a notification's button is pressed |
| `iosApp/` | the Swift host: pinned TLS on `URLSession`, Keychain, the scanner, pickers, Bonjour, background refresh, notification buttons, the Live Activity (`LiveShift.swift`) |
| `iosApp/BulavaWidgets/` | the widget extension: the Live Activity and the week's widgets for the Home Screen and Lock Screen (`com.stepanok.bulava.widgets`) |
| `iosApp/Shared/` | `ShiftAttributes`, compiled into both the app and the extension |
| `push-relay/` | the service that reaches an iPhone while its app is closed: wake-ups and the Live Activity |

## Build

```bash
./gradlew :androidApp:assembleDebug          # a debug APK
./gradlew :androidApp:assemblePreview        # shrunk like a release, signed with the debug key — for trying on a device
./gradlew :shared:testAndroidHostTest        # logic and the wire contract, on the JVM
./gradlew :shared:iosSimulatorArm64Test      # the same logic on iOS
open iosApp/iosApp.xcodeproj                 # the iPhone app; the Kotlin framework builds as part of it
```

## Releasing

Signed builds are made by the maintainer, with keys that never enter git and with release scripts
and the App Store listing that are not part of the public repository (`RELEASING.md` beside this
file, in the maintainer's copy). To run a copy of your own, give it your own bundle identifier and
team in `iosApp/Configuration/Config.xcconfig` and sign with your own keys.

To try the app against a Mac without touching real projects, run the harness described at the end
of `link-protocol/README.md` and pair with `adb shell am start -d "bulava://pair#…"` (Android) or
`xcrun simctl openurl booted "bulava://pair#…"` (iOS simulator).
