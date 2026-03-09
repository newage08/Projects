#!/usr/bin/env python3
"""
朝のブリーフィング自動更新スクリプト v3
毎朝6:30にNotionページを更新する
"""

import json
import subprocess
import re
from datetime import datetime, date, timedelta

import requests

# --- 設定 ---
NOTION_TOKEN = "ntn_D81968600957bzPBdoE0RvPyas3hB0CASKfi5ELVc0eaaR"
PAGE_ID = "31d1e892-28bf-80fa-9d8f-feacd3dc3b9d"
HOLDINGS = [
    {"name": "大林組",      "code": "1802", "shares": 700},
    {"name": "ソニーグループ", "code": "6758", "shares": 1000},
    {"name": "丸紅",        "code": "8002", "shares": 300},
    {"name": "三菱商事",    "code": "8058", "shares": 300},
]
NOTION_HEADERS = {
    "Authorization": f"Bearer {NOTION_TOKEN}",
    "Content-Type": "application/json",
    "Notion-Version": "2022-06-28",
}
SESSION = requests.Session()
SESSION.headers.update({"User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"})

# ===== Notion APIヘルパー =====

def notion_get(ep): return SESSION.get(f"https://api.notion.com/v1/{ep}", headers=NOTION_HEADERS, timeout=15).json()
def notion_patch(ep, d): SESSION.patch(f"https://api.notion.com/v1/{ep}", headers=NOTION_HEADERS, json=d, timeout=15)
def notion_delete(ep): SESSION.delete(f"https://api.notion.com/v1/{ep}", headers=NOTION_HEADERS, timeout=15)

def get_children(block_id):
    r = notion_get(f"blocks/{block_id}/children?page_size=100")
    return r.get("results", [])

def append_blocks(block_id, children):
    for i in range(0, len(children), 90):
        notion_patch(f"blocks/{block_id}/children", {"children": children[i:i+90]})

# ===== ブロック生成 =====

def h1(t): return {"object":"block","type":"heading_1","heading_1":{"rich_text":[{"type":"text","text":{"content":t}}]}}
def h2(t): return {"object":"block","type":"heading_2","heading_2":{"rich_text":[{"type":"text","text":{"content":t}}]}}
def h3(t): return {"object":"block","type":"heading_3","heading_3":{"rich_text":[{"type":"text","text":{"content":t}}]}}
def p(t):  return {"object":"block","type":"paragraph","paragraph":{"rich_text":[{"type":"text","text":{"content":t}}]}}
def li(t): return {"object":"block","type":"bulleted_list_item","bulleted_list_item":{"rich_text":[{"type":"text","text":{"content":t}}]}}
def div(): return {"object":"block","type":"divider","divider":{}}
def callout(t, e="💡"): return {"object":"block","type":"callout","callout":{"rich_text":[{"type":"text","text":{"content":t}}],"icon":{"type":"emoji","emoji":e}}}

# ===== 天気 =====

def get_weather():
    try:
        r = SESSION.get("https://wttr.in/Tokyo?format=j1", timeout=15)
        d = r.json()
        cur   = d["current_condition"][0]
        today = d["weather"][0]
        tmrw  = d["weather"][1]

        def fmt(w, label):
            desc = w["hourly"][4]["weatherDesc"][0]["value"]
            maxt, mint = w["maxtempC"], w["mintempC"]
            rain = w["hourly"][4]["chanceofrain"]
            return f"{label}: {desc}  最高{maxt}℃/最低{mint}℃  降水確率{rain}%"

        return [
            f"現在: {cur['weatherDesc'][0]['value']} {cur['temp_C']}℃（体感{cur['FeelsLikeC']}℃）",
            fmt(today, "今日"),
            fmt(tmrw,  "明日"),
        ]
    except Exception as e:
        return [f"天気取得失敗: {e}"]

# ===== カレンダー（AppleScript・タイムアウト対策済み） =====

