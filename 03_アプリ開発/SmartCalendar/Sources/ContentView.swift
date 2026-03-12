import SwiftUI
import EventKit

// MARK: - ContentView

struct ContentView: View {
    @StateObject private var manager = CalendarManager()

    var body: some View {
        ZStack {
            Color(red: 0.06, green: 0.06, blue: 0.08).ignoresSafeArea()
            if manager.hasError {
                PermissionErrorView()
            } else {
                MainCalendarView().environmentObject(manager)
            }
        }
        .task {
            await manager.requestAccess()
        }
    }
}

// MARK: - MainCalendarView

struct MainCalendarView: View {
    @EnvironmentObject var manager: CalendarManager

    @State private var selectedDate: Date = Calendar.current.startOfDay(for: Date())
    
    // --- 新アーキテクチャ：カレンダーから明示的に選択された日（これに値が入った時だけリストがスクロールする） ---
    @State private var selectedDateFromCalendar: Date? = nil
    
    @State private var showInput = false
    @State private var inputText = ""
    @State private var inputWantsReminder = false
    @State private var liveParsedEvent: ParsedEvent? = nil
    @State private var pendingProgress: Double = 0.0
    @State private var openedFromInput = false
    @State private var parseTask: Task<Void, Never>? = nil
    @State private var deletingEvent: CalendarEvent? = nil
    @State private var editingEvent: CalendarEvent? = nil
    @State private var listProxy: ScrollViewProxy? = nil
    @State private var hasInitiallyScrolled = false
    @State private var showCalendar = true
    @State private var inputSelectedDate: Date? = nil
    @State private var isSearching = false
    @State private var searchText = ""
    @State private var cachedSearchResults: [(date: Date, events: [CalendarEvent])] = []
    @State private var searchTask: Task<Void, Never>? = nil
    @FocusState private var isSearchFocused: Bool
    @AppStorage("showHeaderYearMonth") private var showHeaderYearMonth = true
    @AppStorage("searchRangeYears") private var searchRangeYears = 3
    @State private var showSettings = false
    @State private var currentSearchYearsBack = 3
    // 検索結果の自動スクロール制御用
    @State private var lastCachedSearchCount = 0
    @State private var searchTopDate: Date? = nil
    @State private var pendingSearchRestoreDate: Date? = nil
    // 月変更フェッチのキャンセル用タスク
    @State private var fetchMonthTask: Task<Void, Never>? = nil
    @State private var suppressListSyncUntil: Date = .distantPast
    @State private var isProgrammaticListSync = false
    @State private var isUserListDragging = false
    @State private var endDragTask: Task<Void, Never>? = nil
    @State private var isLoadingMoreSearch = false

