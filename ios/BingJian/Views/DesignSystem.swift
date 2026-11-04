import SwiftUI
import UIKit

enum Palette {
    static let teal = Color(red: 0.05, green: 0.42, blue: 0.42)
    static let sage = Color(red: 0.57, green: 0.75, blue: 0.69)
    static let peach = Color(red: 0.93, green: 0.62, blue: 0.40)
    static let ink = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? .white : UIColor(red: 0.09, green: 0.22, blue: 0.28, alpha: 1) })
    static let canvas = Color(uiColor: UIColor { $0.userInterfaceStyle == .dark ? UIColor(red: 0.06, green: 0.11, blue: 0.13, alpha: 1) : UIColor(red: 0.94, green: 0.97, blue: 0.97, alpha: 1) })
    static let card = Color(uiColor: .secondarySystemGroupedBackground)
}

struct Surface<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}

struct MetricView: View {
    var title: String
    var value: Double?
    var unit: String
    var color: Color = Palette.ink
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(value?.concise ?? "—").font(.system(size: 28, weight: .semibold, design: .rounded)).monospacedDigit()
                if value != nil { Text(unit).font(.caption).foregroundStyle(.secondary) }
            }.foregroundStyle(color)
            if value == nil { Text("暂无数据").font(.caption2).foregroundStyle(.secondary) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct HintLabel: View {
    var text: String
    var systemImage = "info.circle"
    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

struct EmptyRecordsView: View {
    var title: String
    var message: String
    var symbol: String
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: symbol).font(.system(size: 32)).foregroundStyle(Palette.sage)
            Text(title).font(.headline)
            Text(message).font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
        }.padding(30).frame(maxWidth: .infinity)
    }
}

struct DateStrip: View {
    @EnvironmentObject private var model: AppModel
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(model.day).font(.title2.weight(.semibold))
                Button("今天") { model.selectToday() }.font(.caption)
            }
            Spacer()
            DatePicker("记录日期", selection: Binding(get: { model.displayDate }, set: { model.selectedDate = $0 }),
                       in: ...Date(), displayedComponents: .date)
                .labelsHidden().tint(Palette.teal)
                .environment(\.timeZone, TimeZone(identifier: model.profile.timezone) ?? .current)
        }
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
