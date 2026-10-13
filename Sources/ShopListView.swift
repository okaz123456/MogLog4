import SwiftUI
import SwiftData
import UIKit

// 一覧の表示切替（D-25）
enum ShopStatusFilter: String, CaseIterable, Identifiable {
    case all = "すべて"
    case visited = "行った"
    case wantToGo = "行きたい"
    var id: String { rawValue }
}

// 並べ替え（F-11）
enum ShopSortOrder: String, CaseIterable, Identifiable {
    case lastVisit = "最終来店日"
    case rating = "平均評価"
    case name = "店名"
    case created = "登録日"
    var id: String { rawValue }
}

// 一覧の表示形式（I-24）
enum ShopViewMode: String {
    case list   // お店のリスト
    case grid   // 来店記録の写真グリッド（月ごと）
}

// 月ごとのまとまり（I-23、I-24）
struct MonthGroup<Item: Identifiable>: Identifiable {
    let title: String
    var items: [Item]
    var id: String { title }
}

// 並び順を保ったまま、見出しの文字列が同じものをまとめる
func groupByTitle<Item: Identifiable>(_ items: [Item], title: (Item) -> String) -> [MonthGroup<Item>] {
    var groups: [MonthGroup<Item>] = []
    for item in items {
        let key: String = title(item)
        if let lastIndex = groups.indices.last, groups[lastIndex].title == key {
            groups[lastIndex].items.append(item)
        } else {
            groups.append(MonthGroup(title: key, items: [item]))
        }
    }
    return groups
}

struct ShopListView: View {
    @Query(sort: \Shop.updatedAt, order: .reverse) private var shops: [Shop]
    @Query(sort: \Tag.sortOrder) private var allTags: [Tag]

    @State private var addMode: AddMode?
    @State private var searchText = ""
    @State private var selectedTagIDs: Set<UUID> = []
    @State private var showTagFilter = false

    // 次回起動時も保持（D-25）
    @AppStorage("listStatusFilter") private var statusRaw = ShopStatusFilter.all.rawValue
    @AppStorage("listSortOrder") private var sortRaw = ShopSortOrder.lastVisit.rawValue
    @AppStorage("listViewModeV13") private var viewModeRaw = ShopViewMode.grid.rawValue   // 既定はタイル（I-24）

    enum AddMode: String, Identifiable {
        case keyword, photo, manual
        var id: String { rawValue }
    }

    private var isGrid: Bool { viewModeRaw == ShopViewMode.grid.rawValue }

