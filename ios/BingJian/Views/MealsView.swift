import SwiftUI

struct MealsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var newMeal: MealComposerRoute?
    @State private var editing: AppRecord?
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                PageHeading(title: "好好吃，也好好记", subtitle: "从每一餐，了解自己的饮食节奏。", artwork: .food)
                DateStrip()
                Button { newMeal = MealComposerRoute() } label: {
                    Label("记录这一餐", systemImage: "plus")
                }.buttonStyle(FilledActionStyle())
                Surface {
                    HStack {
                        Label("营养记录", systemImage: "leaf").font(.headline).foregroundStyle(Palette.ink)
                        Spacer()
                        StatusPill(title: model.summary.complete ? "已确认" : "记录中",
                                   symbol: model.summary.complete ? "checkmark" : "pencil", background: Palette.lime)
                    }
                    nutrientLayout {
                        MetricView(title: "蛋白质", value: model.summary.protein, unit: "g", color: Palette.teal)
                        MetricView(title: "碳水", value: model.summary.carbs, unit: "g", color: Palette.peach)
                        MetricView(title: "脂肪", value: model.summary.fat, unit: "g", color: Palette.purple)
                    }
                    if !model.summary.missingNutrients.isEmpty {
                        HintLabel(text: "已知部分合计。待补充 \(model.summary.missingNutrients.joined(separator: "、"))")
                    }
                }
                ForEach(model.meals) { record in
                    if let meal = record.decode(MealEntry.self) {
                        Button { editing = record } label: {
                            Surface {
                                HStack(alignment: .top, spacing: 12) {
                                    SymbolBadge(symbol: mealSymbol(meal.mealType), color: meal.mealType == "dinner" ? Palette.purple : Palette.peach)
                                    VStack(alignment: .leading, spacing: 5) {
                                        HStack {
                                            Text(MealTypes.name(meal.mealType)).font(.headline).foregroundStyle(Palette.ink)
                                            Spacer()
                                            Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.secondary)
                                        }
                                        Text(meal.status == "skipped" ? "本餐未进食" : meal.items.map(\.name).joined(separator: "、"))
                                            .font(.subheadline).foregroundStyle(Palette.secondary).lineLimit(2)
                                        if meal.status == "draft" {
                                            Text("待确认").font(.caption.weight(.medium)).foregroundStyle(Palette.peach)
                                        } else {
                                            Text(meal.kcal.map { "\(model.profile.energyUnit == "kJ" ? ($0 * 4.184).concise : $0.concise) \(model.profile.energyUnit)" } ?? "热量待补充")
                                                .font(.subheadline.weight(.semibold)).foregroundStyle(Palette.teal)
                                        }
                                    }
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
                        Label("待补充的餐次", systemImage: "clock").font(.headline).foregroundStyle(Palette.ink)
                        ForEach(model.summary.missingMeals, id: \.self) { type in
                            HStack {
                                Button { newMeal = MealComposerRoute(mealType: type) } label: {
                                    HStack {
                                        Text(MealTypes.name(type)).foregroundStyle(Palette.ink)
                                        Spacer()
                                        Text("去记录").foregroundStyle(Palette.teal)
                                        Image(systemName: "chevron.right").font(.caption)
                                    }.frame(minHeight: 48).contentShape(Rectangle())
                                }.buttonStyle(.plain).accessibilityIdentifier("meal.pending.\(type)")
                                Menu {
                                    Button("明确标记本餐未进食") { model.perform { try await model.skipMeal(type) } }
                                } label: {
                                    Image(systemName: "ellipsis").frame(width: 44, height: 48)
                                }.accessibilityLabel("\(MealTypes.name(type))的其他操作")
                            }.padding(.horizontal, 12).background(Palette.canvas, in: RoundedRectangle(cornerRadius: 14))
                        }
                    }
                }
                Button(model.summary.complete ? "撤回当日完成确认" : "确认当日记录完成") {
                    model.perform { try await model.markComplete(!model.summary.complete) }
                }.buttonStyle(FilledActionStyle()).accessibilityIdentifier("page.end.meals")
            }.padding(.horizontal, 16).padding(.vertical, 18)
        }
        .background(Palette.canvas)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { Text("饮食").font(.title3.weight(.bold)).foregroundStyle(Palette.ink) }
            ToolbarItem(placement: .topBarTrailing) { Button("记录", systemImage: "plus") { newMeal = MealComposerRoute() } }
        }
        .sheet(item: $newMeal) { route in NavigationStack { MealEditorView(initialMealType: route.mealType) } }
        .sheet(item: $editing) { record in NavigationStack { MealEditorView(existing: record) } }
    }

    private var nutrientLayout: AnyLayout {
        typeSize.isAccessibilitySize ? AnyLayout(VStackLayout(alignment: .leading, spacing: 16)) : AnyLayout(HStackLayout(alignment: .top, spacing: 12))
    }

    private func mealSymbol(_ type: String) -> String {
        switch type {
        case "breakfast": return "cup.and.saucer.fill"
        case "lunch": return "fork.knife"
        case "dinner": return "moon.stars.fill"
        default: return "cup.and.saucer"
        }
    }
}

struct MealComposerRoute: Identifiable {
    let id = UUID()
    var mealType: String?
}
