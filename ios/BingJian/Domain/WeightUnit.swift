import Foundation

// 身体重量在存储、健康数据和同步协议中始终使用公斤，仅在输入和显示时换算。
enum WeightUnit: String, CaseIterable, Identifiable, Sendable {
    case kg
    case jin
    case lb

    var id: String { rawValue }
    var name: String {
        switch self {
        case .kg: return "公斤"
        case .jin: return "斤"
        case .lb: return "磅"
        }
    }
    var title: String {
        switch self {
        case .kg: return "公斤（kg）"
        case .jin: return "斤（1 斤 = 0.5 公斤）"
        case .lb: return "磅（lb）"
        }
    }
    private var kilogramsPerUnit: Double {
        switch self {
        case .kg: return 1
        case .jin: return 0.5
        case .lb: return 0.45359237
        }
    }

    func fromKilograms(_ value: Double) -> Double { value / kilogramsPerUnit }
    func kilograms(from value: Double) -> Double { value * kilogramsPerUnit }
    func converted(_ value: Double, to unit: WeightUnit) -> Double { unit.fromKilograms(kilograms(from: value)) }
    func formatted(kilograms: Double) -> String {
        "\(fromKilograms(kilograms).formatted(.number.precision(.fractionLength(0...2)))) \(name)"
    }
}
