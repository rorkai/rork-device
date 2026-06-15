# Roadmap

`rork-device` is a modern Swift implementation of iOS device communication
protocols. The project grows by production-grade vertical slices: each release
should expose useful public APIs, CLI workflows where appropriate, protocol
tests, and clear limitations.

## 0.1.0: Device Sessions And App Installation

The first release focuses on the app-install workflows used by developer tools:

- Parse existing pairing records.
- Connect through local `usbmuxd` or a direct Lockdown endpoint.
- Query basic device information through Lockdown.
- Start Lockdown services.
- Upload IPA files or in-memory IPA bytes through AFC staging.
- Install, remove, and copy provisioning profiles through MISAgent.
- List, install, and uninstall applications through InstallationProxy.
- Expose structured progress and errors.
- Upgrade secure Lockdown and service connections on Apple platforms.
- Provide a Swift library and `rorkdevice` CLI.
- Include an opt-in physical-device smoke test for list, info, profile
  install, IPA install, and IPA uninstall.

Out of scope for 0.1.0:

- Creating new pairings or driving the trust dialog.
- Device add/remove event streams.
- Wi-Fi sync discovery.
- Developer disk image mounting.
- Debugserver, syslog, crash reports, screenshots, backup, and restore.
- Windows support.

Secure-session upgrades are represented by the public `SecureSessionUpgrader`
protocol. The current default inserts SwiftNIO SSL into the package's existing
SwiftNIO channels, and callers can provide another backend without changing the
high-level install flow.

## 0.2.0: Device Events And File Access

The second release expands beyond the app-install vertical slice:

- Stream device attach and detach events through usbmux.
- Expose high-level file operations on AFC.
- Vend application Documents and containers through HouseArrest.
- Add CLI commands for watching devices and managing files.
- Keep pairing creation as the next trust-flow milestone so certificate
  generation, trust prompts, persistence, and physical-device validation can be
  designed together.

## 0.3.0: Remote Pairing And Live Remote Services

The third release adds the modern device-service route used after remote
pairing:

- Authenticate with a remote-pairing identity that the device has already
  accepted.
- Perform pair verification and derive the pre-shared key for a TLS 1.2
  CDTunnel connection.
- Negotiate the private IPv6 addresses, network mask, MTU, and Remote Service
  Discovery port for the tunnel.
- Send and receive complete IPv6 packets through the encrypted tunnel.
- Expose the negotiated TLS cipher suite as typed diagnostic metadata.
- Open Remote Service Discovery over HTTP/2 and RemoteXPC.
- Retain the live discovery advertisement while connecting to its service
  ports.
- Reuse `DeviceSession` workflows for AFC, HouseArrest, MISAgent,
  InstallationProxy, and heartbeat services advertised through RSD.
- Isolate platform-specific tunnel transport selection behind an internal
  boundary, with an Apple Network.framework and Security.framework backend.
- Cover pair verification, CDTunnel framing, RemoteXPC, RSD, service check-in,
  and remote-session behavior with protocol-level tests.

Current limitations:

- Remote-pairing identity creation, trust UI, and identity persistence remain
  out of scope. The supplied identity must already be accepted by the device.
- The application must configure and operate the host packet interface that
  routes the negotiated private IPv6 link.
- The bundled TLS-PSK transport is available only when Network.framework and
  Security.framework are present. Unsupported environments fail explicitly
  with `RorkDeviceError.secureSessionUnsupported`.
- Remote pairing and RSD are library APIs; the CLI continues to use usbmux or a
  direct Lockdown endpoint.

## Future Milestones

The next milestones should expand service coverage without weakening the public
API boundaries:

- Pairing creation, validation, unpairing, and pairing-record storage.
- Portable cryptography and TLS-PSK transports for remote pairing on additional
  host platforms.
- Packet-interface adapters for supported host environments.
- Richer usbmuxd discovery and Wi-Fi sync discovery.
- Syslog relay and crash report retrieval.
- Developer image mounting, screenshots, and debugserver proxying.
- Backup, restore, diagnostics, and recovery services.

## Compatibility Strategy

Compatibility is validated with protocol fixtures, fake service peers, and
opt-in physical-device checks while keeping the implementation Swift-first and
independently structured. Platform-dependent features expose an availability
check and return a typed unsupported error instead of failing through an
unavailable framework or inaccessible API.
