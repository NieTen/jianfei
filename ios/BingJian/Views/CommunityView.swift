import CoreImage.CIFilterBuiltins
import Charts
import SwiftUI
import Vision

struct InviteDisplay: Identifiable {
    var id: String { code }
    var code: String
}

struct CommunityView: View {
    @EnvironmentObject private var model: AppModel
    @State private var create = false
    @State private var join = false
    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                PageHeading(title: "一起记录，彼此鼓励", subtitle: "各自努力，也为对方的小进步高兴。")
                Surface {
                    HStack(alignment: .top, spacing: 20) {
                        BrandMark().padding(12).background(Palette.soft, in: RoundedRectangle(cornerRadius: 20))
                        VStack(alignment: .leading, spacing: 7) {
                            Text("找到你的记录伙伴").font(.system(.title3, design: .rounded).weight(.semibold)).foregroundStyle(Palette.ink)
                            Text("双人或最多八人的小组，按授权分享进度。").font(.subheadline).foregroundStyle(Palette.secondary)
                        }
                    }
                    Button("创建挑战") { create = true }.buttonStyle(FilledActionStyle()).disabled(model.session == nil)
                    Button { join = true } label: {
                        Label("已有邀请码，加入挑战", systemImage: "ticket").font(.subheadline.weight(.medium))
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }.disabled(model.session == nil)
                    if model.session == nil {
                        Divider()
                        NavigationLink { ConnectionSettingsView() } label: {
                            SettingsRow(title: "连接并登录后台", symbol: "link", detail: "登录后邀请伙伴或加入挑战")
                        }.buttonStyle(.plain)
                    }
                }
                ForEach(model.challenges.indices, id: \.self) { index in
                    let challenge = model.challenges[index]
                    NavigationLink {
                        ChallengeDetailView(challengeId: challenge.text("id"))
                    } label: {
                        Surface {
                            HStack {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(challenge.text("title")).font(.headline).foregroundStyle(Palette.ink)
                                    StatusPill(title: "\(challenge.objects("members").count) 人 · \(challengeStatus(challenge.text("status")))", symbol: "person.2")
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                if model.challenges.isEmpty {
                    EmptyRecordsView(title: "还没有挑战", message: "双方分别确认规则和共享范围后，挑战才会开始。", symbol: "person.2.circle")
                }
            }.padding(20)
        }
        .background(Palette.canvas)
        .navigationTitle("伙伴")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if model.session != nil { try? await model.refreshChallenges() }
            if UserDefaults.standard.string(forKey: "pending_invite") != nil { join = true }
        }
        .refreshable { if model.session != nil { try? await model.refreshChallenges() } }
        .sheet(isPresented: $create) { NavigationStack { CreateChallengeView() } }
        .sheet(isPresented: $join) { NavigationStack { JoinChallengeView() } }
    }
}

func challengeStatus(_ value: String) -> String {
    ["pending": "待成员确认", "scheduled": "等待开始", "active": "进行中", "paused": "已暂停",
     "settling": "结算中", "finished": "已结束", "ended_early": "提前结束"][value] ?? value
}

