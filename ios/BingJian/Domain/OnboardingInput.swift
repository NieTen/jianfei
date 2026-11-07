import Foundation

struct OnboardingInput: Equatable {
    var age: Int?
    var heightCm: Double?
    var weight: Double?
    var unit = WeightUnit.kg
    var sex = "unspecified"
    var activityFactor = 1.2
    var recordingOnly = false

    var errors: [String: String] {
        var result: [String: String] = [:]
        if age == nil || !(1...120).contains(age ?? 0) { result["age"] = "请输入 1～120 岁的年龄" }
        if heightCm == nil || !(heightCm!.isFinite && heightCm! > 0 && heightCm! <= 300) { result["height"] = "请输入有效身高，单位为厘米" }
        if weight == nil || !(weight!.isFinite && weight! > 0 && unit.kilograms(from: weight!) <= 600) { result["weight"] = "请填写有效体重并核对单位" }
        if !["male", "female"].contains(sex) { result["sex"] = "请选择用于消耗估算的性别参数" }
        return result
    }

    func profile(basedOn existing: BodyProfile) throws -> BodyProfile {
        guard errors.isEmpty else { throw APIError(code: "PROFILE_REQUIRED", message: "请完善身体信息", fieldErrors: errors) }
        var value = existing
        value.age = age
        value.birthDate = nil
        value.heightCm = heightCm
        value.sexForFormula = sex
        value.activityFactor = activityFactor
        value.recordingOnly = recordingOnly || (age ?? 0) < 18
        value.effectiveAt = TimeFormat.iso()
        return value
    }

    static func isComplete(profile: BodyProfile, weight: Double?) -> Bool {
        weight != nil && profile.heightCm != nil && (profile.age != nil || profile.birthDate != nil) && ["male", "female"].contains(profile.sexForFormula)
    }
}
