import ApelinProtocol
import Foundation
import KWWKAI

/// Calls a provider's native image endpoint and normalizes its response into
/// the same base64 image payload the agent protocol already carries.
///
/// Providers without a native image endpoint keep the legacy SVG fallback in
/// `AgentSession`; a native request never falls back after it has been sent.
enum NativeImageGeneration {
    enum Backend: Sendable, Equatable {
        case openAI
        case gemini
    }

    enum Failure: Error, LocalizedError, Sendable, Equatable {
        case unsupported
        case missingAuthentication
        case invalidEndpoint
        case requestFailed(status: Int, message: String?)
        case malformedResponse
        case invalidImage
        case imageTooLarge

        var errorDescription: String? {
            switch self {
            case .unsupported:
                return "该供应商没有提供原生图像生成端点。"
            case .missingAuthentication:
                return "图像供应商未返回身份凭证。"
            case .invalidEndpoint:
                return "图像供应商的端点无效。"
            case let .requestFailed(status, message):
                if let message, !message.isEmpty { return "Image generation failed (HTTP \(status)): \(message)" }
                return "Image generation failed (HTTP \(status))."
            case .malformedResponse:
                return "图像供应商返回了无效响应。"
            case .invalidImage:
                return "图像供应商返回的数据不是受支持的图像。"
            case .imageTooLarge:
                return "生成的图像过大，无法显示。"
            }
        }
    }

    /// 图像端点的额外设置，来自兼容端点的凭据 extras。
    struct ImageOptions: Sendable, Equatable {
        var mode: AgentImageEndpointMode = .auto
        var customUserAgent: String? = nil
        var azure: Bool = false
        var appendV1: Bool = true

        /// 从凭据 extras 读取；非兼容端点用默认值。
        static func from(credentials: OAuthCredentials?) -> ImageOptions {
            guard let credentials else { return .init() }
            func extra(_ key: String) -> String? {
                guard case let .string(value)? = credentials.extras[key], !value.isEmpty else { return nil }
                return value
            }
            return ImageOptions(
                mode: extra(AgentSignInField.imageEndpointMode.rawValue)
                    .flatMap(AgentImageEndpointMode.init(rawValue:)) ?? .auto,
                customUserAgent: extra(AgentSignInField.customUserAgent.rawValue),
                azure: extra(AgentSignInField.azure.rawValue) == "true",
                appendV1: extra(AgentSignInField.appendV1.rawValue) != "false",
            )
        }
    }

    private struct OpenAIRequest: Encodable {
        let model: String
        let prompt: String
        let n: Int
        let responseFormat: String?

        enum CodingKeys: String, CodingKey {
            case model, prompt, n
            case responseFormat = "response_format"
        }
    }

    private struct OpenAIResponse: Decodable {
        struct Item: Decodable {
            let b64JSON: String?
            let url: String?

            enum CodingKeys: String, CodingKey {
                case b64JSON = "b64_json"
                case url
            }
        }

        let data: [Item]
    }

    private static let maximumImageBytes = 16 * 1024 * 1024

    static func backend(for provider: ProviderConfiguration, model: Model) -> Backend? {
        let modelID = model.id.lowercased()
        switch provider {
        case .stored("openai-api-key", _):
            return modelID.hasPrefix("gpt-image") || modelID.hasPrefix("dall-e") ? .openAI : nil
        case .stored("google-api-key", _):
            return modelID.contains("image") || modelID.contains("imagen") ? .gemini : nil
        case .openAICompatible:
            // A custom OpenAI-compatible account is opt-in only through a
            // clearly image-capable model ID; arbitrary chat models must keep
            // the SVG compatibility path.
            return modelID.hasPrefix("gpt-image") || modelID.hasPrefix("dall-e") ? .openAI : nil
        default:
            return nil
        }
    }

    static func generate(
        backend: Backend,
        model: Model,
        auth: ResolvedProviderAuth?,
        prompt: String,
        options: ImageOptions = .init(),
    ) async throws -> AgentGeneratedImage {
        guard let auth else { throw Failure.missingAuthentication }
        switch backend {
        case .openAI:
            return try await generateOpenAI(model: model, auth: auth, prompt: prompt, options: options)
        case .gemini:
            return try await generateGemini(model: model, auth: auth, prompt: prompt)
        }
    }