struct CreateChallengeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = "一起好好记录"
    @State private var duration = 28
    @State private var members = 2
    @State private var selected = Set(["diet", "weight", "steps"])
    @State private var invitation: InviteDisplay?
    @State private var message: String?
    @State private var busy = false

    var body: some View {
        Form {
            Section("挑战设置") {
                TextField("挑战名称", text: $title)
                Stepper("成员 \(members) 人", value: $members, in: 2...8)
                Stepper("周期 \(duration) 天", value: $duration, in: 1...365)
                LabeledContent("统计时区", value: model.profile.timezone)
                LabeledContent("每日开始", value: String(format: "%02d:%02d", model.profile.dayStartMinutes / 60, model.profile.dayStartMinutes % 60))
            }
            Section("我的计分项目") {
                ForEach([("diet", "饮食记录完成"), ("weight", "记录体重"), ("steps", "达到个人步数目标")], id: \.0) { key, label in
                    Toggle(label, isOn: Binding(get: { selected.contains(key) }, set: { if $0 { selected.insert(key) } else { selected.remove(key) } }))
                }
                Text("每项每日最多 1 分。双方项目组合相同才比较累计积分，其他情况展示个人完成率。").font(.caption).foregroundStyle(.secondary)
            }
            Section("当前个人目标") {
                LabeledContent("目标体重", value: model.goal.targetWeightKg.map { model.weightUnit.formatted(kilograms: $0) } ?? "未设置")
                LabeledContent("步数目标", value: "\(model.goal.stepGoal) 步")
                Text("挑战开始后冻结本次目标快照。修改个人目标可用于后续挑战。").font(.caption).foregroundStyle(.secondary)
            }
            Button("创建并生成邀请") { Task { await create() } }.disabled(busy || selected.isEmpty)
        }
        .navigationTitle("创建挑战")
        .toolbar { Button("关闭") { dismiss() } }
        .sheet(item: $invitation, onDismiss: { dismiss() }) { invite in NavigationStack { InvitationView(code: invite.code) } }
        .alert("创建未完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(message ?? "") }
    }

    private func create() async {
        busy = true
        defer { busy = false }
        do {
            var goal = model.goal
            goal.selectedItems = selected.sorted()
            let response = try await model.api.send("challenges", method: "POST", body: [
                "title": .string(title), "timezone": .string(model.profile.timezone),
                "day_start_minutes": .number(Double(model.profile.dayStartMinutes)),
                "duration_days": .number(Double(duration)), "max_members": .number(Double(members)),
                "goal": .object(try Codec.object(goal))
            ])
            guard let result = response.object else { return }
            invitation = InviteDisplay(code: result.text("invite_code"))
            try await model.refreshChallenges()
        } catch { message = error.localizedDescription }
    }
}

struct JoinChallengeView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var code = UserDefaults.standard.string(forKey: "pending_invite") ?? ""
    @State private var showCamera = false
    @State private var message: String?
    @State private var preview: JSONObject = [:]

    var body: some View {
        Form {
            Section("邀请") {
                TextField("粘贴邀请码", text: $code).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("拍摄邀请二维码", systemImage: "qrcode.viewfinder") { showCamera = true }
                Button("查看邀请概要") {
                    model.perform {
                        preview = try await model.api.send("challenge-invites/\(code.trimmingCharacters(in: .whitespacesAndNewlines))").object ?? [:]
                    }
                }.disabled(code.isEmpty)
                Text("邀请码有效期为 24 小时，每个邀请码只能加入一位成员。").font(.caption).foregroundStyle(.secondary)
            }
            if !preview.isEmpty {
                Section("邀请概要") {
                    LabeledContent("发起人", value: preview.text("owner_name"))
                    LabeledContent("挑战", value: preview.text("title"))
                    LabeledContent("统计时区", value: preview.text("timezone"))
                    LabeledContent("成员人数", value: String(Int(preview.number("max_members") ?? 2)))
                    LabeledContent("周期", value: "\(Int(preview.number("duration_days") ?? 28)) 天")
                }
            }
            Button("加入并查看规则") {
                Task {
                    do {
                        _ = try await model.api.send("challenges/join", method: "POST",
                            body: ["code": .string(code.trimmingCharacters(in: .whitespacesAndNewlines)), "goal": .object(try Codec.object(model.goal))])
                        UserDefaults.standard.removeObject(forKey: "pending_invite")
                        try await model.refreshChallenges()
                        dismiss()
                    } catch { message = error.localizedDescription }
                }
            }.disabled(code.isEmpty || preview.isEmpty)
        }
        .navigationTitle("加入挑战")
        .onChange(of: code) { _, _ in preview = [:] }
        .toolbar { Button("取消") { dismiss() } }
        .sheet(isPresented: $showCamera) {
            CameraPicker { data in
                Task {
                    do {
                        let detector = VNDetectBarcodesRequest()
                        detector.symbologies = [.qr]
                        try VNImageRequestHandler(data: data).perform([detector])
                        guard let raw = detector.results?.first?.payloadStringValue else { throw APIError(code: "QR_NOT_FOUND", message: "没有识别到二维码，请重新拍摄") }
                        if let url = URL(string: raw),
                           let value = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "code" })?.value { code = value }
                        else { code = raw }
                    } catch { message = error.localizedDescription }
                }
            }
        }
        .alert("加入未完成", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("知道了", role: .cancel) {}
        } message: { Text(message ?? "") }
    }
}

