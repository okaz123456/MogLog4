import SwiftUI
import SwiftData
import MapKit

// 住所から位置を求める（I-30）：①住所全体 →②空白より前（建物名を除く）
enum AddressLocator {
    static func coordinate(for address: String) async -> CLLocationCoordinate2D? {
        let trimmed: String = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let found = await search(trimmed) {
            return found
        }
        let parts = trimmed.split(whereSeparator: { $0 == " " || $0 == "　" })
        if let first = parts.first, String(first) != trimmed {
            return await search(String(first))
        }
        return nil
    }

    private static func search(_ query: String) async -> CLLocationCoordinate2D? {
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        request.resultTypes = .address
        guard let response = try? await MKLocalSearch(request: request).start() else { return nil }
        return response.mapItems.first?.location.coordinate
    }
}

// 同じ店の判定（D-41、I-27）
// 店名が一致（全角半角・大文字小文字・空白の違いは無視）し、かつ住所が一致するか位置が100m以内
enum ShopMatcher {
    static let nearMeters: Double = 100

    static func key(_ text: String) -> String {
        TagRules.normalized(text).filter { !$0.isWhitespace }
    }

    static func findSame(name: String,
                         address: String,
                         latitude: Double?,
                         longitude: Double?,
                         in shops: [Shop]) -> Shop? {
        let nameKey: String = key(name)
        guard !nameKey.isEmpty else { return nil }
        let addressKey: String = key(address)
        for shop in shops {
            if shop.isDeleted || shop.modelContext == nil { continue }
            if key(shop.name) != nameKey { continue }
            if !addressKey.isEmpty && key(shop.address) == addressKey {
                return shop
            }
            if let lat = latitude, let lon = longitude,
               let shopLat = shop.latitude, let shopLon = shop.longitude {
                let here = CLLocation(latitude: lat, longitude: lon)
                let there = CLLocation(latitude: shopLat, longitude: shopLon)
                if here.distance(from: there) <= nearMeters {
                    return shop
                }
            }
        }
        return nil
    }
}

// 地図で場所を指定する（I-29、I-30）：地図を動かして中央の印に合わせ、「決定」
struct LocationPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let initial: CLLocationCoordinate2D?
    let onPick: (CLLocationCoordinate2D) -> Void

    @State private var position: MapCameraPosition = .automatic
    @State private var center: CLLocationCoordinate2D?
    @State private var query = ""
    @State private var message = ""
    @State private var isSearching = false
    @State private var prepared = false

    // 指定がないときは日本全体を表示
    private static let japan = MKCoordinateRegion(
        center: CLLocationCoordinate2D(latitude: 36.2, longitude: 138.3),
        span: MKCoordinateSpan(latitudeDelta: 14, longitudeDelta: 14)
    )

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    TextField("地名・駅名・住所で移動", text: $query)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { Task { await jump() } }
                    Button("移動") { Task { await jump() } }
                        .disabled(query.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                }
                .padding(8)
                Text(message.isEmpty ? "地図を動かして、中央の印をお店の場所に合わせてください" : message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 6)
                Map(position: $position)
                    .onMapCameraChange(frequency: .onEnd) { context in
                        center = context.region.center
                    }
                    .overlay {
                        Image(systemName: "scope")
                            .font(.title)
                            .foregroundStyle(.red)
                            .allowsHitTesting(false)
                    }
            }
            .navigationTitle("場所を指定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("決定") {
                        if let center {
                            onPick(center)
                        }
                        dismiss()
                    }
                    .disabled(center == nil)
                }
            }
            .onAppear(perform: prepare)
        }
    }

    private func prepare() {
        guard !prepared else { return }
        prepared = true
        if let initial {
            position = .region(MKCoordinateRegion(center: initial,
                                                  latitudinalMeters: 800,
                                                  longitudinalMeters: 800))
            center = initial
        } else {
            position = .region(Self.japan)
        }
    }

    private func jump() async {
        let trimmed: String = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        isSearching = true
        defer { isSearching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        guard let response = try? await MKLocalSearch(request: request).start(),
              let item = response.mapItems.first else {
            message = "見つかりませんでした"
            return
        }
        let coordinate: CLLocationCoordinate2D = item.location.coordinate
        position = .region(MKCoordinateRegion(center: coordinate,
                                              latitudinalMeters: 800,
                                              longitudinalMeters: 800))
        center = coordinate
        message = "「\(item.name ?? trimmed)」に移動しました"
    }
}

// 指定した位置の周辺のお店を選ぶ（I-30）：選ぶと店名・住所・電話・位置を入力欄に反映
struct NearbyShopPickerView: View {
    @Environment(\.dismiss) private var dismiss
    let latitude: Double
    let longitude: Double
    let initialKeyword: String
    let onSelect: (ShopCandidate) -> Void

    @State private var model = ShopSearchModel()
    @State private var keyword = ""
    @State private var started = false

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack {
                        TextField("店名の一部（空欄なら周辺すべて）", text: $keyword)
                            .onSubmit { Task { await runSearch() } }
                        Button("検索") { Task { await runSearch() } }
                            .disabled(model.isSearching)
                    }
                    if model.isSearching {
                        ProgressView()
                    } else if !model.message.isEmpty {
                        Text(model.message)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("店名で絞り込む")
                }
                Section("周辺のお店（近い順）") {
                    ForEach(model.candidates) { candidate in
                        Button {
                            onSelect(candidate)
                            dismiss()
                        } label: {
                            CandidateRow(candidate: candidate,
                                         distance: candidate.distance(fromLatitude: latitude,
                                                                      longitude: longitude))
                        }
                        .tint(.primary)
                    }
                }
            }
            .navigationTitle("周辺のお店")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
            .task {
                guard !started else { return }
                started = true
                keyword = initialKeyword
                await runSearch()
            }
        }
    }

    // 店名があれば周辺を店名で検索し、見つからなければ周辺のお店すべてを表示
    private func runSearch() async {
        let trimmed: String = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            await model.search(keyword: trimmed, nearLatitude: latitude, longitude: longitude,
                               foodOnly: false)
            if !model.candidates.isEmpty { return }
        }
        await model.searchNearby(latitude: latitude, longitude: longitude)
    }
}