    private static func generateOpenAI(
        model: Model,
        auth: ResolvedProviderAuth,
        prompt: String,
        options: ImageOptions,
    ) async throws -> AgentGeneratedImage {
        // 照抄 Minis 的三档：imagesGenerations 只走 images API；
        // chatCompletions 只走 chat/completions；auto 先试 images API，
        // 4xx 时回退 chat/completions。
        switch options.mode {
        case .imagesGenerations:
            return try await generateViaImagesAPI(model: model, auth: auth, prompt: prompt, options: options)
        case .chatCompletions:
            return try await generateViaChatCompletions(model: model, auth: auth, prompt: prompt, options: options)
        case .auto:
            do {
                return try await generateViaImagesAPI(model: model, auth: auth, prompt: prompt, options: options)
            } catch Failure.requestFailed(status: let status, message: _) where (400 ..< 500).contains(status) {
                return try await generateViaChatCompletions(model: model, auth: auth, prompt: prompt, options: options)
            } catch Failure.malformedResponse {
                // 部分中转站对 /images/generations 返回 200 但正文是
                // chat/completions 结构，解析失败时同样回退。
                return try await generateViaChatCompletions(model: model, auth: auth, prompt: prompt, options: options)
            }
        }
    }

    /// 根据 appendV1/Azure 设置解析 images / chat 请求的路径前缀。
    private static func apiPrefix(options: ImageOptions) -> String? {
        options.appendV1 ? "v1" : nil
    }