struct InvitationView: View {
    @Environment(\.dismiss) private var dismiss
    let code: String
    private var link: String {
        var value = URLComponents()
        value.scheme = "bingjian"
        value.host = "join"
        value.queryItems = [URLQueryItem(name: "code", value: code)]
        return value.string ?? code
    }
    var body: some View {
        VStack(spacing: 24) {
            Text("邀请伙伴一起记录").font(.title2.weight(.semibold))
            if let image = qrImage {
                Image(uiImage: image).interpolation(.none).resizable().scaledToFit().frame(width: 240, height: 240).padding(20).background(.white, in: RoundedRectangle(cornerRadius: 20))
            }
            Text(code).font(.system(.callout, design: .monospaced)).textSelection(.enabled)
            ShareLink(item: link) { Label("分享邀请", systemImage: "square.and.arrow.up") }.buttonStyle(.borderedProminent)
            Button("复制邀请码") { UIPasteboard.general.string = code }
            Text("24 小时内有效，仅可使用一次").font(.caption).foregroundStyle(.secondary)
        }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity).background(Palette.canvas)
            .navigationTitle("邀请").toolbar { Button("完成") { dismiss() } }
    }
    private var qrImage: UIImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(link.utf8)
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let image = CIContext().createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: image)
    }
}

