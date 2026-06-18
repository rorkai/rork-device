import Foundation

/// Stable RSA public key representing the device key returned before pairing.
///
/// The corresponding private key is a test-only TLS fixture. Pairing generation
/// needs only this public value, so tests can verify certificate construction
/// without generating another expensive RSA key for every test run.
let testDevicePublicKeyPEM = Data(
    """
    -----BEGIN RSA PUBLIC KEY-----
    MIIBCgKCAQEArQUIawd8m/EmI6+wbFjETcyu3/BvYPxvdFmLXbkxjJ+JUlxk2N9V
    gnaTwN1vy73I09GQciabxdJuABB00SkJRSss4mVtNJ++RmERyvK2cVe0CSAJEptU
    9PhFuKYbXSblRDX3PRi/eg9Q4lp8UwpehgxqE7okOgVdGeC2MdbmqGic8HVSwWRd
    yD7WcQ/KCu7eUl+haeWfjKYV8WClpydM/2RXZKbbmYP60zQWMq5FtRfycDTIvSp6
    zLvOkYjQnMv2Nnj2iCIrvQiEtfIQcsYmkLwJXsa4a7kBDIhaaIrIQ/C0mgMuvpkm
    j8c9HMluFVTHxFSUeXeBsr7noBqIraKOnQIDAQAB
    -----END RSA PUBLIC KEY-----
    """.utf8
)
