import CryptoKit
import Foundation

enum BlobCryptoError: Error, CustomStringConvertible {
    /// AES-GCM could not produce the combined nonce + ciphertext + tag form.
    case sealFailed
    /// The sealed bytes did not authenticate. The file is corrupt, truncated,
    /// or was written with a different key. Never log the underlying error's
    /// full description, it adds nothing and can carry payload sizes around.
    case authenticationFailed

    var description: String {
        switch self {
        case .sealFailed: return "AES-GCM seal failed"
        case .authenticationFailed: return "AES-GCM authentication failed"
        }
    }
}

/// AES-GCM sealing for the image files that live beside the database.
///
/// MEASURED (probe A12), and this is the measurement that picked the whole
/// storage design. Four corruption cases were applied to each candidate:
///
/// - AES-GCM sealed file: **threw on all four**, body bit-flip, tag bit-flip,
///   truncation, and wrong key. Every one surfaced as an authentication
///   failure.
/// - PNG blob stored inside SQLCipher: flipping one bit inside a database page
///   **read back 1,600,000 bytes with no error at all.**
///
/// A screenshot library that silently hands back garbage is exactly the failure
/// this app exists to avoid, so the image bytes never go in the database.
/// AEAD overhead is 28 bytes per blob (12-byte nonce plus 16-byte tag).
enum BlobCrypto {

    /// Returns the combined form: nonce ++ ciphertext ++ tag, in one `Data`.
    /// One file, one read, no separate nonce bookkeeping to get wrong.
    static func seal(_ plaintext: Data, key: SymmetricKey) throws -> Data {
        let box = try AES.GCM.seal(plaintext, using: key)
        guard let combined = box.combined else { throw BlobCryptoError.sealFailed }
        return combined
    }

    /// Opens a combined-form sealed blob.
    ///
    /// Every failure mode collapses to one error on purpose. The caller cannot
    /// do anything different for a flipped bit than for a truncated file, and
    /// the distinction would only invite a caller to treat one of them as
    /// recoverable.
    static func open(_ sealed: Data, key: SymmetricKey) throws -> Data {
        do {
            let box = try AES.GCM.SealedBox(combined: sealed)
            return try AES.GCM.open(box, using: key)
        } catch {
            throw BlobCryptoError.authenticationFailed
        }
    }
}