struct ChallengeDetailView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let challengeId: String
    @State private var data: JSONObject = [:]
    @State private var messages: [JSONObject] = []
    @State private var text = ""
    @State private var offline = false
    @State private var information = ""
    @State private var showConsent = false
    @State private var showLeave = false
    @State private var invitation: InviteDisplay?
    private var challenge: JSONObject { data["challenge"]?.object ?? [:] }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                DateStrip()
                if !information.isEmpty { HintLabel(text: information, systemImage: offline ? "wifi.slash" : "info.circle") }
                Surface {
                    Text(challenge.text("title", fallback: "挑战")).font(.title2.weight(.semibold))
                    Text(challengeStatus(challenge.text("status"))).font(.subheadline).foregroundStyle(Palette.teal)
                    Text("\(challenge.text("timezone")) · 日界线 \(Int(challenge.number("day_start_minutes") ?? 0) / 60):00 · \(Int(challenge.number("duration_days") ?? 0)) 天").font(.caption).foregroundStyle(.secondary)
                    if challenge.text("status") == "pending" {
                        Button("确认当前规则与个人目标") {
                            perform {
                                guard model.profile.timezone == challenge.text("timezone"),
                                      model.profile.dayStartMinutes == Int(challenge.number("day_start_minutes") ?? 0) else {
                                    throw APIError(code: "CHALLENGE_CLOCK", message: "请先在个人档案中将统计时区和日界线调整为当前挑战规则，再确认加入")
                                }
                                _ = try await model.api.send("challenges/\(challengeId)/confirm", method: "POST",
                                    body: ["version": .number(challenge.number("version") ?? 1)])
                            }
                        }.buttonStyle(.borderedProminent)
                        Button("生成下一位成员的邀请") {
                            perform {
                                let value = try await model.api.send("challenges/\(challengeId)/invite", method: "POST", body: [:])
                                invitation = InviteDisplay(code: value.object?.text("invite_code") ?? "")
                            }
                        }
                    }
                }
                let members = data.objects("members")
                ForEach(members.indices, id: \.self) { index in
                    let member = members[index]
                    Surface {
                        HStack {
                            Circle().fill(index.isMultiple(of: 2) ? Palette.teal : Palette.sage).frame(width: 12, height: 12)
                            Text(member.text("display_name")).font(.headline)
                            Spacer()
                            if member.flag("checked_in") { Label("已记录", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Palette.teal) }
                        }
                        if member.strings("scopes").isEmpty {
                            Text("成员尚未向你共享此日期的数据").font(.subheadline).foregroundStyle(.secondary)
                        } else {
                            HStack {
                                if member["goal_progress"] != nil { MetricView(title: "目标进度", value: member.number("goal_progress"), unit: "%") }
                                if member["weight_change_percent"] != nil { MetricView(title: "体重变化", value: member.number("weight_change_percent"), unit: "%") }
                                if member["steps"] != nil { MetricView(title: "步数", value: member.number("steps"), unit: "步") }
                            }
                            if let weight = member.number("weight_kg") { Text("体重 \(model.weightUnit.formatted(kilograms: weight))").font(.subheadline) }
                            if let health = member["health"]?.object {
                                HStack {
                                    MetricView(title: "平均心率", value: health.number("heart_rate"), unit: "次/分")
                                    MetricView(title: "睡眠", value: health.number("sleep_hours"), unit: "小时")
                                }
                            }
                            let sharedMeals = member.objects("meals")
                            ForEach(sharedMeals.indices, id: \.self) { mealIndex in
                                let sharedMeal = sharedMeals[mealIndex]
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(MealTypes.name(sharedMeal.text("meal_type"))).font(.subheadline.weight(.medium))
                                    Text(sharedMeal.objects("items").map { $0.text("name") }.joined(separator: "、")).font(.caption)
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack {
                                            ForEach(sharedMeal.strings("photo_ids"), id: \.self) { id in
                                                SharedPhotoThumbnail(id: id, challengeId: challengeId)
                                            }
                                        }
                                    }
                                }
                            }
                            if member.strings("scopes").contains("weight") {
                                NavigationLink("查看已授权的体重曲线") {
                                    PartnerHistoryView(challengeId: challengeId, userId: member.text("user_id"))
                                }.font(.caption)
                            }
                            HStack {
                                if let score = member.number("score") { Label("\(Int(score)) 分", systemImage: "flag") }
                                if let streak = member.number("streak") { Label("连续 \(Int(streak)) 天", systemImage: "calendar") }
                            }.font(.caption).foregroundStyle(.secondary)
                            if let score = member.number("score") {
                                let milestone = Int(score) / 10
                                if milestone > 0 { Label("已完成 \(milestone) 个十分里程碑", systemImage: "star.circle").font(.caption).foregroundStyle(Palette.teal) }
                            }
                            if member.flag("result_frozen") { Text("挑战比较结果已冻结").font(.caption2).foregroundStyle(.secondary) }
                        }
                    }
                }
                Surface {
                    Text("送一句鼓励").font(.headline)
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(["今天也一起记录", "慢慢来，我陪你", "记得好好吃饭"], id: \.self) { phrase in
                                Button(phrase) { text = phrase }.buttonStyle(.bordered).font(.caption)
                            }
                        }
                    }
                    TextField("写给伙伴，最多 200 字", text: $text, axis: .vertical)
                    Button("发送鼓励") {
                        model.perform {
                            try await model.queueCommand(path: "challenges/\(challengeId)/encouragements",
                                body: ["id": .string(UUID().uuidString.lowercased()), "message": .string(String(text.prefix(200)))])
                            text = ""
                        }
                    }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ForEach(messages.indices, id: \.self) { index in
                        let message = messages[index]
                        VStack(alignment: .leading, spacing: 4) {
                            Text(message.text("message"))
                            Text(TimeFormat.parse(message.text("created_at"))?.formatted(date: .abbreviated, time: .shortened) ?? "")
                                .font(.caption2).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity, alignment: .leading)
                        .contextMenu {
                            if message.text("sender_id") == model.session?.userId {
                                Button("删除留言", role: .destructive) {
                                    perform { _ = try await model.api.send("challenges/\(challengeId)/encouragements/\(message.text("id"))", method: "DELETE") }
                                }
                            }
                        }
                    }
                }
                Surface {
                    Button("管理我的共享范围", systemImage: "hand.raised") { showConsent = true }
                    if challenge.text("status") == "active" {
                        Button("暂停挑战") { perform { _ = try await model.api.send("challenges/\(challengeId)/pause", method: "POST", body: [:]) } }
                    }
                    if challenge.text("status") == "paused" {
                        Button("同意恢复挑战") { perform { _ = try await model.api.send("challenges/\(challengeId)/resume", method: "POST", body: [:]) } }
                    }
                    Button("退出本次挑战", role: .destructive) { showLeave = true }
                    if !challenge.text("pair_id").isEmpty {
                        Button("解除配对关系", role: .destructive) {
                            model.perform {
                                try await model.queueCommand(path: "pairs/\(challenge.text("pair_id"))", method: "DELETE", priority: 100)
                                dismiss()
                            }
                        }
                    }
                }
            }.padding(20)
        }
        .background(Palette.canvas).navigationTitle("共同记录").navigationBarTitleDisplayMode(.inline)
        .task { await load() }.refreshable { await load() }
        .onChange(of: model.day) { _, _ in Task { await load() } }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in Task { await load() } }
        .sheet(isPresented: $showConsent) {
            NavigationStack { ConsentEditorView(challengeId: challengeId, challenge: challenge) }
        }
        .sheet(item: $invitation) { value in NavigationStack { InvitationView(code: value.code) } }
        .confirmationDialog("退出将结束本次挑战，并撤销本次双方或小组共享授权", isPresented: $showLeave) {
            Button("确认退出", role: .destructive) {
                model.perform {
                    try await model.queueCommand(path: "challenges/\(challengeId)/leave", priority: 100)
                    dismiss()
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    private func perform(_ operation: @escaping @MainActor () async throws -> Void) {
        Task {
            do { try await operation(); await load() }
            catch { information = error.localizedDescription }
        }
    }

    private func load() async {
        let key = "shared_summary:\(challengeId):\(model.day)"
        do {
            let response = try await model.api.send("challenges/\(challengeId)/summary", query: ["day": model.day])
            data = response.object ?? [:]
            messages = try await model.api.send("challenges/\(challengeId)/encouragements").array?.compactMap(\.object) ?? []
            var cached = data
            cached["cached_at_local"] = .string(TimeFormat.iso())
            try await model.requireStore().setMetadata(key, value: Codec.json(cached))
            offline = false
            information = "更新于 \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            if let apiError = error as? APIError, ["FORBIDDEN", "CONSENT_REVOKED", "DEVICE_REVOKED", "AUTH_EXPIRED"].contains(apiError.code) {
                data = [:]
                try? await model.requireStore().setMetadata(key, value: nil)
            } else if let cached = try? await model.requireStore().metadata(key),
                      let object = try? JSONDecoder().decode(JSONObject.self, from: Data(cached.utf8)),
                      let until = TimeFormat.parse(object.text("cached_until")), until > Date(),
                      let saved = TimeFormat.parse(object.text("cached_at_local")), Date() >= saved {
                data = object
                offline = true
            } else { data = [:] }
            information = offline ? "当前显示最近同步缓存，授权租约到期后隐藏。\(error.localizedDescription)" : error.localizedDescription
        }
    }
}

struct SharedPhotoThumbnail: View {
    @EnvironmentObject private var model: AppModel
    let id: String
    let challengeId: String
    @State private var image: UIImage?
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { Image(systemName: "photo").foregroundStyle(.secondary) }
        }.frame(width: 80, height: 80).clipped().clipShape(RoundedRectangle(cornerRadius: 14))
            .task {
                if let data = try? await model.api.request("media/\(id)", query: ["challenge_id": challengeId, "thumbnail": "true"]) {
                    image = UIImage(data: data)
                }
            }
    }
}

