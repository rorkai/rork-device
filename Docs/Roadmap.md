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

## 0.4.0: Remote Trust And Userspace Networking

The fourth release owns the complete unprivileged CoreDevice route for a
USB-connected device:

- Require complete identity material, including the 16-byte identity resolving
  key used by manual pair-setup.
- Generate new Ed25519 identities with independent resolving keys and persist
  them atomically with owner-only permissions.
- Read the trusted Lockdown pairing record directly from local `usbmuxd`.
- Preserve typed pairing rejection reasons instead of treating every error as
  an unknown identity.
- Enter manual pair setup only for authentication and unknown-peer responses.
- Resolve the untrusted pairing service through Remote Service Discovery and
  perform enrollment over RemoteXPC.
- Start `CoreDeviceProxy` through an authenticated Lockdown session and
  negotiate its private IPv6 packet link.
- Run an embedded lwIP IPv6/TCP backend over the packet tunnel.
- Expose device service ports through a loopback gateway compatible with the
  destination-prefixed userspace protocol.
- Represent both the userspace network and an existing external gateway through
  the standard `DeviceTransport` abstraction.
- Open Remote Service Discovery and all advertised service ports through the
  same caller-supplied `DeviceTransport`.
- Launch applications, list running processes, and terminate app processes
  through CoreDevice's direct RemoteXPC app service.
- Add `RemotePairingTrust.establishIfNeeded(for:using:discoveryPort:)` and the
  matching trust progress model.
- Add `rorkdevice tunnel start`, including identity creation, Lockdown pairing
  record loading, tunnel supervision, trust enrollment, and a machine-readable
  ready event.
- Cover SRP-6a, OPACK metadata, RemoteXPC control messages, rejection handling,
  packet forwarding, TCP behavior, gateway framing, and identity persistence
  with deterministic protocol tests and physical-device verification.

Current limitations:

- The embedded userspace backend currently exposes IPv6 TCP streams. It does
  not provide a system packet interface, UDP sockets, or general IP routing.
- The loopback gateway preamble is intentionally compatible with existing
  device tools and is not authenticated; callers should not expose it on an
  untrusted network.
- The long-lived TLS-PSK packet tunnel still uses the Apple transport backend;
  Windows and Linux need additional backends.

## 0.6.0: Host Pairing And Passive Diagnostics

This release completes the local usbmux and Lockdown operations needed by
desktop device-management applications:

- Preserve all usbmux routes and normalized USB or network metadata in
  machine-readable device lists.
- Stream attach and detach events as newline-delimited JSON.
- Generate the RSA certificate hierarchy and private keys required by the
  Lockdown Pair request.
- Keep one candidate host identity stable while polling the device-side Trust
  decision.
- Save accepted pairing records through usbmux and preserve device-issued
  escrow material.
- Export complete pairing records as property lists without narrowing unknown
  fields.
- Validate existing trust without displaying a new Trust dialog.
- Revoke a host identity from the device before deleting its local usbmux
  pairing record.
- Read Developer Mode status passively and retain the explicit reveal command.
- Cover certificate generation, pairing retries, ordered trust removal, record
  persistence, event output, and CLI contracts with deterministic protocol
  tests alongside the existing physical-device checks.

Current limitations:

- Network discovery is limited to routes reported by local usbmux; Bonjour
  Wi-Fi discovery is not implemented independently.
- Windows and Linux support still requires portable usbmux discovery and
  remote-pairing TLS backends.

## Future Milestones

The next milestones should expand service coverage without weakening the public
API boundaries:

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
