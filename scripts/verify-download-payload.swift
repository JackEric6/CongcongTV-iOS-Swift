import Foundation

@main
struct VerifyDownloadPayload {
    static func main() {
        let htmlError = Data("<html><body>Access denied</body></html>".utf8)
        guard DownloadPayloadValidator.isRejectedPayload(htmlError, mimeType: "text/html") else {
            fatalError("HTML protection response was not rejected")
        }

        let jsonError = Data("{\"error\":\"request blocked\"}".utf8)
        guard DownloadPayloadValidator.isRejectedPayload(jsonError, mimeType: "application/json") else {
            fatalError("JSON error response was not rejected")
        }

        var transportStream = Data(repeating: 0, count: 188 * 4)
        for packet in 0..<4 {
            transportStream[packet * 188] = 0x47
        }
        guard DownloadPayloadValidator.isMPEGTransportStream(transportStream),
              DownloadPayloadValidator.isSupportedMediaPayload(
                prefix: transportStream,
                mimeType: "video/mp2t",
                fileExtension: "ts"
              ) else {
            fatalError("Valid MPEG-TS payload was rejected")
        }

        var shortTransportStream = Data(repeating: 0, count: 188 * 2)
        shortTransportStream[0] = 0x47
        shortTransportStream[188] = 0x47
        guard DownloadPayloadValidator.isMPEGTransportStream(shortTransportStream) else {
            fatalError("Valid short MPEG-TS segment was rejected")
        }

        let invalidSegment = Data(repeating: 0x41, count: 188 * 4)
        guard !DownloadPayloadValidator.isMPEGTransportStream(invalidSegment) else {
            fatalError("Non-TS binary response was accepted as a segment")
        }

        var mp4 = Data([0, 0, 0, 24])
        mp4.append(contentsOf: "ftypisom".utf8)
        mp4.append(contentsOf: [0, 0, 0, 0, 105, 115, 111, 109])
        guard DownloadPayloadValidator.isSupportedMediaPayload(
            prefix: mp4,
            mimeType: "video/mp4",
            fileExtension: "mp4"
        ) else {
            fatalError("Valid MP4 payload was rejected")
        }
        guard !DownloadPayloadValidator.isSupportedMediaPayload(
            prefix: jsonError,
            mimeType: "application/octet-stream",
            fileExtension: "mp4"
        ) else {
            fatalError("JSON protection response was accepted as MP4")
        }
        print("DOWNLOAD PAYLOAD VALIDATION CHECKS PASSED")
    }
}