    var body: some View {
        GeometryReader { _ in
            ZStack(alignment: .bottom) {
                VStack(spacing: 0) {
                    // ── カレンダーエリア ──
                    calendarArea()

                    // ── イベントリスト（検索中 or 通常） ──
                    ScrollViewReader { proxy in
                        eventListArea(proxy: proxy)
                    }    .alert("削除しますか？", isPresented: Binding(
                            get: { deletingEvent != nil },
                            set: { if !$0 { deletingEvent = nil } }
                        )) {
                            Button("キャンセル", role: .cancel) { deletingEvent = nil }
                            Button("削除", role: .destructive) {
                                if let ev = deletingEvent { try? manager.deleteEvent(ev) }
                                deletingEvent = nil
                            }
                        } message: {
                            Text("この操作は取り消せません。")
                        }
                }
                .padding(.bottom, 76)

                // ── プレビューカード（廃止：即時登録に統合） ──

                // ── ボトムバー（検索中は非表示）/ 検索バー（検索中は下部に表示） ──
                if !isSearching {
                    BottomBar(
                        showInput: $showInput,
                        inputText: $inputText,
                        liveParsedEvent: $liveParsedEvent,
                        inputWantsReminder: $inputWantsReminder,
                        isSearching: $isSearching,
                        showCalendar: $showCalendar,
                        inputSelectedDate: $inputSelectedDate,
                        selectedDateFromCalendar: $selectedDateFromCalendar,
                        isSearchFocused: $isSearchFocused,
                        currentSelectedDate: selectedDate,
                        onTodayTap: goToToday,
                        onSubmit: { openDetailFromInput() },
                        onLongPress: {
                            UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                            openedFromInput = false
                            editingEvent = manager.newEmptyEvent()
                        },
                        onSettingsTap: { showSettings = true }
                    )
                    .zIndex(20)
                } else {
                    searchBarArea()
                }
            }
            // .ignoresSafeArea(.keyboard) を外すことで、キーボード出現時にBottomBarが画面上に押し上げられる（数字バーが見えるようになる）
            .contentShape(Rectangle())
            .onTapGesture {
                if isSearching {
                    exitSearch()
                }
            }
        }
        .sheet(item: $editingEvent, onDismiss: {
            // シートが閉じたときにリストを再フェッチ
            Task { await manager.forceRefresh(for: manager.displayedMonth) }
            if openedFromInput {
                // キャンセルや下スワイプなら入力画面に戻す
                showInput = true
            }
            openedFromInput = false
        }) { ev in
            EventEditSheet(event: ev)
                .environmentObject(manager)
                // 保存通知を受けて入力欄をクリア
                .onReceive(NotificationCenter.default.publisher(for: .init("EventSheetDidSaveNew"))) { _ in
                    inputText = ""
                    inputSelectedDate = nil
                    liveParsedEvent = nil
                    inputWantsReminder = false
                    openedFromInput = false
                }
        }
        .sheet(isPresented: $showSettings) {
            SettingsView().environmentObject(manager)
        }
        .onChange(of: manager.displayedMonth) { newMonth in
            // ここのイベント取得は連続して呼ばれると重くなるためタスクをキャンセルしてデバウンス
            fetchMonthTask?.cancel()
            fetchMonthTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 40_000_000)
                guard !Task.isCancelled else { return }
                await manager.fetchEvents(for: newMonth)
            }
        }
        .onChange(of: isSearching) { searching in
            // 検索開始時はカウントをリセット
            if searching { lastCachedSearchCount = 0 }
            handleSearchToggle(searching: searching)
        }
        .onChange(of: searchText) { query in
            guard isSearching else { return }
            // デバウンス: 150ms待って最後の入力のみ処理（連続打鍵によるもっさり解消）
            searchTask?.cancel()
            searchTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                cachedSearchResults = buildSearchResults(query: query)
            }
        }
        .onChange(of: inputText) { newVal in
            // NLP解析もデバウンスしてUIのもたつきを減らす
            parseTask?.cancel()
            parseTask = Task { @MainActor in
                try? await Task.sleep(nanoseconds: 120_000_000)
                guard !Task.isCancelled else { return }
                if newVal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    liveParsedEvent = nil
                    inputWantsReminder = false
                } else {
                    liveParsedEvent = NLPService.shared.parse(text: newVal)
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("OpenDuplicateEvent"))) { notif in
            if let ev = notif.object as? CalendarEvent { editingEvent = ev }
        }
        .onReceive(NotificationCenter.default.publisher(for: .init("CalendarDateTapped"))) { notif in
            if let d = notif.object as? Date {
                let day = Calendar.current.startOfDay(for: d)
                if showInput {
                    inputSelectedDate = day
                    selectedDate = day
                    selectedDateFromCalendar = day
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showCalendar = false
                    }
                } else {
                    selectedDateFromCalendar = day
                }
            }
        }
    }

    private var calendarGridHeight: CGFloat {
        // 月ごとの行数変動に伴うレイアウト崩れ（5週目が見切れる等）を防ぐため、常に6週間固定とする
        // DayCellの高さを30へ圧縮したため、32*6+4=196等ではなく30*6+4=184で固定する
        return 6 * 32 + 4
    }

    func goToToday() {
        let today = Calendar.current.startOfDay(for: Date())
        
        // カレンダーの表示月を今月に戻す
        if let month = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: today)) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                manager.setDisplayedMonth(month)
            }
        }
        
        // リスト側へ「今日へのジャンプ命令」を投げる（単一方向）
        selectedDateFromCalendar = today
    }

    // MARK: - View Builders
    
    private var headerWatermarkYear: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy年"
        return f.string(from: manager.displayedMonth)
    }

    private var headerWatermarkMonth: String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "M"
        return f.string(from: manager.displayedMonth)
    }

    @ViewBuilder
    private func calendarArea() -> some View {
        // 検索中はヘッダー・カレンダーを完全非表示（スペース節約）
        // 年月非表示時もヘッダー行なし（歯車はBottomBar左端に移動済み）
        if !isSearching && showHeaderYearMonth {
            CalendarHeader(
                month: manager.displayedMonth,
                onTitleTap: goToToday,
                onSettingsTap: { showSettings = true }
            )
        }

        if showCalendar {
            // ── 曜日ヘッダー ──
            WeekdayRow()

            // ── 指に吸い付くスワイプ月切替カレンダー ──
            ZStack {
                MonthPagerView(selectedDate: $selectedDate)
                    .environmentObject(manager)
                // 年月非表示時の透かし（カレンダーグリッドの背面に月数字を大きく表示）
                if !showHeaderYearMonth {
                    VStack(spacing: 0) {
                        Text(headerWatermarkYear)
                            .font(.system(size: 22, weight: .black))
                            .foregroundColor(Color.white.opacity(0.06))
                            .allowsHitTesting(false)
                            .lineLimit(1)
                        Text(headerWatermarkMonth)
                            .font(.system(size: 160, weight: .black))
                            .foregroundColor(Color.white.opacity(0.09))
                            .allowsHitTesting(false)
                            .minimumScaleFactor(0.1)
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
            }
            .frame(height: calendarGridHeight, alignment: .top)
            .clipped()
            .background(Color(red: 0.08, green: 0.08, blue: 0.11))

            // カレンダーとリストの境界を明確にするセパレーター（横線）
            Rectangle()
                .fill(Color.white.opacity(0.1))
                .frame(height: 1)
                .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func searchBarArea() -> some View {
        if isSearching {
            HStack(spacing: 8) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundColor(.white.opacity(0.5))
                    TextField("検索", text: $searchText)
                        .focused($isSearchFocused)
                        .foregroundColor(.white)
                        .submitLabel(.search)
                        .autocapitalization(.none)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill").foregroundColor(.white.opacity(0.5))
                        }
                    }
                }
                .padding(10)
                .background(Color.white.opacity(0.15))
                .cornerRadius(10)

                Button("キャンセル") {
                    exitSearch()
                }
                .foregroundColor(Color(red: 0.2, green: 0.6, blue: 1.0))
                .font(.system(size: 14, weight: .medium))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Color(red: 0.12, green: 0.12, blue: 0.16)
                    .shadow(color: .black.opacity(0.4), radius: 16, y: -4)
                    .ignoresSafeArea(edges: .bottom)
            )
            .padding(.bottom, 12)
        }
    }
    
    // スクロール位置追跡（空予定が除外されたため精密なOffset検知方式を採用）

    @ViewBuilder
    private func eventListArea(proxy: ScrollViewProxy) -> some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                if isSearching && !searchText.isEmpty {
                    searchResultsView()
                } else {
                    regularEventsView()
                }
                // ボトムバーに被らないよう余白
                Color.clear.frame(height: 100)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isSearching { exitSearch() }
            }
        }
        .simultaneousGesture(
            DragGesture(minimumDistance: 4)
                .onChanged { _ in
                    endDragTask?.cancel()
                    isUserListDragging = true
                }
                .onEnded { _ in
                    endDragTask?.cancel()
                    endDragTask = Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 220_000_000)
                        guard !Task.isCancelled else { return }
                        isUserListDragging = false
                    }
                }
        )
        .scrollIndicators(.hidden)
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
        .onAppear {
            listProxy = proxy
        }
        .onChange(of: manager.upcomingGrouped.count) { count in
            // 初回データロード完了時、一回だけ今日へジャンプするよう命令
            if !hasInitiallyScrolled && count > 0 {
                hasInitiallyScrolled = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    selectedDateFromCalendar = Calendar.current.startOfDay(for: Date())
                }
            }
        }
        .coordinateSpace(name: "scroll")
        .onPreferenceChange(ScrollOffsetKey.self) { offsets in
            let cal = Calendar.current
            if isSearching {
                // 検索モードでは、見えている最上部の日付を記録しておく
                // 値は表示したいヘッダの日付を示す。
                let nearTop = offsets
                    .filter { $0.value >= -24 && $0.value <= 24 }
                    .max(by: { $0.value < $1.value })
                let nearestByDistance = offsets.min(by: { abs($0.value) < abs($1.value) })
                if let (date, _) = nearTop ?? nearestByDistance {
                    searchTopDate = date
                }
            } else {
                // === リストのスクロール → カレンダーへの反映（単方向同期） ===
                // 🚨 無限スクロール防止：検索中/初期化前/カレンダーからのジャンプ命令中はミュート
                guard !isSearching, hasInitiallyScrolled, !manager.isSearchFetching else { return }
                // 実ユーザードラッグ時のみ連動し、プログラムスクロール起因のループを防止
                guard isUserListDragging else { return }
                guard selectedDateFromCalendar == nil else { return }
                guard !isProgrammaticListSync else { return }
                guard manager.syncListToMonth == nil else { return }
                guard Date() >= suppressListSyncUntil else { return }
                
                // 画面上部（Y=0）に最も近いヘッダーを採用（ジャンプ抑制）。
                let nearTop = offsets.filter { $0.value >= -40 && $0.value <= 60 }
                let nearest = nearTop.min(by: { abs($0.value) < abs($1.value) })
                    ?? offsets.min(by: { abs($0.value) < abs($1.value) })
                guard let (date, _) = nearest else { return }
                let newDate = cal.startOfDay(for: date)
                // ループ根絶のため、リストスクロールでは displayedMonth を更新しない。
                // 月変更はカレンダー操作（スワイプ/日付タップ/今日）のみで行う。
                if selectedDate != newDate {
                    selectedDate = newDate
                }
            }
        }
        .onChange(of: selectedDateFromCalendar) { targetDate in
            guard let targetDate = targetDate, !isSearching else { return }
            isProgrammaticListSync = true
            if selectedDate != targetDate { selectedDate = targetDate }
            scrollToSelected(proxy: proxy, targetDate: targetDate, animated: true)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                if selectedDateFromCalendar == targetDate {
                    selectedDateFromCalendar = nil
                }
                isProgrammaticListSync = false
            }
        }
        .onChange(of: showCalendar) { _ in
            // カレンダー表示切替直後はレイアウト再計算でオフセットが大きく揺れるため
            // 一時的にリスト→月同期を停止して暴走スクロールを防ぐ。
            suppressListSyncUntil = Date().addingTimeInterval(0.35)
        }
        .onChange(of: manager.resetTrigger) { _ in
            goToToday()
        }
        .onChange(of: manager.events.count) { _ in
            // 検索用イベントが追加でロードされたら検索結果を自動更新
            guard isSearching, !searchText.isEmpty else { return }
            cachedSearchResults = buildSearchResults(query: searchText.lowercased())
        }
        .onChange(of: cachedSearchResults.count) { newCount in
            guard isSearching, !cachedSearchResults.isEmpty else {
                lastCachedSearchCount = newCount
                return
            }
            if lastCachedSearchCount == 0 {
                // 初回ロードは下まで飛ばす
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    withAnimation { proxy.scrollTo("search_bottom", anchor: .bottom) }
                }
            } else if isLoadingMoreSearch {
                // 追加読み込み時はトップに記録した日付を復元
                let restoreDate = pendingSearchRestoreDate ?? searchTopDate
                if let top = restoreDate {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        proxy.scrollTo("hdr_\(top.timeIntervalSince1970)", anchor: .top)
                    }
                }
                pendingSearchRestoreDate = nil
                isLoadingMoreSearch = false
            }
            lastCachedSearchCount = newCount
        }
        .onChange(of: manager.syncListToMonth) { month in
            guard let month = month, !isSearching else { return }
            isProgrammaticListSync = true
            if let proxy = listProxy {
                scrollToSelected(proxy: proxy, targetDate: month, animated: false)
                selectedDate = month
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                manager.syncListToMonth = nil
                isProgrammaticListSync = false
            }
        }
    }

    @ViewBuilder
    private func searchResultsView() -> some View {
        let results = cachedSearchResults
        if results.isEmpty {
            if searchText.isEmpty {
                Text("キーワードを入力してください")
                    .foregroundColor(.white.opacity(0.4))
                    .padding(.top, 40)
            } else {
                Text("見つかりません")
                    .foregroundColor(.white.opacity(0.5))
                    .padding(.top, 40)
            }
        } else {
            // 「さらに過去を読み込む」ボタン（上端）
            Button {
                // searchTopDate は onPreferenceChange でビューポート最上部の日付をリアルタイム追跡済み
                // ここでは上書きせず、そのまま復元位置として使う
                isLoadingMoreSearch = true
                pendingSearchRestoreDate = searchTopDate
                let more = currentSearchYearsBack + 5
                currentSearchYearsBack = more
                Task { await manager.fetchAllEventsForSearch(yearsBack: more) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.up.circle")
                    Text("さらに過去を読み込む（\(currentSearchYearsBack + 5)年前まで）")
                        .font(.system(size: 13, weight: .medium))
                }
                .foregroundColor(Color(red: 0.2, green: 0.6, blue: 1.0))
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity)
                .background(Color.white.opacity(0.06))
                .cornerRadius(10)
                .padding(.horizontal, 16)
                .padding(.top, 8)
            }

            ForEach(results, id: \.date) { group in
                Section(header:
                    DateSectionHeader(date: group.date)
                        .background(
                            GeometryReader { proxy in
                                Color.clear.preference(
                                    key: ScrollOffsetKey.self,
                                    value: [group.date: proxy.frame(in: .named("scroll")).minY]
                                )
                            }
                        )
                ) {
                    ForEach(group.events) { ev in
                        EventRow(
                            event: ev,
                            onTap: { editingEvent = ev },
                            onToggle: { manager.toggleReminderCompletion(ev) }
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                }
                .id("hdr_\(group.date.timeIntervalSince1970)")
            }

            // 検索結果の最下端マーカー（自動スクロール用）
            Color.clear.frame(height: 1).id("search_bottom")
        }
    }

    @ViewBuilder
    private func regularEventsView() -> some View {
        ForEach(manager.upcomingGrouped, id: \.date) { group in
            Section(
                header: DateSectionHeader(date: group.date)
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: ScrollOffsetKey.self,
                                value: [group.date: proxy.frame(in: .named("scroll")).minY]
                            )
                        }
                    )
            ) {
                if group.events.isEmpty {
                    Text("予定なし")
                        .font(.system(size: 13))
                        .foregroundColor(.white.opacity(0.25))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 32).padding(.bottom, 8)
                } else {
                    ForEach(group.events) { ev in
                        EventRow(
                            event: ev,
                            onTap: { editingEvent = ev },
                            onToggle: { manager.toggleReminderCompletion(ev) }
                        )
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                    }
                }
            }
            .id("hdr_\(group.date.timeIntervalSince1970)") // ScrollTo 用に戻す
        }
    }
    
    
    
    // MARK: - UI Event Handlers
    
    func exitSearch() {
        isSearching = false
        isSearchFocused = false
        searchText = ""
        cachedSearchResults = []
        searchTask?.cancel()
        searchTask = nil
        isLoadingMoreSearch = false
        showCalendar = true
        hasInitiallyScrolled = false // 再スクロールを許可
        isProgrammaticListSync = true
        suppressListSyncUntil = Date().addingTimeInterval(0.7)

        let today = Calendar.current.startOfDay(for: Date())
        if let thisMonth = Calendar.current.date(from: Calendar.current.dateComponents([.year, .month], from: today)) {
            manager.setDisplayedMonth(thisMonth)
            manager.syncListToMonth = thisMonth
        }

        // 検索でメモリに溜まったイベントキャッシュを完全クリアして再取得
        manager.resetEventCache()
        Task {
            await manager.fetchEvents(for: manager.displayedMonth)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
                selectedDateFromCalendar = today
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    isProgrammaticListSync = false
                }
            }
        }
    }

    func handleSearchToggle(searching: Bool) {
        showCalendar = !searching
        if searching {
            isUserListDragging = false
        }
        if searching {
            isSearchFocused = true
            currentSearchYearsBack = searchRangeYears
            manager.resetEventCache()
            Task { await manager.fetchAllEventsForSearch(yearsBack: searchRangeYears) }
        } else {
            searchText = ""
            cachedSearchResults = []
            isSearchFocused = false
        }
    }

    // MARK: - 検索ロジック
    
    func buildSearchResults(query: String) -> [(date: Date, events: [CalendarEvent])] {
        guard !query.isEmpty else { return [] }
        let cal = Calendar.current
        let q = query.lowercased()
        let filtered = manager.events.filter { ev in
            if ev.title.lowercased().contains(q) { return true }
            if let loc = ev.location, loc.lowercased().contains(q) { return true }
            let notes = ev.isReminder ? ev.ekReminder?.notes : ev.ekEvent?.notes
            if let n = notes, n.lowercased().contains(q) { return true }
            let url = ev.isReminder ? ev.ekReminder?.url : ev.ekEvent?.url
            if let u = url?.absoluteString, u.lowercased().contains(q) { return true }
            return false
        }
        var dict: [Date: [CalendarEvent]] = [:]
        for ev in filtered {
            let key = cal.startOfDay(for: ev.startDate)
            dict[key, default: []].append(ev)
        }
        return dict.keys.sorted().map { (date: $0, events: dict[$0]!.sorted { $0.startDate < $1.startDate }) }
    }

    // 互換性のために残す（キャッシュを使わないパス）
    var groupedSearchResults: [(date: Date, events: [CalendarEvent])] {
        buildSearchResults(query: searchText.lowercased())
    }

    func scrollToSelected(proxy: ScrollViewProxy, targetDate: Date, animated: Bool = true) {
        let cal = Calendar.current
        let day = cal.startOfDay(for: targetDate)
        // 正確な日付がリストに存在するかを優先して探す
        if let match = manager.upcomingGrouped.first(where: { cal.isDate($0.date, inSameDayAs: day) }) {
            let id = "hdr_\(match.date.timeIntervalSince1970)"
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0))
                }
            } else {
                proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0))
            }
            return
        }
        // 存在しない場合は従来の挙動で最も近い日へ
        let target = manager.upcomingGrouped.map(\.date).first {
            cal.startOfDay(for: $0) >= day
        } ?? manager.upcomingGrouped.first?.date
        if let t = target {
            let id = "hdr_\(t.timeIntervalSince1970)"
            if animated {
                withAnimation(.easeOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0))
                }
            } else {
                proxy.scrollTo(id, anchor: UnitPoint(x: 0.5, y: 0))
            }
        }
    }

    func openDetailFromInput() {
        guard let parsed = liveParsedEvent,
              let cal = manager.selectedCalendar ?? manager.calendars.first else { return }

        let parsedStart = parseFlexDate(parsed.startDate) ?? Date()
        let parsedEnd = parseFlexDate(parsed.endDate) ?? parsedStart.addingTimeInterval(3600)
        let isAllDay = parsed.isAllDay ?? false

        let start: Date
        let end: Date
        if let selectedDay = inputSelectedDate {
            if isAllDay {
                start = selectedDay
                end = selectedDay
            } else {
                let c = Calendar.current
                let timeComps = c.dateComponents([.hour, .minute], from: parsedStart)
                var dayComps = c.dateComponents([.year, .month, .day], from: selectedDay)
                dayComps.hour = timeComps.hour
                dayComps.minute = timeComps.minute
                start = c.date(from: dayComps) ?? parsedStart
                end = start.addingTimeInterval(parsedEnd.timeIntervalSince(parsedStart))
            }
        } else {
            start = parsedStart
            end = parsedEnd
        }

        let newEv = CalendarEvent(
            id: UUID().uuidString,
            title: parsed.title,
            startDate: start,
            endDate: end,
            calendar: inputWantsReminder
                ? (manager.store.defaultCalendarForNewReminders() ?? manager.reminderCalendars.first ?? cal)
                : cal,
            location: parsed.location,
            isAllDay: isAllDay,
            ekEvent: nil,
            ekReminder: inputWantsReminder ? EKReminder(eventStore: manager.store) : nil,
            isCompleted: false
        )
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        editingEvent = newEv
        showInput = false
        openedFromInput = true
        // NOTE: 入力画面の内容は消さない。キャンセルや下スワイプで戻ったときに復元できるようにする。
        // inputText = ""
        // inputSelectedDate = nil
        // liveParsedEvent = nil
    }

    func submitInput() {
        guard let parsed = liveParsedEvent else { return }

        inputText = ""; showInput = false
        liveParsedEvent = nil
        let asReminder = inputWantsReminder
        inputWantsReminder = false
        let baseInputDate = inputSelectedDate
        inputSelectedDate = nil

        guard let parsedStart = parseFlexDate(parsed.startDate),
              let parsedEnd = parseFlexDate(parsed.endDate) else { return }

        let isAllDay = parsed.isAllDay ?? false

        // カレンダーで日付が選択されていればその日付を使い、時間はNLPから取る
        let start: Date
        let end: Date
        if let selectedDay = baseInputDate {
            let cal = Calendar.current
            if isAllDay {
                start = selectedDay
                end = selectedDay
            } else {
                let timeComps = cal.dateComponents([.hour, .minute], from: parsedStart)
                var dayComps = cal.dateComponents([.year, .month, .day], from: selectedDay)
                dayComps.hour = timeComps.hour
                dayComps.minute = timeComps.minute
                let adjustedStart = cal.date(from: dayComps) ?? parsedStart
                start = adjustedStart
                end = adjustedStart.addingTimeInterval(parsedEnd.timeIntervalSince(parsedStart))
            }
        } else {
            start = parsedStart
            end = parsedEnd
        }

        if asReminder {
            try? manager.addReminder(
                title: parsed.title,
                dueDate: start,
                location: parsed.location,
                calendar: manager.store.defaultCalendarForNewReminders() ?? manager.reminderCalendars.first
            )
        } else {
            try? manager.addEvent(title: parsed.title, startDate: start, endDate: end, location: parsed.location, calendar: manager.selectedCalendar, isAllDay: isAllDay)
        }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    func parseFlexDate(_ s: String) -> Date? {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone.current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }
}