    var body: some View {
        NavigationStack {
            Group {
                if shops.isEmpty {
                    ContentUnavailableView(
                        "まだ記録がありません",
                        systemImage: "fork.knife",
                        description: Text("右上の＋からお店を登録できます")
                    )
                } else if isGrid {
                    gridContent
                        .searchable(text: $searchText, prompt: "店名・住所・メモ")
                } else {
                    listContent
                        .searchable(text: $searchText, prompt: "店名・住所・メモ")
                }
            }
            .navigationTitle("お店")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Menu {
                        Picker("並べ替え", selection: $sortRaw) {
                            ForEach(ShopSortOrder.allCases) { order in
                                Text(order.rawValue).tag(order.rawValue)
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                    }
                    .disabled(isGrid)   // タイル表示は常に来店日の新しい順
                }
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showTagFilter = true
                    } label: {
                        Image(systemName: selectedTagIDs.isEmpty
                              ? "line.3.horizontal.decrease.circle"
                              : "line.3.horizontal.decrease.circle.fill")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { addMode = .keyword } label: {
                            Label("キーワードで探す", systemImage: "magnifyingglass")
                        }
                        Button { addMode = .photo } label: {
                            Label("写真から登録", systemImage: "photo")
                        }
                        Button { addMode = .manual } label: {
                            Label("手入力", systemImage: "square.and.pencil")
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $addMode) { mode in
                switch mode {
                case .keyword:
                    KeywordSearchView()
                case .photo:
                    PhotoRegisterView()
                case .manual:
                    NavigationStack {
                        ShopEditView(mode: .new(ShopDraft(source: .manual)))
                    }
                }
            }
            .sheet(isPresented: $showTagFilter) {
                TagFilterSheet(tags: allTags, selected: $selectedTagIDs)
            }
        }
    }

    // ---- 絞り込み欄（リスト・写真の共通部品） ----

    private var statusPicker: some View {
        Picker("表示", selection: $statusRaw) {
            ForEach(ShopStatusFilter.allCases) { status in
                Text(status.rawValue).tag(status.rawValue)
            }
        }
        .pickerStyle(.segmented)
    }

    // 表示形式の切替（タイル／リスト）：画面上に常に表示する
    private var viewModePicker: some View {
        Picker("表示形式", selection: $viewModeRaw) {
            Text("タイル").tag(ShopViewMode.grid.rawValue)
            Text("リスト").tag(ShopViewMode.list.rawValue)
        }
        .pickerStyle(.segmented)
    }

    private var tagFilterBar: some View {
        HStack {
            Image(systemName: "tag")
            Text(selectedTagNames)
                .font(.caption)
                .lineLimit(1)
            Spacer()
            Button("解除") { selectedTagIDs.removeAll() }
                .font(.caption)
                .buttonStyle(.borderless)
        }
    }

    // ---- リスト表示 ----

    private var listContent: some View {
        List {
            Section {
                viewModePicker
                statusPicker
                if !selectedTagIDs.isEmpty {
                    tagFilterBar
                }
            }
            let list: [Shop] = filteredShops
            if list.isEmpty {
                Section {
                    Text("条件に合うお店がありません")
                        .foregroundStyle(.secondary)
                }
            } else if currentSort == .lastVisit {
                // 最終来店日順のときは月ごとに見出しを付ける（I-23）
                ForEach(monthGroups(list)) { group in
                    Section {
                        ForEach(group.items) { shop in
                            shopLink(shop)
                        }
                    } header: {
                        Text("\(group.title)（\(group.items.count)件）")
                    }
                }
            } else {
                Section {
                    ForEach(list) { shop in
                        shopLink(shop)
                    }
                } header: {
                    Text("\(list.count)件・\(currentSort.rawValue)順")
                }
            }
        }
    }

    private func shopLink(_ shop: Shop) -> some View {
        NavigationLink {
            ShopDetailView(shop: shop)
        } label: {
            ShopRowView(shop: shop)
        }
    }

    private func monthGroups(_ list: [Shop]) -> [MonthGroup<Shop>] {
        groupByTitle(list) { shop in
            if let last = shop.lastVisitDate {
                return JPDate.month(last)
            }
            return "来店日なし"
        }
    }

    // ---- タイル表示（もぐレコ風：月見出し＋3列。1タイル＝1回の来店：I-24、D-39） ----

    private var gridContent: some View {
        let entries: [GridEntry] = filteredEntries
        let groups: [MonthGroup<GridEntry>] = groupByTitle(entries) { entry in
            entry.groupTitle
        }
        let columns: [GridItem] = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)
        return ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                viewModePicker
                statusPicker
                if !selectedTagIDs.isEmpty {
                    tagFilterBar
                }
                Text("\(entries.count)件・来店日の新しい順")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal)
            .padding(.top, 4)

