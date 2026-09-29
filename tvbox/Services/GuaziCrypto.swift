import Foundation
import CommonCrypto
import Security

enum GuaziCryptoError: LocalizedError {
    case invalidResponse
    case invalidKey
    case encryptionFailed
    case decryptionFailed
    case rsaFailed

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "瓜子接口响应无效"
        case .invalidKey:
            return "瓜子加密密钥无效"
        case .encryptionFailed:
            return "瓜子请求加密失败"
        case .decryptionFailed:
            return "瓜子响应解密失败"
        case .rsaFailed:
            return "瓜子 RSA 解密失败"
        }
    }
}

enum GuaziCrypto {
    static let baseURL = "https://api.anctjd.com"
    static let apiVersion = "3.0.5.2"
    static let packageName = "com.xcf8fa289d.s53f6f7725.hc2d9bb51620260914"
    static let versionCode = "2608011"
    static let phoneModel = "Android-TVBox"

    private static let signSalt = "*&zvdvdvddbfikkkumtmdwqppp?|4Y!s!2br"
    private static let publicKey = "MIGfMA0GCSqGSIb3DQEBAQUAA4GNADCBiQKBgQDUM5+/y8sPsWkd1/RQS64X259EUwxFXFE5HlA65MqrxnPs0JqoSRojSDy5QhwvROlaD6TwRQHKMY2OAZ6SnQeUJsChTEFIR9qUkwrs3/MVUMxjsv6JS6Oe/juclyJGTgVmDhB55EafXsD0SQYVj/QXXsxR6ewR5E2kL52yAAD4yQIDAQAB"
    private static let privateKey = "MIICdgIBADANBgkqhkiG9w0BAQEFAASCAmAwggJcAgEAAoGAe6hKrWLi1zQmjTT1ozbE4QdFeJGNxubxld6GrFGximxfMsMB6BpJhpcTouAqywAFppiKetUBBbXwYsYU1wNr648XVmPmCMCy4rY8vdliFnbMUj086DU6Z+/oXBdWU3/b1G0DN3E9wULRSwcKZT3wj/cCI1vsCm3gj2R5SqkA9Y0CAwEAAQKBgAJH+4CxV0/zBVcLiBCHvSANm0l7HetybTh/j2p0Y1sTXro4ALwAaCTUeqdBjWiLSo9lNwDHFyq8zX90+gNxa7c5EqcWV9FmlVXr8VhfBzcZo1nXeNdXFT7tQ2yah/odtdcx+vRMSGJd1t/5k5bDd9wAvYdIDblMAg+wiKKZ5KcdAkEA1cCakEN4NexkF5tHPRrR6XOY/XHfkqXxEhMqmNbB9U34saTJnLWIHC8IXys6Qmzz30TtzCjuOqKRRy+FMM4TdwJBAJQZFPjsGC+RqcG5UvVMiMPhnwe/bXEehShK86yJK/g/UiKrO87h3aEu5gcJqBygTq3BBBoH2md3pr/W+hUMWBsCQQChfhTIrdDinKi6lRxrdBnn0Ohjg2cwuqK5zzU9p/N+S9x7Ck8wUI53DKm8jUJE8WAG7WLj/oCOWEh+ic6NIwTdAkEAj0X8nhx6AXsgCYRql1klbqtVmL8+95KZK7PnLWG/IfjQUy3pPGoSaZ7fdquG8bq8oyf5+dzjE/oTXcByS+6XRQJAP/5ciy1bL3NhUhsaOVy55MHXnPjdcTX0FaLi+ybXZIfIQ2P4rb19mVq1feMbCXhz+L1rG8oat5lYKfpe8k83ZA=="

    private static let randomAlphabet = Array("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")

    static func verifyEmbeddedKeyMaterial() throws {
        _ = try publicSecKey()
        let privateKey = try privateSecKey()
        guard let publicKey = SecKeyCopyPublicKey(privateKey) else {
            throw GuaziCryptoError.invalidKey
        }

        let sessionKey = "0123456789abcdef"
        let sessionIV = "fedcba9876543210"
        let sessionData = try JSONSerialization.data(withJSONObject: [
            "key": sessionKey,
            "iv": sessionIV
        ])
        guard let encryptedSession = SecKeyCreateEncryptedData(
            publicKey,
            .rsaEncryptionPKCS1,
            sessionData as CFData,
            nil
        ) as Data? else {
            throw GuaziCryptoError.rsaFailed
        }

        let form = try createForm(parameters: ["probe": "ok"], token: "", time: 1)
        guard let encodedRequestKey = form["keys"],
              let wrappedRequestKey = Data(base64Encoded: encodedRequestKey),
              wrappedRequestKey.count == SecKeyGetBlockSize(try publicSecKey()) else {
            throw GuaziCryptoError.rsaFailed
        }

        let encryptedResponse = try aesEncrypt(
            #"{"probe":"ok"}"#,
            key: sessionKey,
            iv: sessionIV
        )
        let response = try JSONSerialization.data(withJSONObject: [
            "data": [
                "keys": encryptedSession.base64EncodedString(),
                "response_key": encryptedResponse
            ]
        ])
        let decoded = try decodeResponse(String(decoding: response, as: UTF8.self))
        guard decoded["probe"] as? String == "ok" else {
            throw GuaziCryptoError.decryptionFailed
        }
    }

