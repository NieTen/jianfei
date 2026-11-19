import SwiftUI

private let shareScopes = [("weight", "当天体重"), ("diet", "饮食摘要"), ("meals", "餐次与营养明细"),
                           ("photos", "餐食照片"), ("notes", "餐次备注")]

struct SharingCenterView: View {
    @EnvironmentObject private var model: AppModel
    @State private var direction = "sent"
    @State private var rows: [JSONObject] = []
    @State private var cursor: String?
    @State private var requestID = UUID()
    @State private var loading = false
    @State private var message = ""

    var body: some View {
        List {
            Picker("共享方向", selection: $direction) {
                Text("我发出的").tag("sent")
                Text("我收到的").tag("received")
            }.pickerStyle(.segmented)
            if direction == "sent" {
                NavigationLink("新建只读共享") { ShareEditorView(grant: nil) }
            }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, grant in
                let active = grant.flag("active")
                NavigationLink {
                    if direction == "sent" { ShareEditorView(grant: grant) }
                    else { SharedDayView(grant: grant) }
                } label: {
                    VStack(alignment: .leading) {
                        Text(grant.text("counterpart"))
                        Text(active ? "有效期至 " + (TimeFormat.parse(grant.text("expires_at"))?.formatted() ?? "") : "授权已失效")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.disabled(!active)
            }
            if loading { ProgressView() }
            else if rows.isEmpty && message.isEmpty { Text("暂无共享授权").foregroundStyle(.secondary) }
            if cursor != nil { Button("加载下一页") { Task { await load(more: true) } }.disabled(loading) }
        }
        .navigationTitle("共享中心")
        .task(id: direction) { await load() }
        .refreshable { await load() }
        .onChange(of: model.localDataContext) { _, _ in
            rows = []; cursor = nil; message = ""; requestID = UUID(); loading = false
            Task { await load() }
        }
    }

    private func load(more: Bool = false) async {
        let context = model.localDataContext
        let selection = direction
        let token = UUID()
        requestID = token
        let after = more ? cursor ?? "" : ""
        if !more { rows = []; cursor = nil }
        loading = true
        message = ""
        defer { if requestID == token { loading = false } }
        do {
            let response = try await model.api.send("shares", query: ["direction": selection, "after": after]).object ?? [:]
            try model.checkLocalContext(context)
            guard requestID == token, selection == direction, !Task.isCancelled else { return }
            rows += response.objects("items")
            cursor = response["next"]?.string
        } catch {
            if requestID == token, context == model.localDataContext, !Task.isCancelled { message = error.localizedDescription }
        }
    }
}

struct ShareEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let grant: JSONObject?
    @State private var recipient = ""
    @State private var scopes: Set<String> = []
    @State private var start = Date()
    @State private var end = Date()
    @State private var expiry = Calendar.current.date(byAdding: .day, value: 7, to: Date()) ?? Date()
    @State private var identifier = UUID().uuidString.lowercased()
    @State private var busy = false
    @State private var message = ""
    @State private var confirmRevoke = false

    var body: some View {
        AppForm {
            Section("接收人") {
                if let grant { Text(grant.text("counterpart")) }
                else { TextField("对方的注册邮箱或私有账号", text: $recipient).textInputAutocapitalization(.never).autocorrectionDisabled() }
            }
            Section("可以查看的内容") {
                ForEach(shareScopes, id: \.0) { key, label in
                    Toggle(label, isOn: Binding(get: { scopes.contains(key) }, set: {
                        if $0 { scopes.insert(key) } else { scopes.remove(key) }
                    }))
                }
            }
            Section("授权期限") {
                DatePicker("记录起始日", selection: $start, displayedComponents: .date)
                DatePicker("记录结束日", selection: $end, in: Calendar.current.startOfDay(for: start)..., displayedComponents: .date)
                DatePicker("访问到期时间", selection: $expiry)
            }
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            Button("保存授权") { Task { await save() } }
                .disabled(busy || scopes.isEmpty || expiry <= Date() || (grant == nil && recipient.trimmingCharacters(in: .whitespaces).isEmpty))
            if grant != nil {
                Button("撤销共享", role: .destructive) { confirmRevoke = true }.disabled(busy)
            }
        }
        .navigationTitle(grant == nil ? "新建只读共享" : "管理共享")
        .onAppear {
            guard let grant else { return }
            identifier = grant.text("id")
            scopes = Set(grant.strings("scopes"))
            start = TimeFormat.window(grant.text("from_day"), timezone: TimeZone.current.identifier)?.start ?? start
            end = TimeFormat.window(grant.text("through_day"), timezone: TimeZone.current.identifier)?.start ?? end
            expiry = TimeFormat.parse(grant.text("expires_at")) ?? expiry
        }
        .onChange(of: start) { _, date in if end < date { end = date } }
        .onChange(of: model.localDataContext) { _, _ in dismiss() }
        .confirmationDialog("撤销后，对方将无法继续读取这份共享。", isPresented: $confirmRevoke) {
            Button("确认撤销", role: .destructive) { Task { await revoke() } }
        }
    }

