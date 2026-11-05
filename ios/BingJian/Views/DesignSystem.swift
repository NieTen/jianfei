import SwiftUI
import UIKit

enum Palette {
    static let teal = adaptive(light: 0x176B5A, dark: 0x8DD4BB)
    static let sage = adaptive(light: 0x789F8E, dark: 0xA5C9B8)
    static let peach = adaptive(light: 0xA55C32, dark: 0xEDB38C)
    static let ink = adaptive(light: 0x193C33, dark: 0xE8F2EB)
    static let secondary = adaptive(light: 0x5C7067, dark: 0xB4C6BC)
    static let canvas = adaptive(light: 0xF4F6F1, dark: 0x101C18)
    static let card = adaptive(light: 0xFFFFFF, dark: 0x1B2A23)
    static let soft = adaptive(light: 0xE5EFE7, dark: 0x2A4035)
    static let border = adaptive(light: 0xDDE6DE, dark: 0x3C5044)
    static let forest = Color(red: 0.07, green: 0.24, blue: 0.20)
    static let mint = Color(red: 0.72, green: 0.88, blue: 0.78)

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
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: 24).strokeBorder(Palette.border.opacity(0.65), lineWidth: 0.5) }
            .shadow(color: .black.opacity(0.025), radius: 16, x: 0, y: 6)
    }
}

struct PageHeading: View {
    var title: String
    var subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.system(.largeTitle, design: .rounded, weight: .bold)).foregroundStyle(Palette.ink)
                .accessibilityAddTraits(.isHeader)
            Text(subtitle).font(.subheadline).foregroundStyle(Palette.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
    var body: some View {
        Label(title, systemImage: symbol).font(.caption.weight(.medium))
            .foregroundStyle(Palette.teal).padding(.horizontal, 11).padding(.vertical, 7)
            .background(Palette.soft, in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct BrandMark: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 7) {
            Capsule().fill(Palette.teal).frame(width: 18, height: 58)
            VStack(spacing: 5) {
                Circle().fill(Palette.peach).frame(width: 13, height: 13)
                Capsule().fill(Palette.sage).frame(width: 18, height: 37)
            }
        }.accessibilityHidden(true)
    }
}

struct FilledActionStyle: ButtonStyle {
    @Environment(\.isEnabled) private var enabled
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline)
            .frame(maxWidth: .infinity, minHeight: 24)
            .padding(.horizontal, 18).padding(.vertical, 16)
            .foregroundStyle(.white)
            .background(Palette.forest, in: RoundedRectangle(cornerRadius: 18))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.5)
    }
}

struct ActionTile: View {
    var title: String
    var subtitle: String
    var symbol: String
    var prominent = false
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: symbol).font(.title2).accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline)
                Text(subtitle).font(.caption).opacity(0.85)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(20)
        .foregroundStyle(prominent ? .white : Palette.ink)
        .background(prominent ? Palette.forest : Palette.soft, in: RoundedRectangle(cornerRadius: 22))
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
                if value != nil { Text(unit).font(.caption).foregroundStyle(Palette.secondary) }
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
    var body: some View {
        HStack(spacing: 13) {
            SymbolBadge(symbol: symbol)
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
    var body: some View {
        HStack(spacing: 12) {
            Button { model.selectToday() } label: {
                Label("今天", systemImage: "sun.max").font(.subheadline.weight(.semibold))
                    .padding(.horizontal, 12).frame(minHeight: 44)
                    .background(Palette.soft, in: Capsule())
            }.buttonStyle(.plain).foregroundStyle(Palette.teal)
                .accessibilityHint("返回当前统计日期")
            Spacer()
            DatePicker("记录日期", selection: Binding(get: { model.displayDate }, set: { model.selectedDate = $0 }),
                       in: ...Date(), displayedComponents: .date)
                .labelsHidden().tint(Palette.teal)
                .environment(\.timeZone, TimeZone(identifier: model.profile.timezone) ?? .current)
        }.accessibilityElement(children: .contain)
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
