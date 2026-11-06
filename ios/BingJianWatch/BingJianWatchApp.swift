import SwiftUI

@main
@MainActor
struct BingJianWatchApp: App {
    @StateObject private var model = WatchModel()
    var body: some Scene {
        WindowGroup { WatchDashboard().environmentObject(model) }
    }
}

struct WatchDashboard: View {
    @EnvironmentObject private var model: WatchModel
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 15) {
                    Text("并肩").font(.title2.bold()).foregroundStyle(.mint)
                    HStack {
                        VStack(alignment: .leading) {
                            Text("今日步数").font(.caption2).foregroundStyle(.secondary)
                            Text(model.steps.map { String(Int($0)) } ?? model.summary["steps"] ?? "—").font(.title3).monospacedDigit()
                        }
                        Spacer()
                        Image(systemName: "figure.walk").foregroundStyle(.mint)
                    }
                    if let weight = model.summary["weight"] { Text("最近体重 \(weight)").font(.caption) }
                    if let intake = model.summary["intake"] { Text("已记录 \(intake) kcal").font(.caption) }
                    NavigationLink {
                        WatchQuickEntry(kind: "weight")
                    } label: {
                        Label("记体重", systemImage: "scalemass")
                    }
                    NavigationLink {
                        WatchQuickEntry(kind: "meal")
                    } label: {
                        Label("记饮食", systemImage: "fork.knife")
                    }
                    Text(model.summary["status"] ?? "打开手机查看完整记录").font(.caption2).foregroundStyle(.secondary)
                    if !model.entries.isEmpty {
                        Text("\(model.entries.count) 条等待手机确认").font(.caption)
                        Button("重试传输") { model.flush() }
                        if model.entries.contains(where: { $0.ownerId.isEmpty }), !model.ownerId.isEmpty {
                            Button("将未绑定记录关联到当前手机") {
                                do { try model.associateUnbound() }
                                catch { model.message = error.localizedDescription }
                            }
                        }
                    }
                    Button("读取手表步数") { Task { await model.authorizeHealth() } }.font(.caption)
                    if !model.message.isEmpty { Text(model.message).font(.caption2).foregroundStyle(.secondary) }
                }.padding(.horizontal, 5)
            }
            .task { await model.refreshSteps(); model.flush() }
        }
    }
}

struct WatchQuickEntry: View {
    @EnvironmentObject private var model: WatchModel
    @Environment(\.dismiss) private var dismiss
    let kind: String
    @State private var number = ""
    @State private var name = ""
    @State private var inputUnit = WeightUnit.kg
    var body: some View {
        Form {
            TextField(kind == "weight" ? "体重 \(inputUnit.name)" : "热量 kcal", text: $number)
            if kind == "meal" { TextField("食物名称", text: $name) }
            Button("保存记录") {
                guard let value = Double(number) else { model.message = "请输入有效数值"; return }
                do {
                    try model.save(kind: kind, value: kind == "weight" ? inputUnit.kilograms(from: value) : value, name: name)
                    dismiss()
                } catch { model.message = error.localizedDescription }
            }
            Text("离线时先保存到手表，手机确认后移出待传队列。").font(.caption2).foregroundStyle(.secondary)
        }.navigationTitle(kind == "weight" ? "记体重" : "记饮食")
            .onAppear { inputUnit = model.weightUnit }
            .onChange(of: model.weightUnit) { _, newUnit in
                if let value = Double(number) { number = String(inputUnit.converted(value, to: newUnit)) }
                inputUnit = newUnit
            }
    }
}