    private func save() async {
        guard !busy else { return }
        busy = true
        defer { busy = false }
        let context = model.localDataContext
        var body: JSONObject = ["scopes": .array(scopes.sorted().map(JSONValue.string)), "from_day": .string(TimeFormat.day(start)),
                                "through_day": .string(TimeFormat.day(end)), "expires_at": .string(TimeFormat.iso(expiry)),
                                "expected_version": .number(grant?.number("version") ?? 0)]
        if grant == nil { body["recipient"] = .string(recipient.trimmingCharacters(in: .whitespacesAndNewlines)) }
        do {
            let apiContext = await model.api.requestContext()
            try model.checkLocalContext(context)
            _ = try await model.api.send("shares/\(identifier)", method: "PUT", body: body, expectedContext: apiContext)
            try model.checkLocalContext(context)
            dismiss()
        } catch { if context == model.localDataContext { message = error.localizedDescription } }
    }

    private func revoke() async {
        guard !busy else { return }
        let context = model.localDataContext
        let path = "shares/\(identifier)/revoke"
        busy = true
        defer { busy = false }
        do {
            let apiContext = await model.api.requestContext()
            try model.checkLocalContext(context)
            _ = try await model.api.send(path, method: "POST", body: [:], expectedContext: apiContext)
            try model.checkLocalContext(context)
            dismiss()
        } catch is URLError {
            do {
                try model.checkLocalContext(context)
                try await model.queueCommand(path: path, priority: 100)
                message = model.syncEnabled ? "撤销已排队，等待服务器确认" : "撤销等待服务器确认。联网后可再次点击撤销，或开启同步发送。"
            } catch { if context == model.localDataContext { message = error.localizedDescription } }
        } catch { if context == model.localDataContext { message = error.localizedDescription } }
    }
}

