import SwiftUI
import SwiftData
import MapKit

// 入力中の店情報（保存前の下書き）
struct ShopDraft {
    var name = ""
    var address = ""
    var latitude: Double?
    var longitude: Double?
    var phone: String?
    var url: String?
    var memo = ""
    var source: ShopSource = .manual
    var prefillVisitDate: Date? = nil          // 写真から登録：来店日の初期値
    var prefillPhoto: ProcessedPhoto? = nil    // 写真から登録：来店記録に付ける写真
}

extension ShopDraft {
    init(candidate c: ShopCandidate) {
        self.init(name: c.name, address: c.address,
                  latitude: c.latitude, longitude: c.longitude,
                  phone: c.phone, url: c.url, memo: "", source: .keyword)
    }
}

struct ShopEditView: View {
    enum Mode {
        case new(ShopDraft)
        case edit(Shop)
    }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Tag.sortOrder) private var allTags: [Tag]

    let mode: Mode
    var onSaved: (() -> Void)? = nil

    @State private var draft = ShopDraft()
    @State private var selectedTagIDs: Set<UUID> = []
    @State private var newTagName = ""
    @State private var showDeleteConfirm = false
    @State private var loaded = false

    // 新規登録時の来店記録（D-20）
    @State private var visited = false
    @State private var visitDate = Date.now
    @State private var visitRating: Double?
    @State private var visitMemo = ""

    // 場所・地図（I-30）
    @State private var showLocationPicker = false
    @State private var showNearbyPicker = false
    @State private var isLocating = false
    @State private var locateMessage = ""

    // 同じ店の確認（I-27、D-41）
    @State private var duplicateShop: Shop?
    @State private var showMergeDialog = false

    private var isNew: Bool {
        if case .new = mode { return true } else { return false }
    }

    var body: some View {
        Form {
            Section("お店") {
                TextField("店名（必須）", text: $draft.name)
                TextField("住所", text: $draft.address, axis: .vertical)
                if let phone = draft.phone, !phone.isEmpty {
                    LabeledContent("電話", value: phone)
                }
            }
            locationSection
            if isNew {
                Section {
                    Picker("状態", selection: $visited) {
                        Text("行きたい").tag(false)
                        Text("行った").tag(true)
                    }
                    .pickerStyle(.segmented)
                    if visited {
                        DatePicker("来店日", selection: $visitDate, in: ...Date.now,
                                   displayedComponents: .date)
                        .environment(\.locale, Locale(identifier: "ja_JP"))   // 日本語表示（I-22）
                        StarRatingInput(rating: $visitRating)
                        TextField("来店メモ（食べたもの・感想など）", text: $visitMemo, axis: .vertical)
                            .lineLimit(2...6)
                        if let photo = draft.prefillPhoto {
                            HStack(spacing: 12) {
                                ThumbnailImage(data: photo.thumbnailData, size: 56)
                                Text("この写真を来店記録に付けます")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } header: {
                    Text("状態")
                } footer: {
                    if draft.prefillPhoto != nil && !visited {
                        Text("「行きたい」で登録すると、写真は保存されません。")
                    }
                }
            }
            Section("タグ") {
                TagChipsView(tags: allTags, selected: $selectedTagIDs)
                HStack {
                    TextField("新しいタグ", text: $newTagName)
                    Button("追加") { addNewTag() }
                        .disabled(newTagName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            Section("店メモ") {
                TextField("メモ", text: $draft.memo, axis: .vertical)
                    .lineLimit(3...8)
            }
            if !isNew {
                Section {
                    Button("このお店を削除", role: .destructive) {
                        showDeleteConfirm = true
                    }
                }
            }
        }
        .navigationTitle(isNew ? "お店を登録" : "お店を編集")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("キャンセル") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(draft.name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .confirmationDialog("このお店を削除しますか？",
                            isPresented: $showDeleteConfirm,
                            titleVisibility: .visible) {
            Button("削除する", role: .destructive) { deleteShop() }
        } message: {
            Text("来店記録と写真もすべて削除されます。元に戻せません。")
        }
        .onAppear(perform: loadIfNeeded)
        // 同じ店が見つかったときの確認（I-27）
        .confirmationDialog("登録済みのお店があります",
                            isPresented: $showMergeDialog,
                            titleVisibility: .visible,
                            presenting: duplicateShop) { shop in
            Button("「\(shop.name)」に追加する（統合）") { merge(into: shop) }
            Button("別のお店として登録") { insertNew() }
            Button("キャンセル", role: .cancel) {}
        } message: { shop in
            Text(mergeMessage(shop))
        }
        .sheet(isPresented: $showLocationPicker) {
            LocationPickerView(initial: currentCoordinate) { coordinate in
                draft.latitude = coordinate.latitude
                draft.longitude = coordinate.longitude
                locateMessage = "地図で指定した位置を設定しました"
            }
        }
        .sheet(isPresented: $showNearbyPicker) {
            if let lat = draft.latitude, let lon = draft.longitude {
                NearbyShopPickerView(latitude: lat, longitude: lon,
                                     initialKeyword: trimmedName) { candidate in
                    apply(candidate)
                }
            }
        }
    }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        switch mode {
        case .new(let initial):
            draft = initial
            // 写真から来た場合は「行った」・来店日＝撮影日で始める
            if initial.prefillPhoto != nil || initial.prefillVisitDate != nil {
                visited = true
                visitDate = min(initial.prefillVisitDate ?? .now, .now)
            }
        case .edit(let shop):
            draft = ShopDraft(name: shop.name, address: shop.address,
                              latitude: shop.latitude, longitude: shop.longitude,
                              phone: shop.phone, url: shop.url,
                              memo: shop.memo, source: shop.source)
            selectedTagIDs = Set(shop.tags.map(\.id))
        }
    }

    private func addNewTag() {
        if let tag = TagRules.findOrCreate(name: newTagName, in: context, existing: allTags) {
            selectedTagIDs.insert(tag.id)
        }
        newTagName = ""
    }

    private var trimmedName: String {
        draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var selectedTags: [Tag] {
        allTags.filter { selectedTagIDs.contains($0.id) }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        switch mode {
        case .new:
            // 同じ店が登録済みなら、統合するか確認する（D-41）
            let shops: [Shop] = (try? context.fetch(FetchDescriptor<Shop>())) ?? []
            if let match = ShopMatcher.findSame(name: trimmedName, address: draft.address,
                                                latitude: draft.latitude, longitude: draft.longitude,
                                                in: shops) {
                duplicateShop = match
                showMergeDialog = true
                return
            }
            insertNew()
        case .edit(let shop):
            shop.name = trimmedName
            shop.address = draft.address
            shop.latitude = draft.latitude
            shop.longitude = draft.longitude
            shop.phone = draft.phone
            shop.url = draft.url
            shop.memo = draft.memo
            shop.tags = selectedTags
            shop.updatedAt = .now
            finish()
        }
    }

    // 新しいお店として登録
    private func insertNew() {
        let shop = Shop(name: trimmedName, address: draft.address,
                        latitude: draft.latitude, longitude: draft.longitude,
                        source: draft.source, wantToGo: !visited)
        shop.phone = draft.phone
        shop.url = draft.url
        shop.memo = draft.memo
        context.insert(shop)
        shop.tags = selectedTags
        if visited {
            appendVisit(to: shop)
        }
        finish()
    }

    // 登録済みのお店に統合：来店記録・写真・タグを追加し、空欄の項目だけ補う
    private func merge(into shop: Shop) {
        for tag in selectedTags where !shop.tags.contains(where: { $0.id == tag.id }) {
            shop.tags.append(tag)
        }
        if shop.address.trimmingCharacters(in: .whitespaces).isEmpty {
            shop.address = draft.address
        }
        if shop.latitude == nil || shop.longitude == nil,
           let lat = draft.latitude, let lon = draft.longitude {
            shop.latitude = lat
            shop.longitude = lon
        }
        if (shop.phone ?? "").isEmpty {
            shop.phone = draft.phone
        }
        if (shop.url ?? "").isEmpty {
            shop.url = draft.url
        }
        let memo: String = draft.memo.trimmingCharacters(in: .whitespacesAndNewlines)
        if !memo.isEmpty && !shop.memo.contains(memo) {
            shop.memo = shop.memo.isEmpty ? memo : shop.memo + "\n" + memo
        }
        if visited {
            appendVisit(to: shop)
            shop.wantToGo = false
        }
        shop.updatedAt = .now
        finish()
    }

    private func appendVisit(to shop: Shop) {
        let visit = Visit(date: visitDate, rating: visitRating, memo: visitMemo)
        shop.visits.append(visit)
        if let photo = draft.prefillPhoto {
            visit.photos.append(Photo(imageData: photo.imageData,
                                      thumbnailData: photo.thumbnailData,
                                      takenAt: photo.meta.takenAt,
                                      latitude: photo.meta.latitude,
                                      longitude: photo.meta.longitude,
                                      sortOrder: 0))
        }
    }

    private func finish() {
        try? context.save()
        if let onSaved {
            onSaved()
        } else {
            dismiss()
        }
    }

    private func mergeMessage(_ shop: Shop) -> String {
        var lines: [String] = []
        if !shop.address.isEmpty {
            lines.append(shop.address)
        }
        lines.append("来店記録 \(shop.visits.count)件")
        if visited {
            lines.append("統合すると、今回の来店記録（写真を含む）とタグをこのお店に追加します。")
        } else {
            lines.append("統合すると、タグと店メモをこのお店に追加します。")
        }
        return lines.joined(separator: "\n")
    }

    // ---- 場所・地図（I-30） ----

    @ViewBuilder
    private var locationSection: some View {
        Section {
            if let lat = draft.latitude, let lon = draft.longitude {
                let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                Map(initialPosition: .region(MKCoordinateRegion(center: coordinate,
                                                                latitudinalMeters: 500,
                                                                longitudinalMeters: 500))) {
                    Marker(trimmedName.isEmpty ? "お店" : trimmedName, coordinate: coordinate)
                }
                .frame(height: 160)
                .allowsHitTesting(false)
                .listRowInsets(EdgeInsets())
                .id("\(lat),\(lon)")   // 位置が変わったら地図を描き直す
            } else {
                Text("位置が未設定のため、地図は表示されません")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Button {
                Task { await locateFromAddress() }
            } label: {
                Label("住所から位置を設定", systemImage: "mappin.and.ellipse")
            }
            .disabled(draft.address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLocating)
            Button {
                showLocationPicker = true
            } label: {
                Label("地図で位置を指定", systemImage: "map")
            }
            if draft.latitude != nil && draft.longitude != nil {
                Button {
                    showNearbyPicker = true
                } label: {
                    Label("この位置の周辺でお店を探す", systemImage: "magnifyingglass")
                }
            }
            if isLocating {
                ProgressView()
            } else if !locateMessage.isEmpty {
                Text(locateMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("場所・地図")
        } footer: {
            Text("周辺のお店から選ぶと、店名・住所・電話番号・位置が選んだお店の内容に置き換わります。")
        }
    }

    private var currentCoordinate: CLLocationCoordinate2D? {
        guard let lat = draft.latitude, let lon = draft.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func locateFromAddress() async {
        isLocating = true
        defer { isLocating = false }
        if let coordinate = await AddressLocator.coordinate(for: draft.address) {
            draft.latitude = coordinate.latitude
            draft.longitude = coordinate.longitude
            locateMessage = "住所から位置を設定しました。地図で確認してください"
        } else {
            locateMessage = "住所から位置を見つけられませんでした。「地図で位置を指定」を使ってください"
        }
    }

    private func apply(_ candidate: ShopCandidate) {
        draft.name = candidate.name
        draft.address = candidate.address
        draft.latitude = candidate.latitude
        draft.longitude = candidate.longitude
        draft.phone = candidate.phone
        draft.url = candidate.url
        locateMessage = "「\(candidate.name)」の情報を反映しました"
    }

    private func deleteShop() {
        guard case .edit(let shop) = mode else { return }
        context.delete(shop)
        try? context.save()
        dismiss()
    }
}

// タグの選択（タップで選択/解除）
struct TagChipsView: View {
    let tags: [Tag]
    @Binding var selected: Set<UUID>

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 84), spacing: 8)],
                  alignment: .leading, spacing: 8) {
            ForEach(tags.filter { $0.isPreset || selected.contains($0.id) }) { tag in
                let isOn = selected.contains(tag.id)
                Button {
                    if isOn { selected.remove(tag.id) } else { selected.insert(tag.id) }
                } label: {
                    Text(tag.name)
                        .font(.callout)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .background(isOn ? Color.accentColor : Color.secondary.opacity(0.15),
                                    in: Capsule())
                        .foregroundStyle(isOn ? Color.white : Color.primary)
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(.vertical, 4)
    }
}
