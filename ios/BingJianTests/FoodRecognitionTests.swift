import XCTest
@testable import BingJian

final class FoodRecognitionTests: XCTestCase {
    private var complete: JSONObject {
        ["name": .string("鸡肉饭"), "estimated_weight_g": .number(350), "calories_kcal": .number(620),
         "protein_g": .number(32), "carbs_g": .number(78), "fat_g": .number(20), "confidence": .number(0.6),
         "food_state": .string("cooked"), "evidence_photo_ids": .array([.string("photo-1"), .string("无关照片")])]
    }

    private func output(_ item: JSONObject) -> JSONObject {
        ["items": .array([.object(item)]), "uncertainty_note": .string("按普通碗和常见烹饪用油估算")]
    }

    private func response(_ value: JSONObject) throws -> JSONObject {
        ["status": .string("completed"), "output_text": .string(try Codec.json(value))]
    }

    func testEstimatedTotalsAndPersonalAdjustmentsAreAppliedOnce() throws {
        let food = try XCTUnwrap(FoodRecognition.foods(output(complete), photoIds: ["photo-1"],
            preferences: [FoodPreference(foodName: "鸡肉饭", weightMultiplier: 1.5, calorieMultiplier: 1.2)]).first)
        XCTAssertEqual(food.amount, 525)
        XCTAssertEqual(food.basisAmount, 350)
        XCTAssertEqual(try XCTUnwrap(food.kcal), 1116, accuracy: 0.001)
        XCTAssertEqual(food.protein, 48)
        XCTAssertEqual(food.carbs, 117)
        XCTAssertEqual(food.fat, 30)
        XCTAssertEqual(food.evidencePhotoIds, ["photo-1"])
        XCTAssertEqual(food.requiresPortion, false)
        XCTAssertTrue(food.uncertaintyNote.contains("AI 估算"))
        let meal = MealEntry(status: "confirmed", items: [food])
        try RecordValidator.validate(AppRecord(kind: "meal", day: TimeFormat.day(), value: meal))
    }

    func testEachRequiredNutrientMustBeNumericAndPresent() throws {
        for field in FoodRecognition.nutritionFields {
            for value in [JSONValue.null, .string("100"), .bool(true)] {
                var item = complete
                item[field] = value
                XCTAssertThrowsError(try FoodRecognition.foods(output(item), photoIds: [], preferences: [])) {
                    XCTAssertEqual(($0 as? APIError)?.code, "AI_NUTRITION_INCOMPLETE")
                }
            }
        }
        var negative = complete
        negative["calories_kcal"] = .number(-1)
        XCTAssertThrowsError(try FoodRecognition.foods(output(negative), photoIds: [], preferences: []))
        XCTAssertThrowsError(try FoodRecognition.foods(["items": .array([.string("无效条目")])], photoIds: [], preferences: []))
    }

    func testZeroNutrientsAndNoFoodDoNotInventValues() throws {
        var item = complete
        for field in FoodRecognition.nutritionFields where field != "estimated_weight_g" { item[field] = .number(0) }
        let food = try XCTUnwrap(FoodRecognition.foods(output(item), photoIds: [], preferences: []).first)
        XCTAssertEqual(food.kcal, 0)
        XCTAssertEqual(food.protein, 0)
        XCTAssertTrue(try FoodRecognition.foods(["items": .array([])], photoIds: [], preferences: []).isEmpty)
    }

    func testResponsesEnvelopeRefusalAndIncomplete() throws {
        let value = output(complete)
        XCTAssertEqual(try FoodRecognition.parse(response(value)), value)
        let envelope: JSONObject = ["output": .array([.object(["type": .string("message"), "content": .array([
            .object(["type": .string("output_text"), "text": .string(try Codec.json(value))])])])])]
        XCTAssertEqual(try FoodRecognition.parse(envelope), value)
        XCTAssertThrowsError(try FoodRecognition.parse(["status": .string("incomplete")])) {
            XCTAssertEqual(($0 as? APIError)?.code, "AI_INCOMPLETE")
        }
        let refusal: JSONObject = ["output": .array([.object(["type": .string("message"), "content": .array([
            .object(["type": .string("refusal")])])])])]
        XCTAssertThrowsError(try FoodRecognition.parse(refusal)) { XCTAssertEqual(($0 as? APIError)?.code, "AI_REFUSAL") }
    }

    func testDirectResponsesAutomaticallyCompletesNutritionInBothFormats() async throws {
        let stub = AIHTTPStub()
        let session = stub.session()
        defer { session.invalidateAndCancel(); AIStubURLProtocol.unregister(stub) }
        let client = ResponsesClient(session: session)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        for strict in [true, false] {
            var configuration = AIConfiguration()
            configuration.baseUrl = "https://" + stub.host + "/v1"
            configuration.model = "test-vision"
            configuration.structuredOutput = strict
            var missing = complete
            missing["estimated_weight_g"] = .null
            missing.removeValue(forKey: "protein_g")
            stub.reset([try response(output(missing)), try response(output(complete))])
            let result = try await client.recognize(configuration: configuration, apiKey: "test-only-key",
                photos: [("photo-1", file)], note: "一人份", mealVersion: 3, preferences: [])
            let food = try Codec.decode(FoodItem.self, from: XCTUnwrap(result.objects("items").first))
            XCTAssertEqual(food.amount, 350)
            XCTAssertEqual(food.kcal, 620)
            XCTAssertEqual(food.protein, 32)
            XCTAssertEqual(food.carbs, 78)
            XCTAssertEqual(food.fat, 20)
            XCTAssertEqual(food.requiresPortion, false)
            let requests = stub.requests
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(requests[0].authorization, "Bearer test-only-key")
            XCTAssertEqual(requests[0].url?.path, "/v1/responses")
            let original = try XCTUnwrap(requests[0].body.objects("input").first).objects("content")
            let retry = try XCTUnwrap(requests[1].body.objects("input").first).objects("content")
            XCTAssertEqual(original[1], retry[1], "补全请求应保留原照片")
            XCTAssertTrue(retry.last?.text("text").contains("上次结果") == true)
            for field in FoodRecognition.nutritionFields { XCTAssertTrue(original[0].text("text").contains(field)) }
            XCTAssertEqual(requests[0].body["text"]?.object?["format"]?.object?.text("type"), strict ? "json_schema" : "json_object")
        }
    }

    func testDirectResponsesDoesNotSaveIncompleteNutritionAfterRetry() async throws {
        let stub = AIHTTPStub()
        stub.reset([try response(output(["name": .string("鸡肉饭")]))])
        let session = stub.session()
        defer { session.invalidateAndCancel(); AIStubURLProtocol.unregister(stub) }
        var configuration = AIConfiguration()
        configuration.baseUrl = "https://" + stub.host + "/v1"
        configuration.model = "test-vision"
        do {
            _ = try await ResponsesClient(session: session).recognize(configuration: configuration, apiKey: "",
                photos: [], note: "", mealVersion: 1, preferences: [])
            XCTFail("补全仍缺失时不应返回可保存的成功结果")
        } catch { XCTAssertEqual((error as? APIError)?.code, "AI_NUTRITION_INCOMPLETE") }
        XCTAssertEqual(stub.requests.count, 2)
    }
}
