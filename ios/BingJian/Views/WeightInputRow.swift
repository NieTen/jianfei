import SwiftUI

struct WeightInputRow: View {
    @Binding var amount: Double?
    @Binding var unit: WeightUnit

    var body: some View {
        HStack(spacing: 12) {
            Text("重量").fixedSize()
            TextField("请输入", value: $amount, format: .number)
                .keyboardType(.decimalPad).multilineTextAlignment(.trailing)
                .accessibilityLabel("重量").accessibilityIdentifier("weight.amount")
            Picker("单位", selection: Binding(get: { unit }, set: { next in
                amount = amount.map { unit.converted($0, to: next) }
                unit = next
            })) {
                ForEach(WeightUnit.allCases) { Text($0.name).tag($0) }
            }.pickerStyle(.menu).labelsHidden().fixedSize()
                .accessibilityLabel("体重单位")
        }.frame(minHeight: 44)
    }
}
