import SwiftUI
import PhotosUI
import MapKit

// 写真から店を登録（S-04）
// 開くとすぐに写真ライブラリを表示（I-31）。写真に位置情報がない場合は、地図で場所を指定するか店名・地名で探す（I-29）
struct PhotoRegisterView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var showPicker = false
    @State private var didAutoOpen = false
    @State private var photo: ProcessedPhoto?
    @State private var isProcessing = false
    @State private var loadError = ""
    @State private var model = ShopSearchModel()
    @State private var nameKeyword = ""
    @State private var areaKeyword = ""
    @State private var viewerItem: ViewerItem?
    @State private var pickedLocation: CLLocationCoordinate2D?   // 地図で指定した場所
    @State private var showLocationPicker = false

    // 店を探す中心：地図で指定した場所 → 写真の撮影場所
    private var center: CLLocationCoordinate2D? {
        if let pickedLocation { return pickedLocation }
        if let lat = photo?.meta.latitude, let lon = photo?.meta.longitude {
            return CLLocationCoordinate2D(latitude: lat, longitude: lon)
        }
        return nil
    }

    var body: some View {
        NavigationStack {
            List {
                photoSection
                if photo != nil {
                    if let center {
                        candidatesSection(center)
                        nameSearchSection(center)
                        Section {
                            Button {
                                showLocationPicker = true
                            } label: {
                                Label("地図で場所を指定し直す", systemImage: "map")
                            }
                        } footer: {
                            Text("撮影場所がずれている場合や、別の場所で探したい場合に使います。")
                        }
                    } else {
                        noLocationSection
                    }
                    manualSection
                }
            }
            .navigationTitle("写真から登録")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .photosPicker(isPresented: $showPicker, selection: $pickerItem, matching: .images)
            // 画面を開いたらすぐに写真ライブラリを表示（I-31）
            .task {
                guard !didAutoOpen else { return }
                didAutoOpen = true
                try? await Task.sleep(for: .milliseconds(400))
                showPicker = true
            }
            // 写真を選ばずにライブラリを閉じたら、この画面も閉じる
            .onChange(of: showPicker) { wasShown, isShown in
                guard wasShown && !isShown else { return }
                Task {
                    try? await Task.sleep(for: .milliseconds(600))
                    if photo == nil && pickerItem == nil && !isProcessing {
                        dismiss()
                    }
                }
            }
            .onChange(of: pickerItem) { _, item in
                guard let item else { return }
                Task { await load(item) }
            }
            .sheet(item: $viewerItem) { item in
                PhotoViewer(data: item.data)
            }
            .sheet(isPresented: $showLocationPicker) {
                LocationPickerView(initial: center) { coordinate in
                    pickedLocation = coordinate
                    Task {
                        await model.searchNearby(latitude: coordinate.latitude,
                                                 longitude: coordinate.longitude)
                    }
                }
            }
        }
    }

    // ---- 各セクション ----

    private var photoSection: some View {
        Section {
            Button {
                showPicker = true
            } label: {
                Label(photo == nil ? "写真を選ぶ" : "別の写真を選ぶ", systemImage: "photo")
            }
            if isProcessing {
                ProgressView("写真を読み込み中…")
            }
            if !loadError.isEmpty {
                Text(loadError)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if let photo {
                HStack(spacing: 12) {
                    ThumbnailImage(data: photo.thumbnailData, size: 72)
                        .onTapGesture {
                            viewerItem = ViewerItem(data: photo.imageData)
                        }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(takenText(photo))
                            .font(.callout)
                        Text(locationText(photo))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        } header: {
            Text("1. 写真")
        }
    }

    private func candidatesSection(_ center: CLLocationCoordinate2D) -> some View {
        Section {
            if model.isSearching {
                ProgressView()
            } else if !model.message.isEmpty {
                Text(model.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.candidates) { candidate in
                NavigationLink {
                    ShopEditView(mode: .new(draft(from: candidate)),
                                 onSaved: { dismiss() })
                } label: {
                    CandidateRow(candidate: candidate,
                                 distance: candidate.distance(fromLatitude: center.latitude,
                                                              longitude: center.longitude))
                }
            }
        } header: {
            Text(pickedLocation == nil
                 ? "2. お店の候補（撮影場所から近い順）"
                 : "2. お店の候補（地図で指定した場所から近い順）")
        }
    }

    private func nameSearchSection(_ center: CLLocationCoordinate2D) -> some View {
        Section {
            HStack {
                TextField("店名の一部", text: $nameKeyword)
                    .onSubmit { searchByName(center) }
                Button("検索") { searchByName(center) }
                    .disabled(nameKeyword.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.isSearching)
            }
        } header: {
            Text("候補にない場合：店名で探す（この場所の周辺）")
        }
    }

    // 写真に位置情報がない場合（I-29）
    private var noLocationSection: some View {
        Section {
            Button {
                showLocationPicker = true
            } label: {
                Label("地図で場所を指定して周辺を探す", systemImage: "map")
            }
            HStack {
                TextField("店名・地名（例：渋谷 ラーメン）", text: $areaKeyword)
                    .onSubmit { searchByArea() }
                Button("検索") { searchByArea() }
                    .disabled(areaKeyword.trimmingCharacters(in: .whitespaces).isEmpty
                              || model.isSearching)
            }
            if model.isSearching {
                ProgressView()
            } else if !model.message.isEmpty {
                Text(model.message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            ForEach(model.candidates) { candidate in
                NavigationLink {
                    ShopEditView(mode: .new(draft(from: candidate)),
                                 onSaved: { dismiss() })
                } label: {
                    CandidateRow(candidate: candidate, distance: nil)
                }
            }
        } header: {
            Text("2. お店を探す（この写真には位置情報がありません）")
        }
    }

    private var manualSection: some View {
        Section {
            NavigationLink {
                ShopEditView(mode: .new(manualDraft()), onSaved: { dismiss() })
            } label: {
                Label("候補にない（手入力で登録）", systemImage: "square.and.pencil")
            }
        } footer: {
            Text("手入力の場合も、撮影場所（または地図で指定した場所）の座標・撮影日・写真が登録に使われます。登録画面の「住所から位置を設定」も使えます。")
        }
    }

    private func locationText(_ photo: ProcessedPhoto) -> String {
        photo.meta.latitude == nil ? "位置情報なし" : "位置情報あり"
    }

    private func takenText(_ photo: ProcessedPhoto) -> String {
        guard let taken = photo.meta.takenAt else { return "撮影日時：不明" }
        return "撮影日時：" + JPDate.dayTime(taken)
    }

    // 写真を読み込み、位置情報があれば周辺の店を検索
    private func load(_ item: PhotosPickerItem) async {
        isProcessing = true
        defer { isProcessing = false }
        loadError = ""
        model.candidates = []
        model.message = ""
        guard let data = try? await item.loadTransferable(type: Data.self),
              let processed = ImageTools.process(data) else {
            photo = nil
            loadError = "写真を読み込めませんでした"
            return
        }
        photo = processed
        pickedLocation = nil
        if let lat = processed.meta.latitude, let lon = processed.meta.longitude {
            await model.searchNearby(latitude: lat, longitude: lon)
        }
    }

    private func searchByName(_ center: CLLocationCoordinate2D) {
        let keyword: String = nameKeyword
        Task {
            await model.search(keyword: keyword, nearLatitude: center.latitude,
                               longitude: center.longitude, foodOnly: false)
        }
    }

    // 位置情報がない写真：店名・地名で探す（場所の指定なし）
    private func searchByArea() {
        let keyword: String = areaKeyword
        Task {
            await model.search(keyword: keyword)
        }
    }

    // 候補から登録：店の座標は候補のもの、来店日と写真は写真から
    private func draft(from candidate: ShopCandidate) -> ShopDraft {
        var draft = ShopDraft(candidate: candidate)
        draft.source = .photo
        draft.prefillVisitDate = photo?.meta.takenAt ?? .now
        draft.prefillPhoto = photo
        return draft
    }

    // 手入力：店の座標は撮影場所、または地図で指定した場所（F-04、I-29）
    private func manualDraft() -> ShopDraft {
        var draft = ShopDraft(source: .photo)
        draft.latitude = center?.latitude
        draft.longitude = center?.longitude
        draft.prefillVisitDate = photo?.meta.takenAt ?? .now
        draft.prefillPhoto = photo
        return draft
    }
}

// 候補の行（店名・住所・距離）
struct CandidateRow: View {
    let candidate: ShopCandidate
    let distance: Double?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name)
                Text(candidate.address)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let distance {
                Text(distanceText(distance))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func distanceText(_ meters: Double) -> String {
        if meters < 1000 {
            return "\(Int(meters.rounded()))m"
        }
        return String(format: "%.1fkm", meters / 1000)
    }
}
