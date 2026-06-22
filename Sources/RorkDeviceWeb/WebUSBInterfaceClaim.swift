/// Claims a WebUSB interface, resetting the device once when Chrome retains a
/// claim from a terminated page.
///
/// Recovery is intentionally limited to `claimInterface` browser failures.
/// Retrying descriptor, configuration, or transport errors would hide a
/// different invalid state and could repeat an unsafe operation.
@MainActor
func claimWebUSBInterface(
    using claim: () async throws -> Void,
    recoveringWith recover: () async throws -> Void
) async throws {
    do {
        try await claim()
    } catch let error as WebUSBError {
        guard case .browserOperationFailed(let operation, _) = error,
            operation == "claimInterface"
        else {
            throw error
        }
        try await recover()
        try await claim()
    }
}
