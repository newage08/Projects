import SwiftUI
import EventKit

class EventStoreManager: ObservableObject {
    // 起動時のフリーズを防ぐため、初回アクセス時（バックグラウンドスレッド）に初期化する
    lazy var store: EKEventStore = EKEventStore()
}

enum ViewState {
    case input, list, editingMinutes
}

extension Animation {
    static var mightySpring: Animation { .spring(response: 0.45, dampingFraction: 0.95) }
}

struct ContentView: View {
    // MyAppからEnvironmentObjectとして受け取る（早期初期化で黒画面短縮）
    @EnvironmentObject private var eventManager: EventStoreManager
    private var eventStore: EKEventStore { eventManager.store }

    // 起動時のローディング状態管理
    @State private var isReady = false

    @State private var reminderText = ""
    @State private var proposedTime = Date()
    @State private var hasInitializedTime = false

    @FocusState private var isTextFieldFocused: Bool
    @FocusState private var isMinutesFocused: Bool
    @State private var minutesInputString = ""

    @State private var keyboardHeight: CGFloat = 0
    @State private var timeScale: CGFloat = 1.0
    @State private var timeOffset: CGFloat = 0.0

    @State private var viewState: ViewState = .input
    @State private var currentListIndex = 0

    // インタラクティブスワイプ（入力→リスト）
    @State private var dragOffset: CGFloat = 0
    @State private var isDraggingToList = false
    @State private var screenHeight: CGFloat = UIScreen.main.bounds.height

    @State private var calendars: [EKCalendar] = []
    @State private var remindersMap: [String: [EKReminder]] = [:]

    @State private var isShowingSuccessMark = false
    @State private var floatingText = ""
    @State private var floatingOpacity: Double = 0.0
    @State private var floatingOffset: CGFloat = 0.0

    @State private var localCompletedIDs: Set<String> = []
    @State private var localUncompletedIDs: Set<String> = []

    @State private var hasAccessError = false
    @AppStorage("defaultHourOffset") private var defaultHourOffset = 6
    @AppStorage("swipeHourOffset") private var swipeHourOffset = 1
    @AppStorage("selectedFont") private var selectedFont = "Futura-Bold"
    @AppStorage("defaultTimeMode") private var defaultTimeMode = "offset"  // "offset" or "fixed"
    @AppStorage("defaultFixedHour") private var defaultFixedHour = 19      // 0〜23
    @AppStorage("defaultStartView") private var defaultStartView = "input"   // "input" or "list"
    @AppStorage("defaultListIdentifier") private var defaultListIdentifier = ""
    @AppStorage("appColorScheme") private var appColorScheme = "dark"       // "dark", "light", "system"
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true
    @Environment(\.colorScheme) private var systemColorScheme

    @State private var showingSettings = false
    @State private var bounceOffset: CGFloat = 0
    @State private var isGestureBlocked = false   // Enter後の誤認スワイプを防ぐ
    // 日付手動入力
    @State private var showDatePicker = false

    // リスト内インライン追加用
    @State private var inlineNewTitle: String = ""
    @FocusState private var isInlineFocused: Bool

    // 詳細編集シート用
    @State private var editingReminder: EKReminder? = nil
    @State private var editingTitle: String = ""
    @State private var editingDate: Date = Date()
    @State private var isEditingDateEnabled: Bool = false
    @State private var showingEditSheet: Bool = false
    @State private var showingDeleteConfirm = false

    // ドロップターゲット（ホバー）用
    @State private var hoveredTabId: String? = nil

    // リスト縦スワイプ遷移方向（true = 上から来る）
    @State private var navigatingDown = false
    // リストインタラクティブスワイプ量
    @State private var listSwipeDragOffset: CGFloat = 0
    // 縦スワイプ方向に確定済みかどうか（斜めスワイプのジャンプ防止）
    @State private var isListVerticalDrag = false

    // MARK: - テーマ

    private var preferredScheme: ColorScheme? {
        switch appColorScheme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }
    /// ダーク: 元の深黒、ライト: システム背景
    private var bgColor: Color {
        systemColorScheme == .dark ? Color(red: 0.05, green: 0.05, blue: 0.05) : Color(.systemBackground)
    }
    /// カード背景
    private var cardBgColor: Color {
        systemColorScheme == .dark ? Color.white.opacity(0.07) : Color(.secondarySystemBackground)
    }
    /// 入力フィールド背景
    private var inputBgColor: Color {
        systemColorScheme == .dark ? Color.white.opacity(0.1) : Color(.secondarySystemFill)
    }
    /// メインテキスト色
    private var primaryText: Color {
        systemColorScheme == .dark ? .white : .primary
    }
    /// セカンダリテキスト色
    private var secondaryText: Color {
        systemColorScheme == .dark ? .white.opacity(0.5) : .secondary
    }
    /// リスト本文フォント（selectedFontの中間ウェイト版）
    private var bodyFontName: String {
        switch selectedFont {
        case "HiraginoSans-W6":         return "HiraginoSans-W3"
        case "HiraMinProN-W6":          return "HiraMinProN-W3"
        case "HiraMaruProN-W4":         return "HiraMaruProN-W4"
        case "Futura-Bold":             return "Futura-Medium"
        case "Helvetica-Bold":          return "Helvetica"
        case "Georgia-Bold":            return "Georgia"
        case "Didot-Bold":              return "Didot"
        case "AmericanTypewriter-Bold": return "AmericanTypewriter"
        case "Courier-Bold":            return "Courier"
        case "MarkerFelt-Wide":         return "MarkerFelt-Thin"
        default:                        return selectedFont
        }
    }

