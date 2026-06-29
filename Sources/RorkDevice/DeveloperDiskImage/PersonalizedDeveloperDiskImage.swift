import Crypto
import Foundation

/// Hardware values returned by the personalized image-mounter service.
struct PersonalizationIdentifiers {
    /// Board identifier used to select a build identity.
    let boardID: UInt64

    /// Chip identifier used to select a build identity.
    let chipID: UInt64

    /// Apple security domain used to select a build identity.
    let securityDomain: UInt64

    /// Additional `Ap,` values copied into Apple TSS requests.
    let additionalTSSParameters: [String: Any]
}

/// One hardware-specific build identity from `BuildManifest.plist`.
struct DeveloperDiskImageBuildIdentity {
    /// Board identifier represented by this build identity.
    let boardID: UInt64

    /// Chip identifier represented by this build identity.
    let chipID: UInt64

    /// Apple security domain represented by this build identity.
    let securityDomain: UInt64

    /// Complete build-identity property list used to populate Apple TSS fields.
    let propertyList: [String: Any]

    /// Manifest entries eligible for the Apple TSS ticket request.
    let manifestEntries: [String: Any]
}

/// Files and manifest values selected for one connected device.
struct PersonalizedDeveloperDiskImagePayload {
    /// Personalized disk image selected by the build identity.
    let imageURL: URL

    /// Validated SHA-384 digest sent to the device and Apple TSS.
    let imageDigest: Data

    /// Trust cache paired with the personalized disk image.
    let trustCacheURL: URL

    /// Build identity used to request or reuse a personalization ticket.
    let buildIdentity: DeveloperDiskImageBuildIdentity
}

/// Parsed iOS 17+ personalized Developer Disk Image Restore directory.
struct PersonalizedDeveloperDiskImage {
    /// Root containing the build manifest and all referenced files.
    private let restoreDirectory: URL

    /// Hardware-specific identities decoded from `BuildManifest.plist`.
    private let buildIdentities: [[String: Any]]

    /// Parses and validates the manifest structure in a Restore directory.
    init(contentsOf restoreDirectory: URL) throws {
        let restoreDirectory = restoreDirectory.standardizedFileURL
        let manifestURL = restoreDirectory.appendingPathComponent(
            "BuildManifest.plist"
        )
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            throw RorkDeviceError.invalidInput(
                "Could not read Developer Disk Image BuildManifest.plist: \(error.localizedDescription)"
            )
        }
        guard let manifest = try PropertyListCodec.decode(manifestData)
            as? [String: Any],
            let buildIdentities = manifest["BuildIdentities"]
                as? [[String: Any]],
            !buildIdentities.isEmpty
        else {
            throw RorkDeviceError.invalidInput(
                "Developer Disk Image BuildManifest.plist does not contain build identities."
            )
        }
        self.restoreDirectory = restoreDirectory
        self.buildIdentities = buildIdentities
    }

    /// Selects and authenticates the files for the connected hardware.
    ///
    /// - Throws: An input error when no build identity matches, a manifest
    ///   entry is incomplete, a path escapes `Restore`, or a digest differs.
    func payload(
        matching identifiers: PersonalizationIdentifiers
    ) throws -> PersonalizedDeveloperDiskImagePayload {
        guard let values = buildIdentities.first(where: {
            propertyListUInt64($0["ApBoardID"]) == identifiers.boardID
                && propertyListUInt64($0["ApChipID"]) == identifiers.chipID
                && propertyListUInt64($0["ApSecurityDomain"])
                    == identifiers.securityDomain
        }),
            let manifest = values["Manifest"] as? [String: Any]
        else {
            throw RorkDeviceError.invalidInput(
                "The Developer Disk Image does not support board \(hexadecimal(identifiers.boardID)), chip \(hexadecimal(identifiers.chipID)), security domain \(identifiers.securityDomain)."
            )
        }

        let imageEntry = manifest["PersonalizedDMG"]
            ?? manifest["PersonalizedDmg"]
        guard let imageEntry = imageEntry as? [String: Any] else {
            throw RorkDeviceError.invalidInput(
                "Developer Disk Image manifest is missing PersonalizedDMG."
            )
        }
        guard let trustCacheEntry = manifest["LoadableTrustCache"]
            as? [String: Any]
        else {
            throw RorkDeviceError.invalidInput(
                "Developer Disk Image manifest is missing LoadableTrustCache."
            )
        }

        let imageURL = try fileURL(for: imageEntry)
        let trustCacheURL = try fileURL(for: trustCacheEntry)
        let imageDigest = try validatedDigest(
            for: imageURL,
            manifestEntry: imageEntry,
            description: "Developer Disk Image"
        )
        _ = try validatedDigest(
            for: trustCacheURL,
            manifestEntry: trustCacheEntry,
            description: "Developer Disk Image trust cache"
        )
        return PersonalizedDeveloperDiskImagePayload(
            imageURL: imageURL,
            imageDigest: imageDigest,
            trustCacheURL: trustCacheURL,
            buildIdentity: DeveloperDiskImageBuildIdentity(
                boardID: identifiers.boardID,
                chipID: identifiers.chipID,
                securityDomain: identifiers.securityDomain,
                propertyList: values,
                manifestEntries: manifest
            )
        )
    }

    /// Resolves one manifest path without allowing traversal or symlink escape.
    private func fileURL(for entry: [String: Any]) throws -> URL {
        guard let info = entry["Info"] as? [String: Any],
            let relativePath = info["Path"] as? String,
            !relativePath.isEmpty
        else {
            throw RorkDeviceError.invalidInput(
                "Developer Disk Image manifest entry is missing its file path."
            )
        }
        guard !relativePath.hasPrefix("/") else {
            throw escapedPathError(relativePath)
        }

        let candidate = restoreDirectory.appendingPathComponent(relativePath)
            .standardizedFileURL
        guard candidate.isContained(in: restoreDirectory) else {
            throw escapedPathError(relativePath)
        }

        // Standardizing removes `..`, while resolving symlinks prevents a
        // manifest-controlled link inside Restore from reaching another tree.
        let resolvedRoot = restoreDirectory.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard resolvedCandidate.isContained(in: resolvedRoot) else {
            throw escapedPathError(relativePath)
        }
        let values = try resolvedCandidate.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        )
        guard values.isRegularFile == true,
            values.isSymbolicLink != true
        else {
            throw RorkDeviceError.invalidInput(
                "Developer Disk Image manifest file is missing or is not a regular file: \(relativePath)"
            )
        }
        return resolvedCandidate
    }

    /// Builds the consistent diagnostic used for every path-containment check.
    private func escapedPathError(_ path: String) -> RorkDeviceError {
        .invalidInput(
            "Developer Disk Image manifest path escapes the Restore directory: \(path)"
        )
    }
}

