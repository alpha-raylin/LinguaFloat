# Ollama 連線診斷（2026-10-03）

## 環境與原始狀態

- Apple M1 Pro（8 核）、16 GB RAM，macOS 26.2。
- Ollama 0.24.0，Homebrew `ollama serve`。
- 已安裝 `qwen2.5:14b`（Q4_K_M，8.99 GB）及 `qwen2.5:7b`；本次全部使用 14b。
- 初次 `/api/ps` 沒有載入模型；測試後 14b 的 `size` 與 `size_vram` 皆為 9,311,758,336 bytes，context length 4096。
- 實際 App 設定為 `http://127.0.0.1:11434/v1`、`qwen2.5:14b`、繁體中文；未讀出或記錄 API Key。
- 原本執行的 App 是本專案 `dist/LinguaFloat.app`，版本 0.1.0 / build 1。檔案時間早於目前原始碼，不可用它代表此次修改。
- 原 binary SHA-256：`35f6099d3bac844675d198aa8d3f8725d84b53bb53f41b8d16293d7471452203`。
- 專案不是 Git checkout，未找到適用的 AGENTS.md；以現有檔案直接修改，保留既有 AppKit/Capture 實作。

## 舊請求的量測

以合成文字、相同端點與模型，沿用 App 的 system prompt、遮罩 token 形式，以及 `stream: false`、未設 `max_tokens`／`response_format` 的 JSON body。

|案例|輸入字元|回覆 content 字元|耗時|結果|
|---|---:|---:|---:|---|
|最短請求，初始無模型載入|6|2|20.47 秒|HTTP 200，stop，依指令回覆 OK|
|短句翻譯|35|41|2.41 秒|HTTP 200，合法 JSON|
|遮罩文字校正|81|154|7.23 秒|HTTP 200，合法 JSON|
|重複段落|1908|118|9.20 秒|HTTP 200，但模型縮短重複內容，不適合作長文延遲證據|
|不重複長文，60 秒期限|5771|未收到完整回覆|60.02 秒|TimeoutError，沒有 HTTP 回應|
|同一長文，240 秒期限|5771|1824|128.15 秒|HTTP 200，stop，合法 JSON，1327 completion tokens|

另以 curl 驗證 `/v1/chat/completions` 最短請求，HTTP 200，回覆 OK，287 bytes。該次與長文測試重疊，耗時 48.93 秒含等待，不當成獨立生成速度。

**已證實的失敗機制：非串流請求必須等完整生成才收到資料，60 秒期限小於此模型在這台機器處理該長文的 128 秒。** 服務可達、模型可用，短句與校正可回傳合法 JSON；此逾時發生在 JSON 解碼之前。初次短請求約 20 秒也不足以單獨解釋 60 秒逾時。沒有取得使用者原始逾時文字，因此不宣稱每次歷史逾時都是相同原因。

第一輪真實 Swift 串流測試（尚未加入 schema）另發現獨立問題：短句 2.55 秒、遮罩校正 7.69 秒成功，長文約 119 秒正常結束但不符合 text/explanation JSON 契約，測試正確拒絕結果。因此最終也加入可控制的 JSON schema，而非僅延長等待時間。

## 修正與安全邊界

- 改用 SSE 串流接收並顯示進度；預設整體請求期限 300 秒，可設定 10–1800 秒，URLSession 同時設定 request/resource timeout。
- 設定 `max_tokens: 4096`；`finish_reason: length` 即使內容可解析仍拒絕。缺少正常 stop 或 `[DONE]`、格式错误、保護 token 遺失／重複皆拒絕。
- `response_format: json_schema` 僅對 loopback host 的 11434 port 自動啟用，要求 text/explanation 字串欄位。設定可強制啟用或關閉；其他端點預設不附加此參數。其他服務需提供標準 SSE chat/completions。
- 分開呈現不可連線、HTTP status、真正逾時、連線中斷、取消、輸出截斷與 JSON 格式錯誤。不記錄完整待處理文字或伺服器錯誤 body。
- 自動校正以程序、文字和 AX 元素辨識來源；同一觀察值只送一次，離開有效來源會取消自動請求，觀察到新文字不再取消手動請求。取消與進度／完成皆核對 generation，草稿編輯也會使舊結果失效。
- 面板原本已設 `isReleasedWhenClosed = false`，沒有證據顯示被釋放。補上 `applicationShouldHandleReopen` 與關閉最後視窗仍常駐的明確行為。

