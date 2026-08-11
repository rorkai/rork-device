import Crypto
import Foundation

/// This value contains hardware data returned by the image-mounter service.
struct PersonalizationIdentifiers {
    /// This board identifier selects a build identity.
    let boardID: UInt64

    /// This chip identifier selects a build identity.
    let chipID: UInt64

    /// This Apple security domain selects a build identity.
    let securityDomain: UInt64

    /// These additional `Ap,` values are copied into Apple TSS requests.
    let additionalTSSParameters: [String: Any]
}

/// This value contains one hardware identity from `BuildManifest.plist`.
struct DeveloperDiskImageBuildIdentity {
    /// This build identity represents the board identifier.
    let boardID: UInt64

    /// This build identity represents the chip identifier.
    let chipID: UInt64

    /// This build identity represents the Apple security domain.
    let securityDomain: UInt64

    /// This complete property list populates Apple TSS fields.
    let propertyList: [String: Any]

    /// These manifest entries are eligible for the Apple TSS ticket request.
    let manifestEntries: [String: Any]
}

/// This value contains files and manifest data selected for one device.
struct PersonalizedDeveloperDiskImagePayload {
    /// The build identity selects this personalized disk image.
    let imageURL: URL

    /// This validated SHA-384 digest is sent to the device and Apple TSS.
    let imageDigest: Data

    /// This trust cache is paired with the personalized disk image.
    let trustCacheURL: URL

    /// This build identity requests or reuses a personalization ticket.
    let buildIdentity: DeveloperDiskImageBuildIdentity
}

/// This value parses an iOS 17+ personalized Restore directory.
struct PersonalizedDeveloperDiskImage {
    /// This root contains the build manifest and all referenced files.
    private let restoreDirectory: URL

    /// These hardware identities are decoded from `BuildManifest.plist`.
    private let buildIdentities: [[String: Any]]

    /// Parses and validates the manifest structure in a Restore directory.
    ///
    /// - Parameter restoreDirectory: This root contains `BuildManifest.plist`.
    /// - Throws: The initializer throws `RorkDeviceError.fileSystem` when the
    ///   manifest cannot be read, or `RorkDeviceError.invalidInput` when its
    ///   structure is invalid.
    init(contentsOf restoreDirectory: URL) throws {
        let restoreDirectory = restoreDirectory.standardizedFileURL
        let manifestURL = restoreDirectory.appendingPathComponent(
            "BuildManifest.plist"
        )
        let manifestData: Data
        do {
            manifestData = try Data(contentsOf: manifestURL)
        } catch {
            throw RorkDeviceError.fileSystem(
                path: manifestURL.path,
                reason: error.localizedDescription
            )
        }
        let decodedManifest: Any
        do {
            decodedManifest = try PropertyListCodec.decode(manifestData)
        } catch {
            throw RorkDeviceError.invalidInput(
                "Developer Disk Image BuildManifest.plist could not be decoded: \(error.localizedDescription)"
            )
        }
        guard let manifest = decodedManifest as? [String: Any],
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
    /// - Parameter identifiers: These hardware values select a build identity.
    /// - Returns: The result contains a validated image, trust cache, and identity.
    /// - Throws: The method throws an input error for mismatched identity,
    ///   incomplete manifest data, escaped paths, or invalid digests. It throws
    ///   a filesystem error when a referenced file cannot be inspected.
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
    ///
    /// - Parameter entry: This manifest entry contains an `Info.Path` value.
    /// - Returns: The canonical regular file remains inside the Restore directory.
    /// - Throws: The method throws an input error for unsafe or malformed paths,
    ///   or a filesystem error when local metadata cannot be read.
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

        let values: URLResourceValues
        do {
            values = try candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
            )
        } catch {
            throw RorkDeviceError.fileSystem(
                path: candidate.path,
                reason: error.localizedDescription
            )
        }
        guard values.isRegularFile == true,
            values.isSymbolicLink != true
        else {
            throw RorkDeviceError.invalidInput(
                "Developer Disk Image manifest file is missing or is not a regular file: \(relativePath)"
            )
        }

        // Standardizing removes `..`, while resolving parent symlinks prevents
        // a regular file inside a linked directory from reaching another tree.
        let resolvedRoot = restoreDirectory.resolvingSymlinksInPath()
        let resolvedCandidate = candidate.resolvingSymlinksInPath()
        guard resolvedCandidate.isContained(in: resolvedRoot) else {
            throw escapedPathError(relativePath)
        }
        return resolvedCandidate
    }

    /// Builds the consistent diagnostic used for every path-containment check.
    ///
    /// - Parameter path: The manifest contains this unsafe relative path.
    /// - Returns: The stable input error retains the rejected path.
    private func escapedPathError(_ path: String) -> RorkDeviceError {
        .invalidInput(
            "Developer Disk Image manifest path escapes the Restore directory: \(path)"
        )
    }
}

/// Returns an exact integer from plist numbers or hexadecimal/decimal strings.
///
/// - Parameter value: This property-list scalar is interpreted without rounding.
/// - Returns: The result is exact, or nil for unsupported or fractional input.
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
///
/// - Parameter value: This hardware identifier needs formatting.
/// - Returns: The uppercase value includes a `0x` prefix.
private func hexadecimal(_ value: UInt64) -> String {
    "0x\(String(value, radix: 16, uppercase: true))"
}

/// Validates one extracted payload against its SHA-384 manifest digest.
///
/// - Parameters:
///   - fileURL: This extracted file needs authentication.
///   - manifestEntry: This entry carries the expected digest.
///   - description: Failures use this human-readable file name.
/// - Returns: The result is the verified SHA-384 digest.
/// - Throws: The function throws an input error for a missing or mismatched
///   digest, or a filesystem error when the file cannot be read.
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
///
/// - Parameter fileURL: This local file needs hashing.
/// - Returns: The result contains raw SHA-384 digest bytes.
/// - Throws: The function throws `RorkDeviceError.fileSystem` when the file
///   cannot be read, or `CancellationError` when the caller cancels hashing.
func sha384Digest(of fileURL: URL) throws -> Data {
    let handle: FileHandle
    do {
        handle = try FileHandle(forReadingFrom: fileURL)
    } catch {
        throw RorkDeviceError.fileSystem(
            path: fileURL.path,
            reason: error.localizedDescription
        )
    }
    defer {
        try? handle.close()
    }
    var hasher = SHA384()
    while true {
        try Task.checkCancellation()
        let chunk: Data
        do {
            chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
        } catch {
            throw RorkDeviceError.fileSystem(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
        if chunk.isEmpty {
            break
        }
        hasher.update(data: chunk)
    }
    return Data(hasher.finalize())
}

private extension URL {
    /// Checks path containment on component boundaries after standardization.
    func isContained(in directory: URL) -> Bool {
        standardizedFileURL.pathComponents.starts(
            with: directory.standardizedFileURL.pathComponents
        )
    }
}