/// Returns an exact integer from plist numbers or hexadecimal/decimal strings.
func propertyListUInt64(_ value: Any?) -> UInt64? {
    if let value = value as? UInt64 {
        return value
    }
    if let value = value as? NSNumber {
        let integer = value.uint64Value
        guard value.doubleValue == Double(integer) else {
            return nil
        }
        return integer
    }
    guard let value = value as? String else {
        return nil
    }
    if value.lowercased().hasPrefix("0x") {
        return UInt64(value.dropFirst(2), radix: 16)
    }
    return UInt64(value)
}

/// Produces the uppercase hexadecimal notation used in hardware diagnostics.
private func hexadecimal(_ value: UInt64) -> String {
    "0x\(String(value, radix: 16, uppercase: true))"
}

/// Validates one extracted payload against its SHA-384 manifest digest.
private func validatedDigest(
    for fileURL: URL,
    manifestEntry: [String: Any],
    description: String
) throws -> Data {
    guard let expectedDigest = manifestEntry["Digest"] as? Data,
        expectedDigest.count == SHA384.Digest.byteCount
    else {
        throw RorkDeviceError.invalidInput(
            "\(description) manifest entry has an invalid SHA-384 digest."
        )
    }
    let digest = try sha384Digest(of: fileURL)
    guard digest == expectedDigest else {
        throw RorkDeviceError.invalidInput(
            "\(description) digest does not match BuildManifest.plist."
        )
    }
    return digest
}

/// Hashes a file incrementally so disk images are not loaded into memory.
func sha384Digest(of fileURL: URL) throws -> Data {
    let handle = try FileHandle(forReadingFrom: fileURL)
    defer {
        try? handle.close()
    }
    var hasher = SHA384()
    while let chunk = try handle.read(upToCount: 1024 * 1024),
        !chunk.isEmpty
    {
        hasher.update(data: chunk)
    }
    return Data(hasher.finalize())
}

private extension URL {
    /// Checks path containment on component boundaries after standardization.
    func isContained(in directory: URL) -> Bool {
        let directoryPath = directory.standardizedFileURL.path
        let candidatePath = standardizedFileURL.path
        return candidatePath == directoryPath
            || candidatePath.hasPrefix(directoryPath + "/")
    }
}
