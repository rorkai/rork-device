# Third-Party Notices

This distribution includes the open-source components listed below. The
versions shown are the versions resolved by Swift Package Manager for this
release.

The Apache License 2.0 text is available in the repository's
[LICENSE](LICENSE) file. Exact attribution notices and non-Apache license texts
that must accompany binary distributions are preserved under
[ThirdPartyLicenses](ThirdPartyLicenses).

## Apache License 2.0 Components

- [Swift Argument Parser 1.8.1](https://github.com/apple/swift-argument-parser)
- [SwiftNIO 2.100.0-rork.2](https://github.com/rorkai/swift-nio)
- [SwiftNIO SSL 2.37.2-rork.1](https://github.com/rorkai/swift-nio-ssl)
- [Swift Certificates 1.19.1-rork.1](https://github.com/rorkai/swift-certificates)
- [Swift Crypto 4.5.0-rork.1](https://github.com/rorkai/swift-crypto)
- [Swift ASN.1 1.7.1](https://github.com/apple/swift-asn1)
- [Swift Atomics 1.3.0](https://github.com/apple/swift-atomics)
- [Swift Collections 1.6.0](https://github.com/apple/swift-collections)
- [Swift System 1.7.2](https://github.com/apple/swift-system)
- [Swift ZIP Archive 0.8.1-rork.4](https://github.com/rorkai/swift-zip-archive)

The upstream attribution notices that apply to these components and their
incorporated works are reproduced in:

- [SwiftNIO-NOTICE.txt](ThirdPartyLicenses/SwiftNIO-NOTICE.txt)
- [SwiftNIOSSL-NOTICE.txt](ThirdPartyLicenses/SwiftNIOSSL-NOTICE.txt)
- [SwiftCrypto-NOTICE.txt](ThirdPartyLicenses/SwiftCrypto-NOTICE.txt)
- [SwiftCertificates-NOTICE.txt](ThirdPartyLicenses/SwiftCertificates-NOTICE.txt)
- [SwiftASN1-NOTICE.txt](ThirdPartyLicenses/SwiftASN1-NOTICE.txt)

## Other Components

### Windows Static Runtime

The Windows x64 executable statically incorporates the Swift 6.3.3 standard
library and runtime support, Foundation, Dispatch, and Blocks Runtime. These
components use the Apache License 2.0 with the Swift Runtime Library Exception.
The Apache License 2.0 text is included in the package-level `LICENSE`, and
the exception is reproduced in
[SwiftRuntime-EXCEPTION.txt](ThirdPartyLicenses/SwiftRuntime-EXCEPTION.txt).

The executable also incorporates ICU 76.1, curl 8.9.1, zlib 1.3.1, and Brotli
1.1.0 from the pinned SDK. Their legal texts are reproduced in
[ICU-LICENSE.txt](ThirdPartyLicenses/ICU-LICENSE.txt),
[Curl-LICENSE.txt](ThirdPartyLicenses/Curl-LICENSE.txt),
[Zlib-LICENSE.txt](ThirdPartyLicenses/Zlib-LICENSE.txt), and
[Brotli-LICENSE.txt](ThirdPartyLicenses/Brotli-LICENSE.txt).

### BigInt 5.7.0

[BigInt](https://github.com/attaswift/BigInt) is distributed under the MIT
License. The complete license text is reproduced in
[BigInt-LICENSE.md](ThirdPartyLicenses/BigInt-LICENSE.md).

### BoringSSL

SwiftNIO SSL statically incorporates
[BoringSSL](https://boringssl.googlesource.com/boringssl/) source derived from
revision `817ab07ebb53da35afea409ab9328f578492832d`. BoringSSL contains code under
ISC, OpenSSL, SSLeay, and additional compatible license terms. The complete
license file for that revision is reproduced in
[BoringSSL-LICENSE.txt](ThirdPartyLicenses/BoringSSL-LICENSE.txt).

### lwIP 2.2.1

Selected source files from [lwIP](https://github.com/lwip-tcpip/lwip) provide
the IPv6/TCP userspace network backend. The complete BSD-style license text is
reproduced in [lwIP-LICENSE.txt](ThirdPartyLicenses/lwIP-LICENSE.txt).
