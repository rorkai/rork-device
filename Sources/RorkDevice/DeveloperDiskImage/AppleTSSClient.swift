import Foundation

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// HTTP response shape used to test TSS behavior without network access.
struct TSSHTTPResponse: Sendable {
    let statusCode: Int
    let body: Data
}

/// Minimal HTTP boundary for Apple's TSS request.
protocol TSSHTTPTransport: Sendable {
    func response(for request: URLRequest) async throws -> TSSHTTPResponse
}

/// Ticket boundary used by the image-mounting workflow.
protocol DeveloperDiskImageTicketRequesting {
    func ticket(
        for identity: DeveloperDiskImageIdentity,
        identifiers: PersonalizationIdentifiers,
        nonce: Data,
        ecid: UInt64
    ) async throws -> Data
}

/// URLSession transport that retains the platform's default certificate checks.
private struct URLSessionTSSHTTPTransport: TSSHTTPTransport {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 60
        session = URLSession(configuration: configuration)
    }

    func response(for request: URLRequest) async throws -> TSSHTTPResponse {
        let (body, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw RorkDeviceError.transport(
                "Apple TSS did not return an HTTP response."
            )
        }
        return TSSHTTPResponse(
            statusCode: response.statusCode,
            body: body
        )
    }
}

/// Builds the property list accepted by Apple's TSS endpoint.
struct AppleTSSRequest {
    let propertyList: [String: Any]

    init(
        identity: DeveloperDiskImageIdentity,
        identifiers: PersonalizationIdentifiers,
        nonce: Data,
        ecid: UInt64,
        requestIdentifier: UUID = UUID()
    ) throws {
        let parameters: [String: Any] = [
            "ApProductionMode": true,
            "ApSecurityMode": true,
            "ApSupportsImg4": true,
        ]
        var propertyList: [String: Any] = [
            "@ApImg4Ticket": true,
            "@BBTicket": true,
            "@HostPlatformInfo": "mac",
            "@VersionInfo": "libauthinstall-1104.0.9",
            "@UUID": requestIdentifier.uuidString.uppercased(),
            "ApBoardID": identifiers.boardID,
            "ApChipID": identifiers.chipID,
            "ApECID": ecid,
            "ApNonce": nonce,
            "ApProductionMode": true,
            "ApSecurityDomain": identifiers.securityDomain,
            "ApSecurityMode": true,
            "SepNonce": Data(repeating: 0, count: 20),
            "UID_MODE": false,
        ]

        for (key, value) in identity.values
        where key == "UniqueBuildID" || key.hasPrefix("Ap,") {
            propertyList[key] = value
        }
        for (key, value) in identifiers.additionalValues
        where key.hasPrefix("Ap,") {
            propertyList[key] = value
        }
        for (key, value) in identity.manifest {
            guard let entry = value as? [String: Any],
                plistBoolean(entry["Trusted"]) == true,
                entry["Info"] is [String: Any]
            else {
                continue
            }
            propertyList[key] = try ticketEntry(
                from: entry,
                parameters: parameters
            )
        }
        self.propertyList = propertyList
    }
}

/// Parsed response from Apple's key-value-prefixed TSS protocol.
struct AppleTSSResponse {
    let ticket: Data

    init(data: Data) throws {
        guard data.count <= 16 * 1024 * 1024 else {
            throw RorkDeviceError.protocolViolation(
                "Apple TSS response exceeded the 16 MiB limit."
            )
        }
        guard let response = String(data: data, encoding: .utf8) else {
            throw RorkDeviceError.protocolViolation(
                "Apple TSS response was not UTF-8."
            )
        }
        let status = try field(
            named: "STATUS",
            in: response
        )
        guard let statusCode = Int(status) else {
            throw RorkDeviceError.protocolViolation(
                "Apple TSS response contained an invalid status."
            )
        }
        let message = try field(
            named: "MESSAGE",
            in: response
        )
        guard statusCode == 0, message == "SUCCESS" else {
            throw RorkDeviceError.protocolViolation(
                "Apple TSS rejected the request with status \(statusCode): \(message)"
            )
        }
        let requestString = try trailingField(
            named: "REQUEST_STRING",
            in: response
        )
        let decoded: Any
        do {
            decoded = try PropertyListCodec.decode(Data(requestString.utf8))
        } catch {
            guard let percentDecoded = requestString.removingPercentEncoding,
                percentDecoded != requestString
            else {
                throw RorkDeviceError.protocolViolation(
                    "Apple TSS response contained an invalid ticket property list."
                )
            }
            do {
                decoded = try PropertyListCodec.decode(
                    Data(percentDecoded.utf8)
                )
            } catch {
                throw RorkDeviceError.protocolViolation(
                    "Apple TSS response contained an invalid ticket property list."
                )
            }
        }
        guard let propertyList = decoded as? [String: Any],
            let ticket = propertyList["ApImg4Ticket"] as? Data,
            !ticket.isEmpty
        else {
            throw RorkDeviceError.protocolViolation(
                "Apple TSS response did not contain ApImg4Ticket."
            )
        }
        self.ticket = ticket
    }
}

