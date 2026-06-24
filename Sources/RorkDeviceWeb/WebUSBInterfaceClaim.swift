/// Claims a WebUSB interface, resetting the device once when Chrome retains a
/// claim from a terminated page.
///
/// Recovery is intentionally limited to interface-ownership failures. Retrying
/// descriptor, configuration, or transport errors would hide a different
/// invalid state and could repeat an unsafe operation.
@MainActor
func claimWebUSBInterface(
    using claim: () async throws -> Void,
    recoveringWith recover: () async throws -> Void
) async throws {
    do {
        try await claim()
    } catch let error as WebUSBError {
        switch error {
        case .interfaceInUse:
            break
        case .browserOperationFailed(let operation, let message)
            where operation == "claimInterface"
                && message.lowercased().contains(
                    "unable to claim interface"
                ):
            break
        default:
            throw error
        }
        try await recover()
        try await claim()
    }
}