def run_applescript(script, timeout=20):
    try:
        r = subprocess.run(["osascript", "-e", script], capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip(), r.stderr.strip()
    except subprocess.TimeoutExpired:
        return "", "timeout"
    except Exception as e:
        return "", str(e)

def get_events(days_ahead=0):
    """今日(0)または明日(1)の予定をAppleScriptで取得"""
    offset = days_ahead * 86400
    script = f'''
tell application "Calendar"
    set t to current date
    set startDay to t + {offset}
    set hours of startDay to 0
    set minutes of startDay to 0
    set seconds of startDay to 0
    set endDay to startDay
    set hours of endDay to 23
    set minutes of endDay to 59
    set seconds of endDay to 59
    set out to ""
    repeat with cal in calendars
        try
            set evts to (every event of cal whose start date >= startDay and start date <= endDay)
            repeat with e in evts
                try
                    set eStart to start date of e
                    set hh to text -2 thru -1 of ("0" & (hours of eStart as string))
                    set mm to text -2 thru -1 of ("0" & (minutes of eStart as string))
                    set out to out & hh & ":" & mm & " " & (summary of e) & linefeed
                end try
            end repeat
        end try
    end repeat
    return out
end tell
'''
    out, err = run_applescript(script, timeout=25)
    if err == "timeout":
        return ["（カレンダー取得タイムアウト — Calendarアプリを一度開いてください）"]
    if not out:
        return ["（予定なし）"]
    events = sorted([e.strip() for e in out.split("\n") if e.strip()])
    return events if events else ["（予定なし）"]

def get_reminders():
    script = '''
tell application "Reminders"
    set out to ""
    set t to current date
    set startDay to t
    set hours of startDay to 0
    set minutes of startDay to 0
    set seconds of startDay to 0
    set endDay to t
    set hours of endDay to 23
    set minutes of endDay to 59
    set seconds of endDay to 59
    repeat with rl in every list
        try
            repeat with r in (every reminder of rl whose completed is false)
                try
                    set dd to due date of r
                    if dd >= startDay and dd <= endDay then
                        set out to out & (name of r) & linefeed
                    end if
                end try
            end repeat
        end try
    end repeat
    return out
end tell
'''
    out, err = run_applescript(script, timeout=20)
    if err == "timeout" or not out:
        return ["（リマインダーなし / 取得失敗）"]
    items = [x.strip() for x in out.split("\n") if x.strip()]
    return items if items else ["（なし）"]

# ===== 全体市況 =====

def get_index(symbol, is_fx=False):
    try:
        r = SESSION.get(
            f"https://query1.finance.yahoo.com/v8/finance/chart/{symbol}?interval=1d&range=5d",
            timeout=10
        )
        data = r.json()["chart"]["result"][0]
        closes = [c for c in data["indicators"]["quote"][0].get("close", []) if c]
        price = closes[-1]
        prev  = closes[-2] if len(closes) >= 2 else price
        change = price - prev
        pct    = (change / prev * 100) if prev else 0
        sign   = "+" if change >= 0 else ""
        if is_fx:
            return f"{price:.2f}円"
        return f"{price:,.0f}  ({sign}{change:,.0f} / {sign}{pct:.2f}%)"
    except:
        return "取得失敗"

# ===== 個別株 =====

def get_stock_detail(code):
    try:
        r = SESSION.get(
            f"https://query1.finance.yahoo.com/v8/finance/chart/{code}.T?interval=1d&range=5d",
            timeout=10
        )
        data = r.json()["chart"]["result"][0]
        meta   = data["meta"]
        closes = [c for c in data["indicators"]["quote"][0].get("close", []) if c]
        volumes = [v for v in data["indicators"]["quote"][0].get("volume", []) if v]
        price  = closes[-1]
        prev   = closes[-2] if len(closes) >= 2 else price
        change = price - prev
        pct    = (change / prev * 100) if prev else 0
        sign   = "+" if change >= 0 else ""
        volume = volumes[-1] if volumes else 0
        high52 = meta.get("fiftyTwoWeekHigh", 0)
        low52  = meta.get("fiftyTwoWeekLow", 0)
        dist_from_high = (price / high52 - 1) * 100 if high52 else 0
        return {
            "price": price, "change": change, "pct": pct, "sign": sign,
            "volume": volume, "high52": high52, "low52": low52,
            "dist_from_high": dist_from_high,
        }
    except Exception as e:
        return None

def get_kabutan_news(code):
    """株探からニュース取得"""
    try:
        r = SESSION.get(f"https://kabutan.jp/stock/news?code={code}", timeout=10)
        # ニュースタイトル抽出
        titles = re.findall(r'class="[^"]*s-news[^"]*"[^>]*>.*?<a[^>]*>([^<]{5,80})</a>', r.text, re.DOTALL)
        if not titles:
            titles = re.findall(r'<td class="[^"]*news[^"]*"[^>]*>\s*<a[^>]*>([^<]{5,80})</a>', r.text)
        if not titles:
            # より広いパターン
            titles = re.findall(r'href="/stock/news/detail/[^"]*"[^>]*>([^<]{5,80})<', r.text)
        return titles[:4] if titles else ["（ニュース取得失敗）"]
    except:
        return ["（ニュース取得失敗）"]

def get_shinkyu(code):
    """StockScope（株ビジョン）から信用残・需給データ取得"""
    try:
        r = SESSION.get(f"https://stockscope.app/issues/{code}", timeout=15)
        text = r.text

        buy_match  = re.search(r'信用買残[^\d]*?([\d,]+)株', text)
        sell_match = re.search(r'信用売残[^\d]*?([\d,]+)株', text)
        rate_match = re.search(r'信用倍率[^\d]*?([\d.]+)倍', text)

        if not (buy_match and sell_match):
            # JSON内のデータも試す
            buy_match  = re.search(r'"marginBuyBalance"\s*:\s*([\d]+)', text)
            sell_match = re.search(r'"marginSellBalance"\s*:\s*([\d]+)', text)
            rate_match = re.search(r'"marginRatio"\s*:\s*([\d.]+)', text)

        if buy_match and sell_match:
            buy  = buy_match.group(1).replace(",", "")
            sell = sell_match.group(1).replace(",", "")
            rate = rate_match.group(1) if rate_match else "?"

            buy_i  = int(buy)
            sell_i = int(sell)
            rate_f = float(rate) if rate != "?" else None

            # 需給コメント生成
            if rate_f:
                if rate_f >= 10:
                    comment = "⚠️ 信用倍率が高く売り圧力リスクあり"
                elif rate_f >= 5:
                    comment = "⚡ 信用倍率やや高め、需給悪化に注意"
                elif rate_f >= 2:
                    comment = "✅ 信用倍率は標準的"
                else:
                    comment = "🔵 信用売り優勢（売りが多い）"
            else:
                comment = ""

            return [
                f"信用買残: {int(buy_i):,}株 / 信用売残: {int(sell_i):,}株 / 信用倍率: {rate}倍",
                comment,
            ]
        return ["（需給データ取得失敗）"]
    except Exception as e:
        return [f"（需給データ取得失敗: {e}）"]

def make_stock_analysis(stock, detail, shinkyu_lines, news_titles):
    """保有株の考察テキストを生成"""
    if not detail:
        return ["（データ取得失敗）"]

    lines = []
    p_str = f"{int(detail['price']):,}円  {detail['sign']}{detail['change']:.0f}円（{detail['sign']}{detail['pct']:.2f}%）"
    lines.append(f"株価: {p_str}")
    lines.append(f"出来高: {int(detail['volume']):,}株")
    lines.append(f"52週レンジ: {int(detail['low52']):,}〜{int(detail['high52']):,}円（高値比 {detail['dist_from_high']:.1f}%）")

    # 価格ポジションコメント
    if detail["dist_from_high"] < -25:
        lines.append("📉 高値から25%超下落。底値圏を探る局面")
    elif detail["dist_from_high"] < -15:
        lines.append("📊 調整局面。押し目か下落継続か見極めが必要")
    elif detail["dist_from_high"] < -5:
        lines.append("🔄 高値付近。上値重いか再挑戦かの分岐点")
    else:
        lines.append("🚀 52週高値圏。強いトレンド継続中")

    # 出来高コメント
    return lines

# ===== プロジェクト進捗 =====

def get_project_status():
    return [
        ("T1", "LifeOS構築",      "ヒアリング継続中"),
        ("T2", "NOTE収益化",      "エンタメ記事AI量産・有料記事 → 着手前"),
        ("T3", "アプリリリース",   "SmartCalendar / Developer Account取得待ち"),
        ("T4", "朝のブリーフィング","✅ 毎朝6:30自動更新稼働中"),
    ]

# ===== メイン =====

def main():
    today = date.today()
    tmrw  = today + timedelta(days=1)
    now   = datetime.now()
    WD    = ["月","火","水","木","金","土","日"]
    wd    = WD[today.weekday()]
    wd2   = WD[tmrw.weekday()]

    print(f"ブリーフィング更新中... {today}")

    # 既存ブロック削除
    for block in get_children(PAGE_ID):
        notion_delete(f"blocks/{block['id']}")

    blocks = []

    # ヘッダー
    blocks.append(h1(f"📋 {today.strftime('%Y年%m月%d日')}（{wd}）のブリーフィング"))
    blocks.append(p(f"最終更新: {now.strftime('%H:%M')}　|　🤖 自動生成"))
    blocks.append(div())

    # ===== 天気 =====
    print("  天気取得中...")
    blocks.append(h2("🌤 天気（東京）"))
    for line in get_weather():
        blocks.append(li(line))
    blocks.append(div())

    # ===== カレンダー =====
    print("  カレンダー取得中...")
    blocks.append(h2(f"📆 今日の予定（{today.strftime('%m/%d')} {wd}）"))
    for e in get_events(0):
        blocks.append(li(e))

    blocks.append(h2(f"📅 明日の予定（{tmrw.strftime('%m/%d')} {wd2}）"))
    for e in get_events(1):
        blocks.append(li(e))

    blocks.append(h2("✅ 今日のリマインダー"))
    for r in get_reminders():
        blocks.append(li(r))
    blocks.append(div())

    # ===== 全体市況 =====
    print("  市況取得中...")
    blocks.append(h2("🌍 全体市況"))
    blocks.append(h3("🇯🇵 日本市場"))
    blocks.append(li(f"日経225:  {get_index('^N225')}"))
    blocks.append(li(f"TOPIX:    {get_index('^TOPX')}"))
    blocks.append(li(f"USD/JPY:  {get_index('USDJPY=X', is_fx=True)}"))
    blocks.append(h3("🇺🇸 米国市場（前日）"))
    blocks.append(li(f"NYダウ:   {get_index('^DJI')}"))
    blocks.append(li(f"NASDAQ:   {get_index('^IXIC')}"))
    blocks.append(li(f"S&P500:   {get_index('^GSPC')}"))
    blocks.append(div())

    # ===== 保有株 =====
    print("  保有株取得中...")
    blocks.append(h2("📈 保有株 詳細分析"))

    for stock in HOLDINGS:
        print(f"    {stock['name']}...")
        detail = get_stock_detail(stock["code"])
        news   = get_kabutan_news(stock["code"])
        shinkyu = get_shinkyu(stock["code"])

        blocks.append(h3(f"{stock['name']}（{stock['code']}）× {stock['shares']}株"))

        # 価格・考察
        analysis = make_stock_analysis(stock, detail, shinkyu, news)
        for line in analysis:
            blocks.append(li(line))

        # 需給
        blocks.append(p("⚖️ 需給（StockScope）"))
        for s in shinkyu:
            if s:
                blocks.append(li(s))

        # ニュース
        blocks.append(p("📰 最新ニュース（株探）"))
        for n in news:
            blocks.append(li(n))

    blocks.append(div())

    # ===== プロジェクト進捗 =====
    blocks.append(h2("🚀 プロジェクト進捗"))
    for tid, name, status in get_project_status():
        blocks.append(li(f"{tid}: {name} — {status}"))
    blocks.append(div())

    blocks.append(callout("毎朝6:30自動更新 / crontab / morning_briefing.py v3", "🤖"))

    append_blocks(PAGE_ID, blocks)
    print(f"✅ 完了（{len(blocks)}ブロック）")

if __name__ == "__main__":
    main()
