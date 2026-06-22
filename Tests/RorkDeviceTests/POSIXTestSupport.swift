#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Native socket-type value used by cross-platform test servers.
///
/// Darwin imports `SOCK_STREAM` as an integer, while Glibc imports it as a
/// typed C enum. Centralizing the conversion keeps the socket fixtures focused
/// on the protocol behavior they exercise.
let testStreamSocketType: Int32 = {
    #if canImport(Glibc)
    Int32(SOCK_STREAM.rawValue)
    #else
    SOCK_STREAM
    #endif
}()
