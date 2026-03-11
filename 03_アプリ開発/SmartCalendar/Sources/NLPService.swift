import Foundation

// MARK: - 解析結果モデル

struct ParsedEvent: Codable {
    let title: String
    let startDate: String   // ISO8601: "2026-03-02T15:00:00" or "yyyy-MM-dd" for all-day
    let endDate: String     // ISO8601: "2026-03-02T16:00:00" or "yyyy-MM-dd" for all-day
    let location: String?
    let isAllDay: Bool?     // nil = false (OpenAI responses won't include this)
}

// MARK: - NLPService

class NLPService {
    static let shared = NLPService()
    private init() {}

    // MARK: - メイン解析メソッド（完全ローカル）

    func parse(text: String) -> ParsedEvent {
        // 補助キーが挿入する「 : 」「 〜 」等のスペースを正規化（時刻パターンが壊れないよう）
        let text = text.replacingOccurrences(of: #"\s*:\s*"#, with: ":", options: .regularExpression)
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())

        func toHalf(_ s: String) -> String {
            s.applyingTransform(.fullwidthToHalfwidth, reverse: false) ?? s
        }
        
        func replaceKanjiNumbers(_ s: String) -> String {
            var res = s
            let tens = ["五十": 50, "四十": 40, "三十": 30, "二十": 20, "十": 10]
            let units = ["一": 1, "二": 2, "三": 3, "四": 4, "五": 5, "六": 6, "七": 7, "八": 8, "九": 9]
            for (tK, tV) in tens {
                for (uK, uV) in units {
                    res = res.replacingOccurrences(of: tK + uK, with: "\(tV + uV)")
                }
                res = res.replacingOccurrences(of: tK + "分", with: "\(tV)分")
                res = res.replacingOccurrences(of: tK + "時", with: "\(tV)時")
                res = res.replacingOccurrences(of: tK + "日", with: "\(tV)日")
            }
            for (uK, uV) in units {
                res = res.replacingOccurrences(of: uK, with: "\(uV)")
            }
            res = res.replacingOccurrences(of: "十", with: "10")
            return res
        }

        let normalizedText = replaceKanjiNumbers(toHalf(text))

        // ──── 日付解析（優先度順に判定）────
        var baseDate = today
        var dayKeywords: [String] = []
        
        // 1. 具体的な日付指定 (○/○, ○月○日, ○.○)
        let absoluteDatePattern = #"([0-9]{1,2})[/\.月]([0-9]{1,2})(日)?"#
        if let dRange = normalizedText.range(of: absoluteDatePattern, options: .regularExpression) {
            let matched = String(normalizedText[dRange])
            dayKeywords.append(matched)
            let nums = matched.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap { Int($0) }
            if nums.count >= 2 {
                var comps = cal.dateComponents([.year], from: today)
                comps.month = nums[0]
                comps.day = nums[1]
                if let pd = cal.date(from: comps) {
                    baseDate = cal.startOfDay(for: pd)
                }
            }
        } else {
            // 2. 相対的な日付
            let dayPatterns: [(keywords: [String], offset: Int)] = [
                (["明明後日"], 3), (["明後日", "あさって"], 2), (["明日"], 1), (["今日", "本日"], 0)
            ]
            for (keywords, offset) in dayPatterns {
                if let kw = keywords.first(where: { normalizedText.contains($0) }) {
                    baseDate = cal.date(byAdding: .day, value: offset, to: today) ?? today
                    dayKeywords.append(kw)
                    break
                }
            }
            if dayKeywords.isEmpty {
                if normalizedText.contains("再来週") {
                    baseDate = cal.date(byAdding: .weekOfYear, value: 2, to: today) ?? today
                    dayKeywords.append("再来週")
                } else if normalizedText.contains("来週") {
                    baseDate = cal.date(byAdding: .weekOfYear, value: 1, to: today) ?? today
                    dayKeywords.append("来週")
                }
            }
            let weekdayMap: [String: Int] = ["月曜": 2, "月": 2, "火曜": 3, "火": 3, "水曜": 4, "水": 4, "木曜": 5, "木": 5, "金曜": 6, "金": 6, "土曜": 7, "土": 7, "日曜": 1, "日": 1]
            let prefixes = ["今週", "来週", "再来週", ""]
            outer: for prefix in prefixes {
                for (label, targetWd) in weekdayMap.sorted(by: { $0.key.count > $1.key.count }) {
                    let kwReg = prefix.isEmpty ? label : prefix + "の?" + label
                    if let range = normalizedText.range(of: kwReg, options: .regularExpression), dayKeywords.isEmpty {
                        let currentWd = cal.component(.weekday, from: today)
                        var diff = targetWd - currentWd
                        if prefix == "来週" { diff += 7 }
                        else if prefix == "再来週" { diff += 14 }
                        else if diff <= 0 { diff += 7 }
                        baseDate = cal.date(byAdding: .day, value: diff, to: today) ?? today
                        dayKeywords.append(String(normalizedText[range]))
                        break outer
                    }
                }
            }
        }

        // ──── 時間解析（開始時間、終了時間、長さ）────
        var parsedTimes: [(h: Int, m: Int)] = []
        var timeKeywords: [String] = []
        
        // 時刻パターン。末尾に "間" や "時間" が続く場合は除外するため負の先読みを利用。
        let timePattern = #"([0-9]{1,2}):([0-9]{2})|([0-9]{1,2})時([0-9]{1,2})分|([0-9]{1,2})時半|([0-9]{1,2})時(?!間)"#
        let timeRegex = try! NSRegularExpression(pattern: timePattern)
        let timeMatches = timeRegex.matches(in: normalizedText, range: NSRange(normalizedText.startIndex..., in: normalizedText))
        
        for match in timeMatches {
            guard let range = Range(match.range, in: normalizedText) else { continue }
            let matchStr = String(normalizedText[range])
            // 後続文字が "間" のときは"4時間"由来と見なして除外
            if let nextIdx = normalizedText.index(range.upperBound, offsetBy: 0, limitedBy: normalizedText.endIndex),
               nextIdx < normalizedText.endIndex,
               normalizedText[nextIdx] == "間" {
                continue
            }
            // "4時間" のように "時間" を含む場合も除外
            if matchStr.contains("時間") { continue }
            timeKeywords.append(matchStr)
            
            let nums = matchStr.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap { Int($0) }
            if matchStr.contains("半") {
                if let h = nums.first { parsedTimes.append((h, 30)) }
            } else if nums.count >= 2 {
                parsedTimes.append((nums[0], nums[1]))
            } else if let h = nums.first {
                parsedTimes.append((h, 0))
            }
        }
        
        var hour: Int? = nil
        var minute: Int = 0
        if parsedTimes.count >= 1 {
            hour = parsedTimes[0].h
            minute = parsedTimes[0].m
        }

        var startComponents = cal.dateComponents([.year, .month, .day], from: baseDate)
        startComponents.hour = hour ?? 12
        startComponents.minute = minute
        var start = cal.date(from: startComponents) ?? baseDate.addingTimeInterval(12 * 3600)
        
        // 当日で時刻が過ぎていたら翌日へ繰り上げ
        if dayKeywords.isEmpty, hour != nil, start < Date() {
            start = cal.date(byAdding: .day, value: 1, to: start) ?? start
        }
        
        var end = start.addingTimeInterval(3600)
        var durationKeywords: [String] = []

        // 2つ目の時間が指定されていれば終了時間に
        if parsedTimes.count >= 2 {
            var endComps = cal.dateComponents([.year, .month, .day], from: start)
            endComps.hour = parsedTimes[1].h
            endComps.minute = parsedTimes[1].m
            if let calculatedEnd = cal.date(from: endComps) {
                end = calculatedEnd > start ? calculatedEnd : cal.date(byAdding: .day, value: 1, to: calculatedEnd)!
            }
        } else {
            // 長さ表現 (分, h, m, 時間) を探し加算
            let durationPattern = #"([0-9]+)(時間|h|分|m)"#
            let durRegex = try! NSRegularExpression(pattern: durationPattern)
            let durMatches = durRegex.matches(in: normalizedText, range: NSRange(normalizedText.startIndex..., in: normalizedText))
            for match in durMatches {
                guard let range = Range(match.range, in: normalizedText) else { continue }
                let matchStr = String(normalizedText[range])
                // ※"2時"など timeKeywords に含まれているものは除外
                if timeKeywords.contains(where: { matchStr.contains($0) }) { continue }
                
                durationKeywords.append(matchStr)
                let nums = matchStr.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }.compactMap { Int($0) }
                if let val = nums.first {
                    if matchStr.contains("分") || matchStr.contains("m") {
                        end = start.addingTimeInterval(TimeInterval(val * 60))
                    } else {
                        end = start.addingTimeInterval(TimeInterval(val * 3600))
                    }
                }
                break
            }
        }