    var body: some View {
        GeometryReader { geo in
            ZStack {
                bgColor.ignoresSafeArea()

                // 起動ロード中はスプラッシュ的な表示（黒画面防止）
                if !isReady {
                    VStack(spacing: 24) {
                        Image(systemName: "bell.fill")
                            .font(.system(size: 60, weight: .light))
                            .foregroundColor(primaryText.opacity(0.35))
                        ProgressView()
                            .tint(primaryText.opacity(0.5))
                    }
                } else if hasAccessError {
                    errorView
                } else {
                    ZStack {
                        // ─── Input View ───────────────────────────────────────
                        inputView
                            .frame(width: geo.size.width, height: geo.size.height)
                            .offset(y: inputOffset(h: geo.size.height))
                            .clipped()

                        // ─── List Views (縦スワイプで切り替え) ────────────────
                        if viewState == .list {
                            ZStack {
                                let indicesToRender = [currentListIndex - 1, currentListIndex, currentListIndex + 1]
                                ForEach(indicesToRender, id: \.self) { idx in
                                    if idx == -1 {
                                        // 完了リストはタブ選択時のみ描画（フラッシュ完全防止）
                                        // transitionでアニメーションを管理する
                                        if currentListIndex == -1 {
                                            completedListView
                                                .transition(.asymmetric(
                                                    insertion: .move(edge: .top).combined(with: .opacity),
                                                    removal: .move(edge: .top).combined(with: .opacity)
                                                ))
                                        }
                                    } else if idx >= 0 && idx < calendars.count {
                                        let viewOffset = CGFloat(currentListIndex - idx) * screenHeight + listSwipeDragOffset
                                        singleListView(for: calendars[idx], index: idx)
                                            .offset(y: viewOffset)
                                    }
                                }
                            }
                            // ignoresSafeAreaを外すことでVStackがSafeArea内に収まりリストタイトルが正常に見えるようになる
                            .transition(.move(edge: .top).combined(with: .opacity))
                            .zIndex(30)
                        }

                        // ─── Right Side Tab Menu ───────────────────────────────
                        if viewState == .list && !calendars.isEmpty {
                            rightSideTabMenu
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                                .zIndex(60)
                        }
                    }
                    .clipped()
                    // ───── 全面スワイプジェスチャー ─────────────────────────
                    .simultaneousGesture(
                        DragGesture(minimumDistance: 5)
                            .onChanged { v in
                                guard viewState != .editingMinutes, !isGestureBlocked else { return }
                                let dy = v.translation.height, dx = v.translation.width
                                if viewState == .input {
                                    if dy > 0 && abs(dy) > abs(dx) {
                                        isTextFieldFocused = false
                                        isMinutesFocused = false
                                        isDraggingToList = true
                                        dragOffset = dy
                                    } else if dy < 0 && abs(dy) > abs(dx) && !isDraggingToList {
                                        // 上スワイプ：ぷるんっとした抵抗感
                                        bounceOffset = dy * 0.15
                                    } else if abs(dx) > abs(dy) && !isDraggingToList {
                                        timeOffset = dx * 0.15; timeScale = 1.05
                                    }
                                } else if viewState == .list {
                                    // インタラクティブスワイプ（リスト切り替え）
                                    // 一度縦方向に確定したら方向チェックなしで追従（斜めスワイプ時のジャンプ防止）
                                    if isListVerticalDrag {
                                        // デッドゾーン(15pt)＋フリクション(0.5x)で自然な抵抗感
                                        let deadZone: CGFloat = 15
                                        let sign: CGFloat = dy >= 0 ? 1 : -1
                                        let effective = max(abs(dy) - deadZone, 0) * 0.5 * sign
                                        listSwipeDragOffset = effective
                                    } else if abs(dy) > abs(dx) * 1.2 {
                                        isListVerticalDrag = true
                                    }
                                }
                            }
                            .onEnded { v in
                                guard viewState != .editingMinutes, !isGestureBlocked else { return }
                                let dy = v.translation.height, dx = v.translation.width
                                if viewState == .input {
                                    if isDraggingToList {
                                        if dy > 30 {
                                            isTextFieldFocused = false
                                            isMinutesFocused = false
                                            // しきい値超え → まず視覚的に完走、その後データフェッチ
                                            withAnimation(.mightySpring) { dragOffset = geo.size.height }
                                            fetchAndShowList(screenH: geo.size.height)
                                        } else {
                                            isDraggingToList = false
                                            withAnimation(.mightySpring) { dragOffset = 0 }
                                        }
                                    } else if abs(dx) > abs(dy) {
                                        handleHorizontalSwipe(dx)
                                    } else if dy < -20 && abs(dy) > abs(dx) {
                                        // 上スワイプ → ぷるんっと戻す
                                        withAnimation(.spring(response: 0.35, dampingFraction: 0.4)) { bounceOffset = 0 }
                                    }
                                } else if viewState == .list {
                                    isListVerticalDrag = false
                                    let predY = v.predictedEndTranslation.height
                                    if abs(dy) > abs(dx) * 1.2 && (abs(predY) > 150 || abs(dy) > 80) {
                                        // 下スワイプ (dy > 0): 上から次のリストを引き下ろす
                                        if dy > 0 {
                                            if currentListIndex + 1 < calendars.count {
                                                let nextIdx = currentListIndex + 1
                                                provideHapticFeedback(.light)
                                                withAnimation(.mightySpring) {
                                                    currentListIndex = nextIdx
                                                    listSwipeDragOffset = 0
                                                }
                                            } else {
                                                withAnimation(.mightySpring) { listSwipeDragOffset = 0 }
                                                provideErrorFeedback()
                                            }
                                        } else {
                                            // 上スワイプ (dy < 0): 下から前のリスト（または入力画面）を引き上げる
                                            if currentListIndex > 0 {
                                                let prevIdx = currentListIndex - 1
                                                provideHapticFeedback(.light)
                                                withAnimation(.mightySpring) {
                                                    currentListIndex = prevIdx
                                                    listSwipeDragOffset = 0
                                                }
                                            } else if currentListIndex == 0 {
                                                // 入力画面に戻る
                                                provideHapticFeedback(.light)
                                                withAnimation(.mightySpring) {
                                                    viewState = .input
                                                    dragOffset = 0
                                                    listSwipeDragOffset = 0
                                                }
                                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                                    if !showingSettings { isTextFieldFocused = true }
                                                }
                                            } else {
                                                withAnimation(.mightySpring) { listSwipeDragOffset = 0 }
                                                provideErrorFeedback()
                                            }
                                        }
                                    } else {
                                        withAnimation(.mightySpring) { listSwipeDragOffset = 0 }
                                    }
                                }
                            }
                    )
                }

                // ─── Settings Button ──────────────────────────────────────
                if !hasAccessError {
                    VStack {
                        HStack {
                            Spacer()
                            Button { isTextFieldFocused = false; showingSettings = true } label: {
                                Image(systemName: "gearshape.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.secondary)
                                    .padding(24)
                            }
                        }
                        Spacer()
                    }.zIndex(100)
                }
            }
            .onAppear { screenHeight = geo.size.height }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillShowNotification)) {
            if let r = $0.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect { keyboardHeight = r.height }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in keyboardHeight = 0 }
        .onAppear {
            if !hasInitializedTime {
                proposedTime = defaultProposedTime()
                hasInitializedTime = true
            }
            // バックグラウンドでアクセス権確認 → 完了後isReadyをtrueに
            DispatchQueue.global(qos: .userInitiated).async {
                requestReminderAccess()
            }
        }
        .sheet(isPresented: $showingSettings, onDismiss: {
            proposedTime = defaultProposedTime()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                if !hasAccessError && viewState == .input { isTextFieldFocused = true }
            }
        }) { SettingsView(eventStore: eventStore) }
        .sheet(isPresented: $showDatePicker) {
            NavigationView {
                VStack(spacing: 30) {
                    DatePicker("日時を選択", selection: $proposedTime, displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.graphical)
                        .environment(\.locale, Locale(identifier: "ja_JP"))
                        .padding()
                }
                .navigationTitle("日時の手動設定")
                .navigationBarItems(trailing: Button("完了") { showDatePicker = false })
            }
            .preferredColorScheme(preferredScheme)
        }
        .sheet(isPresented: $showingEditSheet, onDismiss: { editingReminder = nil }) {
            editDetailsSheet
                .preferredColorScheme(preferredScheme)
        }
        .preferredColorScheme(preferredScheme)
    }

    // MARK: - Offsets

    /// 入力画面のY offset
    private func inputOffset(h: CGFloat) -> CGFloat {
        if viewState == .list {
            if currentListIndex == 0 && listSwipeDragOffset < 0 {
                return h + listSwipeDragOffset
            }
            return h
        }          // 下に退場
        if isDraggingToList { return dragOffset }   // 指追従
        return 0
    }

    // MARK: - Input View

    var inputView: some View {
        ZStack {
            Color.white.opacity(0.001).ignoresSafeArea()
                .onTapGesture {
                    if viewState == .editingMinutes {
                        commitMinutes()
                    } else if !reminderText.isEmpty {
                        isTextFieldFocused = false
                        isGestureBlocked = true
                        saveToAppleReminders()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            if viewState == .input { isTextFieldFocused = true }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            isGestureBlocked = false
                        }
                    } else {
                        // 空のときはキーボードを閉じるだけ
                        isTextFieldFocused = false
                    }
                }

            // キーボード上の可視領域内でセンタリング
            VStack(spacing: 20) {
                ZStack {
                    // ─ フローティングバッジ ─
                    Text(floatingText)
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                        .foregroundColor(.black)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 6)
                        .background(Color.white.opacity(0.9))
                        .clipShape(Capsule())
                        .shadow(color: .black.opacity(0.25), radius: 8)
                        .offset(y: floatingOffset - 20)
                        .opacity(floatingOpacity)

                    VStack(spacing: -15) {
                        // 日付ラベル：タップで日時変更（selectedFontを適用）
                        Text(dateString(from: proposedTime))
                            .font(.custom(selectedFont, size: 28))
                            .foregroundColor(secondaryText)
                            .onTapGesture { showDatePicker = true }
                        Group {
                            if viewState == .editingMinutes {
                                ZStack {
                                    // 実際の入力フィールド（透明・カーソル非表示）
                                    TextField("", text: $minutesInputString)
                                        .focused($isMinutesFocused)
                                        .keyboardType(.numberPad)
                                        .foregroundColor(.clear)
                                        .tint(.clear)
                                        .onChange(of: minutesInputString) { v in
                                            let digits = v.filter { $0.isNumber }
                                            minutesInputString = String(digits.prefix(4))
                                        }
                                        .onSubmit { commitMinutes() }
                                    // HH:MM 形式の表示オーバーレイ
                                    let d = minutesInputString
                                    let hh: String = {
                                        switch d.count {
                                        case 3:  return "0" + String(d.prefix(1))
                                        case 4:  return String(d.prefix(2))
                                        default: return "00"
                                        }
                                    }()
                                    let mm: String = {
                                        switch d.count {
                                        case 0:  return "00"
                                        case 1:  return "0" + d
                                        case 2:  return d
                                        default: return String(d.suffix(2))
                                        }
                                    }()
                                    HStack(spacing: 0) {
                                        Text(hh)
                                        Text(":")
                                        Text(mm)
                                    }
                                    .allowsHitTesting(false)
                                }
                            } else {
                                HStack(spacing: 0) {
                                    Text(hourString(from: proposedTime))
                                    Text(":")
                                    Text(minuteString(from: proposedTime))
                                }
                                .contentShape(Rectangle())
                                .onTapGesture { startEditingMinutes() }
                            }
                        }
                        .font(.custom(selectedFont, size: 100)).foregroundColor(primaryText)
                    }
                    .scaleEffect(timeScale).offset(x: timeOffset)
                } // ZStack閉候

                // 「◯時間◯分後」ラベル（ZStack外、時計と重ならない）
                Text(timeRemainingText(from: proposedTime))
                    .font(.system(size: 14, weight: .regular, design: .rounded))
                    .foregroundColor(secondaryText)

                TextField("", text: $reminderText)
                    .focused($isTextFieldFocused)
                    .font(.custom("Futura-Medium", size: 30))
                    .foregroundColor(viewState == .editingMinutes ? .gray.opacity(0.3) : primaryText)
                    .multilineTextAlignment(.center).padding()
                    .background(inputBgColor).cornerRadius(16).padding(.horizontal, 40)
                    .disabled(viewState == .editingMinutes).submitLabel(.done)
                    .onSubmit {
                        // Enter後はスワイプ状態を即リセットしてアニメ誤発火を防ぐ
                        isDraggingToList = false
                        dragOffset = 0
                        isGestureBlocked = true
                        if !reminderText.isEmpty { saveToAppleReminders() }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            if viewState == .input { isTextFieldFocused = true }
                        }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                            isGestureBlocked = false
                        }
                    }
            }
            // キーボード上の可視エリア内でセンタリング
            .offset(y: bounceOffset)
            .frame(maxWidth: .infinity)
            .frame(height: screenHeight - keyboardHeight)
            .animation(.easeOut(duration: 0.25), value: keyboardHeight)
        }
        .overlay(Group {
            if isShowingSuccessMark {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 100)).foregroundColor(.white)
                    .padding(.bottom, keyboardHeight > 0 ? keyboardHeight * 0.5 : 0)
                    .transition(.scale.combined(with: .opacity)).zIndex(2)
            }
        })
    }

    // MARK: - List View

    private func singleListView(for calendar: EKCalendar, index: Int) -> some View {
        let cal = Color(cgColor: calendar.cgColor)
        let rems = (remindersMap[calendar.calendarIdentifier] ?? []).filter { !self.isDone($0) }
        return GeometryReader { listGeo in
            let safeTop = listGeo.safeAreaInsets.top
            ZStack(alignment: .top) {
                bgColor.ignoresSafeArea()
                    // 背景タップ: インライン追加中なら確定、そうでなければ入力画面へ戻る
                    .onTapGesture {
                        if isInlineFocused {
                            addInlineReminder(to: calendar)
                            isInlineFocused = false
                        } else {
                            returnToInput()
                        }
                    }
                VStack(spacing: 0) {
                    // タイトルヘッダー：Safe Areaの高さを動的に取得して正確に配置
                    let actualSafeTop = safeTop > 20 ? safeTop : 47
                    HStack {
                        Text(calendar.title)
                            .font(.custom(selectedFont, size: 20))
                            .foregroundColor(cal)
                        Spacer()
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, actualSafeTop + 16)
                    .padding(.bottom, 10)
                    .background(
                        bgColor
                            .ignoresSafeArea(edges: .top)
                    )
                    .zIndex(1) // スクロール時にコンテンツより上に表示

                    ScrollView {
                        VStack(spacing: 6) {
                            ForEach(rems, id: \.calendarItemIdentifier) { rm in
                                reminderRow(rm: rm, calColor: cal, calId: calendar.calendarIdentifier)
                            }

                            // インライン追加行
                            HStack(spacing: 10) {
                                Image(systemName: "plus")
                                    .font(.system(size: 16, weight: .bold))
                                    .foregroundColor(cal)
                                    .frame(width: 28, height: 28)

                                TextField("追加...", text: $inlineNewTitle)
                                    .focused($isInlineFocused)
                                    .font(.custom(bodyFontName, size: 16))
                                    .foregroundColor(primaryText)
                                    .submitLabel(.done)
                                    .onSubmit {
                                        addInlineReminder(to: calendar)
                                    }
                                Spacer()
                            }
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(cardBgColor.opacity(0.6))
                            .cornerRadius(12)
                        }
                        .padding(.leading, 16)
                        .padding(.trailing, 72)
                        .padding(.bottom, 20)
                    }
                    // キーボードが出ても黒い領域が出ないように: ScrollViewはキーボードで押し上げない
                    .ignoresSafeArea(.keyboard)
                    .scrollDismissesKeyboard(.immediately)
                }
                .frame(width: listGeo.size.width, height: listGeo.size.height + safeTop)
            }
        }
        .ignoresSafeArea(edges: .top)
    }


    private func addInlineReminder(to calendar: EKCalendar) {
        guard !inlineNewTitle.isEmpty else { return }
        let r = EKReminder(eventStore: eventStore)
        r.title = inlineNewTitle
        r.calendar = calendar

        try? eventStore.save(r, commit: true)

        inlineNewTitle = "" // リセットして次へ

        UINotificationFeedbackGenerator().notificationOccurred(.success)

        // ローカルに即座に反映させる
        withAnimation {
            remindersMap[calendar.calendarIdentifier, default: []].append(r)
        }

        // 次の入力を即時にできるようにする
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            isInlineFocused = true
        }
    }


    private func isDone(_ rm: EKReminder) -> Bool {
        let id = rm.calendarItemIdentifier
        if localUncompletedIDs.contains(id) { return false }
        if localCompletedIDs.contains(id) { return true }
        return rm.isCompleted
    }

    private func reminderRow(rm: EKReminder, calColor: Color, calId: String) -> some View {
        let done = isDone(rm)
        let dueDate: Date? = rm.alarms?.first?.absoluteDate ?? rm.dueDateComponents?.date

        let isOverdue = !done && (dueDate != nil && dueDate! < Date())
        let textColor: Color = done ? .gray : (isOverdue ? .red : primaryText)
        let dateColor: Color = done ? .gray.opacity(0.4) : (isOverdue ? .red.opacity(0.8) : .gray.opacity(0.8))

        return HStack(spacing: 10) {
            Button { toggleCompletion(rm) } label: {
                ZStack {
                    Circle().stroke(done ? calColor : calColor.opacity(0.7), lineWidth: 1.5).frame(width: 20, height: 20)
                    if done { Circle().fill(calColor).frame(width: 12, height: 12) }
                }
                .frame(width: 28, height: 28).contentShape(Rectangle())
            }.buttonStyle(PlainButtonStyle())
            Text(rm.title)
                .font(.custom(bodyFontName, size: 16))
                .foregroundColor(textColor)
                .strikethrough(done, color: .gray)
                .lineLimit(nil)
                .multilineTextAlignment(.leading)
            Spacer()
            if let due = dueDate {
                Text(listDateTimeString(from: due))
                    .font(.custom(bodyFontName, size: 13))
                    .foregroundColor(dateColor)
                    .strikethrough(done, color: .gray)
                    .multilineTextAlignment(.trailing)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(cardBgColor).cornerRadius(12)
        .opacity(done ? 0.5 : 1.0)
        .animation(.spring(), value: done)
        .contentShape(Rectangle())
        // ドラッグ（長押しで移動）
        .onDrag { NSItemProvider(object: rm.calendarItemIdentifier as NSString) }
        // タップで詳細編集シートを開く
        .onTapGesture {
            editingTitle = rm.title
            if let d = rm.alarms?.first?.absoluteDate ?? rm.dueDateComponents?.date {
                editingDate = d
                isEditingDateEnabled = true
            } else {
                editingDate = Date().addingTimeInterval(3600)
                isEditingDateEnabled = false
            }
            editingReminder = rm
            showingEditSheet = true
        }
    }

    var editDetailsSheet: some View {
        NavigationView {
            Form {
                Section(header: Text("リマインダーの内容")) {
                    TextField("タイトル", text: $editingTitle)
                        .font(.custom(bodyFontName, size: 18))
                }

                Section(header: Text("通知と期限")) {
                    Toggle("通知（日時）を設定", isOn: $isEditingDateEnabled.animation())

                    if isEditingDateEnabled {
                        DatePicker("日時", selection: $editingDate, displayedComponents: [.date, .hourAndMinute])
                            .environment(\.locale, Locale(identifier: "ja_JP"))
                    }
                }

                Section {
                    Button(action: {
                        showingDeleteConfirm = true
                    }) {
                        HStack {
                            Spacer()
                            Text("このリマインダーを削除")
                                .foregroundColor(.red)
                            Spacer()
                        }
                    }
                }
                .confirmationDialog("削除しますか？", isPresented: $showingDeleteConfirm, titleVisibility: .visible) {
                    Button("削除", role: .destructive) { deleteEditingReminder() }
                    Button("キャンセル", role: .cancel) {}
                }
            }
            .navigationTitle("詳細の編集")
            .navigationBarItems(
                leading: Button("キャンセル") {
                    showingEditSheet = false
                },
                trailing: Button("保存") {
                    saveDetailsEdit()
                }.font(.headline)
            )
        }
    }

    private func saveDetailsEdit() {
        guard let rm = editingReminder else { return }

        if !editingTitle.isEmpty { rm.title = editingTitle }

        if isEditingDateEnabled {
            rm.alarms = [EKAlarm(absoluteDate: editingDate)]
            rm.dueDateComponents = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute], from: editingDate)
        } else {
            rm.alarms = nil
            rm.dueDateComponents = nil
        }

        try? eventStore.save(rm, commit: true)

        // Storeから再取得して強制UI更新
        fetchAndShowList(screenH: screenHeight)

        showingEditSheet = false
    }

    private func deleteEditingReminder() {
        guard let rm = editingReminder else { return }
        try? eventStore.remove(rm, commit: true)

        // ローカルから削除
        withAnimation {
            let calId = rm.calendar.calendarIdentifier
            if let idx = remindersMap[calId]?.firstIndex(where: { $0.calendarItemIdentifier == rm.calendarItemIdentifier }) {
                remindersMap[calId]?.remove(at: idx)
            }
        }

        showingEditSheet = false
    }

    var errorView: some View {
        VStack(spacing: 24) {
            Image(systemName: "exclamationmark.triangle").font(.system(size: 60, weight: .light)).foregroundColor(.red.opacity(0.8))
            Text("リマインダーへのアクセスが\n許可されていません。")
                .font(.custom("Futura-Medium", size: 18)).multilineTextAlignment(.center).foregroundColor(primaryText)
            Button {
                if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
            } label: {
                Text("設定を開いて許可する").font(.custom("Futura-Bold", size: 16)).foregroundColor(primaryText)
                    .padding(.horizontal, 30).padding(.vertical, 14)
                    .background(inputBgColor).cornerRadius(20)
            }
        }.padding().zIndex(10)
    }

    // MARK: - Actions

    private func toggleCompletion(_ reminder: EKReminder) {
        let id = reminder.calendarItemIdentifier
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        withAnimation(.spring()) {
            if isDone(reminder) {
                localCompletedIDs.remove(id); localUncompletedIDs.insert(id)
                reminder.isCompleted = false
            } else {
                localUncompletedIDs.remove(id); localCompletedIDs.insert(id)
                reminder.isCompleted = true
            }
        }
        try? eventStore.save(reminder, commit: true)
    }

    private func fetchAndShowList(screenH: CGFloat) {
        let cals = eventStore.calendars(for: .reminder)
        guard !cals.isEmpty else {
            isDraggingToList = false
            withAnimation(.mightySpring) { dragOffset = 0 }
            provideErrorFeedback(); return
        }
        self.calendars = cals
        let pred = eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
        eventStore.fetchReminders(matching: pred) { result in
            var map: [String:[EKReminder]] = [:]
            for rm in result ?? [] { map[rm.calendar.calendarIdentifier, default: []].append(rm) }
            for k in map.keys { map[k]?.sort {
                ($0.alarms?.first?.absoluteDate ?? $0.dueDateComponents?.date ?? .distantFuture)
                < ($1.alarms?.first?.absoluteDate ?? $1.dueDateComponents?.date ?? .distantFuture) }
            }
            DispatchQueue.main.async {
                // ローカルで完了マークしたリマインダーを最新オブジェクトで再注入
                for id in self.localCompletedIDs {
                    if map.values.contains(where: { $0.contains(where: { $0.calendarItemIdentifier == id }) }) { continue }
                    if let rm = self.eventStore.calendarItem(withIdentifier: id) as? EKReminder {
                        map[rm.calendar.calendarIdentifier, default: []].append(rm)
                    }
                }
                self.remindersMap = map
                withAnimation(.mightySpring) {
                    self.viewState = .list
                    self.currentListIndex = 0
                    self.isDraggingToList = false
                    self.dragOffset = 0
                }
            }
        }
    }

    private func returnToInput() {
        listSwipeDragOffset = 0
        withAnimation(.mightySpring) { viewState = .input; dragOffset = 0 }
        provideHapticFeedback(.light)
        if !isTextFieldFocused && !isMinutesFocused {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { if !showingSettings { isTextFieldFocused = true } }
        }
    }

    private func goToNextList() {
        if currentListIndex + 1 < calendars.count {
            navigatingDown = true
            withAnimation(.mightySpring) { currentListIndex += 1 }
            provideHapticFeedback(.light)
        } else {
            provideErrorFeedback()
        }
    }

    private func goToPreviousList() {
        navigatingDown = false
        if currentListIndex > 0 {
            withAnimation(.mightySpring) { currentListIndex -= 1 }
            provideHapticFeedback(.light)
        } else {
            returnToInput()
        }
    }

    private func handleHorizontalSwipe(_ h: CGFloat) {
        let secs = Double(swipeHourOffset) * 3600
        withAnimation(.spring(response: 0.3, dampingFraction: 0.5)) {
            if h < -30 {
                proposedTime = proposedTime.addingTimeInterval(secs)
                triggerFloatingAnimation(text: "\u{FF0B}\(swipeHourOffset):00"); provideHapticFeedback(.medium)
            } else if h > 30 {
                let t = proposedTime.addingTimeInterval(-secs)
                if t > Date() { proposedTime = t; triggerFloatingAnimation(text: "\u{FF0D}\(swipeHourOffset):00"); provideHapticFeedback(.light) }
                else if proposedTime > Date().addingTimeInterval(60) { proposedTime = Date().addingTimeInterval(60); triggerFloatingAnimation(text: "MIN"); provideHapticFeedback(.light) }
                else { provideErrorFeedback() }
            }
            timeOffset = 0; timeScale = 1.0
        }
    }

    private func startEditingMinutes() {
        minutesInputString = ""  // 空にして即入力
        viewState = .editingMinutes
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { isMinutesFocused = true }
    }

    private func commitMinutes() {
        isMinutesFocused = false
        let digits = minutesInputString.filter { $0.isNumber }
        var c = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute,.second], from: proposedTime)
        if digits.count == 4 {
            let hh = Int(digits.prefix(2)) ?? 0
            let mm = Int(digits.suffix(2)) ?? 0
            c.hour = max(0, min(23, hh))
            c.minute = max(0, min(59, mm))
        } else if digits.count == 3 {
            let hh = Int(String(digits.prefix(1))) ?? 0
            let mm = Int(String(digits.suffix(2))) ?? 0
            c.hour = max(0, min(23, hh))
            c.minute = max(0, min(59, mm))
        } else {
            let mm = Int(digits) ?? 0
            c.minute = max(0, min(59, mm))
        }
        c.second = 0
        if let d = Calendar.current.date(from: c) { proposedTime = d }
        withAnimation(.spring()) { viewState = .input }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { isTextFieldFocused = true }
    }

    private func requestReminderAccess() {
        let grant: (Bool) -> Void = { ok in
            guard ok else {
                DispatchQueue.main.async {
                    self.hasAccessError = true
                    withAnimation(.easeIn(duration: 0.3)) { self.isReady = true }
                }
                return
            }

            if self.defaultStartView == "list" {
                // リストデータを先取得 → viewState=.list にセットしてから isReady=true（入力画面フラッシュ防止）
                let cals = self.eventStore.calendars(for: .reminder)
                guard !cals.isEmpty else {
                    DispatchQueue.main.async {
                        withAnimation(.easeIn(duration: 0.3)) { self.isReady = true }
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.isTextFieldFocused = true }
                    }
                    return
                }
                DispatchQueue.main.async { self.calendars = cals }
                let pred = self.eventStore.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: cals)
                self.eventStore.fetchReminders(matching: pred) { result in
                    var map: [String: [EKReminder]] = [:]
                    for rm in result ?? [] { map[rm.calendar.calendarIdentifier, default: []].append(rm) }
                    for k in map.keys { map[k]?.sort {
                        ($0.alarms?.first?.absoluteDate ?? $0.dueDateComponents?.date ?? .distantFuture)
                        < ($1.alarms?.first?.absoluteDate ?? $1.dueDateComponents?.date ?? .distantFuture) }
                    }
                    DispatchQueue.main.async {
                        self.remindersMap = map
                        self.viewState = .list
                        // defaultListIdentifier に一致するカレンダーから始める
                        if !self.defaultListIdentifier.isEmpty,
                           let idx = cals.firstIndex(where: { $0.calendarIdentifier == self.defaultListIdentifier }) {
                            self.currentListIndex = idx
                        } else {
                            self.currentListIndex = 0
                        }
                        withAnimation(.easeIn(duration: 0.3)) { self.isReady = true }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    withAnimation(.easeIn(duration: 0.3)) { self.isReady = true }
                    if !self.showingSettings && self.viewState == .input {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { self.isTextFieldFocused = true }
                    }
                }
            }
        }
        if #available(iOS 17, *) { eventStore.requestFullAccessToReminders { ok, _ in grant(ok) } }
        else { eventStore.requestAccess(to: .reminder) { ok, _ in grant(ok) } }
    }

    private func saveToAppleReminders() {
        guard !reminderText.isEmpty else { return }
        guard proposedTime > Date() else { provideErrorFeedback(); return }
        let status = EKEventStore.authorizationStatus(for: .reminder)
        var authorized = false
        if #available(iOS 17, *) { authorized = status == .fullAccess || status == .authorized }
        else { authorized = status == .authorized }
        guard authorized else { hasAccessError = true; isTextFieldFocused = false; return }
        let r = EKReminder(eventStore: eventStore)
        r.title = reminderText; r.calendar = eventStore.defaultCalendarForNewReminders()
        r.addAlarm(EKAlarm(absoluteDate: proposedTime))
        r.dueDateComponents = Calendar.current.dateComponents([.year,.month,.day,.hour,.minute], from: proposedTime)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring(response: 0.4, dampingFraction: 0.5)) {
            self.isShowingSuccessMark = true
            self.reminderText = ""
            self.proposedTime = self.defaultProposedTime()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { withAnimation { self.isShowingSuccessMark = false } }
        DispatchQueue.global(qos: .userInitiated).async {
            try? self.eventStore.save(r, commit: true)
        }
    }

    private func defaultProposedTime() -> Date {
        let cal = Calendar.current
        if defaultTimeMode == "fixed" {
            // 固定時刻モード: 今日の設定時刻、すでに過ぎていたら翌日に設定
            var comps = cal.dateComponents([.year, .month, .day], from: Date())
            comps.hour = defaultFixedHour
            comps.minute = 0
            comps.second = 0
            if let today = cal.date(from: comps) {
                if today > Date() {
                    return today
                } else {
                    return cal.date(byAdding: .day, value: 1, to: today) ?? today
                }
            }
            return Date().addingTimeInterval(3600)
        } else {
            // オフセットモード: 今から○時間後（分は切り上げ）
            let base = Date().addingTimeInterval(Double(defaultHourOffset) * 3600)
            var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: base)
            if (comps.minute ?? 0) > 0 {
                comps.minute = 0
                let truncated = cal.date(from: comps) ?? base
                return truncated.addingTimeInterval(3600)
            }
            return cal.date(from: comps) ?? base
        }
    }

    private func dateString(from d: Date) -> String {
        if Calendar.current.isDateInToday(d) { return "\u{4ECA}\u{65E5}" }
        if Calendar.current.isDateInTomorrow(d) { return "\u{660E}\u{65E5}" }
        let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "M/d (E)"; return f.string(from: d)
    }
    private func hourString(from d: Date) -> String { let f = DateFormatter(); f.dateFormat = "HH"; return f.string(from: d) }
    private func minuteString(from d: Date) -> String { let f = DateFormatter(); f.dateFormat = "mm"; return f.string(from: d) }
    private func timeString(from d: Date) -> String { let f = DateFormatter(); f.locale = Locale(identifier: "ja_JP"); f.dateFormat = "HH:mm"; return f.string(from: d) }
    /// リスト用：昨日・今日・明日は文字列で、それ以外は「3/1 12:30」形式
    private func listDateTimeString(from d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        let cal = Calendar.current
        if cal.isDateInYesterday(d) {
            f.dateFormat = "昨日 HH:mm"
        } else if cal.isDateInToday(d) {
            f.dateFormat = "今日 HH:mm"
        } else if cal.isDateInTomorrow(d) {
            f.dateFormat = "明日 HH:mm"
        } else {
            f.dateFormat = "M/d HH:mm"
        }
        return f.string(from: d)
    }
    private func triggerFloatingAnimation(text: String) {
        floatingOpacity = 0; floatingOffset = 0; floatingText = text
        withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
            floatingOpacity = 1.0
            floatingOffset = -30
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) {
            withAnimation(.easeOut(duration: 0.4)) { floatingOpacity = 0 }
        }
    }
    private func timeRemainingText(from date: Date) -> String {
        let diff = date.timeIntervalSince(Date())
        guard diff > 0 else { return "過去の時刻" }
        let totalMinutes = Int(diff / 60)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours > 0 && minutes > 0 { return "\(hours)時間\(minutes)分後" }
        else if hours > 0 { return "\(hours)時間後" }
        else { return "\(minutes)分後" }
    }

    private func iconForCalendar(_ title: String) -> String {
        let t = title.lowercased()
        if t.contains("買") || t.contains("buy") || t.contains("shopping") { return "cart.fill" }
        if t.contains("やる") || t.contains("todo") { return "checklist" }
        if t.contains("仕事") || t.contains("work") { return "briefcase.fill" }
        if t.contains("お知らせ") || t.contains("notice") || t.contains("remind") { return "bell.fill" }
        if t.contains("家族") || t.contains("family") { return "house.fill" }
        if t.contains("予定") || t.contains("plan") { return "calendar" }
        return "list.bullet"
    }

    private var completedListView: some View {
        let allCompleted: [EKReminder] = remindersMap.values.flatMap { $0 }
            .filter { self.isDone($0) }
            .sorted {
                ($0.alarms?.first?.absoluteDate ?? $0.dueDateComponents?.date ?? .distantFuture)
                > ($1.alarms?.first?.absoluteDate ?? $1.dueDateComponents?.date ?? .distantFuture)
            }
        return GeometryReader { listGeo in
            let safeTop = listGeo.safeAreaInsets.top
            ZStack(alignment: .top) {
                bgColor.ignoresSafeArea()
                    .onTapGesture { returnToInput() }
                VStack(spacing: 0) {
                    let actualSafeTop = safeTop > 20 ? safeTop : 47
                    if allCompleted.isEmpty {
                        VStack(spacing: 0) {
                            HStack {
                                Image(systemName: "checkmark.circle.fill")
                                    .foregroundColor(.red)
                                    .font(.system(size: 20, weight: .bold))
                                Text("完了")
                                    .font(.custom("Futura-Bold", size: 20))
                                    .foregroundColor(.red)
                                Spacer()
                            }
                            .padding(.horizontal, 24)
                            .padding(.top, actualSafeTop + 16)
                            .padding(.bottom, 10)

                            Spacer()
                            VStack(spacing: 12) {
                                Image(systemName: "checkmark.circle")
                                    .font(.system(size: 50, weight: .light))
                                    .foregroundColor(secondaryText.opacity(0.5))
                                Text("完了した項目はありません")
                                    .font(.system(size: 16))
                                    .foregroundColor(secondaryText)
                            }
                            Spacer()
                        }
                    } else {
                        HStack {
                            Image(systemName: "checkmark.circle.fill")
                                .foregroundColor(.red)
                                .font(.system(size: 20, weight: .bold))
                            Text("完了")
                                .font(.custom("Futura-Bold", size: 20))
                                .foregroundColor(.red)
                            Spacer()
                        }
                        .padding(.horizontal, 24)
                        .padding(.top, actualSafeTop + 16)
                        .padding(.bottom, 10)
                        .background(bgColor.ignoresSafeArea(edges: .top))
                        .zIndex(1)

                        ScrollView {
                            VStack(spacing: 6) {
                                ForEach(allCompleted, id: \.calendarItemIdentifier) { rm in
                                    let calColor = Color(rm.calendar.cgColor)
                                    reminderRow(rm: rm, calColor: calColor, calId: rm.calendar.calendarIdentifier)
                                }
                            }
                            .padding(.leading, 16)
                            .padding(.trailing, 72)
                            .padding(.bottom, 80)
                        }
                        Color.clear
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                            .onTapGesture { returnToInput() }
                    }
                }
                .frame(width: listGeo.size.width, height: listGeo.size.height + safeTop)
            }
        }
        .ignoresSafeArea(edges: .top)
    }


    private var rightSideTabMenu: some View {
        HStack {
            Spacer()
            VStack(spacing: 12) {
                // ───── 完了タブ（一番上）─────
                let isDoneSelected = currentListIndex == -1
                let isDoneHovered = hoveredTabId == "DONE_TAB"
                let completedCount = remindersMap.values.flatMap { $0 }.filter { self.isDone($0) }.count

                Button {
                    navigatingDown = currentListIndex > -1
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                        currentListIndex = -1
                    }
                    provideHapticFeedback(.light)
                } label: {
                    HStack(spacing: -8) {
                        Text("\(completedCount)")
                            .font(.system(size: 13, weight: .bold, design: .rounded))
                            .foregroundColor(.white)
                            .frame(width: 24, height: 24)
                            .background(isDoneSelected || isDoneHovered ? Color.red : Color.red.opacity(0.7))
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.2), radius: 2, x: -1, y: 1)
                            .zIndex(1)

                        VStack(spacing: 4) {
                            Image(systemName: "checkmark.circle.fill")
                                .font(.system(size: 20))
                                .foregroundColor(isDoneSelected || isDoneHovered ? .red : .gray)
                            Text("完了")
                                .font(.system(size: 10, weight: .bold))
                                .foregroundColor(isDoneSelected || isDoneHovered ? .red : .gray)
                                .lineLimit(1)
                                .frame(width: 44)
                        }
                        .padding(.vertical, 14)
                        .padding(.leading, 12)
                        .padding(.trailing, 20)
                        .background(
                            RoundedRectangle(cornerRadius: 16)
                                .fill(isDoneSelected || isDoneHovered ? Color.white : Color(white: 0.15))
                                .shadow(color: .black.opacity(isDoneSelected || isDoneHovered ? 0.3 : 0), radius: 4, x: -2, y: 0)
                        )
                    }
                    .offset(x: isDoneSelected || isDoneHovered ? 8 : 16)
                    .scaleEffect(isDoneHovered ? 1.15 : 1.0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isDoneHovered)
                }
                .buttonStyle(PlainButtonStyle())
                .onDrop(of: [.plainText], delegate: TabDropDelegate(
                    calendarId: "DONE_TAB",
                    hoveredTabId: $hoveredTabId,
                    onDrop: { id in completeReminderDrag(id: id) }
                ))

                Divider().background(Color.white.opacity(0.3)).frame(width: 40).padding(.vertical, 4)

                // カレンダーごとのドロップタブ
                ForEach((0..<calendars.count), id: \.self) { unreversedIdx in
                    let idx = calendars.count - 1 - unreversedIdx
                    let cal = calendars[idx]
                    let isSelected = currentListIndex == idx
                    let rems = remindersMap[cal.calendarIdentifier]?.filter { !self.isDone($0) } ?? []
                    let count = rems.count
                    let calColor = Color(cal.cgColor)
                    let isHovered = hoveredTabId == cal.calendarIdentifier

                    Button {
                        if currentListIndex != idx {
                            navigatingDown = idx < currentListIndex
                            withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                currentListIndex = idx
                            }
                            provideHapticFeedback(.light)
                        }
                    } label: {
                        HStack(spacing: -8) {
                            Text("\(count)")
                                .font(.system(size: 13, weight: .bold, design: .rounded))
                                .foregroundColor(isSelected ? .black : .white)
                                .frame(width: 24, height: 24)
                                .background(isSelected ? Color.white : Color.gray.opacity(0.8))
                                .clipShape(Circle())
                                .shadow(color: .black.opacity(0.2), radius: 2, x: -1, y: 1)
                                .zIndex(1)

                            VStack(spacing: 4) {
                                Image(systemName: iconForCalendar(cal.title))
                                    .font(.system(size: 20))
                                    .foregroundColor(isSelected ? calColor : .gray)
                                Text(cal.title)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundColor(isSelected ? calColor : .gray)
                                    .lineLimit(1)
                                    .frame(width: 44)
                            }
                            .padding(.vertical, 14)
                            .padding(.leading, 12)
                            .padding(.trailing, 20)
                            .background(
                                RoundedRectangle(cornerRadius: 16)
                                    .fill(isSelected || isHovered ? Color.white : Color(white: 0.15))
                                    .shadow(color: .black.opacity(isSelected || isHovered ? 0.3 : 0), radius: 4, x: -2, y: 0)
                            )
                        }
                        .offset(x: isSelected || isHovered ? 8 : 16)
                        .scaleEffect(isHovered ? 1.15 : 1.0)
                        .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isHovered)
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onDrop(of: [.plainText], delegate: TabDropDelegate(
                        calendarId: cal.calendarIdentifier,
                        hoveredTabId: $hoveredTabId,
                        onDrop: { id in moveReminder(id: id, to: cal) }
                    ))
                }
            }
            .padding(.trailing, -10)
        }
    }

    // ドラッグ＆ドロップ時のロジック

    private func findReminder(id: String) -> EKReminder? {
        for list in remindersMap.values {
            if let rm = list.first(where: { $0.calendarItemIdentifier == id }) {
                return rm
            }
        }
        return eventStore.calendarItem(withIdentifier: id) as? EKReminder
    }

    private func moveReminder(id: String, to calendar: EKCalendar) {
        guard let rm = findReminder(id: id) else { return }
        let oldCalId = rm.calendar.calendarIdentifier
        if oldCalId == calendar.calendarIdentifier { return }
        rm.calendar = calendar
        try? eventStore.save(rm, commit: true)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation {
            if let idx = remindersMap[oldCalId]?.firstIndex(where: { $0.calendarItemIdentifier == id }) {
                remindersMap[oldCalId]?.remove(at: idx)
            }
            remindersMap[calendar.calendarIdentifier, default: []].append(rm)
        }
    }

    private func completeReminderDrag(id: String) {
        guard let rm = findReminder(id: id) else { return }
        if rm.isCompleted { return }
        rm.isCompleted = true
        try? eventStore.save(rm, commit: true)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        withAnimation(.spring()) {
            localUncompletedIDs.remove(id)
            localCompletedIDs.insert(id)
        }
    }

    private func provideHapticFeedback(_ s: UIImpactFeedbackGenerator.FeedbackStyle) {
        guard hapticsEnabled else { return }
        UIImpactFeedbackGenerator(style: s).impactOccurred()
    }
    private func provideErrorFeedback() {
        guard hapticsEnabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }
}

