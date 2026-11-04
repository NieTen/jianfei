import Foundation
import ImageIO
import Vision

struct LocalRecognition: Sendable {
    var items: [FoodItem]
    var note: String
}

enum OnDeviceRecognizer {
    // 使用系统随附的端侧视觉分类模型，候选份量必须由用户填写。
    static func recognize(urls: [URL], photoIds: [String], preferences: [FoodPreference]) async throws -> LocalRecognition {
        try await Task.detached(priority: .userInitiated) {
            let translations = [
                "apple": "苹果", "banana": "香蕉", "orange": "橙子", "bread": "面包", "rice": "米饭",
                "noodle": "面条", "pizza": "披萨", "salad": "沙拉", "egg": "鸡蛋", "chicken": "鸡肉",
                "fish": "鱼类", "soup": "汤", "sandwich": "三明治", "hamburger": "汉堡", "cake": "蛋糕",
                "cookie": "饼干", "yogurt": "酸奶", "milk": "牛奶", "coffee": "咖啡", "tea": "茶",
                "strawberry": "草莓", "grape": "葡萄", "broccoli": "西兰花", "potato": "土豆"
            ]
            var candidates: [String: FoodItem] = [:]
            for (index, url) in urls.enumerated() {
                let request = VNClassifyImageRequest()
                try VNImageRequestHandler(url: url).perform([request])
                for observation in (request.results ?? []).prefix(15) where observation.confidence >= 0.15 {
                    guard let entry = translations.first(where: { observation.identifier.lowercased().contains($0.key) }) else { continue }
                    let name = entry.value
                    let photoId = index < photoIds.count ? photoIds[index] : ""
                    if var existing = candidates[name] {
                        existing.evidencePhotoIds.append(photoId)
                        existing.confidence = max(existing.confidence ?? 0, Double(observation.confidence))
                        candidates[name] = existing
                    } else {
                        let preference = preferences.first { $0.foodName == name }
                        var food = FoodItem(name: name, amount: 100 * (preference?.weightMultiplier ?? 1),
                                            nutritionBasis: "per_100g", source: "ai_estimate",
                                            confidence: Double(observation.confidence),
                                            uncertaintyNote: "系统端侧分类候选。100g 只是待填写份量，热量和营养需要从个人食物库或标签补充")
                        food.evidencePhotoIds = [photoId]
                        food.requiresPortion = true
                        candidates[name] = food
                    }
                }
            }
            let items = candidates.values.sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }
            return LocalRecognition(items: Array(items.prefix(12)),
                note: items.isEmpty ? "本机模型没有可靠候选，请手动添加食物或连接 AI 服务" : "本机模型提供食物类别候选，请核对份量和营养。照片留在本机")
        }.value
    }
}