        // ──── 場所抽出（「○で」「at ○」「in ○」パターン）────
        var location: String? = nil
        var locationKeywords: [String] = []
        let excludedLoc: Set<String> = ["今日", "明日", "明後日", "来週", "あさって", "本日", "月曜", "火曜", "水曜", "木曜", "金曜", "土曜", "日曜", "今週", "電話", "メール", "オンライン", "リモート", "ビデオ"]
        
        let locPattern = #"([^\s\d時分半。、,，.．!！?？\nとのにはがを]+)で|at ([^\s。、,，.．!！?？\n]+)|in ([^\s。、,，.．!！?？\n]+)"#
        let locRegex = try! NSRegularExpression(pattern: locPattern)
        if let match = locRegex.firstMatch(in: normalizedText, range: NSRange(normalizedText.startIndex..., in: normalizedText)),
           let range = Range(match.range, in: normalizedText) {
            let matched = String(normalizedText[range])
            locationKeywords.append(matched)
            
            var candidate = matched
            if candidate.hasSuffix("で") { candidate = String(candidate.dropLast()) }
            if candidate.hasPrefix("at ") { candidate = String(candidate.dropFirst(3)) }
            if candidate.hasPrefix("in ") { candidate = String(candidate.dropFirst(3)) }
            
            let leadingParticles = ["から", "まで", "に", "へ", "を", "は", "が", "と", "の"]
            for p in leadingParticles {
                if candidate.hasPrefix(p) { candidate = String(candidate.dropFirst(p.count)); break }
            }
            if !candidate.isEmpty && !excludedLoc.contains(candidate) { location = candidate }
        }