// MARK: - DropDelegate
struct TabDropDelegate: DropDelegate {
    let calendarId: String
    @Binding var hoveredTabId: String?
    let onDrop: (String) -> Void

    func dropEntered(info: DropInfo) {
        withAnimation { hoveredTabId = calendarId }
    }

    func dropExited(info: DropInfo) {
        if hoveredTabId == calendarId {
            withAnimation { hoveredTabId = nil }
        }
    }

    func performDrop(info: DropInfo) -> Bool {
        withAnimation { hoveredTabId = nil }
        if let item = info.itemProviders(for: [.plainText]).first {
            item.loadObject(ofClass: NSString.self) { string, _ in
                guard let id = string as? String else { return }
                DispatchQueue.main.async { onDrop(id) }
            }
            return true
        }
        return false
    }
}

struct SettingsView: View {
    let eventStore: EKEventStore

    @Environment(\.dismiss) var dismiss
    @AppStorage("defaultHourOffset") private var defaultHourOffset = 6
    @AppStorage("swipeHourOffset") private var swipeHourOffset = 1
    @AppStorage("selectedFont") private var selectedFont = "Futura-Bold"
    @AppStorage("defaultTimeMode") private var defaultTimeMode = "offset"
    @AppStorage("defaultFixedHour") private var defaultFixedHour = 19
    @AppStorage("defaultStartView") private var defaultStartView = "input"
    @AppStorage("defaultListIdentifier") private var defaultListIdentifier = ""
    @AppStorage("appColorScheme") private var appColorScheme = "dark"
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true

