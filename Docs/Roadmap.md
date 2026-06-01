# Roadmap

`rork-device` is a modern Swift implementation of iOS device communication
protocols. The project grows by production-grade vertical slices: each release
should expose useful public APIs, matching CLI commands, protocol tests, and
clear limitations.

## 0.1.0: Device Sessions And App Installation

The first release focuses on the app-install workflows used by developer tools:

- Parse existing pairing records.
- Connect through local `usbmuxd` or a direct Lockdown endpoint.
- Query basic device information through Lockdown.
- Start Lockdown services.
- Upload IPA files through AFC staging.
- Install and remove provisioning profiles through MISAgent.
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
protocol. The Apple backend is built in for 0.1.0, and additional platform
backends can be added without changing the high-level install flow.

## Future Milestones

The next milestones should expand service coverage without weakening the public
API boundaries:

- Device event streams and richer usbmuxd discovery.
- Syslog relay and crash report retrieval.
- HouseArrest and AFC document/container access.
- Developer image mounting, screenshots, and debugserver proxying.
- Backup, restore, diagnostics, and recovery services.

## Compatibility Strategy

The implementation is independent Swift code. Existing open tools and device
protocol traces are useful compatibility oracles, but source should not be
ported file-by-file from other implementations. Tests should prefer protocol
fixtures, fake service peers, and opt-in physical-device checks.
