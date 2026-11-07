import SwiftUI

enum HeaderArtworkKind {
    case sunrise, food, trend, meal, weight
}

struct HeaderArtwork: View {
    let kind: HeaderArtworkKind

    var body: some View {
        GeometryReader { size in
            artwork.frame(width: 100, height: 100)
                .scaleEffect(min(size.size.width, size.size.height) / 100, anchor: .topLeading)
        }.accessibilityHidden(true).allowsHitTesting(false)
    }

    @ViewBuilder private var artwork: some View {
        switch kind {
        case .sunrise:
            ZStack {
                Circle().fill(.yellow.opacity(0.12)).frame(width: 84, height: 84).offset(x: 12, y: -4)
                Image(systemName: "sun.max.fill").font(.system(size: 55)).foregroundStyle(.yellow.gradient).offset(x: 10, y: -9)
                Ellipse().fill(Color.green.opacity(0.18)).frame(width: 110, height: 48).rotationEffect(.degrees(-22)).offset(x: -14, y: 35)
                Ellipse().fill(Color.green.opacity(0.30)).frame(width: 106, height: 56).rotationEffect(.degrees(-24)).offset(x: 30, y: 31)
            }.clipped()
        case .food:
            ZStack {
                Image(systemName: "leaf.fill").font(.system(size: 42)).foregroundStyle(.green.gradient).rotationEffect(.degrees(-25)).offset(x: 24, y: -28)
                Ellipse().fill(Color.green.gradient).frame(width: 48, height: 67).rotationEffect(.degrees(25)).offset(x: -15, y: 4)
                Ellipse().fill(Color(red: 0.88, green: 0.97, blue: 0.57)).frame(width: 38, height: 56).rotationEffect(.degrees(25)).offset(x: -15, y: 4)
                Circle().fill(Color.brown.gradient).frame(width: 22).offset(x: -18, y: 13)
                Circle().fill(Color.orange.gradient).frame(width: 40).offset(x: 23, y: 25)
                Circle().fill(Color.red.gradient).frame(width: 34).offset(x: 29, y: 29)
                Image(systemName: "leaf.fill").foregroundStyle(.green).font(.system(size: 19)).rotationEffect(.degrees(-40)).offset(x: 28, y: 9)
            }.shadow(color: .green.opacity(0.12), radius: 4, y: 5)
        case .trend:
            ZStack(alignment: .bottom) {
                Ellipse().fill(Palette.soft).frame(width: 96, height: 16).offset(y: -8)
                HStack(alignment: .bottom, spacing: 7) {
                    ForEach(0..<4) { index in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [Color.green.opacity(0.7), Palette.teal.opacity(0.7)], startPoint: .top, endPoint: .bottom))
                            .frame(width: 13, height: CGFloat(20 + index * 14))
                    }
                }.padding(.bottom, 17)
                Image(systemName: "arrow.up.right").font(.system(size: 60, weight: .light)).foregroundStyle(.yellow).offset(x: 4, y: -34)
            }
        case .meal:
            ZStack {
                Image(systemName: "leaf.fill").font(.system(size: 35)).foregroundStyle(.green.gradient).rotationEffect(.degrees(25)).offset(x: 17, y: -24)
                Ellipse().fill(Color.orange).frame(width: 76, height: 36).offset(y: 8)
                Ellipse().fill(Color(red: 1, green: 0.94, blue: 0.71)).frame(width: 67, height: 28).offset(y: 3)
                HStack(spacing: 2) {
                    Circle().fill(.green.gradient).frame(width: 19)
                    Circle().fill(.orange.gradient).frame(width: 19)
                    Circle().fill(.green.gradient).frame(width: 19)
                }.offset(y: -1)
                UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26)
                    .fill(LinearGradient(colors: [.orange, .yellow], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 70, height: 33).offset(y: 28)
            }.shadow(color: .orange.opacity(0.15), radius: 4, y: 5)
        case .weight:
            ZStack {
                RoundedRectangle(cornerRadius: 17).fill(Palette.purple.opacity(0.18).gradient).frame(width: 75, height: 82)
                RoundedRectangle(cornerRadius: 17).stroke(Palette.purple.opacity(0.4), lineWidth: 2).frame(width: 75, height: 82)
                Image(systemName: "gauge.with.needle").font(.system(size: 30)).foregroundStyle(Palette.purple).offset(y: -17)
                HStack(spacing: 16) {
                    Capsule().fill(Palette.purple.opacity(0.25)).frame(width: 13, height: 29)
                    Capsule().fill(Palette.purple.opacity(0.25)).frame(width: 13, height: 29)
                }.offset(y: 20)
            }.rotationEffect(.degrees(5))
        }
    }
}

struct HeroWave: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
            path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                          control1: CGPoint(x: rect.width * 0.45, y: rect.maxY),
                          control2: CGPoint(x: rect.width * 0.58, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
            path.closeSubpath()
        }
    }
}