    @State private var availableCalendars: [EKCalendar] = []

    let availableFonts: [(name: String, label: String)] = [
        // 日本語フォント
        ("HiraginoSans-W6",     "ヒラギノ角ゴ"),
        ("HiraMinProN-W6",      "ヒラギノ明朝"),
        ("HiraMaruProN-W4",     "ヒラギノ丸ゴ"),
        // 欧文フォント
        ("Futura-Bold",         "Futura"),
        ("Georgia-Bold",        "Georgia"),
        ("Courier-Bold",        "Courier"),
    ]

    private var preferredScheme: ColorScheme? {
        switch appColorScheme {
        case "dark": return .dark
        case "light": return .light
        default: return nil
        }
    }

    // 固定時刻モードでの次のリマインダー時刻をプレビュー表示用に生成
    private var fixedTimePreview: String {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day], from: Date())
        comps.hour = defaultFixedHour
        comps.minute = 0
        comps.second = 0
        guard let today = cal.date(from: comps) else { return "" }
        let target = today > Date() ? today : (cal.date(byAdding: .day, value: 1, to: today) ?? today)
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = cal.isDateInToday(target) ? "今日 HH:mm" : "翌日 HH:mm"
        return f.string(from: target)
    }

    var body: some View {
        NavigationView {
            Form {
                // ── デフォルト時刻設定 ──
                Section(header: Text("デフォルト時刻")) {
                    HStack {
                        modeButton(label: "○時間後", value: "offset")
                        modeButton(label: "固定時刻", value: "fixed")
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                    if defaultTimeMode == "offset" {
                        Stepper(value: $defaultHourOffset, in: 0...48) {
                            HStack {
                                Text("上限時間")
                                Spacer()
                                Text("\(defaultHourOffset) 時間後").foregroundColor(.gray)
                            }
                        }
                    } else {
                        HStack {
                            Text("指定時刻")
                            Spacer()
                            Picker("", selection: $defaultFixedHour) {
                                ForEach(0..<24) { h in
                                    Text(String(format: "%02d:00", h)).tag(h)
                                }
                            }
                            .pickerStyle(.wheel)
                            .frame(width: 90, height: 100)
                            .clipped()
                        }

                        HStack {
                            Image(systemName: "clock.arrow.circlepath")
                                .foregroundColor(.gray)
                            Text("次回のデフォルト")
                                .foregroundColor(.gray)
                            Spacer()
                            Text(fixedTimePreview)
                                .foregroundColor(.blue)
                                .font(.system(size: 15, weight: .medium))
                        }
                        .font(.system(size: 14))

                        Text("現在時刻が\(String(format: "%02d:00", defaultFixedHour))を過ぎている場合は自動的に翌日の\(String(format: "%02d:00", defaultFixedHour))に設定します。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }

                // ── 起動画面設定 ──
                Section(header: Text("起動画面")) {
                    HStack {
                        startViewButton(label: "入力", value: "input")
                        startViewButton(label: "リスト", value: "list")
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                    if defaultStartView == "list" && !availableCalendars.isEmpty {
                        Picker("起動リスト", selection: $defaultListIdentifier) {
                            Text("最初のリスト").tag("")
                            ForEach(availableCalendars, id: \.calendarIdentifier) { cal in
                                Text(cal.title).tag(cal.calendarIdentifier)
                            }
                        }
                    }
                    Text("「リスト」にするとアプリ起動時に直接リスト画面が表示されます。")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                // ── スワイプ設定 ──
                Section(header: Text("スワイプ")) {
                    Stepper(value: $swipeHourOffset, in: 1...24) {
                        HStack {
                            Text("時間変更量")
                            Spacer()
                            Text("\(swipeHourOffset) 時間").foregroundColor(.gray)
                        }
                    }
                }

                // ── テーマ ──
                Section(header: Text("テーマ")) {
                    Picker("", selection: $appColorScheme) {
                        Text("ダーク").tag("dark")
                        Text("ライト").tag("light")
                        Text("システム").tag("system")
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                // ── フォント ──
                Section(header: Text("フォント")) {
                    ForEach(availableFonts, id: \.name) { font in
                        HStack {
                            Text(font.label)
                                .font(.custom(font.name, size: 18))
                            Spacer()
                            if selectedFont == font.name {
                                Image(systemName: "checkmark").foregroundColor(.blue)
                            }
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { selectedFont = font.name }
                    }
                }

                // ── その他 ──
                Section(header: Text("その他")) {
                    Toggle("ハプティクス（振動）", isOn: $hapticsEnabled)
                }
            }
            .navigationTitle("設定")
            .navigationBarItems(trailing: Button("閉じる") { dismiss() })
            .onAppear { availableCalendars = eventStore.calendars(for: .reminder) }
        }.preferredColorScheme(preferredScheme)
    }

    @ViewBuilder
    private func modeButton(label: String, value: String) -> some View {
        let isSelected = defaultTimeMode == value
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                defaultTimeMode = value
            }
        } label: {
            Text(label)
                .font(.system(size: 15, weight: isSelected ? .bold : .regular))
                .foregroundColor(isSelected ? .white : .gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.blue : Color.gray.opacity(0.15))
                )
        }
        .buttonStyle(PlainButtonStyle())
    }

    @ViewBuilder
    private func startViewButton(label: String, value: String) -> some View {
        let isSelected = defaultStartView == value
        Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                defaultStartView = value
            }
        } label: {
            Text(label)
                .font(.system(size: 15, weight: isSelected ? .bold : .regular))
                .foregroundColor(isSelected ? .white : .gray)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(isSelected ? Color.blue : Color.gray.opacity(0.15))
                )
        }
        .buttonStyle(PlainButtonStyle())
    }
}