    static func createForm(parameters: [String: Any], token: String, time: Int64) throws -> [String: String] {
        let key = randomText(length: 16)
        let iv = randomText(length: 16)
        let parameterData = try JSONSerialization.data(withJSONObject: parameters, options: [])
        let requestKey = try aesEncrypt(
            String(decoding: parameterData, as: UTF8.self),
            key: key,
            iv: iv
        )

        let keyObject: [String: String] = ["key": key, "iv": iv]
        let keyData = try JSONSerialization.data(withJSONObject: keyObject, options: [])
        let keys = try rsaEncrypt(keyData)
        let normalizedToken = token
        let signatureText = "token_id=,token=\(normalizedToken),phone_type=1,request_key=\(requestKey),app_id=1,time=\(time),keys=\(keys)"
        let signature = md5Hex(signatureText + signSalt)

        return [
            "token": normalizedToken,
            "token_id": "",
            "phone_type": "1",
            "time": String(time),
            "phone_model": phoneModel,
            "keys": keys,
            "request_key": requestKey,
            "signature": signature,
            "app_id": "1",
            "ad_version": "1"
        ]
    }

    static func decodeResponse(_ raw: String) throws -> [String: Any] {
        guard let data = raw.data(using: .utf8),
              let outer = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let responseData = outer["data"] as? [String: Any],
              let encryptedKeys = responseData["keys"] as? String,
              let responseKey = responseData["response_key"] as? String else {
            throw GuaziCryptoError.invalidResponse
        }

        let sessionData = try rsaDecrypt(encryptedKeys)
        guard let session = try JSONSerialization.jsonObject(with: sessionData) as? [String: Any],
              let key = session["key"] as? String,
              let iv = session["iv"] as? String else {
            throw GuaziCryptoError.rsaFailed
        }

        let plain = try aesDecrypt(responseKey, key: key, iv: iv)
        guard let plainData = plain.data(using: .utf8),
              let object = try JSONSerialization.jsonObject(with: plainData) as? [String: Any] else {
            throw GuaziCryptoError.decryptionFailed
        }
        return object
    }

