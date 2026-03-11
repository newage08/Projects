import EventKit
import SwiftUI

// MARK: - Models

struct CalendarEvent: Identifiable {
    let id: String
    let title: String
    let startDate: Date
    let endDate: Date
    let calendar: EKCalendar
    let location: String?
    let isAllDay: Bool
    let ekEvent: EKEvent?
    let ekReminder: EKReminder?
    var isCompleted: Bool

    var isReminder: Bool { ekReminder != nil }

    var calendarColor: Color {
        Color(cgColor: calendar.cgColor)
    }
}

// MARK: - CalendarManager

@MainActor
class CalendarManager: ObservableObject {
    let store = EKEventStore()

    @Published var events: [CalendarEvent] = [] {
        didSet {
            // eventsByDay はfetchEvents等で個別に最適化して更新されるため、ここでの全体再構築は重くなるため省く
            updateUpcomingGrouped()
        }
    }
    /// 選択/表示中の月（カレンダー上部の月表示と連動）
    @Published private(set) var displayedMonth: Date = Calendar.current.startOfDay(for: Date()) {
        didSet {
            // 月が切り替わったら、その月の「月初め」をアンカーとしてリストに追加するためグループを再構築
            updateUpcomingGrouped()
        }
    }

    // 表示月を変更する際はこのメソッドを経由し、不得意範囲にならないよう制限する
    func setDisplayedMonth(_ month: Date) {
        // ユーザーが自由に過去未来を見られるよう、制限を10年 (120ヶ月) に拡大。
        // それ以上移動しても表示自体は動くが、イベントフェッチは範囲外になるだけで
        // 空白になるので実用上は十分。
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let diff = cal.dateComponents([.month], from: today, to: month).month ?? 0
        let limit = 120 // +-10年まで
        var clamped = month
        if diff < -limit {
            clamped = cal.date(byAdding: .month, value: -limit, to: today)!
        } else if diff > limit {
            clamped = cal.date(byAdding: .month, value: limit, to: today)!
        }
        if clamped != displayedMonth {
            displayedMonth = clamped
        }
    }
    @Published var eventsByDay: [Date: [CalendarEvent]] = [:]
    /// リスト表示用：日ごとの予定グループ（今日と表示月月初めを必ず含む）
    @Published var upcomingGrouped: [(date: Date, events: [CalendarEvent])] = []
    
    @Published var calendars: [EKCalendar] = []          // イベント用カレンダー
    @Published var reminderCalendars: [EKCalendar] = []  // リマインダー用カレンダー
    @Published var hasAccess = false
    @Published var hasError = false
    
    @Published var resetTrigger: UUID = UUID()
    @Published var syncListToMonth: Date? = nil // ★ カレンダーからリストへの同期トリガー
    @Published var selectedCalendar: EKCalendar? = nil
    
    // イベントロード範囲のキャッシュ
    @Published var loadedStart: Date? = nil
    @Published var loadedEnd: Date? = nil
    
    // 多重フェッチを防止するフラグ
    private(set) var isFetching = false
    private(set) var isSearchFetching = false

    // MARK: - アクセス要求

