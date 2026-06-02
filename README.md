# rork-device

[![Swift](https://img.shields.io/badge/Swift-5.9-orange.svg)](Package.swift)
[![SwiftPM](https://img.shields.io/badge/SwiftPM-supported-brightgreen.svg)](Package.swift)
[![License](https://img.shields.io/badge/License-Apache%202.0-blue.svg)](LICENSE)

Modern Swift tools and libraries for iOS device communication.

`rork-device` is an open-source Swift package for developer workflows that
need to communicate with physical iOS devices. It provides a library-first API
and a matching `rorkdevice` CLI.

The project is intentionally built as independent Swift code with protocol-level
tests and clear public API boundaries.

## Features

- **Swift-first library** - the `RorkDevice` module exposes device discovery,
  Lockdown sessions, service startup, and app-management APIs directly to Swift
  applications.
- **Command-line tools** - the `rorkdevice` CLI supports device inspection,
  app listing, provisioning-profile management, IPA installation, and app
  removal.
- **Pairing records** - parse existing Lockdown pairing-record plists and
  preserve unknown fields for diagnostics.
- **SwiftNIO transports** - connect through local `usbmuxd` or a known direct
  Lockdown endpoint with non-blocking TCP and Unix-domain socket streams.
- **Secure sessions** - upgrade Lockdown and secure service connections through
  a public `SecureSessionUpgrader` protocol, with an Apple Security.framework
  backend enabled by default on Apple platforms.
- **Lockdown values** - query common device identity and OS metadata through a
  typed `DeviceInfo` summary.
- **AFC staging** - create `/PublicStaging` and upload IPA files or in-memory
  IPA bytes before installation.
- **Provisioning profiles** - install, remove, and copy CMS-wrapped
  `.mobileprovision` payloads through MISAgent.
- **Application management** - browse installed apps, install staged IPA
  packages, and uninstall apps through InstallationProxy.
- **Structured progress** - expose InstallationProxy progress events and typed
  protocol errors for application workflows.
- **Protocol test harness** - validate usbmux, Lockdown, AFC, MISAgent, and
  InstallationProxy behavior with fake service peers and protocol fixtures.
- **Physical-device smoke tests** - provide an opt-in release check for list,
  info, provisioning-profile install/copy, IPA install, and IPA uninstall.

See [Docs/Roadmap.md](Docs/Roadmap.md) for release scope, current limitations,
and planned services such as pairing creation, device events, syslog, crash
reports, debugserver, developer image mounting, backup, and restore.

## Library Example

```swift
import Foundation
import RorkDevice

let client = DeviceClient()
let devices = try await client.discoverDevices()
let pairing = try PairingRecord.load(from: URL(fileURLWithPath: "pairing.plist"))

guard let device = devices.first else {
    throw RorkDeviceError.invalidInput("No device found.")
}

let session = try await client.connect(to: device, using: pairing)
let info = try await session.fetchDeviceInfo()
print(info.deviceName ?? "Unnamed device")

try await session.installApplication(
    at: URL(fileURLWithPath: "App.ipa"),
    bundleIdentifier: "com.example.app"
) { progress in
    print(progress.status, progress.percentComplete ?? -1)
}
```

## Usage

`rorkdevice` uses Swift ArgumentParser. Commands are grouped by the device
workflow they drive:

```bash
rorkdevice list
rorkdevice info --pairing-record pairing.plist
rorkdevice apps list --pairing-record pairing.plist
rorkdevice profiles install Profile.mobileprovision --pairing-record pairing.plist
rorkdevice profiles copy --output-directory Profiles --pairing-record pairing.plist
rorkdevice profiles remove PROFILE-UUID --pairing-record pairing.plist
rorkdevice install App.ipa --bundle-identifier com.example.app --pairing-record pairing.plist
rorkdevice uninstall com.example.app --pairing-record pairing.plist
```

Direct/tunnel Lockdown endpoints can be selected explicitly:

```bash
rorkdevice info --host 10.7.0.1 --port 62078 --pairing-record pairing.plist
```

```text
USAGE: rorkdevice <subcommand>

OPTIONS:
  --version               Show the version.
  -h, --help              Show help information.

SUBCOMMANDS:
  list                    List devices reported by local usbmuxd.
  info                    Print basic Lockdown device information.
  apps                    Manage installed apps.
  install                 Install an IPA.
  uninstall               Uninstall an app by bundle identifier.
  profiles                Manage provisioning profiles.

  See 'rorkdevice help <subcommand>' for detailed help.
```

The install command stages an IPA with AFC and asks InstallationProxy to install
the staged package:

```text
USAGE: rorkdevice install [--udid <udid>] [--host <host>] [--port <port>] [--pairing-record <pairing-record>] <ipa-path> --bundle-identifier <bundle-identifier>

ARGUMENTS:
  <ipa-path>              IPA path.

OPTIONS:
  --udid <udid>           Device UDID. Defaults to the first discovered device.
  --host <host>           Direct Lockdown host. When provided, usbmuxd
                          discovery is skipped.
  --port <port>           Direct Lockdown port. (default: 62078)
  --pairing-record <pairing-record>
                          Existing Lockdown pairing record plist.
  --bundle-identifier <bundle-identifier>
                          Bundle identifier for the IPA.
  --version               Show the version.
  -h, --help              Show help information.
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
