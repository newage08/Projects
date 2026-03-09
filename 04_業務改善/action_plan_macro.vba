Sub CreateActionPlan()
    Dim ws As Worksheet
    Dim lastRow As Long
    Dim i As Long
    
    ' 新しいシートを追加
    Set ws = ThisWorkbook.Sheets.Add
    ws.Name = "アクションプラン"
    
    ' 表のヘッダーを設定
    ws.Range("A1").Value = "大項目"
    ws.Range("B1").Value = "具体的施策"
    ws.Range("C1").Value = "担当者"
    ws.Range("D1").Value = "優先度"
    ws.Range("E1").Value = "期限"
    ws.Range("F1").Value = "進捗状態"
    ws.Range("G1").Value = "備考"
    
    ' 4月〜3月のガントチャートヘッダー（H1〜S1）
    Dim startCol As Integer
    startCol = 8
    For i = 1 To 12
        Dim monthNum As Integer
        monthNum = (i + 2) Mod 12
        If monthNum = 0 Then monthNum = 12
        
        ws.Cells(1, startCol + i - 1).Value = monthNum & "月"
        ws.Cells(1, startCol + i - 1).ColumnWidth = 4
    Next i
    
    ' ヘッダーの装飾（色付けと太字）
    With ws.Range("A1:S1")
        .Interior.Color = RGB(0, 51, 102) ' 濃い青背景
        .Font.Color = RGB(255, 255, 255) ' 白文字
        .Font.Bold = True
        .HorizontalAlignment = xlCenter
    End With
    
    ' サンプルデータを1行だけ追加（コピペ用）
    ws.Range("A2").Value = "新規開拓"
    ws.Range("B2").Value = "〇〇業界へのテレアポ月50件"
    ws.Range("C2").Value = "自分"
    ws.Range("D2").Value = "高"
    ws.Range("E2").Value = "毎月末"
    ws.Range("F2").Value = "未着手"
    
    ' 罫線を引く（20行目まで）
    With ws.Range("A1:S20")
        .Borders.LineStyle = xlContinuous
    End With
    
    ' セル幅の自動調整（A〜G列）
    ws.Columns("A:G").AutoFit
    
    MsgBox "アクションプラン表のフォーマットが作成されました！", vbInformation, "完了"
End Sub
