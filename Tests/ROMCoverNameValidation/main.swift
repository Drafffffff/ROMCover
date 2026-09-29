import Foundation
import ROMCoverCore

final class MockURLProtocol: URLProtocol {
    static var status = 200
    static var observedBody: Data?
    static let content = #"{"english_title":"Harvest Moon: The Tale of Two Towns","alternate_titles":["Bokujou Monogatari: Futago no Mura"],"confidence":"medium"}"#

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let body = request.httpBody { Self.observedBody = body }
        else if let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var collected = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                collected.append(contentsOf: buffer.prefix(read))
            }
            Self.observedBody = collected
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Build the nested JSON response without manually escaping its content.
        let data: Data
        if Self.status == 200 {
            data = try! JSONSerialization.data(withJSONObject: ["choices": [["finish_reason": "stop", "message": ["content": Self.content]]]])
        } else {
            data = Data(#"{"error":{"message":"Invalid API key"}}"#.utf8)
        }
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct NameValidation {
    static func main() async {
        do {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [MockURLProtocol.self]
            let session = URLSession(configuration: configuration)
            let root = URL(fileURLWithPath: "/private/tmp/private-library")
            let file = root.appendingPathComponent("Roms/NDS/003 牧场物语 双子村(JP)(SOMA汉化组)(1024Mb).nds")
            let game = ROMGame(fileURL: file, rootURL: root, system: .nds)
            let resolver = DeepSeekNameResolver(session: session)
            let result = try await resolver.resolve(game: game, apiKey: "test-key")
            guard result.title == "Harvest Moon: The Tale of Two Towns", result.confidence == "medium" else { throw Failure("名称解析错误") }
            guard let body = MockURLProtocol.observedBody,
                  let payload = try JSONSerialization.jsonObject(with: body) as? [String: Any],
                  payload["model"] as? String == "deepseek-flash",
                  (payload["response_format"] as? [String: String])?["type"] == "json_object",
                  let text = String(data: body, encoding: .utf8),
                  text.contains("003 牧场物语 双子村"), !text.contains(root.path) else { throw Failure("请求格式或隐私边界错误") }
            MockURLProtocol.status = 401
            let other = ROMGame(fileURL: root.appendingPathComponent("Roms/NDS/Other.nds"), rootURL: root, system: .nds)
            do {
                _ = try await resolver.resolve(game: other, apiKey: "bad-key")
                throw Failure("无效 API Key 未被检测")
            } catch ROMCoverError.invalidDeepSeekKey { }
            print("DeepSeek name resolution validation passed")
        } catch {
            fputs("Name validation failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }
}