    func requestAccess() async {
        do {
            let eventGranted: Bool
            let remGranted: Bool
            if #available(iOS 17.0, *) {
                eventGranted = try await store.requestFullAccessToEvents()
                remGranted = try await store.requestFullAccessToReminders()
            } else {
                eventGranted = try await store.requestAccess(to: .event)
                remGranted = try await store.requestAccess(to: .reminder)
            }
            hasAccess = eventGranted || remGranted
            hasError = !hasAccess
            if hasAccess {
                loadCalendars()
                // iOSの制限により、最大4年以内の指定でもエラーになる場合があるため
                // 古いイベントが消える問題を修正し、リマインダーも取得する
                Task { await fetchEvents(for: displayedMonth) }
            }
        } catch {
            hasError = true
        }
    }

    // MARK: - カレンダー一覧

    func loadCalendars() {
        calendars = store.calendars(for: .event)
        reminderCalendars = store.calendars(for: .reminder)
        if selectedCalendar == nil {
            selectedCalendar = store.defaultCalendarForNewEvents
        }
    }

    // MARK: - イベント取得

    func fetchEvents(for month: Date) async {
        guard !isFetching else { return }
        // 以前は24ヶ月以上を無視していたが、この制限は撤廃。
        // カレンダー表示は自由に動かせるが、フェッチでは半年前前後の範囲のみを読み込む
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        isFetching = true
        defer { isFetching = false }
        
        guard let start = cal.date(from: cal.dateComponents([.year, .month], from: month)),
              let end = cal.date(byAdding: DateComponents(month: 1, day: 1), to: start)
        else { return }

        // 初期フェッチやスクロールごとに、表示月の「前後6ヶ月（計1年分）」のデータを超高速にロードします。
        // これによりスクロールの途切れを防ぎつつ、メインスレッドのUIフリーズを回避します。
        let reqStart = cal.date(byAdding: .month, value: -6, to: start) ?? start
        let reqEnd = cal.date(byAdding: .month, value: 6, to: start) ?? end

        // 今回要求されている範囲がすでに取り込み済み（包含）ならスキップ
        if let ls = loadedStart, let le = loadedEnd, reqStart >= ls && reqEnd <= le {
            return
        }

        let fetchStart: Date
        let fetchEnd: Date
        if let ls = loadedStart, let le = loadedEnd {
            fetchStart = min(ls, reqStart)
            fetchEnd = max(le, reqEnd)
        } else {
            fetchStart = reqStart
            fetchEnd = reqEnd
        }

        // --- EventKitからデータ取得 ---
        let pred = store.predicateForEvents(withStart: fetchStart, end: fetchEnd, calendars: nil)
        let ekEvents = store.events(matching: pred)

        let remPred = store.predicateForReminders(in: nil)
        let ekReminders: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: remPred) { reminders in
                continuation.resume(returning: reminders ?? [])
            }
        }

        // 取得件数ゼロはEventKitの制限による可能性があるので既存データを保持して終了
        if ekEvents.isEmpty && ekReminders.isEmpty {
            return
        }

        // --- マッピング ---
        var newMapped = ekEvents.map { ek in
            CalendarEvent(
                id: "\(ek.eventIdentifier ?? UUID().uuidString)_\(ek.startDate.timeIntervalSince1970)", // 決定論的で一意なID（再取得時のスクロール飛び防止）
                title: ek.title ?? "（タイトルなし）",
                startDate: ek.startDate,
                endDate: ek.endDate,
                calendar: ek.calendar,
                location: ek.location,
                isAllDay: ek.isAllDay,
                ekEvent: ek,
                ekReminder: nil,
                isCompleted: false
            )
        }
        
        let remMapped = ekReminders.compactMap { rem -> CalendarEvent? in
            guard let comps = rem.dueDateComponents,
                  let due = cal.date(from: comps),
                  due >= fetchStart, due < fetchEnd else { return nil }
            return CalendarEvent(
                id: "\(rem.calendarItemIdentifier)_\(due.timeIntervalSince1970)", // 決定論的で一意なID
                title: rem.title ?? "（タイトルなし）",
                startDate: due,
                endDate: due,
                calendar: rem.calendar,
                location: rem.location,
                isAllDay: comps.hour == nil,
                ekEvent: nil,
                ekReminder: rem,
                isCompleted: rem.isCompleted
            )
        }
        newMapped.append(contentsOf: remMapped)

        // --- マージ処理の簡略化とバグ防止 ---
        // 複雑な差分アップデートはEventKitの更新タイミングと合わずにイベントが欠損する原因となるため、
        // 常に「現在から前後数ヶ月」のウィンドウを取り直してローカルをクリーンな状態に保ちます。
        events = newMapped
        loadedStart = fetchStart
        loadedEnd = fetchEnd
        
        // ソートとグループ化
        events.sort { $0.startDate < $1.startDate }

        // ローカルの完了状態を復元
        var localCompletions: [String: Bool] = [:]
        for ev in events where ev.isReminder { localCompletions[ev.id] = ev.isCompleted }
        for i in Array(events.indices) where events[i].isReminder {
            if localCompletions[events[i].id] == true {
                events[i].isCompleted = true
            }
        }

        // eventsByDay を再構築
        var dict: [Date: [CalendarEvent]] = [:]
        for ev in events {
            let d = cal.startOfDay(for: ev.startDate)
            dict[d, default: []].append(ev)
        }
        eventsByDay = dict
        
        updateUpcomingGrouped()
    }

    // MARK: - イベント追加

    func addEvent(
        title: String,
        startDate: Date,
        endDate: Date,
        location: String?,
        calendar: EKCalendar?,
        notes: String? = nil,
        isAllDay: Bool = false
    ) throws {
        let ek = EKEvent(eventStore: store)
        ek.title = title
        ek.startDate = startDate
        ek.endDate = isAllDay ? startDate : endDate
        ek.location = location
        ek.notes = notes
        ek.isAllDay = isAllDay
        ek.calendar = calendar ?? store.defaultCalendarForNewEvents
        try store.save(ek, span: .thisEvent, commit: true)

        // ローカルに即座に反映
        let newEvent = CalendarEvent(
            id: UUID().uuidString, // 追加時も同様に一意のID
            title: title,
            startDate: startDate,
            endDate: isAllDay ? startDate : endDate,
            calendar: ek.calendar,
            location: location,
            isAllDay: isAllDay,
            ekEvent: ek,
            ekReminder: nil,
            isCompleted: false
        )
        withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
            events.append(newEvent)
            events.sort { $0.startDate < $1.startDate }
            // eventsByDayも即時更新（カレンダーのドットに反映）
            let d = Calendar.current.startOfDay(for: startDate)
            eventsByDay[d, default: []].append(newEvent)
            eventsByDay[d]?.sort { $0.startDate < $1.startDate }
            updateUpcomingGrouped()
        }
    }

    // MARK: - イベント削除

    func deleteEvent(_ event: CalendarEvent) throws {
        if let ek = event.ekEvent {
            try store.remove(ek, span: .thisEvent, commit: true)
        } else if let rem = event.ekReminder {
            try store.remove(rem, commit: true)
        }
        withAnimation {
            events.removeAll { $0.id == event.id }
            // eventsByDayも即時更新
            let d = Calendar.current.startOfDay(for: event.startDate)
            eventsByDay[d]?.removeAll { $0.id == event.id }
            updateUpcomingGrouped()
        }
    }
    
    /// イベントキャッシュを完全クリア（検索終了後のリセット用）
    func resetEventCache() {
        events = []
        eventsByDay = [:]
        loadedStart = nil
        loadedEnd = nil
        upcomingGrouped = []
    }

    /// 検索用に広い範囲のイベントを取得する（yearsBack=99で最大30年）
    /// EventKitのpredicateForEventsは4年超の範囲をfetchStartから4年に自動truncateするため、
    /// 4年チャンクに分割して最新から過去に向かって取得する
    func fetchAllEventsForSearch(yearsBack: Int = 3) async {
        guard !isSearchFetching else { return }
        isSearchFetching = true
        defer { isSearchFetching = false }

        let cal = Calendar.current
        let today = Date()
        let totalYears = yearsBack == 99 ? 30 : yearsBack
        guard let overallStart = cal.date(byAdding: .year, value: -totalYears, to: today),
              let overallEnd = cal.date(byAdding: .year, value: 1, to: today) else { return }

        let chunkYears = 4  // EventKit の上限に合わせた分割サイズ
        var allDict = [String: CalendarEvent]()
        for ev in self.events { allDict[ev.id] = ev }

        // 最新から過去へ向かってチャンク取得（最新イベントを最初に確実に取得するため）
        var chunkEnd = overallEnd
        while chunkEnd > overallStart {
            let chunkStartRaw = cal.date(byAdding: .year, value: -chunkYears, to: chunkEnd) ?? overallStart
            let chunkStart = chunkStartRaw < overallStart ? overallStart : chunkStartRaw

            let pred = store.predicateForEvents(withStart: chunkStart, end: chunkEnd, calendars: nil)
            let ekEvents = store.events(matching: pred)
            for ek in ekEvents {
                let id = "\(ek.eventIdentifier ?? UUID().uuidString)_\(ek.startDate.timeIntervalSince1970)"
                allDict[id] = CalendarEvent(
                    id: id,
                    title: ek.title ?? "（タイトルなし）",
                    startDate: ek.startDate,
                    endDate: ek.endDate,
                    calendar: ek.calendar,
                    location: ek.location,
                    isAllDay: ek.isAllDay,
                    ekEvent: ek,
                    ekReminder: nil,
                    isCompleted: false
                )
            }

            // チャンクごとに中間結果を公開してUIが随時更新できるようにする
            let snapshot = allDict
            let snapStart = chunkStart
            let snapEnd = overallEnd
            self.events = snapshot.values.sorted { $0.startDate < $1.startDate }
            self.loadedStart = min(self.loadedStart ?? snapStart, snapStart)
            self.loadedEnd = max(self.loadedEnd ?? snapEnd, snapEnd)
            self.updateUpcomingGrouped()

            // 次のチャンクへ進む前にUIに処理を渡す
            await Task.yield()

            if chunkStartRaw <= overallStart { break }
            chunkEnd = chunkStart
        }
    }

    // MARK: - 新規空イベント作成
    
    func newEmptyEvent() -> CalendarEvent {
        let ek = EKEvent(eventStore: store)
        ek.title = ""
        // 長押しで開くので終日イベントとして今日を設定
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        ek.startDate = today
        ek.endDate = today
        ek.isAllDay = true
        if let defaultCal = store.defaultCalendarForNewEvents {
            ek.calendar = defaultCal
        } else if let firstCal = calendars.first {
            ek.calendar = firstCal
        }
        return CalendarEvent(
            id: UUID().uuidString,
            title: "",
            startDate: ek.startDate,
            endDate: ek.endDate,
            calendar: ek.calendar,
            location: nil,
            isAllDay: true,
            ekEvent: ek,
            ekReminder: nil,
            isCompleted: false
        )
    }

    // MARK: - イベント複製

    func duplicateEvent(_ event: CalendarEvent) -> CalendarEvent {
        let ek = EKEvent(eventStore: store)
        if let src = event.ekEvent {
            ek.title = src.title
            ek.startDate = src.startDate
            ek.endDate = src.endDate
            ek.location = src.location
            ek.notes = src.notes
            ek.url = src.url
            ek.isAllDay = src.isAllDay
            ek.calendar = src.calendar ?? store.defaultCalendarForNewEvents ?? calendars.first
        } else {
            ek.title = event.title
            ek.startDate = event.startDate
            ek.endDate = event.endDate
            ek.location = event.location
            ek.isAllDay = event.isAllDay
            ek.calendar = event.calendar
        }
        return CalendarEvent(
            id: UUID().uuidString,
            title: ek.title ?? event.title,
            startDate: ek.startDate,
            endDate: ek.endDate,
            calendar: ek.calendar ?? event.calendar,
            location: ek.location,
            isAllDay: ek.isAllDay,
            ekEvent: ek,
            ekReminder: nil,
            isCompleted: false
        )
    }

    // MARK: - リマインダー完了トグル

    func toggleReminderCompletion(_ event: CalendarEvent) {
        guard let rem = event.ekReminder else { return }
        rem.isCompleted = !rem.isCompleted
        rem.completionDate = rem.isCompleted ? Date() : nil
        try? store.save(rem, commit: true)
        // ローカル更新
        if let idx = events.firstIndex(where: { $0.id == event.id }) {
            events[idx].isCompleted = rem.isCompleted
            let d = Calendar.current.startOfDay(for: event.startDate)
            if let di = eventsByDay[d]?.firstIndex(where: { $0.id == event.id }) {
                eventsByDay[d]?[di].isCompleted = rem.isCompleted
            }
            updateUpcomingGrouped()
        }
    }

    // MARK: - 便利メソッド

    func resetToToday() {
        resetTrigger = UUID()
    }

    /// 指定日のイベント一覧（O(1)アクセス）
    func events(on date: Date) -> [CalendarEvent] {
        return eventsByDay[Calendar.current.startOfDay(for: date)] ?? []
    }

    /// 月グリッド用：指定月のカレンダー表示用42日分（6週）を返す
    /// 前後の月の日付も埋めて返すことで常に高さを一定に保つ
    func daysInMonth(_ month: Date) -> [Date?] {
        let cal = Calendar.current
        guard let range = cal.range(of: .day, in: .month, for: month),
              let firstDay = cal.date(from: cal.dateComponents([.year, .month], from: month))
        else { return [] }

        let weekday = cal.component(.weekday, from: firstDay)
        let leadingBlanks = (weekday - cal.firstWeekday + 7) % 7

        var days: [Date?] = []
        
        // 前の月の日付で埋める
        if leadingBlanks > 0 {
            for i in (1...leadingBlanks).reversed() {
                days.append(cal.date(byAdding: .day, value: -i, to: firstDay))
            }
        }
        
        // 当月の日付
        for day in range {
            days.append(cal.date(byAdding: .day, value: day - 1, to: firstDay))
        }
        
        // 常に6週（42日）になるよう次の月の日付で埋める
        let currentCount = days.count
        if currentCount < 42 {
            let trailingBlanks = 42 - currentCount
            for i in 1...trailingBlanks {
                // 当月の最後の日からのオフセット
                if let lastDayOfThisMonth = cal.date(byAdding: .day, value: range.count - 1, to: firstDay) {
                    days.append(cal.date(byAdding: .day, value: i, to: lastDayOfThisMonth))
                }
            }
        }
        
        return days
    }

    /// 全イベントリスト（日付グループ）
    /// ※ 「予定がない日も表示する」元の仕様に戻しつつ、表示期間を表示月（displayedMonth）の前後3ヶ月に絞ることでラグと無限ループを防止
    private func updateUpcomingGrouped() {
        let cal = Calendar.current
        var dict: [Date: [CalendarEvent]] = [:]
        
        let today = cal.startOfDay(for: Date())
        
        // 🚨 表示月を中心に前後3ヶ月分のみをリストに表示するように制限する（起動・スクロールの高速化とバグ防止）
        guard let start = cal.date(byAdding: .month, value: -3, to: displayedMonth),
              let end = cal.date(byAdding: .month, value: 3, to: displayedMonth) else { return }
        
        let startOfDay = cal.startOfDay(for: start)
        let endOfDay = cal.startOfDay(for: end)
        
        // 1. 指定範囲内のすべての日付を空の配列で初期化（予定のない日も確保）
        var current = startOfDay
        while current <= endOfDay {
            dict[current] = []
            guard let next = cal.date(byAdding: .day, value: 1, to: current) else { break }
            current = next
        }
        
        // 2. 実際のイベントを追加（範囲外は無視）
        for ev in events {
            let key = cal.startOfDay(for: ev.startDate)
            if dict[key] != nil {
                dict[key]?.append(ev)
            }
        }
        
        upcomingGrouped = dict.keys.sorted().map { (date: $0, events: dict[$0]!) }
    }
}