    private static func applyHeaders(
        _ request: inout URLRequest,
        auth: ResolvedProviderAuth,
        options: ImageOptions,
    ) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if options.azure {
            request.setValue(auth.token, forHTTPHeaderField: "api-key")
        } else {
            request.setValue("Bearer \(auth.token)", forHTTPHeaderField: "Authorization")
        }
        let trimmed = options.customUserAgent?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        request.setValue(
            trimmed.isEmpty ? CompatibleEndpointUserAgent.default : trimmed,
            forHTTPHeaderField: "User-Agent",
        )
    }

    private static func generateViaImagesAPI(
        model: Model,
        auth: ResolvedProviderAuth,
        prompt: String,
        options: ImageOptions,
    ) async throws -> AgentGeneratedImage {
        let endpoint = try endpoint(
            baseURL: model.baseURL,
            suffix: ["images", "generations"],
            prefix: apiPrefix(options: options),
        )
        let isGPTImage = model.id.lowercased().hasPrefix("gpt-image")
        let requestBody = OpenAIRequest(
            model: model.id,
            prompt: prompt,
            n: 1,
            // GPT Image always returns base64 and rejects response_format;
            // DALL-E and most compatible gateways need it explicitly.
            responseFormat: isGPTImage ? nil : "b64_json"
        )
        let body = try JSONEncoder().encode(requestBody)
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        applyHeaders(&request, auth: auth, options: options)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, body: data)
        let decoded: OpenAIResponse
        do {
            decoded = try JSONDecoder().decode(OpenAIResponse.self, from: data)
        } catch {
            throw Failure.malformedResponse
        }
        guard let item = decoded.data.first else { throw Failure.malformedResponse }
        if let encoded = item.b64JSON, !encoded.isEmpty {
            return try image(fromBase64: encoded, preferredMIMEType: "image/png")
        }
        guard let imageURL = item.url else { throw Failure.malformedResponse }
        return try await downloadImage(from: imageURL)
    }

    /// chat/completions 多模态图像输出：模型把图片以 data URL 放进回复的
    /// content 里，与 Minis 的 chat-completions 图像模式一致。
    private static func generateViaChatCompletions(
        model: Model,
        auth: ResolvedProviderAuth,
        prompt: String,
        options: ImageOptions,
    ) async throws -> AgentGeneratedImage {
        let endpoint = try endpoint(
            baseURL: model.baseURL,
            suffix: ["chat", "completions"],
            prefix: apiPrefix(options: options),
        )
        let bodyObject: [String: Any] = [
            "model": model.id,
            "messages": [["role": "user", "content": prompt]],
            "n": 1,
        ]
        let body = try JSONSerialization.data(withJSONObject: bodyObject)
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        applyHeaders(&request, auth: auth, options: options)
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, body: data)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = root["choices"] as? [[String: Any]],
              let first = choices.first,
              let message = first["message"] as? [String: Any]
        else { throw Failure.malformedResponse }
        if let encoded = firstBase64Image(in: message) {
            return try image(fromBase64: encoded, preferredMIMEType: "image/png")
        }
        throw Failure.malformedResponse
    }

    /// 从 chat/completions 的 message.content 里找第一张图片：既认字符串
    /// content 中的 data URL，也认数组 content 里的 image_url 块。
    private static func firstBase64Image(in message: [String: Any]) -> String? {
        func encoded(from string: String) -> String? {
            guard string.lowercased().hasPrefix("data:image/"),
                  let comma = string.firstIndex(of: ",") else { return nil }
            return String(string[string.index(after: comma)...])
        }
        if let content = message["content"] as? String, let found = encoded(from: content) {
            return found
        }
        if let parts = message["content"] as? [[String: Any]] {
            for part in parts {
                if let url = part["image_url"] as? String, let found = encoded(from: url) { return found }
                if let object = part["image_url"] as? [String: Any],
                   let url = object["url"] as? String, let found = encoded(from: url) { return found }
                if let data = part["b64_json"] as? String, !data.isEmpty { return data }
            }
        }
        return nil
    }

    private static func generateGemini(
        model: Model,
        auth: ResolvedProviderAuth,
        prompt: String
    ) async throws -> AgentGeneratedImage {
        let modelID = model.id.hasPrefix("models/") ? String(model.id.dropFirst("models/".count)) : model.id
        let endpoint = try endpoint(
            baseURL: model.baseURL,
            suffix: ["models", "\(modelID):generateContent"],
            prefix: "v1beta"
        )
        let requestBody: [String: Any] = [
            "contents": [["parts": [["text": prompt]]]],
            // Gemini's image-capable models only emit image inlineData when
            // IMAGE is explicitly requested in the response modalities.
            "generationConfig": ["responseModalities": ["TEXT", "IMAGE"]],
        ]
        let body = try JSONSerialization.data(withJSONObject: requestBody)
        var request = URLRequest(url: endpoint, timeoutInterval: 120)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(auth.token, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = body

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, body: data)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let inline = firstInlineImage(in: object),
              !inline.data.isEmpty
        else { throw Failure.malformedResponse }
        return try image(fromBase64: inline.data, preferredMIMEType: inline.mimeType)
    }

    static func endpoint(
        baseURL: String,
        suffix: [String],
        prefix: String? = nil
    ) throws -> URL {
        guard let base = URL(string: baseURL),
              let scheme = base.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false)
        else { throw Failure.invalidEndpoint }

        var path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let alreadyHasPrefix = prefix.map { path == $0 || path.hasSuffix("/\($0)") } ?? false
        if let prefix, !alreadyHasPrefix {
            path = path.isEmpty ? prefix : "\(path)/\(prefix)"
        }
        path = ([path] + suffix).filter { !$0.isEmpty }.joined(separator: "/")
        components.path = "/" + path
        guard let url = components.url else { throw Failure.invalidEndpoint }
        return url
    }

    private static func validate(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
        guard (200 ..< 300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])
                .flatMap { errorObject in
                    (errorObject["error"] as? [String: Any])?["message"] as? String
                        ?? errorObject["message"] as? String
                }
                ?? String(decoding: body.prefix(500), as: UTF8.self)
            throw Failure.requestFailed(status: http.statusCode, message: message)
        }
    }

    private static func downloadImage(from string: String) async throws -> AgentGeneratedImage {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme)
        else { throw Failure.invalidImage }
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response: response, body: data)
        let header = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")
        return try image(from: data, preferredMIMEType: header)
    }

    static func image(fromBase64 encoded: String, preferredMIMEType: String?) throws -> AgentGeneratedImage {
        let payload: String
        if let comma = encoded.firstIndex(of: ","), encoded[..<comma].lowercased().hasPrefix("data:") {
            payload = String(encoded[encoded.index(after: comma)...])
        } else {
            payload = encoded
        }
        guard let data = Data(base64Encoded: payload, options: [.ignoreUnknownCharacters]) else {
            throw Failure.invalidImage
        }
        return try image(from: data, preferredMIMEType: preferredMIMEType)
    }

    private static func image(from data: Data, preferredMIMEType: String?) throws -> AgentGeneratedImage {
        guard !data.isEmpty else { throw Failure.invalidImage }
        guard data.count <= maximumImageBytes else { throw Failure.imageTooLarge }
        guard let mimeType = imageMIMEType(data: data, preferred: preferredMIMEType) else {
            throw Failure.invalidImage
        }
        return AgentGeneratedImage(data: data.base64EncodedString(), mimeType: mimeType)
    }

    private static func imageMIMEType(data: Data, preferred: String?) -> String? {
        let bytes = [UInt8](data.prefix(12))
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]) { return "image/png" }
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) { return "image/jpeg" }
        if bytes.starts(with: Array("GIF8".utf8)) { return "image/gif" }
        if bytes.count >= 12,
           bytes.starts(with: Array("RIFF".utf8)),
           Array(bytes[8 ..< 12]) == Array("WEBP".utf8) { return "image/webp" }
        if let preferred,
           let type = preferred.split(separator: ";", maxSplits: 1).first.map(String.init),
           type.lowercased().hasPrefix("image/")
        {
            return type
        }
        return nil
    }

    private static func firstInlineImage(in value: Any) -> (data: String, mimeType: String)? {
        if let dictionary = value as? [String: Any] {
            for key in ["inlineData", "inline_data"] {
                if let inline = dictionary[key] as? [String: Any],
                   let data = inline["data"] as? String
                {
                    let mime = (inline["mimeType"] as? String) ?? (inline["mime_type"] as? String)
                    return (data, mime ?? "image/png")
                }
            }
            for child in dictionary.values {
                if let found = firstInlineImage(in: child) { return found }
            }
        } else if let array = value as? [Any] {
            for child in array {
                if let found = firstInlineImage(in: child) { return found }
            }
        }
        return nil
    }
}