/// Requests personalized Developer Disk Image tickets from Apple.
struct AppleTSSClient: DeveloperDiskImageTicketRequesting {
    private static let endpoint = URL(
        string: "https://gs.apple.com/TSS/controller?action=2"
    )!

    private let transport: any TSSHTTPTransport

    init(transport: any TSSHTTPTransport = URLSessionTSSHTTPTransport()) {
        self.transport = transport
    }

    func ticket(
        for identity: DeveloperDiskImageIdentity,
        identifiers: PersonalizationIdentifiers,
        nonce: Data,
        ecid: UInt64
    ) async throws -> Data {
        let propertyList = try AppleTSSRequest(
            identity: identity,
            identifiers: identifiers,
            nonce: nonce,
            ecid: ecid
        ).propertyList
        let body = try PropertyListCodec.encode(propertyList)
        var request = URLRequest(url: Self.endpoint)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue(
            "no-cache",
            forHTTPHeaderField: "Cache-Control"
        )
        request.setValue(
            "text/xml; charset=utf-8",
            forHTTPHeaderField: "Content-Type"
        )
        request.setValue(
            "InetURL/1.0",
            forHTTPHeaderField: "User-Agent"
        )

        let response: TSSHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch let error as RorkDeviceError {
            throw error
        } catch {
            throw RorkDeviceError.transport(
                "Apple TSS request failed: \(error.localizedDescription)"
            )
        }
        guard response.statusCode == 200 else {
            throw RorkDeviceError.transport(
                "Apple TSS returned HTTP status \(response.statusCode)."
            )
        }
        return try AppleTSSResponse(data: response.body).ticket
    }
}

/// Removes manifest-only metadata and applies production/security rules.
private func ticketEntry(
    from manifestEntry: [String: Any],
    parameters: [String: Any]
) throws -> [String: Any] {
    var ticketEntry = manifestEntry
    guard let info = ticketEntry.removeValue(forKey: "Info")
        as? [String: Any]
    else {
        throw RorkDeviceError.invalidInput(
            "Developer Disk Image manifest entry is missing Info."
        )
    }
    if ticketEntry["Digest"] == nil {
        ticketEntry["Digest"] = Data()
    }
    if let rules = info["RestoreRequestRules"] as? [[String: Any]],
        !rules.isEmpty
    {
        for rule in rules {
            guard let conditions = rule["Conditions"]
                as? [String: Any],
                conditions.allSatisfy({ condition in
                    guard let actualValue = restoreRuleValue(
                        for: condition.key,
                        parameters: parameters
                    ) else {
                        return false
                    }
                    return propertyListValuesEqual(
                        actualValue,
                        condition.value
                    )
                }),
                let actions = rule["Actions"] as? [String: Any]
            else {
                continue
            }
            for (key, value) in actions {
                if let number = value as? NSNumber,
                    number.intValue == 255
                {
                    continue
                }
                ticketEntry[key] = value
            }
        }
    } else {
        ticketEntry["EPRO"] = true
        ticketEntry["ESEC"] = true
    }
    return ticketEntry
}

/// Maps Apple restore-rule condition names to the active TSS parameters.
private func restoreRuleValue(
    for condition: String,
    parameters: [String: Any]
) -> Any? {
    switch condition {
    case "ApRawProductionMode", "ApCurrentProductionMode":
        return parameters["ApProductionMode"]
    case "ApRawSecurityMode":
        return parameters["ApSecurityMode"]
    case "ApRequiresImage4":
        return parameters["ApSupportsImg4"]
    case "ApDemotionPolicyOverride":
        return parameters["DemotionPolicy"]
    case "ApInRomDFU":
        return parameters["ApInRomDFU"]
    default:
        return nil
    }
}

/// Compares Foundation property-list scalars without coercing their types.
private func propertyListValuesEqual(_ lhs: Any, _ rhs: Any) -> Bool {
    guard let lhs = lhs as? NSObject,
        let rhs = rhs as? NSObject
    else {
        return false
    }
    return lhs.isEqual(rhs)
}

/// Extracts a key-value field that ends at the next ampersand.
private func field(named name: String, in response: String) throws -> String {
    let prefix = "\(name)="
    guard let start = response.range(of: prefix)?.upperBound else {
        throw RorkDeviceError.protocolViolation(
            "Apple TSS response was missing \(name)."
        )
    }
    let suffix = response[start...]
    let end = suffix.firstIndex(of: "&") ?? response.endIndex
    return String(response[start..<end])
}

/// Extracts the final field without treating XML entities as separators.
private func trailingField(
    named name: String,
    in response: String
) throws -> String {
    let prefix = "\(name)="
    guard let start = response.range(of: prefix)?.upperBound else {
        throw RorkDeviceError.protocolViolation(
            "Apple TSS response was missing \(name)."
        )
    }
    return String(response[start...])
}

/// Reads a plist Boolean while preserving `false`.
private func plistBoolean(_ value: Any?) -> Bool? {
    if let value = value as? Bool {
        return value
    }
    return (value as? NSNumber)?.boolValue
}