// MARK: - Fantasticalライクヘッダー

struct CalendarHeader: View {
    let month: Date
    let onTitleTap: () -> Void
    let onSettingsTap: () -> Void

    private static let yearFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "yyyy年"; return f
    }()
    private static let monthFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "M月"; return f
    }()

    var yearStr: String { Self.yearFmt.string(from: month) }
    var monthStr: String { Self.monthFmt.string(from: month) }

    var body: some View {
        ZStack {
            // 中央：年月（タップで今日へ）—— .id で月変化時にページめくりアニメ
            HStack(alignment: .lastTextBaseline, spacing: 6) {
                Text(yearStr)
                    .font(.system(size: 16, weight: .bold))
                    .foregroundColor(Color(red: 1.0, green: 0.27, blue: 0.23))
                Text(monthStr)
                    .font(.system(size: 28, weight: .bold))
                    .foregroundColor(.white)
            }
            .onTapGesture { onTitleTap() }
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 16)
        .padding(.top, 4)
        .padding(.bottom, 2)
        .background(Color(red: 0.08, green: 0.08, blue: 0.11))
    }
}

// MARK: - 曜日ヘッダー

struct WeekdayRow: View {
    private let days = ["日", "月", "火", "水", "木", "金", "土"]
    var body: some View {
        HStack(spacing: 0) {
            ForEach(days, id: \.self) { d in
                Text(d)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(
                        d == "日" ? Color(red: 1.0, green: 0.27, blue: 0.23).opacity(0.8) :
                        d == "土" ? Color(red: 0.4, green: 0.6, blue: 1.0) :
                        .white.opacity(0.4)
                    )
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Color(red: 0.08, green: 0.08, blue: 0.11))
    }
}

// MARK: - 指に吸い付くスワイプページング

// MARK: - 指に吸い付くスワイプページング

struct MonthPagerView: View {
    @EnvironmentObject var manager: CalendarManager
    @Binding var selectedDate: Date
    @State private var isSnapping = false
    @State private var slotOffset: CGFloat = 0
    @State private var isHorizontalDrag = false
    // ローカルで管理する表示月。manager.displayedMonth に依存せず @State で原子的に更新。
    @State private var baseMonth: Date = Calendar.current.startOfDay(for: Date())

