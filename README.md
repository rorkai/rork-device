# rork-device

Modern Swift tools and libraries for iOS device communication.

`rork-device` is an open source Swift package for developer workflows that
need to communicate with physical iOS devices. It provides a library-first API
and a matching `rorkdevice` CLI.

The project is intentionally built as independent Swift code with protocol-level
tests and clear public API boundaries.

## Goals

- Swift-native library APIs for iOS device services.
- A practical CLI for app installation and device inspection.
- Cross-platform architecture for direct/tunnel transports and local usbmuxd.
- Strong docstrings, protocol fixtures, and opt-in physical-device tests.
- Clean, maintainable implementations of the device protocols we support.

## 0.1.0 Scope

The first milestone focuses on device sessions and app installation:

- Parse existing Lockdown pairing records.
- Connect through local `usbmuxd` or a direct Lockdown endpoint.
- Query basic device information.
- Start Lockdown services.
- Stage IPA files through AFC.
- Install and remove provisioning profiles through MISAgent.
- List, install, and uninstall applications through InstallationProxy.
- Expose structured errors and install progress.

Pairing creation, device event streams, syslog, crash reports, debugserver,
developer image mounting, backup, and restore are planned for later milestones.

Secure Lockdown/session upgrades are modeled through `SecureSessionUpgrader` so
apps can supply the TLS backend that matches their platform. On Apple
platforms, `DeviceClient` uses the built-in Security.framework backend by
default for Lockdown and secure service connections.

See [Docs/Roadmap.md](Docs/Roadmap.md) for the release roadmap.

## Library Example

```swift
import Foundation
import RorkDevice

let client = DeviceClient()
let devices = try await client.devices()
let pairing = try PairingRecord.load(from: URL(fileURLWithPath: "pairing.plist"))

guard let device = devices.first else {
    throw RorkDeviceError.invalidInput("No device found.")
}

let session = try await client.session(for: device, pairingRecord: pairing)
let info = try await session.deviceInfo()
print(info.deviceName ?? "Unnamed device")

try await session.installApplication(
    ipaURL: URL(fileURLWithPath: "App.ipa"),
    bundleIdentifier: "com.example.app"
) { progress in
    print(progress.status, progress.percentComplete ?? -1)
}
```

## CLI Examples

```bash
rorkdevice list
rorkdevice info --pairing-record pairing.plist
rorkdevice apps list --pairing-record pairing.plist
rorkdevice profiles install Profile.mobileprovision --pairing-record pairing.plist
rorkdevice install App.ipa --bundle-identifier com.example.app --pairing-record pairing.plist
rorkdevice uninstall com.example.app --pairing-record pairing.plist
```

Direct/tunnel Lockdown endpoints can be selected explicitly:

```bash
rorkdevice info --host 10.7.0.1 --port 62078 --pairing-record pairing.plist
```

## Development

```bash
swift test
swift run rorkdevice --help
```

Physical-device checks should be opt-in and must not run in normal CI unless
the required device and pairing record are available.

Run the release smoke test against a paired device with:

```bash
RORK_DEVICE_PHYSICAL_SMOKE=1 \
RORK_DEVICE_PAIRING_RECORD=/path/to/pairing.plist \
RORK_DEVICE_PROFILE=/path/to/Profile.mobileprovision \
RORK_DEVICE_IPA=/path/to/App.ipa \
RORK_DEVICE_BUNDLE_ID=com.example.app \
swift test --filter PhysicalDeviceSmokeTests
```

Set `RORK_DEVICE_UDID` as well when more than one device is visible through
local `usbmuxd`.

## License

rork-device is licensed under the Apache License 2.0. See [LICENSE](LICENSE).
