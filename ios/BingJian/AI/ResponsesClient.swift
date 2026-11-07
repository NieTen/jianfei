import Foundation

actor ResponsesClient {
    private let session: URLSession
    private var modelCache: [String: (Date, [AIModelOption])] = [:]

    init(session: URLSession? = nil) {
        if let session { self.session = session; return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 210
        configuration.urlCache = nil
        self.session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
    }

    private func request(configuration: AIConfiguration, apiKey: String, path: String, body: JSONObject? = nil) async throws -> JSONObject {
        let base = try AIAddress.normalize(configuration.baseUrl)
        var request = URLRequest(url: base.appendingPathComponent(path))
        request.httpMethod = body == nil ? "GET" : "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty { request.setValue("Bearer " + apiKey, forHTTPHeaderField: "Authorization") }
        request.httpBody = try body.map { try JSONEncoder().encode($0) }
        let (data, response) = try await session.data(for: request)
        guard let status = (response as? HTTPURLResponse)?.statusCode else { throw APIError(code: "AI_NETWORK", message: "AI 服务响应无效") }
        guard (200..<300).contains(status) else {
            let messages = [400: "模型或 Responses 参数不兼容，请核对模型与结构化输出设置",
                            401: "AI 密钥无效或已过期", 403: "当前密钥无权使用此模型",
                            404: "AI 接口或模型不存在", 429: "AI 服务限流或额度不足"]
            throw APIError(code: "AI_HTTP_\(status)", message: messages[status] ?? "AI 服务暂不可用",
                           retryable: status >= 500 || status == 429)
        }
        return try JSONDecoder().decode(JSONObject.self, from: data)
    }

    func models(configuration: AIConfiguration, apiKey: String, refresh: Bool = false) async throws -> [AIModelOption] {
        let url = try AIAddress.normalize(configuration.baseUrl).absoluteString
        let key = url + "|" + String(apiKey.hashValue)
        if !refresh, let cached = modelCache[key], Date().timeIntervalSince(cached.0) < 300 { return cached.1 }
        let response = try await request(configuration: configuration, apiKey: apiKey, path: "models")
        let rows = response.objects("data").isEmpty ? response.objects("models") : response.objects("data")
        let result = rows.compactMap { row -> AIModelOption? in
            let id = row.text("id", fallback: row.text("slug"))
            guard !id.isEmpty, row.text("visibility", fallback: "list") == "list" else { return nil }
            return AIModelOption(id: id, name: row.text("display_name", fallback: id))
        }.sorted { $0.id < $1.id }
        modelCache[key] = (Date(), result)
        return result
    }

    func recognize(configuration: AIConfiguration, apiKey: String, photos: [(String, URL)], note: String,
                   mealVersion: Int, preferences: [FoodPreference]) async throws -> JSONObject {
        guard !configuration.model.isEmpty else { throw APIError(code: "AI_MODEL_REQUIRED", message: "请先选择模型") }
        guard let schemaURL = Bundle.main.url(forResource: "food_schema", withExtension: "json") else {
            throw APIError(code: "AI_SCHEMA_MISSING", message: "应用缺少识别数据结构，请重新安装完整构建")
        }
        let schema = try JSONDecoder().decode(JSONObject.self, from: Data(contentsOf: schemaURL))
        let ids = photos.map(\.0)
        let prompt = try FoodRecognition.prompt(schema: schema, photoIds: ids, note: note)
        var content: [JSONValue] = [.object(["type": .string("input_text"), "text": .string(prompt)])]
        for (_, url) in photos {
            let data = try Data(contentsOf: url)
            content.append(.object(["type": .string("input_image"), "image_url": .string("data:image/jpeg;base64," + data.base64EncodedString()), "detail": .string("auto")]))
        }
        let format: JSONObject = configuration.structuredOutput
            ? ["type": .string("json_schema"), "name": .string("food_recognition"), "strict": .bool(true), "schema": .object(schema)]
            : ["type": .string("json_object")]
        var response: JSONObject = [:]
        var output: JSONObject = [:]
        var foods: [FoodItem] = []
        for attempt in 0..<2 {
            try Task.checkCancellation()
            response = try await request(configuration: configuration, apiKey: apiKey, path: "responses", body: [
                "model": .string(configuration.model), "input": .array([.object(["role": .string("user"), "content": .array(content)])]),
                "text": .object(["format": .object(format)]), "store": .bool(false),
                "max_output_tokens": .number(Double(configuration.maxOutputTokens))
            ])
            output = try FoodRecognition.parse(response)
            do {
                foods = try FoodRecognition.foods(output, photoIds: ids, preferences: preferences)
                break
            } catch let error as APIError where ["AI_NUTRITION_INCOMPLETE", "AI_FORMAT"].contains(error.code) {
                guard attempt == 0 else {
                    throw APIError(code: "AI_NUTRITION_INCOMPLETE", message: "AI 自动补全后仍未提供完整份量与营养，请重试或更换支持图像营养估算的模型")
                }
                content.append(.object(["type": .string("input_text"), "text": .string(try FoodRecognition.completionPrompt(output))]))
            }
        }
        return ["items": .array(try foods.map { .object(try Codec.object($0)) }), "raw_result": .object(output),
                "model_name": .string(configuration.model), "model_version": .string(response.text("model", fallback: configuration.model)),
                "meal_version": .number(Double(mealVersion)), "needs_user_confirmation": .bool(true),
                "uncertainty_note": output["uncertainty_note"] ?? .string("份量与营养为 AI 估算，请核对实际食用量")]
    }
}