    private var displayMonths: [Date] {
        let cal = Calendar.current
        let prev = cal.date(byAdding: .month, value: -1, to: baseMonth)!
        let next = cal.date(byAdding: .month, value: 1, to: baseMonth)!
        return [prev, baseMonth, next]
    }

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { i in
                    MonthGrid(
                        month: displayMonths[i],
                        selectedDate: $selectedDate,
                        onDateSelected: { date in
                            NotificationCenter.default.post(name: .init("CalendarDateTapped"), object: date)
                        }
                    )
                    .frame(width: w)
                    .environmentObject(manager)
                }
            }
            .frame(width: w, alignment: .leading)
            .offset(x: -w + slotOffset)
            .gesture(
                DragGesture(minimumDistance: 8)
                    .onChanged { v in
                        guard !isSnapping else { return }
                        if abs(v.translation.width) > abs(v.translation.height) || isHorizontalDrag {
                            isHorizontalDrag = true
                            slotOffset = v.translation.width
                        }
                    }
                    .onEnded { v in
                        guard isHorizontalDrag else { return }
                        isHorizontalDrag = false
                        guard !isSnapping else { return }
                        let vel = v.predictedEndTranslation.width
                        let dist = v.translation.width
                        if vel < -60 || dist < -40 {
                            isSnapping = true
                            snapTo(direction: 1, width: w)
                        } else if vel > 60 || dist > 40 {
                            isSnapping = true
                            snapTo(direction: -1, width: w)
                        } else {
                            withAnimation(.spring(response: 0.22, dampingFraction: 0.9)) { slotOffset = 0 }
                        }
                    }
            )
        }
        .onAppear { baseMonth = manager.displayedMonth }
        .onChange(of: manager.displayedMonth) { month in
            // 外部（今日ボタン等）からの月変更を反映（スナップ中は無視）
            if !isSnapping { baseMonth = month }
        }
    }

    /// direction: +1=次月, -1=前月
    func snapTo(direction: Int, width: CGFloat) {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let monthsDiff = cal.dateComponents([.month], from: today, to: baseMonth).month ?? 0
        let limit = 120
        if (monthsDiff <= -limit && direction < 0) || (monthsDiff >= limit && direction > 0) {
            withAnimation(.easeOut(duration: 0.12)) { slotOffset = 0 }
            isSnapping = false
            return
        }

        let targetX: CGFloat = direction > 0 ? -width : width
        let newMonth = cal.date(byAdding: .month, value: direction, to: baseMonth)!
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        withAnimation(.easeOut(duration: 0.12)) { slotOffset = targetX }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) {
            // baseMonth と slotOffset を同一フレームで原子的に更新 → チラつき・ずれなし
            baseMonth = newMonth
            slotOffset = 0
            manager.setDisplayedMonth(newMonth)
            manager.syncListToMonth = newMonth
            isSnapping = false
        }
    }
}

// MARK: - 月グリッド（1ヶ月分）

struct MonthGrid: View {
    @EnvironmentObject var manager: CalendarManager
    let month: Date
    @Binding var selectedDate: Date
    let onDateSelected: (Date) -> Void

    private let cal = Calendar.current

    var body: some View {
        let days = manager.daysInMonth(month)
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: 7), spacing: 2) {
            ForEach(0..<days.count, id: \.self) { i in
                if let date = days[i] {
                    DayCell(
                        date: date,
                        displayMonth: month,
                        selectedDate: $selectedDate,
                        onTap: { onDateSelected(date) }
                    )
                    .environmentObject(manager)
                } else {
                    Color.clear.frame(height: 34)
                }
            }
        }
        .padding(.horizontal, 8)
        .padding(.bottom, 2)
        .background(Color(red: 0.08, green: 0.08, blue: 0.11))
    }
}

// MARK: - 日付セル

struct DayCell: View {
    @EnvironmentObject var manager: CalendarManager
    let date: Date
    let displayMonth: Date
    @Binding var selectedDate: Date
    let onTap: () -> Void
    private let cal = Calendar.current

    var isToday: Bool { cal.isDateInToday(date) }
    var isSelected: Bool { cal.isDate(date, inSameDayAs: selectedDate) }
    var isCurrentMonth: Bool { cal.isDate(date, equalTo: displayMonth, toGranularity: .month) }
    var dayEvents: [CalendarEvent] { manager.events(on: date) }
    
