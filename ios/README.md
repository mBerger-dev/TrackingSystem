# iOS — TrackingSystem

Open **`TrackingSystem.xcworkspace`**, not the project file.

```
SensorCore/     Swift package: packet decode, link stats, CSV rows.
                Pure Foundation — no CoreBluetooth, so `swift test` runs on a Mac.
TrackingApp/    The iOS app. CoreBluetooth + SwiftUI. Device only.
```

## Running the tests

```bash
cd ios/SensorCore && swift test
```

No hardware needed. This is where the link-measurement logic is verified —
`LinkStats` is deliberately separate from CoreBluetooth so a reported loss
figure can be checked against synthetic input instead of by holding two boards
and watching a number.

## Deploying to the phone

CoreBluetooth does nothing in the Simulator — there is no radio. Everything
below needs a physical iPhone.

Signing uses **free provisioning**, so **builds stop launching after 7 days**.
Re-deploy from Xcode before a measurement session; a stale build refusing to
open is expected, not a bug.

First run on a new device, in this order:

1. **Settings → Privacy & Security → Developer Mode** → on → the phone restarts.
   (The row only appears after a development build has been installed once.)
2. **Settings → General → VPN & Device Management** → your Apple ID → **Trust**.

## Bluetooth permission

The project sets `GENERATE_INFOPLIST_FILE = YES`, so **there is no `Info.plist`
file** — the key lives in build settings as
`INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription`. Edit it via the target's
Info tab or Build Settings (search `bluetooth`). Without it, iOS terminates the
app the moment it touches CoreBluetooth.

## Boards

Both tags must be powered and flashed with the sensor-stream firmware. They
advertise as `DWM-INIT` and `DWM-RESP`. Only `DWM-INIT` reports a distance;
`DWM-RESP` always sends the sentinel, which the decoder turns into `nil`.
See `firmware/ble-contract.md`.

## Verifying the toolchain without a phone

```bash
xcodebuild -workspace TrackingSystem.xcworkspace -scheme TrackingApp \
  -destination 'generic/platform=iOS' -configuration Debug build \
  CODE_SIGNING_ALLOWED=NO
```

Compiles the app against `SensorCore` without signing or a device attached —
useful for telling a real build error apart from stale SourceKit diagnostics in
the editor, which this project produced more than once during setup.
