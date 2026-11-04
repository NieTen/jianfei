import SwiftUI

struct MealsView: View {
    @EnvironmentObject private var model: AppModel
    @State private var newMeal = false
    @State private var editing: AppRecord?
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                DateStrip()
                Surface {
                    HStack {
                        MetricView(title: "蛋白质", value: model.summary.protein, unit: "g")
                        MetricView(title: "碳水", value: model.summary.carbs, unit: "g")
                        MetricView(title: "脂肪", value: model.summary.fat, unit: "g")
                    }
                    if !model.summary.missingNutrients.isEmpty {
                        HintLabel(text: "已知部分合计。待补充 \(model.summary.missingNutrients.joined(separator: "、"))")
                    }
                }
                ForEach(model.meals) { record in
                    if let meal = record.decode(MealEntry.self) {
                        Button { editing = record } label: {
                            Surface {
                                HStack {
                                    VStack(alignment: .leading, spacing: 5) {
                                        Text(MealTypes.name(meal.mealType)).font(.headline).foregroundStyle(Palette.ink)
                                        Text(meal.status == "skipped" ? "本餐未进食" : meal.items.map(\.name).joined(separator: "、"))
                                            .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                                    }
                                    Spacer()
                                    if meal.status == "draft" { Text("待确认").font(.caption).foregroundStyle(Palette.peach) }
                                    else { Text(meal.kcal.map { "\($0.concise) kcal" } ?? "热量待补充").font(.subheadline).foregroundStyle(Palette.ink) }
                                }
                                if !meal.photoIds.isEmpty {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack { ForEach(meal.photoIds, id: \.self) { PhotoThumbnail(id: $0) } }
                                    }
                                }
                            }
                        }.buttonStyle(.plain)
                        .contextMenu {
                            Button("复制到所选日期", systemImage: "doc.on.doc") { model.perform { try await model.copyMeal(record) } }
                            Button("删除餐次", systemImage: "trash", role: .destructive) { model.perform { try await model.deleteRecord(record) } }
                        }
                    }
                }
                if model.meals.isEmpty {
                    EmptyRecordsView(title: "从这一餐开始", message: "拍一张照片，也可以手动填写。记录先保存在手机里。", symbol: "fork.knife.circle")
                }
                if !model.summary.missingMeals.isEmpty {
                    Surface {
                        Text("这些餐次还未记录").font(.headline)
                        ForEach(model.summary.missingMeals, id: \.self) { type in
                            HStack {
                                Text(MealTypes.name(type))
                                Spacer()
                                Button("本餐未进食") { model.perform { try await model.skipMeal(type) } }.font(.subheadline)
                            }
                        }
                    }
                }
                Button(model.summary.complete ? "撤回今日完成确认" : "确认今日记录完成") {
                    model.perform { try await model.markComplete(!model.summary.complete) }
                }.buttonStyle(.borderedProminent).frame(maxWidth: .infinity)
            }.padding(20)
        }
        .background(Palette.canvas)
        .navigationTitle("饮食")
        .toolbar { Button("记录", systemImage: "plus") { newMeal = true } }
        .sheet(isPresented: $newMeal) { NavigationStack { MealEditorView() } }
        .sheet(item: $editing) { record in NavigationStack { MealEditorView(existing: record) } }
    }
}