    // 選択された日付と同じ週かどうか（カレンダーの週ハイライト用）
    var isInSelectedWeek: Bool {
        let cal = Calendar.current
        // 週の始まりの日付を比較して同一週か判定する
        guard let startOfDateWeek = cal.dateInterval(of: .weekOfYear, for: date)?.start,
              let startOfSelectedWeek = cal.dateInterval(of: .weekOfYear, for: selectedDate)?.start else {
            return false
        }
        return cal.isDate(startOfDateWeek, inSameDayAs: startOfSelectedWeek)
    }

    var body: some View {
        VStack(spacing: 2) {
            ZStack {
                // 🚨 選択週のハイライト（薄いグレー）
                if isInSelectedWeek && isCurrentMonth {
                    Rectangle()
                        .fill(Color(red: 0.2, green: 0.6, blue: 1.0).opacity(0.13))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                if isSelected && !isToday {
                    Circle().fill(Color.white.opacity(0.18)).frame(width: 24, height: 24)
                }
                if isToday {
                    Circle().fill(Color(red: 1.0, green: 0.27, blue: 0.23)).frame(width: 24, height: 24)
                }
                Text("\(cal.component(.day, from: date))")
                    .font(.system(size: 15, weight: isToday ? .bold : .regular))
                    .foregroundColor(isToday ? .white : isCurrentMonth ? .white : .white.opacity(0.2))
            }
            .frame(height: 24)
            HStack(spacing: 3) {
                ForEach(dayEvents.prefix(3)) { ev in
                    Circle().fill(ev.calendarColor).frame(width: 3.5, height: 3.5)
                }
            }.frame(height: 4)
        }
        .frame(height: 30)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .onTapGesture {
            // 他月の日付をタップすると、自動でその月へ移動して選択も行う
            if !isCurrentMonth {
                let cal = Calendar.current
                let newMonth = cal.date(from: cal.dateComponents([.year, .month], from: date))!
                withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                    manager.setDisplayedMonth(newMonth)
                }
                manager.syncListToMonth = newMonth
            }
            onTap()
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
    }
}

// MARK: - Scroll Tracking Key

struct ScrollOffsetKey: PreferenceKey {
    typealias Value = [Date: CGFloat]
    static var defaultValue: Value = [:]
    static func reduce(value: inout Value, nextValue: () -> Value) {
        value.merge(nextValue()) { $1 }
    }
}

// MARK: - セクションヘッダー

struct DateSectionHeader: View {
    let date: Date
    private let cal = Calendar.current

    private static let labelFormatter: DateFormatter = {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "yyyy年M月d日 (E)"
        return df
    }()
    
    var label: String {
        return Self.labelFormatter.string(from: date)
    }
    private static let subFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy/MM/dd"
        return f
    }()

    var sub: String {
        return Self.subFormatter.string(from: date)
    }

    var body: some View {
        HStack {
            Text(label)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.white.opacity(0.6))
            Spacer()
        }
        .padding(.horizontal, 16).padding(.top, 16).padding(.bottom, 8)
        .background(Color(red: 0.06, green: 0.06, blue: 0.08))
    }
}

// MARK: - イベント行

struct EventRow: View {
    let event: CalendarEvent
    let onTap: () -> Void
    var onToggle: (() -> Void)? = nil

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "HH:mm"
        return f
    }()

    var timeLabel: String {
        if event.isAllDay { return "終日" }
        if event.isReminder { return Self.timeFormatter.string(from: event.startDate) }
        return "\(Self.timeFormatter.string(from: event.startDate))〜\(Self.timeFormatter.string(from: event.endDate))"
    }

    var isPast: Bool { event.endDate < Date() }

    @AppStorage("listCompactMode") private var listCompactMode = false

    var body: some View {
        Button {
            onTap()
        } label: {
            HStack(spacing: listCompactMode ? 10 : 14) {
                ZStack {
                    Circle()
                        .fill(event.calendarColor.opacity(0.2))
                        .frame(width: listCompactMode ? 32 : 40, height: listCompactMode ? 32 : 40)
                    Image(systemName: event.isReminder
                          ? (event.isCompleted ? "checkmark.circle.fill" : "circle")
                          : "calendar.circle.fill")
                        .font(.system(size: listCompactMode ? 18 : 22))
                        .foregroundColor(event.isReminder && event.isCompleted
                                         ? .white.opacity(0.3) : event.calendarColor)
                }
                VStack(alignment: .leading, spacing: listCompactMode ? 1 : 3) {
                    Text(event.title)
                        .font(.system(size: listCompactMode ? 14 : 16, weight: .semibold))
                        .foregroundColor(event.isReminder && event.isCompleted ? .white.opacity(0.4) : .white)
                        .lineLimit(1)
                        .strikethrough(event.isReminder && event.isCompleted)
                    HStack(spacing: 8) {
                        Text(timeLabel)
                            .font(.system(size: listCompactMode ? 12 : 14, weight: .medium))
                            .foregroundColor(.white)
                        if let loc = event.location, !loc.isEmpty {
                            Label(loc, systemImage: "mappin.circle.fill")
                                .font(.system(size: listCompactMode ? 10 : 11))
                                .foregroundColor(.white.opacity(0.45))
                                .lineLimit(1)
                        }
                    }
                }
                Spacer()
            }
            .padding(listCompactMode ? 10 : 14)
            .background(
                RoundedRectangle(cornerRadius: listCompactMode ? 10 : 14)
                    .fill(Color(red: 0.11, green: 0.11, blue: 0.12))
            )
            .opacity((isPast && !event.isReminder) ? 0.4 : 1.0)
        }
        .buttonStyle(PlainButtonStyle())
        // リマインダーのアイコン部分だけ横取りしてトグル
        .overlay(alignment: .leading) {
            if event.isReminder {
                Color.clear
                    .frame(width: 68)
                    .contentShape(Rectangle())
                    .onTapGesture { onToggle?() }
            }
        }
    }
}

// MARK: - ボトムバー

struct BottomBar: View {
    @Binding var showInput: Bool
    @Binding var inputText: String
    @Binding var liveParsedEvent: ParsedEvent?
    @Binding var inputWantsReminder: Bool
    @Binding var isSearching: Bool
    @Binding var showCalendar: Bool
    @Binding var inputSelectedDate: Date?
    @Binding var selectedDateFromCalendar: Date?
    @FocusState.Binding var isSearchFocused: Bool
    let currentSelectedDate: Date
    let onTodayTap: () -> Void
    let onSubmit: () -> Void
    let onLongPress: () -> Void
    let onSettingsTap: () -> Void
    @AppStorage("inputShowDigits") private var inputShowDigits = true
    @AppStorage("inputShowTilde") private var inputShowTilde = true
    @AppStorage("inputShowHours") private var inputShowHours = true
    @AppStorage("inputShowMinutes") private var inputShowMinutes = true
    @AppStorage("inputShowTemp") private var inputShowTemp = true
    @AppStorage("inputShowTask") private var inputShowTask = true
    @FocusState private var focused: Bool

