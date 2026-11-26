<p align="center">
  <a href="https://zigzagbrowser.com"><img src="../../../docs/brand/readme-hero.jpg" width="960" alt="Zigzag：用起來舒服，輕得像沒有。輕量的 Mac 瀏覽器，免費開源。一個分割顯示的 Zigzag 視窗，Fonts In Use 和 Grilli Type 並排，側邊欄裡是空間和已固定分頁。"></a>
</p>

<div align="center">

<p align="center"><sub><a href="../../../README.md">English</a> | <a href="README.zh-Hans.md">简体中文</a> | 繁體中文 | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.es.md">Español</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | <a href="README.nl.md">Nederlands</a> | <a href="README.pl.md">Polski</a> | <a href="README.tr.md">Türkçe</a></sub></p>

本文是 README.md 的翻譯；如有出入，以英文版為準。

</div>

<p align="center">
  <a href="https://zigzagbrowser.com/download"><b>下載 Mac 版</b></a><br>
  <sub>或是 <code>brew install --cask zigaowang/tap/zigzag</code></sub><br>
  <sub>免費開源。需要 macOS 15.4 或以上版本。</sub>
</p>

<p align="center">
  分頁放在側邊欄裡，依空間分組。用 Swift 在 WebKit 上寫成的原生 Mac App，<br>
  安裝後大約 35 MB，不需要帳號，也沒有遙測。
</p>

## 我為什麼做它

你好，我是 Zigao，上海的一名高中生。我每天都用 Arc。The Browser Company 宣布 Arc 會在 12 月 22 日停止營運時，我實在不想回到分頁排在上方的瀏覽器，而試過的其他瀏覽器，不是 Chromium 的分支，就是圍繞 AI 打造的。所以我自己做了一個，從那之後它就一直是我的主力瀏覽器。

**為什麼用 WebKit，不用 Chromium？** 其實我一開始是 fork 了 Helium。原始碼大約 100 GB，在我的 Mac 上每次建置要 3 到 4 個小時，我一個人根本維護不下去。WebKit 本來就內建在 macOS 裡，更省電、更省記憶體，安全性修正也由 Apple 隨 macOS 更新一起推出。你一樣可以用 Chrome 延伸功能，直接從 Chrome 線上應用程式商店安裝。

**為什麼不用 Zen 或 Orion？** 開始做之前這兩個我都試過，都很不錯。Zen 以 Firefox 為基礎，用的是 Firefox 延伸功能，在我看來也不太像 Mac App。Orion 比較接近，但它不開源。我想要的是：用起來像 Arc，感覺是原生的，開源，還能執行我的 Chrome 延伸功能。

## 從 Arc 過來

**你的 Arc 可以一起帶過來。** 選擇「檔案 › 從其他瀏覽器匯入…」，選 Arc，你的空間、已固定分頁、固定的資料夾、收藏、瀏覽記錄、密碼、登入狀態和延伸功能都會過來。開啟的分頁也可以一起過來，連分割顯示也在，點到時才載入；不勾選「開啟的分頁」就從頭開始。如果你的空間分散在多個 Arc 個人資料裡，每個 Arc 個人資料都會變成一份獨立的 Zigzag 個人資料。

**1Password 可以用。** 在 Zigzag 裡從 Chrome 線上應用程式商店安裝它，和在 Arc 裡一樣。它會和 1Password App 連線。第一次使用時，在 1Password 的「設定 › 瀏覽器」裡加入 Zigzag。Bitwarden 也可以用。