            if entries.isEmpty {
                Text("条件に合うお店がありません")
                    .foregroundStyle(.secondary)
                    .padding(.top, 40)
            } else {
                LazyVGrid(columns: columns, spacing: 3, pinnedViews: [.sectionHeaders]) {
                    ForEach(groups) { group in
                        Section {
                            ForEach(group.items) { entry in
                                NavigationLink {
                                    ShopDetailView(shop: entry.shop)
                                } label: {
                                    ShopTileView(entry: entry)
                                }
                                .buttonStyle(.plain)
                            }
                        } header: {
                            MonthHeaderView(title: group.title)
                        }
                    }
                }
                .padding(.horizontal, 3)
                .padding(.bottom, 12)
            }
        }
    }

    // 絞り込んだお店の来店記録を新しい順に並べ（日付不明はその後）、来店記録のないお店を末尾に付ける
    private var filteredEntries: [GridEntry] {
        var visitEntries: [GridEntry] = []
        var shopOnlyEntries: [GridEntry] = []
        for shop in filteredShops {
            let visits: [Visit] = shop.visits.filter { !$0.isDeleted && $0.modelContext != nil }
            if visits.isEmpty {
                shopOnlyEntries.append(GridEntry(shop: shop, visit: nil))
            } else {
                for visit in visits {
                    visitEntries.append(GridEntry(shop: shop, visit: visit))
                }
            }
        }
        visitEntries.sort { a, b in
            guard let visitA = a.visit, let visitB = b.visit else { return false }
            return Visit.newerFirst(visitA, visitB)
        }
        shopOnlyEntries.sort { a, b in a.shop.createdAt > b.shop.createdAt }
        return visitEntries + shopOnlyEntries
    }

    // ---- 絞り込みと並べ替え ----

    private var currentStatus: ShopStatusFilter {
        ShopStatusFilter(rawValue: statusRaw) ?? .all
    }

    private var currentSort: ShopSortOrder {
        ShopSortOrder(rawValue: sortRaw) ?? .lastVisit
    }

    private var selectedTagNames: String {
        let names: [String] = allTags.filter { selectedTagIDs.contains($0.id) }.map(\.name)
        return names.joined(separator: "・")
    }

    private var filteredShops: [Shop] {
        let keyword: String = TagRules.normalized(searchText)
        var result: [Shop] = []
        for shop in shops {
            if shop.isDeleted || shop.modelContext == nil { continue }
            if !matchesStatus(shop) { continue }
            if !matchesKeyword(shop, keyword) { continue }
            if !matchesTags(shop) { continue }
            result.append(shop)
        }
        return sorted(result)
    }

    private func matchesStatus(_ shop: Shop) -> Bool {
        switch currentStatus {
        case .all: return true
        case .visited: return shop.isVisited
        case .wantToGo: return !shop.isVisited
        }
    }

    // 店名・住所・店メモ・来店メモの部分一致（D-27）
    private func matchesKeyword(_ shop: Shop, _ keyword: String) -> Bool {
        if keyword.isEmpty { return true }
        let fields: [String] = [shop.name, shop.address, shop.memo]
        for field in fields {
            if TagRules.normalized(field).contains(keyword) { return true }
        }
        for visit in shop.visits {
            if TagRules.normalized(visit.memo).contains(keyword) { return true }
        }
        return false
    }

    // 選んだタグをすべて含む（D-26）
    private func matchesTags(_ shop: Shop) -> Bool {
        if selectedTagIDs.isEmpty { return true }
        let shopTagIDs: Set<UUID> = Set(shop.tags.map(\.id))
        return selectedTagIDs.isSubset(of: shopTagIDs)
    }

    private func sorted(_ list: [Shop]) -> [Shop] {
        switch currentSort {
        case .lastVisit:
            // 来店記録のない店（行きたい）は末尾
            return list.sorted { a, b in
                let dateA: Date = a.lastVisitDate ?? .distantPast
                let dateB: Date = b.lastVisitDate ?? .distantPast
                if dateA != dateB { return dateA > dateB }
                return a.updatedAt > b.updatedAt
            }
        case .rating:
            // 未評価の店は末尾
            return list.sorted { a, b in
                let ratingA: Double = a.averageRating ?? -1
                let ratingB: Double = b.averageRating ?? -1
                if ratingA != ratingB { return ratingA > ratingB }
                return a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .name:
            return list.sorted { a, b in
                a.name.localizedStandardCompare(b.name) == .orderedAscending
            }
        case .created:
            return list.sorted { a, b in a.createdAt > b.createdAt }
        }
    }
}

// 月の見出し（写真表示用。スクロール中も上部に残る）
struct MonthHeaderView: View {
    let title: String

    var body: some View {
        HStack {
            Text(title)
                .font(.subheadline.bold())
                .foregroundStyle(.white)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.gray, in: RoundedRectangle(cornerRadius: 6))
        .padding(.vertical, 3)
        .background(Color(uiColor: .systemBackground))
    }
}

// タイル表示の1マス分のデータ（来店記録1件、または来店記録のないお店1件）
struct GridEntry: Identifiable {
    let shop: Shop
    let visit: Visit?

    var id: PersistentIdentifier {
        visit?.persistentModelID ?? shop.persistentModelID
    }

    // 月見出しの文字列
    var groupTitle: String {
        guard let visit else { return "来店記録なし（行きたい）" }
        return visit.isDateUnknown ? "日付不明" : JPDate.month(visit.date)
    }