    // 入力エリアで「詳細」ボタンから利用できるDateFormatter
    private static let mmddFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "M/d"
        return f
    }()
    private static let timeFmt: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "HH:mm"
        return f
    }()
    private func parseFlexDateForLive(_ s: String) -> Date? {
        let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.timeZone = TimeZone.current
        for fmt in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let d = df.date(from: s) { return d }
        }
        return nil
    }

    private func openCalendarPickerFromInput() {
        withAnimation(.spring(response: 0.25, dampingFraction: 0.85)) {
            showCalendar = true
            focused = false
            if let d = inputSelectedDate {
                selectedDateFromCalendar = Calendar.current.startOfDay(for: d)
            }
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            if showInput {
                VStack(spacing: 4) {
                    if showInput {
                        VStack(spacing: 2) {
                            if inputShowDigits {
                                SwipeDigitKeyRow(inputText: $inputText)
                            }
                            let wordKeys: [(String, String, Bool)] = [
                                ("時", "時", inputShowHours),
                                ("分", "分", inputShowMinutes),
                                ("〜", "〜", inputShowTilde),
                                ("task", "", inputShowTask),
                                ("仮", " 仮", inputShowTemp)
                            ]
                            let visibleWordKeys = wordKeys.filter(\.2)
                            if !visibleWordKeys.isEmpty {
                                HStack(spacing: 3) {
                                    ForEach(visibleWordKeys, id: \.0) { char, insert, _ in
                                        Button {
                                            if char == "task" {
                                                inputWantsReminder.toggle()
                                                if inputWantsReminder && !inputText.contains(" task") {
                                                    inputText += " task"
                                                }
                                            } else {
                                                inputText += insert
                                            }
                                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                                        } label: {
                                            Text(char)
                                                .font(.system(size: 13, weight: .medium))
                                                .foregroundColor(
                                                    char == "仮" ? Color.orange :
                                                    char == "task" && inputWantsReminder ? Color(red: 0.2, green: 0.6, blue: 1.0) :
                                                    .white.opacity(0.85)
                                                )
                                                .frame(maxWidth: .infinity).frame(height: 26)
                                                .background(
                                                    char == "task" && inputWantsReminder
                                                        ? Color(red: 0.2, green: 0.6, blue: 1.0).opacity(0.2)
                                                        : Color.white.opacity(0.09)
                                                )
                                                .cornerRadius(5)
                                        }
                                        .buttonStyle(KeyButtonStyle())
                                    }
                                }
                            }
                        }
                        .padding(.horizontal, 4).padding(.top, 4)
                    }
                    
                    // ✨ ライブプレビュー表示領域 ✨
                    if let parsed = liveParsedEvent, let start = parseFlexDateForLive(parsed.startDate), !inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        HStack(spacing: 8) {
                            // 日付・時間ラベル
                            Button {
                                openCalendarPickerFromInput()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "clock")
                                        .font(.system(size: 11, weight: .bold))
                                    // カレンダー選択日がある場合はその日付を優先
                                    let displayDate = inputSelectedDate ?? start
                                    let dStr = Self.mmddFmt.string(from: displayDate)
                                    let tStr = (parsed.isAllDay ?? false) ? "終日" : Self.timeFmt.string(from: start)
                                    Text("\(dStr)\(tStr)")
                                        .font(.system(size: 13, weight: .bold))
                                }
                                .foregroundColor(Color(red: 0.2, green: 0.6, blue: 1.0))
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color(red: 0.2, green: 0.6, blue: 1.0).opacity(0.15))
                                .cornerRadius(6)
                            }
                            .buttonStyle(.plain)
                            .contentShape(Rectangle())
                            
                            // タイトル
                            Text(parsed.title)
                                .font(.system(size: 14, weight: .medium))
                                .foregroundColor(.white)
                                .lineLimit(1)
                            
                            // 場所
                            if let loc = parsed.location, !loc.isEmpty {
                                HStack(spacing: 2) {
                                    Image(systemName: "mappin")
                                        .font(.system(size: 11, weight: .medium))
                                    Text(loc)
                                }
                                .font(.system(size: 11, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                                .lineLimit(1)
                            }

                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .padding(.top, 8)
                        .transition(.opacity)
                    } else if let selectedDate = inputSelectedDate, inputText.isEmpty {
                        // ── 日付選択中ラベル（テキスト未入力時） ──
                        Button {
                            openCalendarPickerFromInput()
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "calendar.badge.clock")
                                    .font(.system(size: 12, weight: .bold))
                                Text("\(Self.mmddFmt.string(from: selectedDate))を選択中")
                                    .font(.system(size: 13, weight: .bold))
                                Spacer()
                            }
                            .foregroundColor(Color(red: 0.2, green: 0.6, blue: 1.0))
                            .padding(.horizontal, 14)
                            .padding(.top, 8)
                            .transition(.opacity)
                        }
                        .buttonStyle(.plain)
                        .contentShape(Rectangle())
                    }

                    // 入力ボックス本体
                    HStack(spacing: 8) {
                        TextField(inputSelectedDate != nil ? "「15:00 会議 渋谷」（日付はカレンダーから）" : "「明日15時に会議 渋谷」", text: $inputText)
                            .focused($focused)
                            .font(.system(size: 16)).foregroundColor(.white)
                            .submitLabel(.send)
                            .onSubmit { onSubmit() }
                            .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } }
                        
                        Button { onSubmit() } label: {
                            Image(systemName: "arrow.up.circle.fill")
                                .font(.system(size: 28))
                                .foregroundColor(inputText.isEmpty ? .white.opacity(0.3) : Color(red: 0.2, green: 0.6, blue: 1.0))
                        }.disabled(inputText.isEmpty)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 10)
                }
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white.opacity(0.1)))
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        showInput = false; inputText = ""; focused = false
                        inputSelectedDate = nil
                        inputWantsReminder = false
                    }
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 22)).foregroundColor(.white.opacity(0.5))
                }
            } else {
                // ── 通常モード：ZStackで+を中央に固定 ──
                ZStack {
                    HStack(spacing: 0) {
                        // 歯車ボタン（左端）
                        Button(action: onSettingsTap) {
                            Image(systemName: "gearshape")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                                .frame(width: 44, height: 50)
                        }
                        // 検索ボタン（歯車の右隣）
                        Button {
                            withAnimation(.easeOut(duration: 0.15)) {
                                isSearching.toggle()
                            }
                            if isSearching {
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                                    isSearchFocused = true
                                }
                            }
                        } label: {
                            Image(systemName: "magnifyingglass")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(.white.opacity(0.6))
                                .frame(width: 40, height: 50)
                        }
                        Spacer()
                        // カレンダー切替 + 今日（右）
                        HStack(spacing: 4) {
                            Button {
                                withAnimation(.easeOut(duration: 0.15)) {
                                    showCalendar.toggle()
                                }
                            } label: {
                                Image(systemName: showCalendar ? "chevron.up" : "calendar")
                                    .font(.system(size: 18))
                                    .foregroundColor(.white.opacity(0.7))
                                    .frame(width: 36, height: 44)
                            }
                            Button(action: onTodayTap) {
                                Text("今日")
                                    .font(.system(size: 14, weight: .semibold)).foregroundColor(.white)
                                    .frame(width: 44, height: 36)
                                    .background(Color.white.opacity(0.1)).cornerRadius(10)
                            }
                        }
                    }
                    // +ボタン（中央固定）
                    Button {
                        withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                            showInput = true
                            showCalendar = true
                            inputWantsReminder = false
                            // 明示タップ日 > 現在の選択日 の優先順で初期日付を設定
                            inputSelectedDate = selectedDateFromCalendar ?? currentSelectedDate
                        }
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    } label: {
                        ZStack {
                            Circle()
                                .fill(Color(red: 0.2, green: 0.6, blue: 1.0))
                                .frame(width: 50, height: 50)
                                .shadow(color: Color(red: 0.2, green: 0.6, blue: 1.0).opacity(0.5), radius: 10)
                            Image(systemName: "plus").font(.system(size: 22, weight: .bold)).foregroundColor(.white)
                        }
                    }
                    .simultaneousGesture(LongPressGesture(minimumDuration: 0.5).onEnded { _ in
                        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
                        onLongPress()
                    })
                }
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: showInput ? 20 : 30)
                .fill(Color(red: 0.12, green: 0.12, blue: 0.16))
                .shadow(color: .black.opacity(0.4), radius: 16, y: -4)
        )
        .padding(.horizontal, showInput ? 8 : 20)
        .padding(.bottom, 12)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: showInput)
    }
}

// MARK: - プレビューカード

struct ParsedEventCard: View {
    let event: ParsedEvent
    let progress: Double
    let onUndo: () -> Void
    let onCommit: () -> Void // ★ 追加