## 驗證與限制

固定 fixture 測試涵蓋請求遮罩、Unicode 串流重組、截斷、非正常結束、JSON 錯誤、保護 token、HTTP 404、連線失敗、逾時與取消。Controller 測試涵蓋取消後晚到結果、草稿編輯、自動校正去重及面板重開。

真實 API 整合測試直接呼叫正式 ModelClient，使用短句、含 `git status` 的遮罩校正，以及相同 5771 字元長文；不需 Accessibility 權限。

最終 schema + 串流的實測結果：

|案例|輸入字元|還原後 text 字元|完成耗時|首次內容進度|進度更新次數|
|---|---:|---:|---:|---:|---:|
|短句翻譯|35|8|2.19 秒|0.70 秒|6|
|含程式碼校正|54|56|7.46 秒|1.24 秒|23|
|不重複長文|5771|1764|145.85 秒|10.47 秒|432|

三者皆通過正式 HTTP 成功檢查、正常 SSE 結束、JSON 欄位驗證與保護 token 還原。這裡的輸出長度是 `text`，與舊測試記錄整個 JSON content 的長度不同。串流未讓模型變快；它提供生成中的進度，配合有上限的整體期限與格式約束使本次長文完成。

- `swift test` 最終共 16 項：14 項通過、2 項需明確啟用的 live tests 跳過；兩項 live tests 已另行啟用並通過。
- 真實連線中途取消可立即返回；10 秒 resource timeout 在持續串流下仍確實逾時，整項取消／期限測試耗時 10.76 秒。
- `scripts/build-app.sh` 的測試、release build、ad-hoc 簽名成功；`codesign --verify --strict` 通過。
- 最終 App 為 `dist/LinguaFloat.app`，0.1.1 / build 2，SHA-256：`99059edf68a8196bc8f99644242124f0f3dcc421478bc8bec2ccf633a6e2b123`。
- 已正常結束旧程序並啟動上述 App，核對完整程序路徑。UI 合成草稿翻譯顯示完成（2 秒），含程式碼的校正顯示完成（15 秒）。未按 Enter、未執行草稿、未套用到其他 App。
- 實際按關閉按鈕後視窗數為 0、選單列仍有 1 個；`open` 相同 App 後視窗恢復且 PID 不變。另驗證選單列的「開啟語言助手」可恢復面板。

修改檔案：`Sources/LinguaFloat/ModelClient.swift`、`Settings.swift`、`Controller.swift`、`App.swift`；`Package.swift`、`Info.plist`；新增 `Tests/LinguaFloatTests/ModelClientTests.swift`、`ControllerTests.swift`、`scripts/probe-ollama.py`；更新 `README.md` 與本紀錄。原有 TextPolicy 與 Capture 未改動。

重啟（目前已執行新版；以下供日後使用）：

```sh
osascript -e 'tell application "/Users/alpha/Downloads/LinguaFloat/dist/LinguaFloat.app" to quit'
open /Users/alpha/Downloads/LinguaFloat/dist/LinguaFloat.app
```

仍未實作長文分段，超過 24,000 字元拒絕。模型可能漏譯一般文字；JSON 正常與保護 token 檢查不能保證翻譯完整性。游標旁泡泡、終端機編輯中提示詞擷取／替換、Herdr 焦點同步、IME、OCR 及富文字安全等原型限制不變。