    // タイルの写真：その来店記録の中で撮影日時が最も新しい写真（I-28）
    // 撮影日時のない写真は最も古い扱い。すべてない場合は1枚目
    var thumbnailData: Data? {
        guard let visit else { return nil }
        let photos: [Photo] = visit.sortedPhotos.filter { !$0.isDeleted && $0.modelContext != nil }
        var best: Photo? = nil
        for photo in photos {
            guard let current = best else {
                best = photo
                continue
            }
            let currentDate: Date = current.takenAt ?? .distantPast
            let date: Date = photo.takenAt ?? .distantPast
            if date > currentDate {
                best = photo
            }
        }
        return best?.thumbnailData
    }
}

// タイル1マス：写真の上に店名、店名の下にその来店の評価の★（I-24、I-25）
struct ShopTileView: View {
    let entry: GridEntry

    private var thumbnail: UIImage? {
        guard let data = entry.thumbnailData else { return nil }
        return UIImage(data: data)
    }

    var body: some View {
        Color.secondary.opacity(0.12)
            .aspectRatio(1, contentMode: .fit)
            .overlay {
                if let image = thumbnail {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    Image(systemName: entry.visit == nil ? "bookmark" : "fork.knife")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                }
            }
            .overlay(alignment: .bottomLeading) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.shop.name)
                        .font(.system(size: 16, weight: .bold))   // 従来の約1.5倍（I-32）
                        .minimumScaleFactor(0.8)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if let rating = entry.visit?.ratingValue {
                        TileStarsView(rating: rating)
                    }
                }
                .padding(.horizontal, 6)
                .padding(.top, 14)
                .padding(.bottom, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    LinearGradient(colors: [Color.black.opacity(0), Color.black.opacity(0.7)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
            .clipped()
            .contentShape(Rectangle())
    }
}

// タイル用の小さい★（写真の上でも見えるように黄色＋白文字）
struct TileStarsView: View {
    let rating: Double

    var body: some View {
        HStack(spacing: 2) {
            HStack(spacing: 0) {
                ForEach(1...5, id: \.self) { index in
                    Image(systemName: StarRatingLabel.symbol(for: index, value: rating))
                }
            }
            .foregroundStyle(Color.yellow)
            Text(String(format: "%.1f", rating))
                .foregroundStyle(.white)
        }
        .font(.system(size: 13.5, weight: .semibold))   // 従来の1.5倍（I-32）
        .lineLimit(1)
        .minimumScaleFactor(0.8)
    }
}

// 一覧の1行（サムネイル付き）
struct ShopRowView: View {
    let shop: Shop

    // 最新の来店記録の1枚目の写真（日付不明は後回し）
    private var coverThumbnail: Data? {
        let visits: [Visit] = shop.visits
            .filter { !$0.isDeleted && $0.modelContext != nil }
            .sorted(by: Visit.newerFirst)
        for visit in visits {
            let photos: [Photo] = visit.sortedPhotos.filter { !$0.isDeleted && $0.modelContext != nil }
            if let first = photos.first {
                return first.thumbnailData
            }
        }
        return nil
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if let data = coverThumbnail {
                ThumbnailImage(data: data, size: 56)
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.secondary.opacity(0.12))
                    .frame(width: 56, height: 56)
                    .overlay {
                        Image(systemName: "fork.knife")
                            .foregroundStyle(.secondary)
                    }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(shop.name)
                        .font(.headline)
                        .lineLimit(1)
                    Spacer()
                    Text(shop.isVisited ? "行った" : "行きたい")
                        .font(.caption)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 2)
                        .background((shop.isVisited ? Color.green : Color.orange).opacity(0.2),
                                    in: Capsule())
                }
                // 店名の下に平均評価の星（I-25）
                if shop.isVisited {
                    StarRatingLabel(rating: shop.averageRating)
                }
                if let last = shop.lastVisitDate {
                    Text("最終来店 " + JPDate.day(last))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if !shop.tags.isEmpty {
                    Text(shop.sortedTags.map(\.name).joined(separator: "・"))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// タグで絞り込み
struct TagFilterSheet: View {
    @Environment(\.dismiss) private var dismiss
    let tags: [Tag]
    @Binding var selected: Set<UUID>

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TagChipsView(tags: tags, selected: $selected)
                } footer: {
                    Text("選んだタグをすべて含むお店を表示します")
                }
            }
            .navigationTitle("タグで絞り込み")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("クリア") { selected.removeAll() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