struct PartnerHistoryView: View {
    @EnvironmentObject private var model: AppModel
    let challengeId: String
    let userId: String
    @State private var points: [TrendPoint] = []
    @State private var loading = true
    @State private var message = ""
    var body: some View {
        ScrollView {
            Surface {
                Text("近 30 日已授权测量").font(.headline)
                Text("体重单位：\(model.weightUnit.name)").font(.caption).foregroundStyle(.secondary)
                if loading { ProgressView() }
                Chart(points) {
                    PointMark(x: .value("日期", $0.date), y: .value("体重 \(model.weightUnit.name)", model.weightUnit.fromKilograms($0.value))).foregroundStyle(Palette.teal)
                }.chartYScale(domain: .automatic(includesZero: false)).frame(height: 260)
                Text(message.isEmpty ? "仅绘制有测量且在授权范围内的日期" : message).font(.caption).foregroundStyle(.secondary)
            }.padding(20)
        }.background(Palette.canvas).navigationTitle("伙伴体重趋势")
            .task {
                defer { loading = false }
                do {
                    for offset in (0..<30).reversed() {
                        try Task.checkCancellation()
                        let date = Calendar.current.date(byAdding: .day, value: -offset, to: model.selectedDate) ?? model.selectedDate
                        let day = TimeFormat.day(date, timezone: model.profile.timezone, startMinutes: model.profile.dayStartMinutes)
                        let response = try await model.api.send("challenges/\(challengeId)/summary", query: ["day": day]).object ?? [:]
                        if let member = response.objects("members").first(where: { $0.text("user_id") == userId }),
                           member.flag("has_weight_record"), let weight = member.number("weight_kg") {
                            points.append(TrendPoint(day: day, date: date, value: weight))
                        }
                    }
                } catch { message = error.localizedDescription }
            }
    }
}

