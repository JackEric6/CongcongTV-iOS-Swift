import Foundation

@main
struct VerifyGuaziCrypto {
    static func main() throws {
        try GuaziCrypto.verifyEmbeddedKeyMaterial()
        print("GUAZI RSA KEY IMPORT AND ROUND-TRIP CHECK PASSED")
    }
}