    static func responseCode(_ raw: String) -> Int {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return 0
        }
        if let value = object["code"] as? Int {
            return value
        }
        if let value = object["code"] as? String {
            return Int(value) ?? 0
        }
        return 0
    }

    static func responseMessage(_ raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ""
        }
        return stringValue(object["msg"])
    }

    private static func aesEncrypt(_ plain: String, key: String, iv: String) throws -> String {
        let encrypted = try crypt(
            Data(plain.utf8),
            operation: CCOperation(kCCEncrypt),
            key: Data(key.utf8),
            iv: Data(iv.utf8)
        )
        return encrypted.map { String(format: "%02X", $0) }.joined()
    }

    private static func aesDecrypt(_ hex: String, key: String, iv: String) throws -> String {
        let encrypted = try hexData(hex)
        let plain = try crypt(
            encrypted,
            operation: CCOperation(kCCDecrypt),
            key: Data(key.utf8),
            iv: Data(iv.utf8)
        )
        guard let value = String(data: plain, encoding: .utf8) else {
            throw GuaziCryptoError.decryptionFailed
        }
        return value
    }

    private static func crypt(_ data: Data, operation: CCOperation, key: Data, iv: Data) throws -> Data {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128 else {
            throw GuaziCryptoError.invalidKey
        }
        let outputCapacity = data.count + kCCBlockSizeAES128
        var output = Data(count: outputCapacity)
        var outputLength = 0
        let status = output.withUnsafeMutableBytes { outputBytes in
            data.withUnsafeBytes { inputBytes in
                key.withUnsafeBytes { keyBytes in
                    iv.withUnsafeBytes { ivBytes in
                        CCCrypt(
                            operation,
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyBytes.baseAddress,
                            key.count,
                            ivBytes.baseAddress,
                            inputBytes.baseAddress,
                            data.count,
                            outputBytes.baseAddress,
                            outputCapacity,
                            &outputLength
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else {
            throw operation == CCOperation(kCCEncrypt)
                ? GuaziCryptoError.encryptionFailed
                : GuaziCryptoError.decryptionFailed
        }
        output.removeSubrange(outputLength..<output.count)
        return output
    }

    private static func rsaEncrypt(_ data: Data) throws -> String {
        let key = try publicSecKey()
        guard
              let encrypted = SecKeyCreateEncryptedData(
                  key,
                  .rsaEncryptionPKCS1,
                  data as CFData,
                  nil
              ) as Data? else {
            throw GuaziCryptoError.rsaFailed
        }
        return encrypted.base64EncodedString()
    }

    private static func rsaDecrypt(_ value: String) throws -> Data {
        let key = try privateSecKey()
        guard
              let encrypted = Data(base64Encoded: value),
              let plain = SecKeyCreateDecryptedData(
                  key,
                  .rsaEncryptionPKCS1,
                  encrypted as CFData,
                  nil
              ) as Data? else {
            throw GuaziCryptoError.rsaFailed
        }
        return plain
    }

    private static func publicSecKey() throws -> SecKey {
        guard let wrappedData = Data(base64Encoded: publicKey) else {
            throw GuaziCryptoError.invalidKey
        }
        let keyData = try unwrapSubjectPublicKeyInfo(wrappedData)
        guard let key = SecKeyCreateWithData(
            keyData as CFData,
            [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPublic
            ] as CFDictionary,
            nil
        ) else {
            throw GuaziCryptoError.invalidKey
        }
        return key
    }

    private static func privateSecKey() throws -> SecKey {
        guard let wrappedData = Data(base64Encoded: privateKey) else {
            throw GuaziCryptoError.invalidKey
        }
        let keyData = try unwrapPrivateKeyInfo(wrappedData)
        guard let key = SecKeyCreateWithData(
            keyData as CFData,
            [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate
            ] as CFDictionary,
            nil
        ) else {
            throw GuaziCryptoError.invalidKey
        }
        return key
    }

    private static func unwrapPrivateKeyInfo(_ data: Data) throws -> Data {
        var root = DERReader(data)
        let sequence = try root.read(tag: 0x30)
        guard root.isAtEnd else { throw GuaziCryptoError.invalidKey }

        var fields = DERReader(sequence)
        _ = try fields.read(tag: 0x02)
        _ = try fields.read(tag: 0x30)
        let keyData = try fields.read(tag: 0x04)
        guard keyData.first == 0x30 else { throw GuaziCryptoError.invalidKey }
        return keyData
    }

    private static func unwrapSubjectPublicKeyInfo(_ data: Data) throws -> Data {
        var root = DERReader(data)
        let sequence = try root.read(tag: 0x30)
        guard root.isAtEnd else { throw GuaziCryptoError.invalidKey }

        var fields = DERReader(sequence)
        _ = try fields.read(tag: 0x30)
        let bitString = try fields.read(tag: 0x03)
        guard bitString.first == 0, bitString.count > 1 else {
            throw GuaziCryptoError.invalidKey
        }
        let keyData = Data(bitString.dropFirst())
        guard keyData.first == 0x30 else { throw GuaziCryptoError.invalidKey }
        return keyData
    }

    private static func hexData(_ value: String) throws -> Data {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard normalized.count.isMultiple(of: 2) else {
            throw GuaziCryptoError.decryptionFailed
        }
        var result = Data()
        result.reserveCapacity(normalized.count / 2)
        var index = normalized.startIndex
        while index < normalized.endIndex {
            let next = normalized.index(index, offsetBy: 2)
            guard let byte = UInt8(normalized[index..<next], radix: 16) else {
                throw GuaziCryptoError.decryptionFailed
            }
            result.append(byte)
            index = next
        }
        return result
    }

    private static func md5Hex(_ value: String) -> String {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        let bytes = Array(value.utf8)
        bytes.withUnsafeBytes { buffer in
            _ = CC_MD5(buffer.baseAddress, CC_LONG(bytes.count), &digest)
        }
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    private static func randomText(length: Int) -> String {
        String((0..<length).map { _ in randomAlphabet.randomElement()! })
    }

    private static func stringValue(_ value: Any?) -> String {
        if let value = value as? String {
            return value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return ""
    }

    private struct DERReader {
        private let bytes: [UInt8]
        private(set) var offset = 0

        init(_ data: Data) {
            bytes = Array(data)
        }

        var isAtEnd: Bool { offset == bytes.count }

        mutating func read(tag expectedTag: UInt8) throws -> Data {
            guard offset + 2 <= bytes.count, bytes[offset] == expectedTag else {
                throw GuaziCryptoError.invalidKey
            }
            offset += 1

            let firstLengthByte = Int(bytes[offset])
            offset += 1
            let length: Int
            if firstLengthByte & 0x80 == 0 {
                length = firstLengthByte
            } else {
                let lengthByteCount = firstLengthByte & 0x7F
                guard lengthByteCount > 0, lengthByteCount <= MemoryLayout<Int>.size,
                      offset + lengthByteCount <= bytes.count else {
                    throw GuaziCryptoError.invalidKey
                }
                var decodedLength = 0
                for _ in 0..<lengthByteCount {
                    guard decodedLength <= (Int.max >> 8) else {
                        throw GuaziCryptoError.invalidKey
                    }
                    decodedLength = (decodedLength << 8) | Int(bytes[offset])
                    offset += 1
                }
                length = decodedLength
            }

            guard length <= bytes.count - offset else {
                throw GuaziCryptoError.invalidKey
            }
            let value = Data(bytes[offset..<(offset + length)])
            offset += length
            return value
        }
    }
}
