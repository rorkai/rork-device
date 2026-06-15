import Foundation

/// Strict numeric conversions for remote-pairing JSON messages.
///
/// Protocol fields arrive through `JSONSerialization`, which represents JSON
/// booleans and numbers as `NSNumber`. These conversions preserve the protocol's
/// integer constraints instead of accepting Objective-C numeric coercions.
enum RemotePairingJSONValue {
    /// Returns a positive 16-bit integer when the JSON value represents one exactly.
    ///
    /// Boolean values, fractions, zero, negative values, and values larger than
    /// `UInt16.max` are rejected.
    static func positiveUInt16(from value: Any?) -> UInt16? {
        guard let number = value as? NSNumber,
              !isBoolean(number),
              let integer = UInt16(exactly: number.doubleValue),
              integer > 0 else {
            return nil
        }
        return integer
    }

    /// Distinguishes JSON booleans from numeric `NSNumber` instances.
    ///
    /// `JSONSerialization` uses the Objective-C boolean encodings `c` and `B`.
    /// Other integral encodings remain eligible for exact conversion.
    private static func isBoolean(_ number: NSNumber) -> Bool {
        switch String(cString: number.objCType) {
        case "c", "B":
            true
        default:
            false
        }
    }
}
