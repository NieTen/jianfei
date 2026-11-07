import SwiftUI
import UIKit

struct KeyboardDismissToolbar: ViewModifier {
    func body(content: Content) -> some View {
        content.toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("收起键盘") {
                    // 数字键盘没有回车键，提供明确的收起入口，方便查看下一项。
                    UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
                }.accessibilityIdentifier("keyboard.dismiss")
            }
        }
    }
}

enum Palette {
    static let teal = adaptive(light: 0x007E69, dark: 0x6CE4C0)
    static let sage = adaptive(light: 0x4B9C88, dark: 0x99CDBD)
    static let peach = adaptive(light: 0xB75108, dark: 0xFFBC7C)
    static let purple = adaptive(light: 0x8840CC, dark: 0xCEAAFF)
    static let ink = adaptive(light: 0x102C30, dark: 0xEAF6F2)
    static let secondary = adaptive(light: 0x606F70, dark: 0xB2C9C3)
    static let canvas = adaptive(light: 0xF5FAF8, dark: 0x101E1D)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x1A2D2B)
    static let soft = adaptive(light: 0xE4F8F0, dark: 0x21433B)
    static let warm = adaptive(light: 0xFFE4CE, dark: 0x483023)
    static let lavender = adaptive(light: 0xECE0FF, dark: 0x352846)
    static let lime = adaptive(light: 0xEFF8CF, dark: 0x334527)
    static let border = adaptive(light: 0xE5EDEA, dark: 0x354D46)
    static let forest = Color(red: 0.00, green: 0.40, blue: 0.36)
    static let mint = Color(red: 0.83, green: 1.00, blue: 0.94)
    static let heroGradient = LinearGradient(colors: [Color(red: 0.00, green: 0.49, blue: 0.56), forest, Color(red: 0.00, green: 0.48, blue: 0.38)], startPoint: .topLeading, endPoint: .bottomTrailing)
    static let actionGradient = LinearGradient(colors: [Color(red: 0.00, green: 0.51, blue: 0.41), Color(red: 0.00, green: 0.46, blue: 0.44)], startPoint: .leading, endPoint: .trailing)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(uiColor: UIColor { traits in
            let value = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(red: CGFloat((value >> 16) & 255) / 255,
                           green: CGFloat((value >> 8) & 255) / 255,
                           blue: CGFloat(value & 255) / 255, alpha: 1)
        })
    }
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 14) { content }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Palette.border.opacity(0.45), lineWidth: 0.5) }
            .shadow(color: Palette.forest.opacity(0.055), radius: 16, x: 0, y: 6)
    }
}

