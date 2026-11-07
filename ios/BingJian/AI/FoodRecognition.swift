import Foundation

enum FoodRecognition {
    static let nutritionFields = ["estimated_weight_g", "calories_kcal", "protein_g", "carbs_g", "fat_g"]

    static func prompt(schema: JSONObject, photoIds: [String], note: String) throws -> String {
        guard !schema.text("description").isEmpty else {
            throw APIError(code: "AI_SCHEMA_MISSING", message: "应用缺少营养估算规则，请更新应用")
        }
        return schema.text("description") + "\n照片标识依次为 " + (try Codec.json(photoIds))
            + "。用户说明 " + (try Codec.json(note))
    }

    static func parse(_ response: JSONObject) throws -> JSONObject {
        if let status = response["status"]?.string, status != "completed" {
            throw APIError(code: "AI_INCOMPLETE", message: "模型输出未完成，可在 AI 设置中增加输出上限或简化照片")
        }
        var texts: [String] = []
        for message in response.objects("output") where message.text("type") == "message" {
            for part in message.objects("content") {
                if part.text("type") == "refusal" { throw APIError(code: "AI_REFUSAL", message: "模型未能识别，请更换清晰照片或模型") }
                if part.text("type") == "output_text" { texts.append(part.text("text")) }
            }
        }
        if texts.isEmpty, let text = response["output_text"]?.string { texts.append(text) }
        guard !texts.isEmpty else { throw APIError(code: "AI_EMPTY", message: "模型未返回可用食物结果") }
        guard let output = try? JSONDecoder().decode(JSONObject.self, from: Data(texts.joined().utf8)) else {
            throw APIError(code: "AI_FORMAT", message: "模型未返回有效 JSON，请检查结构化输出设置")
        }
        return output
    }

    static func foods(_ output: JSONObject, photoIds: [String], preferences: [FoodPreference]) throws -> [FoodItem] {
        guard let rows = output["items"]?.array, rows.count <= 100, rows.allSatisfy({ $0.object != nil }) else {
            throw APIError(code: "AI_FORMAT", message: "模型结果不符合食物识别格式")
        }
        return try rows.map { row in
            let item = row.object ?? [:]
            let name = item.text("name").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else { throw APIError(code: "AI_FORMAT", message: "候选食物名称缺失") }
            // 不用 0 或默认 100 克掩盖缺失值，交给同一个模型自动补全。
            guard nutritionFields.allSatisfy({ item.number($0) != nil }) else {
                throw APIError(code: "AI_NUTRITION_INCOMPLETE", message: "AI 未返回完整份量与营养，正在准备补全")
            }
            let amount = item.number("estimated_weight_g") ?? 0
            let preference = preferences.first { $0.foodName.localizedCaseInsensitiveCompare(name) == .orderedSame }
            var note = "份量、热量及营养为 AI 估算，可直接保存，也可按实际食用量调整。"
            if !output.text("uncertainty_note").isEmpty { note += " " + output.text("uncertainty_note") }
            let food = FoodItem(name: name, amount: amount * (preference?.weightMultiplier ?? 1),
                                basisAmount: amount, nutritionBasis: "total",
                                basisKcal: item.number("calories_kcal").map { $0 * (preference?.calorieMultiplier ?? 1) },
                                basisProteinG: item.number("protein_g"), basisCarbsG: item.number("carbs_g"),
                                basisFatG: item.number("fat_g"), source: "ai_estimate",
                                confidence: item.number("confidence"), uncertaintyNote: note,
                                foodState: item.text("food_state", fallback: "unknown"),
                                evidencePhotoIds: item.strings("evidence_photo_ids").filter { photoIds.contains($0) },
                                requiresPortion: false)
            do { try RecordValidator.food(food) }
            catch { throw APIError(code: "AI_FORMAT", message: "模型返回的份量或营养数据无效") }
            return food
        }
    }

    static func completionPrompt(_ output: JSONObject) throws -> String {
        "\n上次结果的份量或营养字段缺失或无效。请结合原照片补全并返回整餐完整 JSON，"
            + "不要只返回缺失字段，不要删除已识别的食物。必须给出 estimated_weight_g、calories_kcal、protein_g、carbs_g、fat_g 的数值估算。"
            + "对缺少份量的食物估算常见份量，并核对全部营养与份量一致。上次结果："
            + String((try Codec.json(output)).prefix(16000))
    }
}
