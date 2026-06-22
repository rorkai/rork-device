# rork-device

[![Swift](https://img.shields.io/badge/Swift-6.0-orange.svg)](Package.swift)
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
  file access, app listing, provisioning-profile management, IPA installation,
  app removal, and CoreDevice process launch and termination.
- **Host pairing lifecycle** - generate the certificate material required by
  Lockdown, drive the iPhone Trust flow, save accepted records through
  `usbmuxd`, export complete property lists, validate existing trust, and
  remove trust from both the device and host.
- **Developer Mode diagnostics** - read the current AMFI status or reveal the
  Developer Mode setting without enabling it or restarting the device
  automatically.
- **Remote identity lifecycle** - generate, validate, and atomically persist
  complete CoreDevice identities with owner-only file permissions.
- **Remote trust enrollment** - distinguish typed device rejections and
  complete manual trust for newly generated or existing identities.
- **CoreDevice userspace networking** - negotiate the Lockdown packet tunnel,
  run an embedded IPv6/TCP backend, and expose device services through the
  destination-prefixed loopback protocol used by existing device tools.
- **SwiftNIO transports** - connect through local `usbmuxd` or a known direct
  Lockdown endpoint with non-blocking TCP and Unix-domain socket streams.
- **Remote-pairing tunnels** - authenticate an existing remote-pairing identity,
  establish a TLS 1.2 PSK-protected CDTunnel, and exchange complete IPv6
  packets through the negotiated link.
- **Remote services** - connect to Remote Service Discovery through an active
  tunnel, complete its HTTP/2 and RemoteXPC handshake, and use the advertised
  services through the same high-level `DeviceSession` APIs or any
  `DeviceTransport` that reaches the tunnel's private service ports.
- **Tunnel diagnostics** - inspect the negotiated network configuration and
  TLS cipher suite without coupling application behavior to transport-specific
  metadata.
- **Device events** - watch usbmux attach and detach events through an
  `AsyncThrowingStream`.
- **Secure sessions** - upgrade Lockdown and secure service connections through
  a public `SecureSessionUpgrader` protocol, with a SwiftNIO SSL backend enabled
  by default for the package's built-in transports.
- **Lockdown values** - query common device identity and OS metadata through a
  typed `DeviceInfo` summary or emit the complete scalar dictionary as
  machine-readable CLI JSON.
- **AFC staging** - create `/PublicStaging` and upload IPA files or in-memory
  IPA bytes before installation.
- **AFC file access** - list directories, read file metadata, download files,
  upload files, remove paths, and move paths.
- **HouseArrest containers** - vend app Documents or full app containers as AFC
  clients when the device permits access.
- **Provisioning profiles** - install, remove, and copy CMS-wrapped
  `.mobileprovision` payloads through MISAgent.
- **Application management** - browse installed apps, install staged IPA
  packages, uninstall through InstallationProxy, and launch or terminate apps
  through CoreDevice's direct RemoteXPC app service.
- **Structured progress** - expose InstallationProxy progress events and typed
  protocol errors for application workflows.
- **Protocol test harness** - validate usbmux, Lockdown, remote pairing,
  RemoteXPC, Remote Service Discovery, AFC, MISAgent, and InstallationProxy
  behavior with fake service peers and protocol fixtures.
- **Physical-device smoke tests** - provide an opt-in release check for list,
  info, provisioning-profile install/copy, IPA install, and IPA uninstall.

See [Docs/Roadmap.md](Docs/Roadmap.md) for release scope, current limitations,
and planned services such as Wi-Fi discovery, syslog, crash reports,
debugserver, developer image mounting, backup, and restore.

## Installation

Add `rork-device` to the package dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/rorkai/rork-device.git", from: "0.8.2"),
]
```

Then add the library product to the target that communicates with devices:

```swift
.target(
    name: "DeviceIntegration",
    dependencies: [
        .product(name: "RorkDevice", package: "rork-device"),
    ]
)
```

## Lockdown Example

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

## CoreDevice Userspace Tunnel

The complete local-device route can be built without an external tunnel
process. `DeviceClient` reads the trusted Lockdown record from `usbmuxd`,
`RemotePairingIdentity` owns the stable CoreDevice credential, and the
userspace network exposes device TCP services without creating a privileged
system interface:

```swift
import Foundation
import RorkDevice

let client = DeviceClient()
let devices = try await client.discoverDevices()
guard let device = devices.first else {
    throw RorkDeviceError.invalidInput("No device found.")
}

let pairingRecord = try await client.pairingRecord(
    for: device.identifier
)
let session = try await client.connect(
    to: device,
    using: pairingRecord
)
let identity = try RemotePairingIdentity.loadOrCreate(
    at: URL(fileURLWithPath: "remote-pairing.plist")
)
let packetTunnel = try await session.openCoreDeviceTunnel()
let network = try CoreDeviceUserspaceNetwork(tunnel: packetTunnel)
let gateway = try await CoreDeviceUserspaceGateway.start(network: network)
defer {
    gateway.close()
}

try await RemotePairingTrust.establishIfNeeded(
    for: identity,
    using: network,
    discoveryPort: network.configuration.serviceDiscoveryPort
)

let remoteSession = try await client.connect(
    toRemoteServicesUsing: network,
    discoveryPort: network.configuration.serviceDiscoveryPort
)
try await remoteSession.launchApplication(
    bundleIdentifier: "com.example.app",
    options: ApplicationLaunchOptions(
        arguments: ["--diagnostic"],
        environment: ["EXAMPLE_MODE": "test"],
        terminateExistingProcess: true
    )
)

print("Device:", network.configuration.deviceAddress)
print("RSD port:", network.configuration.serviceDiscoveryPort)
print("Gateway:", "\(gateway.host):\(gateway.port)")
```

`loadOrCreate(at:)` writes a binary property list with mode `0600` and returns
the same identity on later launches. The first trust attempt may require the
user to approve the identity on the iPhone; later attempts verify the stored
identity without repeating enrollment.

`CoreDeviceUserspaceGateway` accepts the 20-byte destination preamble used by
userspace-aware device tools: the device's 16-byte IPv6 address followed by a
little-endian 32-bit service port. Keep the listener on loopback unless the
application adds its own access control.

The CLI owns the same lifecycle and prints a newline-delimited JSON endpoint
after the tunnel and trust checks are ready:

```bash
rorkdevice tunnel start \
  --udid 00008140-000000000000001C \
  --identity remote-pairing.plist
```

## Device Diagnostics

The CLI can replace common USB discovery and Lockdown diagnostic helpers
without loading a separate device-communication library:

```bash
# List only devices physically attached over USB.
rorkdevice list --usb

# Preserve every usbmux route and its normalized transport in JSON.
rorkdevice list --details --json

# Stream attach and detach events as newline-delimited JSON.
rorkdevice watch --json

# Verify that the stored host pairing authenticates the expected device.
rorkdevice pairing validate \
  --udid 00008140-000000000000001C

# Establish or repair host trust and save the accepted record through usbmux.
rorkdevice pairing establish \
  --udid 00008140-000000000000001C

# Export the complete trusted pairing property list to stdout or a file.
rorkdevice pairing export \
  --udid 00008140-000000000000001C \
  --output pairing.plist

# Revoke this host's trust and delete its stored pairing record.
rorkdevice pairing remove \
  --udid 00008140-000000000000001C

# Return the scalar Lockdown value dictionary with its original key names.
rorkdevice info \
  --udid 00008140-000000000000001C \
  --json

# Read Developer Mode without changing device state.
rorkdevice developer-mode status \
  --udid 00008140-000000000000001C \
  --json

# Reveal the user-controlled Developer Mode setting.
rorkdevice developer-mode reveal \
  --udid 00008140-000000000000001C
```

`pairing establish` is the only command above that can display the iPhone Trust
dialog. It reuses one generated host identity while waiting for the user, then
saves the device-issued escrow material only after acceptance. Pairing export
and validation never initiate trust. `pairing remove` revokes the identity from
the device before deleting the local record, so a rejected device-side request
does not discard the credentials needed to retry. Developer Mode status and
reveal also leave enablement and any required device restart under the user's
control.

## Direct Remote-Pairing Tunnel

For applications that already have a direct remote-pairing control endpoint,
`RemotePairingTunnel` verifies an accepted identity, negotiates an encrypted
private IPv6 link, and returns the network parameters needed by the
application's packet interface:

```swift
import Foundation
import RorkDevice

guard RemotePairingTunnel.isSupported else {
    throw RorkDeviceError.secureSessionUnsupported
}

let tunnel = try await RemotePairingTunnel.connect(
    to: "10.7.0.1",
    using: identity
)
defer { tunnel.close() }

let network = tunnel.configuration
print("Host address:", network.hostAddress)
print("Device address:", network.deviceAddress)
print("MTU:", network.maximumTransmissionUnit)

if let cipherSuite = tunnel.tlsCipherSuite {
    print("TLS cipher suite:", cipherSuite)
}
```

`RemotePairingTunnel` exchanges complete IPv6 packets through
`sendPacket(_:)` and `receivePacket()`. The application must configure a packet
interface from `configuration` and continuously bridge packets between that
interface and the tunnel. After the route to `deviceAddress` is active, connect
to the negotiated Remote Service Discovery endpoint:

```swift
let session = try await DeviceClient().connect(
    toRemoteServicesAt: network.deviceAddress,
    port: network.serviceDiscoveryPort
)
let applications = try await session.installedApplications()
```

The returned `DeviceSession` retains the discovery connection, but the
application must also retain `RemotePairingTunnel` for as long as it uses any
advertised service. Network Extension integrations on Apple platforms can use
`connect(to:port:using:through:requestedMaximumTransmissionUnit:timeout:)` to
bind the control and TLS connections to a specific `NWInterface`.

The direct remote-pairing path remains independent from the Lockdown
CoreDevice userspace network. Applications can choose the route appropriate to
their process and platform while reusing the same identity, trust, and
`DeviceSession` APIs.

## Platform Support

The package currently targets macOS 13 or later and iOS 16 or later. Lockdown
secure-session upgrades use SwiftNIO SSL on the package's SwiftNIO transports.
Remote-pairing TLS-PSK connections use the Apple Network.framework and
Security.framework backend described below.

`RemotePairingTunnel.isSupported` reports whether the bundled remote-pairing
transport is available in the current process. Calling `connect` when it is not
available throws `RorkDeviceError.secureSessionUnsupported` before opening a
network connection.

Platform-specific remote-pairing transport selection is isolated behind an
internal boundary so a portable backend can be added later without changing
the high-level tunnel or `DeviceSession` APIs. The current release does not
include a Windows or Linux backend.

## Usage

`rorkdevice` uses Swift ArgumentParser. Commands are grouped by the device
workflow they drive:

```bash
rorkdevice list
rorkdevice list --details --json
rorkdevice watch --json
rorkdevice pairing establish --udid DEVICE-UDID
rorkdevice pairing export --udid DEVICE-UDID --output pairing.plist
rorkdevice pairing remove --udid DEVICE-UDID
rorkdevice pairing validate --udid DEVICE-UDID
rorkdevice developer-mode status --udid DEVICE-UDID --json
rorkdevice info --pairing-record pairing.plist
rorkdevice files list / --pairing-record pairing.plist
rorkdevice files list / --pairing-record pairing.plist --json
rorkdevice files info /PublicStaging --pairing-record pairing.plist --json
rorkdevice files list / --bundle-identifier com.example.app --pairing-record pairing.plist
rorkdevice apps list --pairing-record pairing.plist
rorkdevice apps list --pairing-record pairing.plist --json
rorkdevice launch com.example.app --kill-existing \
  --userspace-device-address fd92:fbe0:acf3::2 \
  --userspace-gateway-port 60112 \
  --remote-service-discovery-port 54130
rorkdevice terminate com.example.app \
  --userspace-device-address fd92:fbe0:acf3::2 \
  --userspace-gateway-port 60112 \
  --remote-service-discovery-port 54130
rorkdevice profiles install Profile.mobileprovision --pairing-record pairing.plist
rorkdevice profiles copy --output-directory Profiles --pairing-record pairing.plist
rorkdevice profiles remove PROFILE-UUID --pairing-record pairing.plist
rorkdevice install App.ipa --bundle-identifier com.example.app --pairing-record pairing.plist
rorkdevice uninstall com.example.app --pairing-record pairing.plist
rorkdevice remote-pairing trust --identity selfIdentity.plist --device-address fd01:172:3c68::1 --discovery-port 54130 --gateway-port 60106
rorkdevice tunnel start --udid DEVICE-UDID --identity selfIdentity.plist
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
  watch                   Watch usbmux device attach and detach events.
  info                    Print basic Lockdown device information.
  pairing                 Validate the host pairing used by Lockdown.
  developer-mode          Prepare Developer Mode setup on an iOS device.
  files                   Manage files through AFC or HouseArrest.
  apps                    Manage installed apps.
  install                 Install an IPA.
  uninstall               Uninstall an app by bundle identifier.
  profiles                Manage provisioning profiles.
  remote-pairing          Manage the identity used by CoreDevice remote pairing.
  tunnel                  Open and expose CoreDevice packet tunnels.

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
