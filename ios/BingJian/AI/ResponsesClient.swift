import Foundation

actor ResponsesClient {
    private let session: URLSession
    private var modelCache: [String: (Date, [AIModelOption])] = [:]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 210
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: NoRedirectDelegate(), delegateQueue: nil)
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
        let prompt = "识别同一餐的食物，多角度中的同一份食物只计算一次。返回 JSON，包含 items 和 uncertainty_note。" +
            "每项返回名称、估算克数、该份量的总热量和三大营养素、置信度、生熟状态及照片证据标识。" +
            "不能可靠判断的数值返回 null，无法识别返回空数组。照片标识 \(ids.joined(separator: ","))。用户说明 \(note)"
        var content: [JSONValue] = [.object(["type": .string("input_text"), "text": .string(prompt)])]
        for (_, url) in photos {
            let data = try Data(contentsOf: url)
            content.append(.object(["type": .string("input_image"), "image_url": .string("data:image/jpeg;base64," + data.base64EncodedString()), "detail": .string("auto")]))
        }
        let format: JSONObject = configuration.structuredOutput
            ? ["type": .string("json_schema"), "name": .string("food_recognition"), "strict": .bool(true), "schema": .object(schema)]
            : ["type": .string("json_object")]
        let response = try await request(configuration: configuration, apiKey: apiKey, path: "responses", body: [
            "model": .string(configuration.model), "input": .array([.object(["role": .string("user"), "content": .array(content)])]),
            "text": .object(["format": .object(format)]), "store": .bool(false),
            "max_output_tokens": .number(Double(configuration.maxOutputTokens))
        ])
        if let status = response["status"]?.string, status != "completed" {
            throw APIError(code: "AI_INCOMPLETE", message: "模型输出未完成，可在 AI 设置中增加输出上限或简化照片")
        }
        var texts: [String] = []
        for message in response.objects("output") where message.text("type") == "message" {
            for part in message.objects("content") {
                if part.text("type") == "refusal" { throw APIError(code: "AI_REFUSAL", message: "模型未能识别，请手动记录或更换照片") }
                if part.text("type") == "output_text" { texts.append(part.text("text")) }
            }
        }
        if texts.isEmpty, let text = response["output_text"]?.string { texts.append(text) }
        guard !texts.isEmpty else { throw APIError(code: "AI_EMPTY", message: "模型未返回可用食物结果") }
        let output = try JSONDecoder().decode(JSONObject.self, from: Data(texts.joined().utf8))
        guard output["items"]?.array != nil else { throw APIError(code: "AI_FORMAT", message: "模型结果不符合识别格式") }
        var foods: [FoodItem] = []
        for item in output.objects("items").prefix(100) {
            let name = item.text("name")
            guard !name.isEmpty else { throw APIError(code: "AI_FORMAT", message: "候选食物名称缺失") }
            let weight = item.number("estimated_weight_g")
            if let weight, weight <= 0 { throw APIError(code: "AI_FORMAT", message: "候选食物份量无效") }
            let preference = preferences.first { $0.foodName.localizedCaseInsensitiveCompare(name) == .orderedSame }
            let amount = weight ?? 100
            var food = FoodItem(name: name, amount: amount * (preference?.weightMultiplier ?? 1),
                                basisAmount: amount, nutritionBasis: "total",
                                basisKcal: weight == nil ? nil : item.number("calories_kcal").map { $0 * (preference?.calorieMultiplier ?? 1) },
                                basisProteinG: weight == nil ? nil : item.number("protein_g"),
                                basisCarbsG: weight == nil ? nil : item.number("carbs_g"),
                                basisFatG: weight == nil ? nil : item.number("fat_g"), source: "ai_estimate",
                                confidence: item.number("confidence"), uncertaintyNote: output.text("uncertainty_note"),
                                foodState: item.text("food_state", fallback: "unknown"),
                                evidencePhotoIds: item.strings("evidence_photo_ids").filter { ids.contains($0) })
            food.requiresPortion = weight == nil
            if weight == nil { food.uncertaintyNote = "份量无法可靠估算，请填写实际份量及营养依据" }
            try RecordValidator.food(food)
            foods.append(food)
        }
        return ["items": .array(try foods.map { .object(try Codec.object($0)) }), "raw_result": .object(output),
                "model_name": .string(configuration.model), "model_version": .string(response.text("model", fallback: configuration.model)),
                "meal_version": .number(Double(mealVersion)), "needs_user_confirmation": .bool(true),
                "uncertainty_note": output["uncertainty_note"] ?? .string("请核对份量和营养")]
    }
}
