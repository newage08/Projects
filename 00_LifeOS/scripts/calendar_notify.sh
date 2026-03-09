#!/bin/bash
# カレンダー通知スクリプト
# 予定の10分前にmacOS通知を出す

NOTIFY_BEFORE=10  # 何分前に通知するか
ALREADY_NOTIFIED_FILE="/tmp/calendar_notified.txt"

touch "$ALREADY_NOTIFIED_FILE"

events=$(osascript << 'EOF'
tell application "Calendar"
  set today to current date
  set todayStart to today - (time of today)
  set todayEnd to todayStart + (23 * hours + 59 * minutes)
  set result to ""
  repeat with c in every calendar
    set evs to (every event of c whose start date >= todayStart and start date <= todayEnd)
    repeat with e in evs
      set t to start date of e
      set result to result & (summary of e) & "|" & ((time of t) div 60) & "\n"
    end repeat
  end repeat
  return result
end tell
EOF
)

now_minutes=$(date +"%H * 60 + %M" | bc)

while IFS='|' read -r title start_min; do
  [[ -z "$title" ]] && continue

  diff=$((start_min - now_minutes))

  if [ "$diff" -eq "$NOTIFY_BEFORE" ]; then
    key="${title}_${start_min}"
    if ! grep -q "$key" "$ALREADY_NOTIFIED_FILE"; then
      hour=$((start_min / 60))
      min=$((start_min % 60))
      time_str=$(printf "%02d:%02d" $hour $min)

      osascript -e "display notification \"${time_str}から「${title}」があるで！そろそろ出かける時間やで。\" with title \"📅 予定リマインド\" sound name \"Ping\""

      echo "$key" >> "$ALREADY_NOTIFIED_FILE"
    fi
  fi
done <<< "$events"

# 日付変わったらログリセット
today=$(date +"%Y%m%d")
last=$(cat /tmp/calendar_notify_date.txt 2>/dev/null)
if [ "$today" != "$last" ]; then
  > "$ALREADY_NOTIFIED_FILE"
  echo "$today" > /tmp/calendar_notify_date.txt
fi
