# LinguaFloat 0.5.0 — macOS 浮動語言助手原型

獨立 Swift 原生實作，未複製其他專案程式碼。不綁定 Codex 或任何 LLM CLI。macOS 14+，無第三方 Swift 套件依賴。

## 狀態（請先讀）

這仍是原型。現已在 Apple M1 Pro / 16 GB、macOS 26.2 上進行 Swift 編譯、回歸測試及本機 Ollama API 驗證。驗證範圍與量測見 [Ollama 診斷紀錄](docs/ollama-validation.md)。**Accessibility、OCR、IME、iTerm2/Herdr 與各 App 相容性尚未逐項驗收**；不要把「已實作」理解成完整 Mac 驗收。

## 已實作的程式路徑

- 選單列常駐、浮動面板、全域快捷鍵。
- Accessibility 讀取選取文字、焦點欄位、可取得的視窗文字樹。有限深度/節點，不保證整頁或隱藏內容。
- 互動框選截圖 + 本機 Vision OCR；取消/失敗後清除暫存圖片。
- 固定 Herdr pane ID 的最近 200 行讀取，透過 CLI 而非解析特定 agent 日誌。
- OpenAI 相容 chat/completions 翻譯及同語言校正；也可指定 Ollama 的相容端點。
- API Key 存鑰匙圈；模型、端點等設定存 UserDefaults。
- 0.3.0 以跨 App 使用為中心重做介面（`Sources/LinguaFloat/Views.swift`、`Controller.swift`）。啟動只進選單列，不彈視窗；第一次使用（未設模型或未授權）才開「開始使用」視窗，內含「測試連線」。
- 快速面板：熱鍵觸發後出現在選取文字正下方（放不下就翻到上方，拿不到位置就靠近滑鼠），寬 400、高度隨內容。版面依序為來源列（來源 App、擷取方式、字數、模式、釘住、⋯）、結果（主角，串流逐字顯示）、折疊的原文（⌘E 展開編輯）、動作列。↩ 複製並關閉、Esc 關閉（處理中則取消）、⌘1／⌘2 換模式重跑、⌘⇧C 只複製。按 Esc 或點到其他 App 就消失，並把焦點還給原本的 App。
- 工作台：按 📌 或從選單列「開啟語言助手」進入，置中、可拖曳、可調整大小、原文編輯器常開（⌘↩ 執行），不會自動消失。
- 取代：校正或翻譯選取片段後可「取代選取文字」（透過 AXSelectedText 改寫選取範圍），焦點欄位整欄則「套用至原欄位」。套用前核對原文與程序。
- 整個視窗的擷取（沒有選取、沒有焦點欄位時）先顯示字數與確認，按 ↩ 才送出，避免本機模型無端處理一大段選單文字。
- 擷取失敗時依原因提供後援：授予權限、使用剪貼簿（只在你點了才讀）、框選 OCR、手動輸入。
- 等待狀態只顯示「翻譯中／校正中」，超過 5 秒提示模型載入中；開始收到內容就直接顯示部分譯文。失敗時顯示原因與「重試」。期限秒數等細節留在設定。
- 0.5.0 桌面小幫手（`Sources/LinguaFloat/Pet.swift`，預設開啟）：螢幕角落一個可拖曳的小圖示，所有結果、進度、失敗與確認都以旁邊的泡泡顯示，泡泡與小幫手永遠不會成為 key window，所以你在別處打字不會被打斷。點小幫手才打開完整面板並取得鍵盤焦點；泡泡上有複製、取代／套用、打開。關掉小幫手後，熱鍵與選取翻譯會直接打開面板，但跟隨模式觸發的結果一律不搶焦點。
- 0.4.0 跟隨模式（`Sources/LinguaFloat/Follow.swift`）：開啟後只看前景視窗，用 Accessibility 通知加 1 秒輪詢。三種觸發：選取文字停 0.6 秒就翻譯並彈出；可編輯欄位停止輸入 1.5 秒自動處理（中文翻成「第二語言」，其他語言校正）；終端機（iTerm2、Terminal 等）出現新輸出且安靜 2 秒後只翻新增的列。後兩者預設只亮選單列圖示，面板開著時才直接更新。密碼欄位一律排除，可用 bundle ID 排除 App。Chromium 與 Electron App 會被要求開放內容的 Accessibility 樹。
- 終端機特別處理：畫面是一整塊文字，依游標所在列與 pane 分隔線切出目前這一格；輸入框靠提示符（❯ > $ %）辨識，agent 的進度列（例如「Ruminating… (10m 5s)」）會被濾掉；游標列以下永遠不算新內容。不會對終端機寫字；在 Herdr 可用「送到 Herdr」把結果以 `herdr pane send-text` 放進目前聚焦的窗格，不按 Enter。
- 文法筆記：一般模型以結構化欄位回傳每一處修改（原文、修正、原因），App 自己排成「原文」→「修正」：原因，預設展開。用結構而不是叫模型排版，是因為 JSON schema 嚴格模式下模型若在字串裡打英文引號會把筆記截斷。本機端點會送 `reasoning_effort: none`，否則 Qwen3 這類模型會先思考十幾秒。
- 翻譯專用模型（設定 → 模型服務）：填入 HY-MT1.5、TranslateGemma 之類的純翻譯模型後，翻譯模式改走它，用 Hunyuan 文件的簡單提示詞、不要求 JSON、沒有學習筆記；校正與筆記仍用一般模型。保護 token 遮罩與截斷檢查照舊。「測試連線」會一併確認兩個模型都在清單裡。
- 設定為分組表單，含測試連線、完成後自動複製（預設關閉）、期限範圍即時檢查、鑰匙圈儲存回饋及權限狀態。原生控制項、深淺色皆可用。0.4.x 移除了舊的「允許清單自動校正」，跟隨模式的「打字就跟」完全取代它。
- 替換前核對原文與程序；不合成 Enter、不操作 shell、不自動貼回終端機。
- fenced code、inline code、URL、常見路徑與 $/% 指令行遮罩；模型遺失或重複 token 則拒絕結果。此為啟發式保護，不能辨識所有程式語法。

