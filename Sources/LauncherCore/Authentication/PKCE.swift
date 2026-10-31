import Crypto
import Foundation

/// OAuth 2.0 PKCE S256 helper.
public struct PKCEPair: Sendable, Equatable {
    public let verifier: String
    public let challenge: String

    public init(verifier: String, challenge: String) {
        self.verifier = verifier
        self.challenge = challenge
    }
}

public enum PKCE {
    /// RFC 7636 allows 43–128 characters from the unreserved set; 32 random bytes ⇒ 43 chars.
    public static func generate(byteCount: Int = 32) -> PKCEPair {
        let verifier = randomURLSafeString(byteCount: max(32, min(96, byteCount)))
        return PKCEPair(verifier: verifier, challenge: challenge(for: verifier))
    }

    public static func challenge(for verifier: String) -> String {
        let digest = SHA256.hash(data: Data(verifier.utf8))
        return base64URL(Data(digest))
    }

    public static func randomURLSafeString(byteCount: Int) -> String {
        var generator = SystemRandomNumberGenerator()
        var bytes = [UInt8]()
        bytes.reserveCapacity(byteCount)
        for _ in 0..<byteCount {
            bytes.append(UInt8.random(in: 0...255, using: &generator))
        }
        return base64URL(Data(bytes))
    }

    public static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