struct PageHeading: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    var title: String
    var subtitle: String
    var artwork: HeaderArtworkKind? = nil
    var body: some View {
        HStack(spacing: 4) {
            VStack(alignment: .leading, spacing: 9) {
                Text(title).font(.system(.title, design: .rounded, weight: .bold)).foregroundStyle(Palette.ink)
                    .accessibilityAddTraits(.isHeader)
                Text(subtitle).font(.subheadline).foregroundStyle(Palette.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }.frame(maxWidth: .infinity, alignment: .leading)
            if let artwork, !typeSize.isAccessibilitySize {
                HeaderArtwork(kind: artwork).frame(width: 82, height: 82)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SymbolBadge: View {
    var symbol: String
    var color: Color = Palette.teal
    var body: some View {
        Image(systemName: symbol).font(.system(.body, design: .rounded, weight: .semibold))
            .foregroundStyle(color).frame(width: 44, height: 44)
            .background(color.opacity(0.10), in: RoundedRectangle(cornerRadius: 15))
            .accessibilityHidden(true)
    }
}

struct StatusPill: View {
    var title: String
    var symbol = "circle.dotted"
    var background: Color = Palette.soft
    var body: some View {
        Label(title, systemImage: symbol).font(.caption.weight(.medium))
            .foregroundStyle(Palette.teal).padding(.horizontal, 11).padding(.vertical, 7)
            .background(background, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct BrandMark: View {
    var body: some View {
        Image(systemName: "leaf.circle.fill").symbolRenderingMode(.palette)
            .foregroundStyle(Palette.teal, Palette.soft).font(.system(size: 50))
            .accessibilityHidden(true)
    }
}

struct FilledActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.horizontal, 18).padding(.vertical, 16)
            .foregroundStyle(.white)
            .background(Palette.actionGradient, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: Palette.teal.opacity(enabled ? 0.14 : 0), radius: 10, x: 0, y: 5)
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}

struct ActionTile: View {
    var title: String
    var subtitle: String
    var symbol: String
    var prominent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: symbol).font(.title2.weight(.semibold))
                    .foregroundStyle(prominent ? Palette.peach : Palette.purple)
                Spacer(minLength: 0)
                HeaderArtwork(kind: prominent ? .meal : .weight).frame(width: 55, height: 44)
            }.accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).foregroundStyle(Palette.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(17)
        .foregroundStyle(Palette.ink)
        .background(LinearGradient(colors: [prominent ? Palette.warm : Palette.lavender, Palette.card.opacity(0.7)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 22))
        .accessibilityElement(children: .combine)
    }
}

struct MetricView: View {
    var title: String
    var value: Double?
    var unit: String
    var color: Color = Palette.ink
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(Palette.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value?.concise ?? "—").font(.system(.title2, design: .rounded, weight: .bold)).monospacedDigit()
                if value != nil { Text(unit).font(.caption).foregroundStyle(color) }
            }.foregroundStyle(color).lineLimit(1).minimumScaleFactor(0.75)
            if value == nil { Text("等待记录").font(.caption2).foregroundStyle(Palette.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

struct SettingsRow: View {
    var title: String
    var symbol: String
    var detail: String? = nil
    var color: Color = Palette.teal
    var body: some View {
        HStack(spacing: 13) {
            SymbolBadge(symbol: symbol, color: color)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Palette.ink)
                if let detail { Text(detail).font(.caption).foregroundStyle(Palette.secondary) }
            }
            Spacer(minLength: 8)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(Palette.secondary)
                .accessibilityHidden(true)
        }.frame(minHeight: 48).contentShape(Rectangle())
    }
}

struct HintLabel: View {
    var text: String
    var systemImage = "info.circle"
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(Palette.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct EmptyRecordsView: View {
    var title: String
    var message: String
    var symbol: String
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: symbol).font(.system(.largeTitle, design: .rounded))
                .foregroundStyle(Palette.teal).frame(width: 76, height: 76)
                .background(Palette.soft, in: RoundedRectangle(cornerRadius: 26))
                .accessibilityHidden(true)
            Text(title).font(.headline).foregroundStyle(Palette.ink)
            Text(message).font(.subheadline).foregroundStyle(Palette.secondary).multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 26).padding(.horizontal, 16).frame(maxWidth: .infinity)
    }
}

struct DateStrip: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dynamicTypeSize) private var typeSize
    var body: some View {
        dateLayout {
            Button { model.selectToday() } label: {
                Label("今天", systemImage: "sun.max").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(Palette.soft, in: Capsule())
            }.buttonStyle(.plain).foregroundStyle(Palette.teal)
                .accessibilityHint("返回当前统计日期")
            if !typeSize.isAccessibilitySize { Spacer(minLength: 0) }
            HStack(spacing: 6) {
                Image(systemName: "calendar").foregroundStyle(Palette.secondary).accessibilityHidden(true)
                DatePicker("记录日期", selection: Binding(get: { model.displayDate }, set: { model.selectedDate = $0 }),
                           in: ...Date(), displayedComponents: .date)
                    .labelsHidden().tint(Palette.teal)
                    .environment(\.timeZone, TimeZone(identifier: model.profile.timezone) ?? .current)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .contain)
    }

    private var dateLayout: AnyLayout {
        typeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
    }
}

struct TrendRangeButtons: View {
    @Environment(\.dynamicTypeSize) private var typeSize
    @Binding var selection: Int
    private let ranges = [(7, "7天"), (30, "30天"), (90, "90天"), (365, "1年"), (0, "自定义")]

    var body: some View {
        Group {
            if typeSize.isAccessibilitySize {
                Picker("时间范围", selection: $selection) {
                    ForEach(ranges, id: \.0) { Text($0.1).tag($0.0) }
                }.pickerStyle(.menu).frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                HStack(spacing: 0) {
                    ForEach(ranges, id: \.0) { range in
                        Button { selection = range.0 } label: {
                            Text(range.1).font(.subheadline.weight(.medium)).lineLimit(1)
                                .frame(maxWidth: .infinity, minHeight: 38)
                                .foregroundStyle(selection == range.0 ? .white : Palette.ink)
                                .background {
                                    if selection == range.0 { RoundedRectangle(cornerRadius: 12).fill(Palette.actionGradient) }
                                }
                        }.buttonStyle(.plain).accessibilityAddTraits(selection == range.0 ? .isSelected : [])
                    }
                }.padding(3).background(Palette.border.opacity(0.35), in: RoundedRectangle(cornerRadius: 15))
            }
        }.accessibilityElement(children: .contain).accessibilityLabel("趋势时间范围")
    }
}

struct PhotoThumbnail: View {
    @EnvironmentObject private var model: AppModel
    var id: String
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { ZStack { Palette.sage.opacity(0.15); Image(systemName: "photo").foregroundStyle(.secondary) } }
        }
        .frame(width: 82, height: 82).clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(Palette.border.opacity(0.6), lineWidth: 0.5) }
        .task(id: id) {
            if let data = await model.thumbnailData(id) { image = UIImage(data: data) }
        }
        .accessibilityLabel("餐食照片")
    }
}

struct PrivacyNote: View {
    var body: some View {
        HintLabel(text: "照片识别和能量计算均为估算。记录用于了解趋势，不能替代医疗评估。", systemImage: "heart.text.square")
    }
}