**它不會被關掉。** 沒有帳號，Zigzag 也不依賴我的伺服器。我託管的只有更新來源和一份很短的廣告阻擋修正清單，就算它們不見了，Zigzag 也照樣能用。[隱私](#隱私)裡列出了 Zigzag 自己會連線的所有地方。

## 看看它

<p align="center">
  <img src="../../../docs/spaces.gif" width="960" alt="在 Zigzag 的三個空間之間切換，每個空間都有自己的顏色和分頁">
</p>

<table>
  <tr>
    <td width="50%"><img src="../../../site/assets/clips/split.jpg" alt="分割顯示：Fonts In Use 和 Grilli Type 並排"><br><b>分割顯示。</b>把分頁拖到網頁上，就能在旁邊開啟，最多同時四個。</td>
    <td width="50%"><img src="../../../docs/all-tabs.jpg" alt="三個空間裡的所有分頁以卡片顯示"><br><b>所有分頁一覽。</b>⇧⌘\ 顯示所有空間。打字就能篩選。</td>
  </tr>
  <tr>
    <td width="50%"><img src="../../../site/assets/win-peek.webp" alt="一篇關於字體排印的維基百科文章，浮在開啟它的網頁上"><br><b>Zigzag Mini。</b>按住 Shift 點一下連結，先看一眼，不會失去目前的位置。</td>
    <td width="50%"><img src="../../../site/assets/clips/reader.jpg" alt="閱讀器裡的一篇 The Public Domain Review 文章"><br><b>閱讀器。</b>長篇文章，沒有雜亂的東西。</td>
  </tr>
</table>

<p align="center"><sub>更多動態示範，請見 <a href="https://zigzagbrowser.com">zigzagbrowser.com</a>。</sub></p>

## 它能做什麼

| | |
|---|---|
| **空間** | 每個空間都有自己的顏色、圖示、已固定分頁和資料夾。在側邊欄上滑動，或把滑鼠滾輪往側邊撥一下，就能切換。 |
| **收藏** | 最常用的網站排成圖示，顯示在每個空間上方。任何分頁、已固定分頁或收藏都可以換上自己的表情符號或符號。 |
| **個人資料** | 把工作和生活分開。每份個人資料都有自己的延伸功能、登入狀態、瀏覽記錄和收藏，每個空間都屬於其中一份。 |
| **在空間中開啟的網站** | 在網站設定或「設定 › 空間」裡幫網站選一個空間，它的連結不管從哪裡來（其他 App、⌘T 或另一個空間），都會在那裡開啟，就像 Arc 的 Air Traffic Control。路徑也可以分到各自的空間，例如 `github.com/org1` 到一個，`github.com/org2` 到另一個。使用獨立個人資料的空間，效果就像 Firefox 的容器。 |
| **指令列** | ⌘T 或 ⌘L。可以找開啟的分頁、瀏覽記錄和網站。輸入 `you`，按 Tab，就在 YouTube 裡搜尋了。把指令列拖到視窗裡的任意位置，之後它就會在那裡開啟。 |
| **分頁群組** | 選幾個分頁，選擇「將分頁分組」，它們就會變成側邊欄裡的一個資料夾，可以一起展開、收起、重新命名和移動。把分頁往右拖，就會巢狀放到上面那個分頁底下；往左拖，就會移出來。 |
| **即時資料夾** | 一個固定的資料夾，自動從訂閱來源、網站或 GitHub 填入內容：提取要求、請你審查的提取要求，或你的儲存庫裡尚未關閉的議題和提取要求。新網頁會帶一個小圓點。 |
| **分割顯示** | 最多四個分頁：把分頁拖到網頁邊緣佔一半，拖到角落佔四分之一。拖動網頁上方的細條可以移動它，固定分割顯示就能留住它。 |
| **視窗** | 把分頁拖到另一個視窗，它會原封不動地移過去，不會重新載入。開啟「設定 › 分頁 › 視窗分享空間的分頁」，同一個空間的所有視窗就會列出相同的分頁，和 Arc 一樣。側邊欄可以放在左邊或右邊。 |
| **網頁 App** | 「安裝為 App」會把網站變成一個獨立的 App，出現在「應用程式」資料夾、Dock 和 ⌘Tab 裡，工具列是網站的顏色。 |
| **小播放器** | 影片播放時離開那個分頁，影片會跟著你，進到一個小播放器裡。可以從任一邊緣調整大小，放在任何地方，甚至放到視窗外面、蓋在其他 App 上。不想要的話，可以從它的選單裡關掉。切換到其他 App 時，影片會以子母畫面浮在上面。 |
| **串流** | 受保護的音樂和影片和在 Safari 裡一樣可以播放，用的是 WebKit 的 FairPlay Streaming：Spotify 網頁播放器可以用，其他支援 Safari 的服務也可以。 |
| **正在播放** | 在背景發出聲音的每個分頁，都會在側邊欄底部有一張卡片，最多三張，可以暫停或靜音。 |
| **所有分頁** | ⇧⌘\ 一次顯示所有空間。打字就能篩選，也可以把分頁拖到另一個空間。 |
| **清除** | 關掉你已經沒在看的分頁，留下正在用的。把指標移到它上面，就能看到會關掉哪些。分割顯示要嘛整個留下，要嘛整個關掉。復原就能找回來。 |
| **Zigzag Mini** | ⌃⌘N 開啟一個小視窗，用來快速看一個網頁，⌘O 把它移到瀏覽器視窗裡。按住 Shift 點一下連結，或選擇「在 Zigzag Mini 中開啟連結」，它會在一個浮在視窗上的 Zigzag Mini 裡開啟；⌘O 把它放進一個分頁，就在你點的那個旁邊，Esc 關閉它。其他 App 裡的連結也會在 Zigzag Mini 裡開啟，就像 Little Arc（可以在「設定 › Zigzag Mini」裡關掉），「在 Zigzag Mini 中開啟」可以把一個分頁移進去。 |
| **密碼** | 存在 Mac 的鑰匙圈裡，由 iCloud 鑰匙圈同步。支援觸控 ID、密碼產生器，還會檢查強度不足和重複使用的密碼。通行密鑰也可以用。 |
| **深色網頁** | 用 Dark Reader 的引擎把淺色網站畫成深色，帶著它對數千個網站的修正，所以照片顏色不會跑掉。本身有深色外觀的網站維持原樣。想更暗的話，可以用純黑。可以對所有網站開啟，也可以逐一網站開啟。 |
| **廣告阻擋** | 內建且預設開啟：大約 130,000 條 EasyList、EasyPrivacy 和 EasyList China 規則，編譯成 WebKit 內容規則列表，再加上會自動更新的 uBlock Origin 過濾清單。 |
| **WebRTC** | 開啟「防止 WebRTC 洩漏 IP 位址」後，你使用代理伺服器或 VPN 時，網站就無法透過 WebRTC 得知你的真實 IP 位址。在你允許的網站上通話照常，網站在被阻擋時嘗試使用 WebRTC，會告訴你，並提供「為此網站允許」。 |
| **Cookie 彈出式視窗** | 幫你拒絕，從不接受，用的是 DuckDuckGo 的 Autoconsent 規則。想自己回答的話，可以對所有網站或單一網站不處理。 |
| **網站設定** | 每個網站一個面板：縮放、權限（相機、麥克風、位置、通知、彈出式視窗、開啟 App、螢幕分享、WebRTC），每一項都可以設為詢問、允許或阻擋，還有開關 JavaScript、憑證、延伸功能，以及深色網頁、廣告阻擋和 Cookie 彈出式視窗的開關。網站要求其中某一項時，會在網頁上方的一張卡片裡詢問，可以只允許這一次或一律允許，你拒絕過的網站就不會再問。 |
| **Boosts** | 「隱藏元素」可以隱藏網站上你不想要的部分，例如橫幅或側欄，「編輯樣式…」可以幫網站加上你自己的 CSS。兩個都在網站設定的 ⋯ 選單裡，並且跟著網站保留。 |
| **開發者模式** | 給你正在做的網站用，一開始就包含 `localhost`：帶錯誤計數的主控台、檢查元素、裝置尺寸、淺色和深色、列印樣式、關閉 JavaScript、影像或樣式、換用其他使用者代理，還有一個 QR 碼，用手機開啟這個網頁。 |
| **延伸功能** | 來自 Chrome 線上應用程式商店，商店本身的按鈕會顯示「新增到 Zigzag」。1Password、Bitwarden、Dark Reader、Tampermonkey 和大多數熱門延伸功能都可以用；不能用的請見下文。 |
| **匯入** | 從 Arc、Chrome、Safari、Dia、Edge、Brave、Vivaldi、Opera、Comet、Helium、Yandex、Whale、Chromium、Thorium、Firefox、Zen 和 Orion 匯入書籤、瀏覽記錄、密碼、登入狀態和延伸功能。 |
| **下載項目** | 把某種類型的檔案存到專屬的資料夾，或在 PDF 這類安全檔案儲存後直接開啟。規則可以把連結或下載項目轉交給 App、指令碼或 aria2 這類下載管理器，轉交前會先問你。請見 [docs/download-rules.md](../../../docs/download-rules.md)。 |
| **自動化** | AppleScript、捷徑和 `osascript` 可以列出和開啟分頁、讀取網頁，寫法和 Safari、Chrome 接受的一樣。請見 [docs/automation.md](../../../docs/automation.md)。 |
| **AI App** | 預設關閉，開啟後，你 Mac 上的 AI App 可以透過 MCP 使用你的分頁，但絕不會碰到私密瀏覽視窗和密碼。請見 [docs/automation.md](../../../docs/automation.md#ai-apps-mcp)。 |
| **你的資料** | 「檔案 › 匯出你的資料…」會把書籤存成任何瀏覽器都能匯入的標準 HTML 檔案，還有一份完整的 Zigzag 備份，可以在另一台 Mac 上還原。 |
| **語言** | 英文、簡體中文、繁體中文、日文、韓文、德文、法文、義大利文、西班牙文、巴西葡萄牙文、俄文、荷蘭文、波蘭文和土耳其文。 |
| **還有** | 閱讀器、PDF 檢視器、接力到你的 iPhone、iPad 或另一台 Mac、截圖（區域、網頁的一部分或整個網頁，⇧⌘2）、裝置端翻譯、標出每個相符項目的網頁內尋找、帶「最近關閉」和最近七天的「瀏覽記錄」選單、預設網頁縮放、喜歡的話可以在網頁上方顯示網址列、子母畫面、私密瀏覽視窗、網頁檢查器。 |

## 還缺什麼

它是我每天用的瀏覽器，但 Zigzag 還很年輕，你會遇到 bug。Arc 使用者會注意到的地方：

- 不能在 Mac 之間同步，也不能同步到 iPhone。密碼透過 iCloud 鑰匙圈同步；空間和分頁不會。
- 空間圖示不會從 Arc 帶過來，需要在 Zigzag 裡重新選。空間顏色會換成最接近的 Zigzag 顏色。
- 沒有 Easels 和 Notes，Boosts 只支援 CSS（隱藏元素和編輯樣式，沒有逐一網站的指令碼）。瀏覽器裡沒有內建 AI：只有你開啟後，AI App 才能透過 MCP 使用 Zigzag。
- 有幾個 Chrome 延伸功能 API 還沒有：分頁群組 API、除錯器設定、Chrome 本身的 Google 帳號登入（`identity.getAuthToken`），以及舊的阻擋請求的 webRequest。代理伺服器延伸功能可以設定固定的 HTTP、HTTPS 或 SOCKS5 代理伺服器，但不能用 PAC 指令碼，所以 FoxyProxy 的 Proxy by Patterns 模式無法使用。
- EasyList 和其他內建阻擋清單隨 Zigzag 一起更新，不會自己更新；只有 uBlock Origin 的清單會。
- 只支援 macOS 15.4 或以上版本。

## 它是怎麼做的

Zigzag 大約是 120,000 行 Swift 6 和 AppKit，圍繞 `WKWebView` 寫成。沒有 Chromium，也沒有 Electron：引擎是 macOS 內建的 WebKit，所以 App 很小，引擎的安全性修正也隨 macOS 更新而來，而不是由我發布。

| 部分 | 怎麼做的 |
|---|---|
| **網頁** | 每個分頁一個 `WKWebView`。一段時間沒用的分頁可以休眠：釋放網頁視圖，分頁保留快照和狀態，你回來時再重新載入。私密瀏覽視窗使用非永久性的資料儲存。 |
| **延伸功能** | WebKit 的網頁延伸功能支援（`WKWebExtensionController`，這也是最低需求為 macOS 15.4 的原因）。Zigzag 從 Chrome 線上應用程式商店下載 CRX3 套件，檢查簽章，然後載入。WebKit 沒有的 Chrome API（瀏覽記錄、書籤、下載項目、通知、側邊面板、離屏頁面、網頁登入、分頁音訊、新分頁頁面、使用者指令碼、代理伺服器等等）由 Zigzag 自己透過一個小橋接來回應，並依每個延伸功能自己的權限檢查。延伸功能提供的搜尋引擎（`search_provider`）會加入設定裡的選項，只有你選了才會使用。原生訊息傳遞負責連接 1Password 和其他延伸功能的輔助 App。 |
| **沙盒** | 網站上的圖片和 PDF 在兩個沙盒化的 XPC 輔助程式 `ZigzagImageDecoder` 和 `ZigzagPDFRenderer` 裡讀取，它們沒有網路，也不能存取檔案，所以格式有問題的圖片或 PDF 碰不到你的密碼和個人資料。PDF 檢視器繪製的是輔助程式算繪好的頁面；App 本身從不直接開啟網站的 PDF。 |
| **安全連線** | 憑證警告會在「詳細資訊」下說明哪裡有問題。網站透過 HSTS 標頭，或在 Chromium 的預先載入清單上（內建，大約 95,000 個網域名稱，只在需要顯示警告時就地讀取）要求只用安全連線的，就不會有「仍要造訪此網站」，和 Safari、Chrome 一樣。網站要求用憑證來識別你時，會提供你鑰匙圈裡它能接受的憑證，和 Safari 一樣：在「鑰匙圈存取」裡打開 .p12 檔案就能加入。 |
| **廣告阻擋** | EasyList、EasyPrivacy 和 EasyList China 事先用 SafariConverterLib 轉換成內容規則列表（`WKContentRuleListStore`），只編譯一次並快取。uBlock Origin 的清單在過期時下載，由 Ghostery 的 adblocker 引擎在它自己的 JavaScript 環境裡比對，每個網頁開始載入時，會拿到它的網站需要的 scriptlet 和隱藏規則。 |
| **深色網頁** | Dark Reader 的動態主題和它的網站修正，內建，在獨立的指令碼環境裡執行。會先告訴網頁視窗是深色的，所以有自己深色主題的網站會用自己的，不會被改動。 |
| **Cookie 彈出式視窗** | DuckDuckGo 的 Autoconsent 和它的規則，內建，在獨立的指令碼環境裡執行。 |
| **密碼** | 存成鑰匙圈項目，所以 iCloud 鑰匙圈會同步它們，觸控 ID 可以解鎖。通行密鑰透過 Apple 的瀏覽器通行密鑰權限。自動填寫是一個很小的內容指令碼，只填寫你看得到的欄位。 |
| **匯入** | 讀取每個瀏覽器自己的檔案：Arc 的 `StorableSidebar.json`、Chromium 的書籤和 SQLite 瀏覽記錄、Safari 的 `Bookmarks.plist`、Firefox 的 `places.sqlite`、Orion 的 `favourites.plist` 和 `history`。Chromium 的密碼在 macOS 問過你之後，用那個瀏覽器鑰匙圈項目裡的密鑰解密。 |
| **你的資料** | 空間、固定項目和收藏在 `Library.json`，個人資料在 `Profiles.json`，開啟的分頁在 `Session.json`，瀏覽記錄在 SQLite 裡（每份個人資料一個檔案），全都在 `~/Library/Application Support/Zigzag` 下。寫入會防抖動並且是不可分割的，讀不了的檔案會被放到一旁，絕不會被覆寫。 |
| **閱讀器** | Mozilla 的 Readability，在網頁裡執行，用 Zigzag 自己的字體排印顯示。 |
| **網頁 App** | 安裝為 App 的網站，是 `~/Applications/Zigzag Apps` 裡一個獨立的小 App，每次啟動都交給 Zigzag，所以網頁在 Zigzag 裡執行，帶著你的登入狀態、延伸功能和阻擋設定。 |
| **更新** | Sparkle 2，從 zigzagbrowser.com 取得 EdDSA 簽署的更新，分成穩定版和 Beta 版兩個更新來源。發布的版本用 Developer ID 簽署並經過公證。 |

原始碼依功能組織：`Sidebar`、`Tabs`、`Web`、`Extensions`、`Passwords`、`Import`、`Profiles`、`CommandBar`、`Desk`（所有分頁一覽）、`WebApps`、`Developer`、`MCP`（AI App）、`Settings`、`Window` 和 `Design`（Zigzag 自己繪製的控制項和設計權杖）。2,000 多個測試涵蓋匯入、密碼、延伸功能、網址處理、瀏覽記錄、AI App 和安全性修正。

## 隱私

沒有帳號，沒有分析，沒有遙測。你怎麼瀏覽，什麼都不會傳給我。除了你開啟的網頁，Zigzag 自己只會建立這些連線：

- **更新。** 每隔幾個小時，以及 Mac 喚醒之後，Zigzag 會讀取 zigzagbrowser.com 上的更新來源。請求裡只有 Zigzag 的版本號，沒有別的；不會傳送系統概況。新版本也從那裡下載。
- **搜尋建議。** 你在網址列輸入時，文字會傳給你的搜尋引擎來取得建議，不帶 Cookie。Google、DuckDuckGo、Brave、Bing、Kagi 和 Ecosia 提供建議；使用其他搜尋引擎時，什麼都不會傳送。可以在「設定 › 搜尋」裡關掉。
- **網站圖示。** 圖示來自每個網站本身，已固定分頁、收藏，以及還沒開啟過的匯入書籤也是如此。
- **過濾清單。** 啟動時，以及之後清單過期時（每幾個小時到每天一次），Zigzag 會從 uBlock Origin 自己的位址（GitHub Pages、Cloudflare Pages 或 jsDelivr）下載 uBlock Origin 的過濾清單，從 Ghostery 的 CDN 下載它的 scriptlet。也會從 zigzagbrowser.com 下載 Zigzag 自己的一份很短的網站修正清單。這些請求不帶 Cookie，也不包含任何關於你或你瀏覽的內容。
- **延伸功能。** 安裝延伸功能時從 Chrome 線上應用程式商店下載。啟動時，每天最多一次，Zigzag 會問商店你的延伸功能有沒有更新，這會把延伸功能的 ID 和版本傳給 Google。
- **設定流程。** 歡迎畫面會顯示幾個來自 Google 圖示服務的網站圖示，並載入維基百科首頁作為預覽。

翻譯在你的 Mac 上進行，用的是 Apple 的裝置端翻譯。詐騙網站警告是 WebKit 自己的，和 Safari 的一樣。密碼留在你 Mac 的鑰匙圈裡，只透過你自己的 iCloud 鑰匙圈同步。「輔助說明 › 報告問題」會寫一份你可以先讀過的報告，除非你自己傳送，否則什麼都不會送出。Mac 上的「密碼」列表會在 `~/Library/Logs/Zigzag/passwords.log` 裡記一份很小的操作記錄，從不記錄登入資訊或網站，而且只留在你的 Mac 上。你的 Zigzag 卡片是在你的 Mac 上，用你帳號的名稱和 Zigzag 第一次執行的日期產生的，它的圖片裡只有卡片上顯示的內容。

## 安裝

從 [zigzagbrowser.com](https://zigzagbrowser.com/download) 下載 DMG，打開它，把 Zigzag 拖到「應用程式」。或是用 Homebrew：

    brew install --cask zigaowang/tap/zigzag

更新會自動安裝。每個版本改了什麼，請見[版本說明](https://zigzagbrowser.com/release-notes)和[CHANGELOG.zh-Hant.md](../changelog/CHANGELOG.zh-Hant.md)。

## 意見回饋

- **Bug 和想法：** [提交議題](https://github.com/ZigaoWang/zigzag/issues/new/choose)，或在 App 裡選擇「輔助說明 › 提供意見回饋…」。如果是 bug，「輔助說明 › 報告問題…」會寫一份報告，你可以在傳送前先讀過。
- **電子郵件：** a@zigao.wang
- **安全性問題：** 請見 [SECURITY.md](../../../SECURITY.md)。請不要貼在公開的議題裡。

## 從原始碼建置

需求：macOS 15.4 或以上版本、Xcode 27 或以上版本，以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
brew install xcodegen
git clone https://github.com/ZigaoWang/zigzag.git
cd zigzag
xcodegen generate
open Zigzag.xcodeproj
```

執行 **Zigzag** scheme。Debug 建置會以一個獨立的 App「Zigzag Dev」執行，有自己的資料，所以絕不會碰到你平常用的 Zigzag。

簽署是依我的團隊設定的。要在你的 Mac 上建置，改 `project.yml` 裡的兩個地方，然後再執行一次 `xcodegen generate`：

- `DEVELOPMENT_TEAM`：你自己的團隊 ID（Xcode › Settings › Accounts 裡看得到）。
- Debug 的 `PRODUCT_BUNDLE_IDENTIFIER`：換成你自己的，例如 `com.yourname.zigzag.dev`，因為`wang.zigao.zigzag.dev` 是註冊在我的團隊底下的。

執行測試：

```sh
xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag
```

## 參與貢獻

歡迎貢獻。專案怎麼建置、測試，程式碼風格是什麼樣子，請看 [CONTRIBUTING.md](../../../CONTRIBUTING.md)。

## 授權

Zigzag 的程式碼採用 [Apache License, Version 2.0](../../../LICENSE) 授權。盡量用、盡量改、盡量 fork、盡量發布，商業用途也可以。

「Zigzag」這個名稱、App 圖示和標誌不在授權範圍內：它們是商標，保留一切權利。fork 需要用自己的名稱和圖示。請見 [TRADEMARKS.md](../../../TRADEMARKS.md) 和 [NOTICE](../../../NOTICE)。Zigzag 用到的第三方作品列在[THIRD_PARTY_NOTICES.md](../../../THIRD_PARTY_NOTICES.md) 裡。

## 致謝

感謝 [LINUX DO](https://linux.do) 社群很早就試用 Zigzag，並分享了他們的意見回饋。

<p align="center">
  <a href="https://linux.do"><img src="https://shorturl.at/ggSqS" alt="LINUX DO" /></a>
</p>