    var dateLabel: String {
        // 終日イベント
        if event.isAllDay == true {
            let df = DateFormatter(); df.locale = Locale(identifier: "en_US_POSIX"); df.dateFormat = "yyyy-MM-dd"
            if let s = df.date(from: event.startDate) {
                let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP")
                f.dateFormat = Calendar.current.isDateInToday(s) ? "'今日'" :
                               Calendar.current.isDateInTomorrow(s) ? "'明日'" : "M月d日"
                return f.string(from: s) + "終日"
            }
        }
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        for fmt in ["yyyy-MM-dd'T'HH:mm:ssZ", "yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd"] {
            df.dateFormat = fmt
            if let s = df.date(from: event.startDate) {
                let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP")
                f.dateFormat = Calendar.current.isDateInToday(s) ? "今日HH:mm" :
                               Calendar.current.isDateInTomorrow(s) ? "明日HH:mm" : "M月d日HH:mm"
                return f.string(from: s)
            }
        }
        return event.startDate
    }

    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Color.white.opacity(0.1))
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color(red: 0.2, green: 0.6, blue: 1.0))
                        .frame(width: g.size.width * progress)
                }
            }.frame(height: 3)
            HStack(spacing: 14) {
                ZStack {
                    Circle().fill(Color(red: 0.2, green: 0.6, blue: 1.0).opacity(0.2)).frame(width: 40, height: 40)
                    Image(systemName: "calendar.badge.checkmark").font(.system(size: 18))
                        .foregroundColor(Color(red: 0.2, green: 0.6, blue: 1.0))
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.title).font(.system(size: 16, weight: .semibold)).foregroundColor(.white).lineLimit(1)
                    HStack(spacing: 8) {
                        Label(dateLabel, systemImage: "clock").font(.system(size: 12)).foregroundColor(.white.opacity(0.6))
                        if let loc = event.location, !loc.isEmpty {
                            Label(loc, systemImage: "mappin").font(.system(size: 12))
                                .foregroundColor(.white.opacity(0.6)).lineLimit(1)
                        }
                    }
                }
                Spacer()
                Button(action: onUndo) {
                    Text("キャンセル").font(.system(size: 13, weight: .medium))
                        .foregroundColor(Color(red: 1.0, green: 0.4, blue: 0.4))
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .background(Color.red.opacity(0.12)).cornerRadius(8)
                }
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            
            // ★ 手動登録ボタンを追加
            Button(action: onCommit) {
                Text("この内容で登録").font(.system(size: 16, weight: .bold))
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color(red: 0.2, green: 0.6, blue: 1.0))
                    .cornerRadius(10)
            }
            .padding(.horizontal, 16).padding(.bottom, 12)
        }
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(Color(red: 0.14, green: 0.14, blue: 0.2))
                .shadow(color: .black.opacity(0.5), radius: 16, y: 4)
        )
    }
}

// MARK: - ScaleButtonStyle

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - DigitButtonStyle（数字キー押下時に大きいプレビューを表示）

struct DigitButtonStyle: ButtonStyle {
    let char: String
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.85 : 1)
            .overlay(alignment: .top) {
                if configuration.isPressed {
                    Text(char)
                        .font(.system(size: 34, weight: .bold))
                        .foregroundColor(.white)
                        .frame(width: 48, height: 52)
                        .background(Color(red: 0.25, green: 0.35, blue: 0.55).cornerRadius(10))
                        .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                        .offset(y: -58)
                }
            }
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
            .zIndex(configuration.isPressed ? 100 : 0)
    }
}

// MARK: - SwipeDigitKeyRow（スワイプで数字選択）

struct SwipeDigitKeyRow: View {
    @Binding var inputText: String
    private let digits = ["1","2","3","4","5","6","7","8","9","0"]
    @State private var hoveredIndex: Int? = nil

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 3) {
                ForEach(0..<digits.count, id: \.self) { i in
                    Text(digits[i])
                        .font(.system(size: hoveredIndex == i ? 24 : 19, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .frame(height: 32)
                        .background(
                            (hoveredIndex == i ? Color.white.opacity(0.25) : Color.white.opacity(0.12))
                                .cornerRadius(5)
                        )
                        .overlay(alignment: .top) {
                            if hoveredIndex == i {
                                Text(digits[i])
                                    .font(.system(size: 34, weight: .bold))
                                    .foregroundColor(.white)
                                    .frame(width: 48, height: 52)
                                    .background(Color(red: 0.25, green: 0.35, blue: 0.55).cornerRadius(10))
                                    .shadow(color: .black.opacity(0.45), radius: 8, y: 2)
                                    .offset(y: -58)
                            }
                        }
                        .animation(.easeOut(duration: 0.08), value: hoveredIndex)
                        .zIndex(hoveredIndex == i ? 100 : 0)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .local)
                    .onChanged { v in
                        let buttonWidth = geo.size.width / CGFloat(digits.count)
                        let idx = min(max(Int(v.location.x / buttonWidth), 0), digits.count - 1)
                        if hoveredIndex != idx {
                            hoveredIndex = idx
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                    }
                    .onEnded { _ in
                        if let idx = hoveredIndex {
                            inputText += digits[idx]
                            UIImpactFeedbackGenerator(style: .light).impactOccurred()
                        }
                        hoveredIndex = nil
                    }
            )
        }
        .frame(height: 32)
    }
}

// MARK: - KeyButtonStyle（補助キー押下時に拡大）

struct KeyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 1.2 : 1.0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

// MARK: - イベント編集シート

struct EventEditSheet: View {
    @EnvironmentObject var manager: CalendarManager
    @Environment(\.dismiss) private var dismiss
    let event: CalendarEvent

    @State private var title: String
    @State private var startDate: Date
    @State private var endDate: Date
    @State private var location: String
    @State private var url: String
    @State private var notes: String
    @State private var isAllDay: Bool
    @State private var calendarId: String
    @State private var showDeleteConfirm = false // ★ 削除アラート用
    @State private var showCancelAlert = false // キャンセル確認

    init(event: CalendarEvent) {
        self.event = event
        _title = State(initialValue: event.title)
        _startDate = State(initialValue: event.startDate)
        _endDate = State(initialValue: event.endDate)
        _location = State(initialValue: event.location ?? "")
        
        let initialURL = event.isReminder ? event.ekReminder?.url : event.ekEvent?.url
        let initialNotes = event.isReminder ? event.ekReminder?.notes : event.ekEvent?.notes
        _url = State(initialValue: initialURL?.absoluteString ?? "")
        _notes = State(initialValue: initialNotes ?? "")
        
        _isAllDay = State(initialValue: event.isAllDay)
        _calendarId = State(initialValue: event.calendar.calendarIdentifier)
    }

    var isNew: Bool {
        event.ekEvent == nil && event.ekReminder == nil
    }

    var navTitle: String {
        isNew ? "新規作成" : "イベントを編集"
    }

    var body: some View {
        NavigationStack {
            List {
                Section("タイトル") {
                    TextField("イベント名", text: $title)
                }
                Section("日時") {
                    Toggle("終日", isOn: $isAllDay)
                    DatePicker("開始", selection: $startDate,
                               displayedComponents: isAllDay ? [.date] : [.date, .hourAndMinute])
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                    if !isAllDay {
                        DatePicker("終了", selection: $endDate,
                                   displayedComponents: [.date, .hourAndMinute])
                            .environment(\.locale, Locale(identifier: "ja_JP"))
                    }
                }
                Section("場所") {
                    HStack {
                        TextField("場所（任意）", text: $location)
                        if !location.isEmpty {
                            Button {
                                guard let enc = location.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) else { return }
                                // Google Maps アプリ → Google Maps Web の順で開く
                                if let nativeURL = URL(string: "comgooglemaps://?q=\(enc)"),
                                   UIApplication.shared.canOpenURL(nativeURL) {
                                    UIApplication.shared.open(nativeURL)
                                } else if let webURL = URL(string: "https://maps.google.com/?q=\(enc)") {
                                    UIApplication.shared.open(webURL)
                                }
                            } label: { Image(systemName: "map").foregroundColor(.blue) }
                        }
                    }
                }
                Section("URL") {
                    HStack {
                        TextField("https://...", text: $url)
                            .keyboardType(.URL)
                            .autocapitalization(.none)
                            .disableAutocorrection(true)
                        if let validURL = URL(string: url), validURL.scheme != nil {
                            Button {
                                UIApplication.shared.open(validURL)
                            } label: {
                                Image(systemName: "link")
                                    .foregroundColor(.blue)
                            }
                        }
                    }
                }
                Section("メモ") {
                    TextEditor(text: $notes)
                        .frame(minHeight: 100)
                }
                // イベントはイベント用、リマインダーはリマインダー用カレンダーを表示
                let availableCalendars = event.isReminder ? manager.reminderCalendars : manager.calendars
                if !availableCalendars.isEmpty {
                    Section(event.isReminder ? "リマインダーリスト" : "カレンダー") {
                        Picker(event.isReminder ? "リスト" : "カレンダー", selection: $calendarId) {
                            ForEach(availableCalendars, id: \.calendarIdentifier) { cal in
                                Text(cal.title).tag(cal.calendarIdentifier)
                            }
                        }
                    }
                }
                if !isNew {
                    Section {
                        Button {
                            let dup = manager.duplicateEvent(event)
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                                // onDismissでfetchEventsが走った後に編集シートを開く
                                NotificationCenter.default.post(name: .init("OpenDuplicateEvent"), object: dup)
                            }
                        } label: {
                            Text("このイベントを複製")
                                .frame(maxWidth: .infinity, alignment: .center)
                        }
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            Text("このイベントを削除").frame(maxWidth: .infinity, alignment: .center)
                        }
                        .alert("本当に削除しますか？", isPresented: $showDeleteConfirm) {
                            Button("キャンセル", role: .cancel) {}
                            Button("削除", role: .destructive) {
                                try? manager.deleteEvent(event)
                                manager.resetToToday()
                                dismiss()
                            }
                        } message: {
                            Text("この操作は取り消せません。")
                        }
                    }
                }

