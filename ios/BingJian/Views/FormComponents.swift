import SwiftUI

// 保留原生表单行为，让选择器、键盘和辅助功能沿用系统交互。
struct AppForm<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        Form {
            content
                .listRowBackground(Palette.card)
                .listRowSeparatorTint(Palette.border)
        }
        .modifier(RecordPageStyle())
        .modifier(KeyboardDismissToolbar())
    }
}

// 列表仍使用 List，保留搜索、下拉刷新、滑动操作与按需加载。
struct AppList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        List {
            content
                .listRowBackground(Palette.card)
                .listRowSeparatorTint(Palette.border)
        }
        .listStyle(.insetGrouped)
        .modifier(RecordPageStyle())
    }
}

struct RecordPageStyle: ViewModifier {
    func body(content: Content) -> some View {
        content
            .scrollContentBackground(.hidden)
            .background(Palette.canvas)
            .listSectionSpacing(18)
            .environment(\.defaultMinListRowHeight, 48)
            .tint(Palette.teal)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(Palette.canvas, for: .navigationBar)
            .toolbarBackground(.visible, for: .navigationBar)
            .scrollDismissesKeyboard(.interactively)
    }
}

struct FormIntro: View {
    var title: String
    var subtitle: String
    var symbol: String
    var color: Color = Palette.teal

    var body: some View {
        Section {
            HStack(alignment: .top, spacing: 14) {
                SymbolBadge(symbol: symbol, color: color)
                VStack(alignment: .leading, spacing: 6) {
                    Text(title).font(.system(.title3, design: .rounded, weight: .bold))
                        .foregroundStyle(Palette.ink).accessibilityAddTraits(.isHeader)
                    Text(subtitle).font(.subheadline).foregroundStyle(Palette.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(18).frame(maxWidth: .infinity, alignment: .leading)
            .background(LinearGradient(colors: [color.opacity(0.10), Palette.card],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        in: RoundedRectangle(cornerRadius: 24))
            .listRowInsets(EdgeInsets()).listRowBackground(Color.clear).listRowSeparator(.hidden)
        }
        .textCase(nil)
    }
}

struct FormField<Content: View>: View {
    var title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
            content
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .background(Palette.canvas, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityLabel(title)
        }.padding(.vertical, 6)
    }
}

struct SoftActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 48)
            .foregroundStyle(configuration.role == .destructive ? Color.red : Palette.teal)
            .background(Palette.soft, in: RoundedRectangle(cornerRadius: 16))
            .opacity(enabled ? (configuration.isPressed ? 0.72 : 1) : 0.45)
    }
}