struct ConsentEditorView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let challengeId: String
    let challenge: JSONObject
    @State private var recipient = ""
    @State private var scopes = Set<String>()
    @State private var consentRows: [JSONObject] = []
    @State private var history = Date()
    @State private var version = 0
    private let options = [
        ("checkin", "打卡与饮食完整状态"), ("goal_progress", "目标进度"), ("weight_change", "体重变化百分比"),
        ("steps", "步数"), ("score", "积分"), ("streak", "连续天数"), ("weight", "原始体重"),
        ("meals", "食物与营养明细"), ("photos", "食物照片"), ("notes", "备注与自由文本"),
        ("health", "心率、睡眠及活动摘要"), ("profile", "身体档案")
    ]
    private var recipients: [JSONObject] {
        challenge.objects("members").filter { $0.text("user_id") != model.session?.userId && $0.text("status") == "active" }
    }

    var body: some View {
        Form {
            Section("共享对象") {
                Picker("成员", selection: $recipient) {
                    ForEach(recipients.indices, id: \.self) { index in
                        Text(recipients[index].text("display_name")).tag(recipients[index].text("user_id"))
                    }
                }
                DatePicker("允许读取的起始日期", selection: $history, displayedComponents: .date)
                Text("每位成员的权限独立保存，变更只影响所选对象。").font(.caption).foregroundStyle(.secondary)
            }
            Section("共享字段") {
                ForEach(options, id: \.0) { key, label in
                    Toggle(label, isOn: Binding(get: { scopes.contains(key) }, set: { if $0 { scopes.insert(key) } else { scopes.remove(key) } }))
                }
            }
            Section {
                Text("变化率、进度和积分也可能透露相关情况。请只选择愿意提供的信息。").font(.caption).foregroundStyle(.secondary)
                Button("保存授权") { save(revoke: false) }
                Button("撤销对该成员的全部共享", role: .destructive) { save(revoke: true) }
                Text("离线撤销将在服务器收到后生效，已下载缓存最长可见至原 24 小时租约结束。").font(.caption).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("共享授权")
        .toolbar { Button("关闭") { dismiss() } }
        .task {
            recipient = recipients.first?.text("user_id") ?? ""
            if let start = TimeFormat.parse(challenge.text("start_at")) { history = max(Date(), start) }
            do {
                consentRows = try await model.api.send("challenges/\(challengeId)/consents").array?.compactMap(\.object) ?? []
                loadSelected()
            } catch { model.errorMessage = error.localizedDescription }
        }
        .onChange(of: recipient) { _, _ in loadSelected() }
    }

    private func loadSelected() {
        let value = consentRows.first { $0.text("recipient_id") == recipient }
        scopes = Set(value?.strings("scopes") ?? [])
        version = Int(value?.number("version") ?? 0)
        if let day = value?.text("history_from"), let date = TimeFormat.window(day, timezone: challenge.text("timezone"))?.start { history = date }
    }

    private func save(revoke: Bool) {
        guard !recipient.isEmpty else { return }
        let values = revoke ? [] : scopes.sorted()
        model.perform {
            try await model.queueCommand(path: "challenges/\(challengeId)/consent", method: "PUT", body: [
                "recipient_id": .string(recipient), "scopes": .array(values.map(JSONValue.string)),
                "history_from": .string(TimeFormat.day(history, timezone: challenge.text("timezone"))),
                "expected_version": .number(Double(version))
            ], priority: revoke ? 100 : 50)
            dismiss()
        }
    }
}