## 在 Mac 編譯

先安裝 Xcode command-line tools（或完整 Xcode），在這個資料夾開終端機：

```sh
./scripts/build-app.sh
open dist/LinguaFloat.app
```

腳本先執行 `swift test` 再建置 .app；未 notarize，供本機開發使用。若鑰匙圈有 Apple Development 憑證會自動用它簽名，也可用 SIGN_IDENTITY 指定。**ad-hoc 簽名會讓「輔助使用」「螢幕錄製」授權綁定單一次建置，重建後系統設定雖顯示開啟、App 實際無權限**；遇到時在系統設定移除 LinguaFloat 後重新加入。也可用 Xcode 開啟 Package.swift。

## 設定與使用

1. 開設定，填入模型名稱。預設服務是 `http://127.0.0.1:11434/v1`，需自行啟動 Ollama 並下載模型；本程式不會安裝服務或模型。要快又準的翻譯可另外填「翻譯專用模型」，例如 `ollama pull translategemma:4b` 或 `demonbyron/HY-MT1.5-7B`。
2. 雲端相容服務填 base URL（含 /v1）及 API Key；結果必須支援依提示回傳 JSON 的 text/explanation 欄位。原型不自動修復非 JSON 回覆。
   服務需支援標準 `chat/completions` SSE 串流。請求期限預設 300 秒，可設 10–1800 秒；開始接收後顯示字元數與經過時間。輸出上限為 4096 token，達上限或未正常結束時拒絕結果，不會套用部分文字。JSON schema 預設僅在本機 11434 端點啟用，可手動關閉；其他相容服務預設只使用 JSON 提示詞，也可自行啟用 schema。
3. 按「授予輔助使用」，到系統設定核准。OCR 另外需要螢幕錄製權限。
4. 在其他 App 選取文字後按 Option+Shift+L 翻譯、Option+Shift+C 校正。結果出現在桌面小幫手旁的泡泡，鍵盤焦點留在你原本的 App；點小幫手打開完整面板（↩ 複製並關閉，Esc 關閉，可取代時有「取代選取文字」或「套用至原欄位」）。
5. 想不按熱鍵：在設定或選單列開「跟隨前景視窗」，並視需要改「第二語言」（預設 English）。
6. iTerm2 等不暴露選取文字的 App：先 ⌘C，面板會提供「使用剪貼簿」（只在你點了才讀）；畫面上的文字可用 ⋯ 選單的框選 OCR。原型不會偷偷讀剪貼簿。
6. Herdr：用 `which herdr` 確認執行檔，`herdr pane list` 找 pane ID，填到設定，再按「Herdr 窗格」。目前固定 pane，不自動判斷焦點、不跟隨輸出。使用 `pane read ID --source recent --lines 200`，需相容的 Herdr 版本。
7. 在 TextEdit 測「打字就跟」：開跟隨模式，在純文字文件輸入英文，停 1.5 秒後選單列圖示亮起，按熱鍵看建議。「套用至原欄位」會整欄替換，可能失去富文字格式。
8. 終端機提示詞：先選取後校正或貼到草稿區，再點建議複製，自行貼回。**尚未實作任意 CLI 正在編輯的提示詞自動監測或精準替換。**

## 仍待開發

- 終端機輸入框的辨識仍是啟發式（提示符與分隔線）；非 ❯ > $ % 的提示符需要調整，多窗格並排時靠游標欄位判斷。
- 終端機不寫回：只能複製或「送到 Herdr」。可安全回填的終端機協定尚無。
- IME 組字半截時跟隨模式可能多跑一次，靠「文字變了就作廢舊結果」處理，沒有真正的組字偵測。
- 瀏覽器全文擴充、長文切塊翻譯。
- 細粒度差異、撤銷保證、富文字保存、可設定快捷鍵。

## 驗收順序

1. macOS 編譯與核心測試通过。
2. 設定本機模型；手動草稿翻譯/校正，測模型 JSON 格式錯誤。
3. TextEdit 授權/拒絕、選取、全文讀取、修改後舊建議拒絕、密碼欄位排除。
4. iTerm2 與 Herdr：多窗格目標、OCR 取消/拒絕權限、中文英文/路徑/程式碼混排。
5. 網路斷線、取消後晚到結果、模型改動保護 token、超過 24,000 字元限制。

本機 Ollama 整合測試（只送出固定合成文字；需要已下載 `qwen2.5:14b`）：

```sh
LINGUAFLOAT_LIVE_TEST=1 swift test --filter ModelClientTests/testLive
```

舊版非串流行為重現：`python3 scripts/probe-ollama.py`，較長且不重複的文字為 `python3 scripts/probe-ollama.py --long`。後者依序測試 60 秒與 240 秒期限；不輸出完整模型文字或 API Key。

API 來源：
- https://herdr.dev/docs/socket-api/
- https://developer.apple.com/documentation/applicationservices/axuielement_h
- https://developer.apple.com/documentation/vision/vnrecognizetextrequest
- https://developer.apple.com/documentation/appkit/nspanel

文字僅在手動觸發或你開啟跟隨模式時傳到設定的服務。無內容日誌、無遙測；螢幕截圖在 OCR 後刪除。翻譯引擎與你終端機裡使用哪個 LLM CLI 相互獨立。