                // ── 最下部にも保存ボタン ──
                Section {
                    Button {
                        save()
                    } label: {
                        Text("保存")
                            .font(.system(size: 16, weight: .semibold))
                            .frame(maxWidth: .infinity, alignment: .center)
                            .foregroundColor(Color(red: 0.2, green: 0.6, blue: 1.0))
                    }
                }
            }
            .id(event.id)
            .navigationTitle(navTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") {
                        // 予定を捨てるか確認
                        showCancelAlert = true
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }.fontWeight(.semibold)
                }
            }
            .alert("編集中の予定を破棄しますか？", isPresented: $showCancelAlert) {
                Button("残す", role: .cancel) {}
                Button("破棄", role: .destructive) { dismiss() }
            } message: {
                Text("この操作は元に戻せません。")
            }
        }
    }

    func save() {
        if let ek = event.ekEvent {
            ek.title = title.isEmpty ? "(無題)" : title
            ek.startDate = startDate
            ek.endDate = isAllDay ? startDate : max(endDate, startDate.addingTimeInterval(60))
            ek.location = location.isEmpty ? nil : location
            ek.url = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))
            ek.notes = notes.isEmpty ? nil : notes
            ek.isAllDay = isAllDay
            if let cal = manager.calendars.first(where: { $0.calendarIdentifier == calendarId }) {
                ek.calendar = cal
            }
            try? manager.store.save(ek, span: .thisEvent, commit: true)
        } else if let rem = event.ekReminder {
            rem.title = title.isEmpty ? "(無題)" : title
            var comp = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: startDate)
            comp.timeZone = .current
            rem.dueDateComponents = comp
            rem.location = location.isEmpty ? nil : location
            rem.url = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines))
            rem.notes = notes.isEmpty ? nil : notes
            if let cal = manager.reminderCalendars.first(where: { $0.calendarIdentifier == calendarId }) {
                rem.calendar = cal
            }
            try? manager.store.save(rem, commit: true)
        } else {
            // 新規イベント（"詳細"ボタン経由）
            let cal = manager.calendars.first(where: { $0.calendarIdentifier == calendarId })
                ?? manager.selectedCalendar
            try? manager.addEvent(
                title: title.isEmpty ? "(無題)" : title,
                startDate: startDate,
                endDate: isAllDay ? startDate : max(endDate, startDate.addingTimeInterval(60)),
                location: location.isEmpty ? nil : location,
                calendar: cal,
                notes: notes.isEmpty ? nil : notes,
                isAllDay: isAllDay
            )
            // 保存したことをメイン画面に通知（入力画面のリセット）
            NotificationCenter.default.post(name: .init("EventSheetDidSaveNew"), object: nil)
        }
        Task { await manager.forceRefresh(for: manager.displayedMonth) }
        dismiss()
    }
}

// MARK: - 設定画面

struct SettingsView: View {
    @AppStorage("showHeaderYearMonth") private var showHeaderYearMonth = true
    @AppStorage("searchRangeYears") private var searchRangeYears = 3
    @AppStorage("inputShowDigits") private var inputShowDigits = true
    @AppStorage("inputShowTilde") private var inputShowTilde = true
    @AppStorage("inputShowHours") private var inputShowHours = true
    @AppStorage("inputShowMinutes") private var inputShowMinutes = true
    @AppStorage("inputShowTemp") private var inputShowTemp = true
    @AppStorage("inputShowTask") private var inputShowTask = true
    @EnvironmentObject var manager: CalendarManager
    @Environment(\.dismiss) private var dismiss

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        NavigationStack {
            List {
                // ── 表示設定 ──
                Section {
                    Toggle("ヘッダーに年月を表示", isOn: $showHeaderYearMonth)
                    Toggle("コンパクトなリスト表示", isOn: .init(
                        get: { UserDefaults.standard.bool(forKey: "listCompactMode") },
                        set: { UserDefaults.standard.set($0, forKey: "listCompactMode") }
                    ))
                    if !showHeaderYearMonth {
                        Label("非表示時はカレンダーに薄く透かし表示されます", systemImage: "info.circle")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("表示")
                }

                // ── 入力設定 ──
                Section {
                    if !manager.calendars.isEmpty {
                        Picker("デフォルト登録先", selection: Binding(
                            get: { manager.selectedCalendar?.calendarIdentifier ?? "" },
                            set: { id in
                                manager.selectedCalendar = manager.calendars.first { $0.calendarIdentifier == id }
                            }
                        )) {
                            ForEach(manager.calendars, id: \.calendarIdentifier) { cal in
                                HStack(spacing: 6) {
                                    Circle()
                                        .fill(Color(cgColor: cal.cgColor))
                                        .frame(width: 10, height: 10)
                                    Text(cal.title)
                                }
                                .tag(cal.calendarIdentifier)
                            }
                        }
                    }
                } header: {
                    Text("入力")
                }

                // ── 補助キー設定 ──
                Section {
                    Toggle("数字キー（0〜9）", isOn: $inputShowDigits)
                    Toggle("チルダ（〜）", isOn: $inputShowTilde)
                    Toggle("時", isOn: $inputShowHours)
                    Toggle("分", isOn: $inputShowMinutes)
                    Toggle("task（リマインド）", isOn: $inputShowTask)
                    Toggle("仮", isOn: $inputShowTemp)
                } header: {
                    Text("補助キー（入力画面）")
                } footer: {
                    Text("非表示にした補助キーは入力画面に表示されません")
                        .font(.caption)
                }

                // ── 検索設定 ──
                Section {
                    Picker("検索範囲（過去）", selection: $searchRangeYears) {
                        Text("1年").tag(1)
                        Text("3年").tag(3)
                        Text("5年").tag(5)
                        Text("10年").tag(10)
                        Text("永久").tag(99)
                    }
                    Label("範囲を広げると検索に時間がかかる場合があります", systemImage: "clock")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } header: {
                    Text("検索")
                }

                // ── カレンダー連携 ──
                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        HStack {
                            Label("iOSのカレンダー設定を開く", systemImage: "calendar.badge.plus")
                            Spacer()
                            Image(systemName: "arrow.up.right.square").foregroundColor(.secondary)
                        }
                    }
                    .foregroundColor(.primary)
                } header: {
                    Text("カレンダー連携")
                }

                // ── アプリ情報 ──
                Section {
                    HStack {
                        Text("バージョン")
                        Spacer()
                        Text(appVersion).foregroundColor(.secondary)
                    }
                    HStack {
                        Label("SmartCalendar", systemImage: "calendar")
                        Spacer()
                        Text("自然言語でサクッと登録").foregroundColor(.secondary).font(.caption)
                    }
                } header: {
                    Text("このアプリについて")
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("閉じる") { dismiss() }
                }
            }
        }
    }
}

// MARK: - 権限エラー

struct PermissionErrorView: View {
    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "calendar.badge.exclamationmark")
                .font(.system(size: 64))
                .foregroundColor(Color(red: 1.0, green: 0.27, blue: 0.23).opacity(0.8))
            Text("カレンダーへのアクセスが\n許可されていません")
                .font(.system(size: 18, weight: .medium)).multilineTextAlignment(.center).foregroundColor(.white)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("設定を開く").font(.system(size: 16, weight: .semibold)).foregroundColor(.white)
                    .padding(.horizontal, 32).padding(.vertical, 14)
                    .background(Color(red: 0.2, green: 0.6, blue: 1.0)).cornerRadius(20)
            }
        }.padding()
    }
}