struct SharedDayView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var phase
    let grant: JSONObject
    @State private var date = Date()
    @State private var result: JSONObject = [:]
    @State private var message = ""
    @State private var loadID = UUID()
    @State private var deadline: TimeInterval?
    private var start: Date { TimeFormat.window(grant.text("from_day"), timezone: TimeZone.current.identifier)?.start ?? Date() }
    private var end: Date { TimeFormat.window(grant.text("through_day"), timezone: TimeZone.current.identifier)?.end.addingTimeInterval(-1) ?? Date() }

    var body: some View {
        List {
            DatePicker("查看日期", selection: $date, in: start...max(start, end), displayedComponents: .date)
            if !message.isEmpty { Text(message).foregroundStyle(.secondary) }
            if !result.isEmpty {
                if result["weight_kg"] != nil {
                    LabeledContent("当天体重", value: result.number("weight_kg").map { model.weightUnit.formatted(kilograms: $0) } ?? "未记录")
                }
                if let diet = result["diet"]?.object {
                    LabeledContent("已记录摄入", value: diet.number("intake_kcal").map { "\($0.concise) 千卡" } ?? "未知")
                    LabeledContent("饮食记录", value: diet.flag("intake_complete") ? "完整" : "未完成")
                }
                ForEach(Array(result.objects("meals").enumerated()), id: \.offset) { _, meal in
                    Section(MealTypes.name(meal.text("meal_type"))) {
                        ForEach(Array(meal.objects("items").enumerated()), id: \.offset) { _, item in
                            Text("\(item.text("name")) · \(item.number("amount")?.concise ?? "") \(item.text("unit"))")
                            if let kcal = item["nutrition"]?.object?.number("kcal") { Text("\(kcal.concise) 千卡").font(.caption) }
                        }
                        if !meal.text("note").isEmpty { Text(meal.text("note")) }
                        ForEach(meal.strings("photo_ids"), id: \.self) { photo in
                            SharedGrantPhoto(grantID: grant.text("id"), photoID: photo)
                        }
                    }
                }
            }
        }
        .navigationTitle(grant.text("counterpart"))
        .onAppear { date = min(max(date, start), end) }
        .task(id: TimeFormat.day(date)) { await load() }
        .refreshable { await load() }
        .onChange(of: model.localDataContext) { _, _ in
            result = [:]; deadline = nil; loadID = UUID(); message = "账号已切换，请重新打开共享"
        }
        .onDisappear { result = [:]; deadline = nil; loadID = UUID() }
        .onChange(of: phase) { _, phase in
            result = [:]; deadline = nil; loadID = UUID()
            if phase == .active { Task { await load() } }
        }
        .task(id: deadline) {
            guard let limit = deadline else { return }
            do { try await Task.sleep(for: .seconds(max(0, limit - ProcessInfo.processInfo.systemUptime))) } catch { return }
            guard limit == deadline else { return }
            result = [:]
            // 在同一任务完成刷新后替换期限，避免取消正在进行的刷新。
            await load()
        }
    }

    private func load() async {
        let token = UUID()
        loadID = token
        let context = model.localDataContext
        let day = TimeFormat.day(date)
        result = [:]
        guard phase == .active else { return }
        let started = ProcessInfo.processInfo.systemUptime
        do {
            let response = try await model.api.send("shares/\(grant.text("id"))/summary", query: ["day": day]).object ?? [:]
            try model.checkLocalContext(context)
            guard loadID == token, day == TimeFormat.day(date), !Task.isCancelled, phase == .active else { return }
            let duration = SharedSummaryLease.grantDuration(response, elapsed: ProcessInfo.processInfo.systemUptime - started)
            guard duration > 0 else {
                throw APIError(code: "SHARE_EXPIRED", message: "共享已到期")
            }
            result = response
            deadline = ProcessInfo.processInfo.systemUptime + duration
            message = ""
        } catch {
            guard loadID == token, context == model.localDataContext else { return }
            deadline = nil
            message = error.localizedDescription
        }
    }
}

private struct SharedGrantPhoto: View {
    @EnvironmentObject private var model: AppModel
    let grantID: String
    let photoID: String
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 240) }
            else { Text("餐食照片").foregroundStyle(.secondary) }
        }.task(id: photoID) {
            let context = model.localDataContext
            image = nil
            let bytes = try? await model.api.request("shares/\(grantID)/media/\(photoID)", query: ["thumbnail": "true"])
            if let bytes, !Task.isCancelled, context == model.localDataContext { image = UIImage(data: bytes) }
        }
    }
}

struct ProgressCardShareView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.displayScale) private var scale
    @State private var preview: UIImage?

    var body: some View {
        VStack(spacing: 24) {
            if let preview {
                let image = Image(uiImage: preview)
                image.resizable().scaledToFit()
                ShareLink(item: image, preview: SharePreview("我的记录卡片", image: image)) {
                    Label("分享这张卡片", systemImage: "square.and.arrow.up")
                }.buttonStyle(FilledActionStyle())
            }
        }.padding().navigationTitle("卡片预览")
        .task(id: model.dataRevision) {
            let records = model.recordIndex.byDay[model.day] ?? []
            let meals = records.filter { $0.kind == "meal" && ["confirmed", "skipped"].contains($0.payload.text("status")) }
            let card = VStack(alignment: .leading, spacing: 16) {
                Text("并肩 · 我的记录").font(.title.bold())
                Text(model.day).font(.headline)
                Text("饮食已记录 \(Set(meals.map { $0.payload.text("meal_type") }).count) 个餐次")
                Text(model.recordIndex.representativeWeight(day: model.day) == nil ? "当天尚无体重记录" : "已完成当天体重记录")
            }.padding(28).frame(width: 320, alignment: .leading).foregroundStyle(Color.black)
                .background(Color(red: 0.91, green: 0.96, blue: 0.93))
            let renderer = ImageRenderer(content: card)
            renderer.scale = scale
            preview = renderer.uiImage
        }
    }
}