        // ──── タイトル抽出 ────
        var title = text
        title = title.replacingOccurrences(of: #"[０-９0-9一二三四五六七八九十]{1,2}時半|[０-９0-9一二三四五六七八九十]{1,2}時(?!間)[０-９0-9一二三四五六七八九十]{0,2}分?|[０-９0-9]{1,2}:[０-９0-9]{2}"#, with: " ", options: .regularExpression)
        title = title.replacingOccurrences(of: #"[０-９0-9一二三四五六七八九十]+(時間|h|分|m)(の|間)?"#, with: " ", options: .regularExpression)
        // 末尾に "間" が残ってしまうケースを追加で除去
        title = title.replacingOccurrences(of: #"([０-９0-9]+)(時間|h|分|m)間"#, with: " ", options: .regularExpression)
        title = title.replacingOccurrences(of: #"[０-９0-9]{1,2}[/\.月][０-９0-9]{1,2}(日)?"#, with: " ", options: .regularExpression)
            
        for kw in dayKeywords + locationKeywords {
            let escapedKw = NSRegularExpression.escapedPattern(for: kw)
            title = title.replacingOccurrences(of: escapedKw + "(から|まで|[にのへでをはがと])*", with: " ", options: .regularExpression)
        }
        
        title = title.replacingOccurrences(of: #"^\s*(から|まで|〜|~|[のにはがをでへと])+\s*"#, with: "", options: .regularExpression)
        title = title.replacingOccurrences(of: #"\s*(から|まで|〜|~|[のにはがをでへと])+\s*$"#, with: "", options: .regularExpression)
        
        for p in ["から", "まで", "の", "に", "を", "は", "が", "と", "で", "〜", "~"] {
            title = title.replacingOccurrences(of: "\\s\(p)\\s+", with: " ", options: .regularExpression)
        }
        
        title = title.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if title.isEmpty || title == " " { title = text }

        if hour == nil {
            let df = DateFormatter()
            df.dateFormat = "yyyy-MM-dd"
            let ds = df.string(from: baseDate)
            return ParsedEvent(title: title, startDate: ds, endDate: ds, location: location, isAllDay: true)
        }

        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return ParsedEvent(title: title, startDate: fmt.string(from: start), endDate: fmt.string(from: end), location: location, isAllDay: false)
    }
}
