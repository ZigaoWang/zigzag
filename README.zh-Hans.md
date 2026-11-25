<p align="center">
  <a href="https://zigzagbrowser.com"><img src="docs/brand/readme-hero.jpg" width="960" alt="Zigzag：用着舒服，轻得像没有。轻量的 Mac 浏览器，免费开源。一个分屏浏览的 Zigzag 窗口，Fonts In Use 和 Grilli Type 并排，边栏里是空间和已固定标签页。"></a>
</p>

<div align="center">

[English](README.md) | 简体中文 | [繁體中文](README.zh-Hant.md) | [日本語](README.ja.md) | [한국어](README.ko.md) | [Deutsch](README.de.md) | [Français](README.fr.md) | [Italiano](README.it.md) | [Español](README.es.md) | [Português (Brasil)](README.pt-BR.md) | [Русский](README.ru.md) | [Nederlands](README.nl.md) | [Polski](README.pl.md) | [Türkçe](README.tr.md)

本文是 README.md 的翻译；如有出入，以英文版为准。

</div>

<p align="center">
  <a href="https://zigzagbrowser.com/download"><b>下载 Mac 版</b></a><br>
  <sub>或者 <code>brew install --cask zigaowang/tap/zigzag</code></sub><br>
  <sub>免费开源。需要 macOS 15.4 或更高版本。</sub>
</p>

<p align="center">
  标签页放在边栏里，按空间分组。用 Swift 在 WebKit 上写的原生 Mac App，<br>
  安装后大约 35 MB，不需要账户，也没有遥测。
</p>

## 我为什么做它

你好，我是 Zigao，上海的一名高中生。我每天都用 Arc。The Browser Company 宣布 Arc 会在 12 月 22 日停止运营时，我实在不想回到标签页排在顶上的浏览器，而试过的其他浏览器，要么是 Chromium 的分支，要么是围绕 AI 做的。所以我自己做了一个，从那以后它就一直是我的主力浏览器。

**为什么用 WebKit，不用 Chromium？** 其实我一开始是 fork 了 Helium。源代码大约 100 GB，在我的 Mac 上每次构建要 3 到 4 个小时，我一个人根本维护不下去。WebKit 本来就是 macOS 自带的，更省电、更省内存，安全修复也由 Apple 随 macOS 更新一起推送。你照样可以用 Chrome 扩展，直接从 Chrome 网上应用店安装。

**为什么不用 Zen 或 Orion？** 开始做之前这两个我都试过，都不错。Zen 基于 Firefox，用的是 Firefox 扩展，在我看来也不太像 Mac App。Orion 更接近，但它不开源。我想要的是：用起来像 Arc，感觉是原生的，开源，还能跑我的 Chrome 扩展。

## 从 Arc 过来

**你的 Arc 可以一起带过来。** 选择“文件 › 从其他浏览器导入…”，选 Arc，你的空间、已固定标签页、固定的文件夹、收藏、历史记录、密码、登录状态和扩展都会过来。打开的标签页也可以一起过来，连分屏浏览也在，点到时才加载；不勾选“打开的标签页”就从头开始。如果你的空间分布在多个 Arc 个人资料里，每个 Arc 个人资料都会变成一份单独的 Zigzag 个人资料。

**1Password 能用。** 在 Zigzag 里从 Chrome 网上应用店安装它，和在 Arc 里一样。它会和 1Password App 连接。第一次用时，在 1Password 的“设置 › 浏览器”里添加 Zigzag。Bitwarden 也能用。

**它不会被关掉。** 没有账户，Zigzag 也不依赖我的服务器。我托管的只有更新源和一份很短的广告拦截修复列表，就算它们没了，Zigzag 也照样能用。[隐私](#隐私)里列出了 Zigzag 自己会连接的所有地方。

## 看看它

<p align="center">
  <img src="docs/spaces.gif" width="960" alt="在 Zigzag 的三个空间之间切换，每个空间都有自己的颜色和标签页">
</p>

<table>
  <tr>
    <td width="50%"><img src="site/assets/clips/split.jpg" alt="分屏浏览：Fonts In Use 和 Grilli Type 并排"><br><b>分屏浏览。</b>把标签页拖到网页上，就能在旁边打开，最多同时四个。</td>
    <td width="50%"><img src="docs/all-tabs.jpg" alt="三个空间里的所有标签页以卡片显示"><br><b>所有标签页一览。</b>⇧⌘\ 显示所有空间。打字就能筛选。</td>
  </tr>
  <tr>
    <td width="50%"><img src="site/assets/win-peek.webp" alt="一篇关于字体排印的维基百科文章，浮在打开它的网页上"><br><b>Zigzag Mini。</b>按住 Shift 点按链接，看一眼，不会丢掉当前的位置。</td>
    <td width="50%"><img src="site/assets/clips/reader.jpg" alt="阅读器里的一篇 The Public Domain Review 文章"><br><b>阅读器。</b>长文章，没有杂乱的东西。</td>
  </tr>
</table>

<p align="center"><sub>更多动态演示，见 <a href="https://zigzagbrowser.com">zigzagbrowser.com</a>。</sub></p>

## 它能做什么

| | |
|---|---|
| **空间** | 每个空间都有自己的颜色、图标、已固定标签页和文件夹。在边栏上轻扫，或者把鼠标滚轮往侧边拨一下，就能切换。 |
| **收藏** | 最常用的网站排成图标，显示在每个空间上方。任何标签页、已固定标签页或收藏都可以换上自己的表情符号或符号。 |
| **个人资料** | 把工作和生活分开。每份个人资料都有自己的扩展、登录状态、历史记录和收藏，每个空间都属于其中一份。 |
| **在空间中打开的网站** | 在网站设置或“设置 › 空间”里给网站选一个空间，它的链接不管从哪里来（其他 App、⌘T 或另一个空间），都会在那里打开，就像 Arc 的 Air Traffic Control。路径也可以分到各自的空间，比如 `github.com/org1` 去一个，`github.com/org2` 去另一个。用单独个人资料的空间，效果就像 Firefox 的容器。 |
| **命令栏** | ⌘T 或 ⌘L。可以找打开的标签页、历史记录和网站。输入 `you`，按 Tab，就在 YouTube 里搜索了。把命令栏拖到窗口里的任意位置，之后它就会在那里打开。 |
| **标签页分组** | 选几个标签页，选择“将标签页编组”，它们就会变成边栏里的一个文件夹，可以一起打开、收起、重新命名和移动。把标签页往右拖，就嵌套到上面那个标签页下面；往左拖，就拿出来。 |
| **实时文件夹** | 一个固定的文件夹，自动从订阅源、网站或 GitHub 填充内容：拉取请求、请求你审查的拉取请求，或者你的仓库里未关闭的议题和拉取请求。新网页会带一个小圆点。 |
| **分屏浏览** | 最多四个标签页：把标签页拖到网页边缘占一半，拖到角落占四分之一。拖动网页顶部的细条可以移动它，固定分屏浏览就能留住它。 |
| **窗口** | 把标签页拖到另一个窗口，它会原样移过去，不会重新载入。打开“设置 › 标签页 › 窗口共享空间的标签页”，同一个空间的所有窗口就会列出相同的标签页，和 Arc 一样。边栏可以放在左边或右边。 |
| **网页 App** | “安装为 App”会把网站变成一个独立的 App，出现在“应用程序”文件夹、程序坞和 ⌘Tab 里，工具栏是网站的颜色。 |
| **小播放器** | 视频播放时离开那个标签页，视频会跟着你，进到一个小播放器里。可以从任意边缘调整大小，放在任何地方，甚至放到窗口外面、盖在其他 App 上。不想要的话，可以从它的菜单里关掉。切换到其他 App 时，视频会以画中画浮在上面。 |
| **流媒体** | 受保护的音乐和视频和在 Safari 里一样能播放，用的是 WebKit 的 FairPlay Streaming：Spotify 网页播放器能用，其他支持 Safari 的服务也能用。 |
| **正在播放** | 在后台发出声音的每个标签页，都会在边栏底部有一张卡片，最多三张，可以暂停或静音。 |
| **所有标签页** | ⇧⌘\ 一次显示所有空间。打字就能筛选，把标签页拖到另一个空间也行。 |
| **清除** | 关掉你已经不看的标签页，留下正在用的。把指针移到它上面，就能看到会关掉哪些。分屏浏览要么整个留下，要么整个关掉。撤销就能找回来。 |
| **Zigzag Mini** | ⌃⌘N 打开一个小窗口，用来快速看一个网页，⌘O 把它移到浏览器窗口里。按住 Shift 点按链接，或者选择“在 Zigzag Mini 中打开链接”，它会在一个浮在窗口上的 Zigzag Mini 里打开；⌘O 把它放进一个标签页，就在你点按的那个旁边，Esc 关闭它。其他 App 里的链接也会在 Zigzag Mini 里打开，就像 Little Arc（可以在“设置 › Zigzag Mini”里关掉），“在 Zigzag Mini 中打开”能把一个标签页移进去。 |
| **密码** | 存在 Mac 的钥匙串里，由 iCloud 钥匙串同步。支持触控 ID、密码生成器，还会检查弱密码和重复使用的密码。通行密钥也能用。 |
| **深色网页** | 用 Dark Reader 的引擎把浅色网站画成深色，带着它对几千个网站的修复，所以照片颜色不会变。自带深色外观的网站保持原样。想更暗的话，可以用纯黑。可以对所有网站打开，也可以按网站打开。 |
| **广告拦截** | 内置并默认打开：大约 130,000 条 EasyList、EasyPrivacy 和 EasyList China 规则，编译成 WebKit 内容规则列表，再加上会自动更新的 uBlock Origin 过滤列表。 |
| **WebRTC** | 打开“防止 WebRTC 泄露 IP 地址”后，你用代理或 VPN 时，网站就没法通过 WebRTC 知道你的真实 IP 地址。在你允许的网站上通话照常，网站在被阻止时尝试使用 WebRTC，会告诉你，并提供“为此网站允许”。 |
| **Cookie 弹窗** | 帮你拒绝，从不接受，用的是 DuckDuckGo 的 Autoconsent 规则。想自己回答的话，可以对所有网站或单个网站不处理。 |
| **网站设置** | 每个网站一个面板：缩放、权限（摄像头、麦克风、位置、通知、弹出式窗口、打开 App、屏幕共享、WebRTC），每项都可以设为询问、允许或阻止，还有开关 JavaScript、证书、扩展，以及深色网页、广告拦截和 Cookie 弹窗的开关。网站请求其中某项时，会在网页上方的一张卡片里询问，可以只允许这一次或一直允许，你拒绝过的网站就不会再问。 |
| **Boosts** | “隐藏元素”能隐藏网站上你不想要的部分，比如横幅或侧栏，“编辑样式…”能给网站加上你自己的 CSS。两个都在网站设置的 ⋯ 菜单里，并且跟着网站保留。 |
| **开发者模式** | 给你在做的网站用，一开始就包括 `localhost`：带错误计数的控制台、检查元素、设备尺寸、浅色和深色、打印样式、关闭 JavaScript、图像或样式、换用户代理，还有一个二维码，用手机打开这个网页。 |
| **扩展** | 来自 Chrome 网上应用店，商店自己的按钮会显示“添加到 Zigzag”。1Password、Bitwarden、Dark Reader、Tampermonkey 和大多数热门扩展都能用；不能用的见下文。 |
| **导入** | 从 Arc、Chrome、Safari、Dia、Edge、Brave、Vivaldi、Opera、Comet、Helium、Yandex、Whale、Chromium、Thorium、Firefox、Zen 和 Orion 导入书签、历史记录、密码、登录状态和扩展。 |
| **下载** | 把某种类型的文件存到单独的文件夹，或者在 PDF 这类安全文件存好后直接打开。规则可以把链接或下载转交给 App、脚本或 aria2 这样的下载管理器，转交前会先问你。见 [docs/download-rules.md](docs/download-rules.md)。 |
| **自动化** | AppleScript、快捷指令和 `osascript` 可以列出和打开标签页、读取网页，写法和 Safari、Chrome 接受的一样。见 [docs/automation.md](docs/automation.md)。 |
| **AI 应用** | 默认关闭，打开后，你 Mac 上的 AI 应用可以通过 MCP 使用你的标签页，但永远碰不到无痕浏览窗口和密码。见 [docs/automation.md](docs/automation.md#ai-apps-mcp)。 |
| **你的数据** | “文件 › 导出你的数据…”会把书签存成任何浏览器都能导入的标准 HTML 文件，还有一份完整的 Zigzag 备份，可以在另一台 Mac 上恢复。 |
| **语言** | 英文、简体中文、繁体中文、日语、韩语、德语、法语、意大利语、西班牙语、巴西葡萄牙语、俄语、荷兰语、波兰语和土耳其语。 |
| **还有** | 阅读器、PDF 查看器、接力到你的 iPhone、iPad 或另一台 Mac、截图（区域、网页的一部分或整个网页，⇧⌘2）、设备端翻译、标出每个匹配项的网页内查找、带“最近关闭”和最近七天的“历史记录”菜单、默认网页缩放、喜欢的话可以把地址栏放在页面上方、画中画、无痕浏览窗口、网页检查器。 |

## 还缺什么

它是我每天用的浏览器，但 Zigzag 还很年轻，你会碰到 bug。Arc 用户会注意到的地方：

- 不能在 Mac 之间同步，也不能同步到 iPhone。密码通过 iCloud 钥匙串同步；空间和标签页不会。
- 空间图标不会从 Arc 带过来，需要在 Zigzag 里重新选。空间颜色会换成最接近的 Zigzag 颜色。
- 没有 Easels 和 Notes，Boosts 只支持 CSS（隐藏元素和编辑样式，没有按网站的脚本）。浏览器里没有内置 AI：只有你打开后，AI 应用才能通过 MCP 使用 Zigzag。
- 有几个 Chrome 扩展 API 还没有：标签页组 API、调试器设置、Chrome 自己的 Google 账户登录（`identity.getAuthToken`），以及旧的拦截请求的 webRequest。代理扩展可以设置固定的 HTTP、HTTPS 或 SOCKS5 代理，但不能用 PAC 脚本，所以 FoxyProxy 的 Proxy by Patterns 模式用不了。
- EasyList 和其他内置拦截列表随 Zigzag 一起更新，不会自己更新；只有 uBlock Origin 的列表会。
- 只支持 macOS 15.4 或更高版本。

## 它是怎么做的

Zigzag 大约是 120,000 行 Swift 6 和 AppKit，围绕 `WKWebView` 写成。没有 Chromium，也没有 Electron：引擎是 macOS 自带的 WebKit，所以 App 很小，引擎的安全修复也随 macOS 更新而来，而不是由我来发。

| 部分 | 怎么做的 |
|---|---|
| **网页** | 每个标签页一个 `WKWebView`。一段时间没用的标签页可以休眠：释放网页视图，标签页保留快照和状态，你回来时再重新载入。无痕浏览窗口使用非持久的数据存储。 |
| **扩展** | WebKit 的网页扩展支持（`WKWebExtensionController`，这也是最低要求 macOS 15.4 的原因）。Zigzag 从 Chrome 网上应用店下载 CRX3 包，检查签名，然后加载。WebKit 没有的 Chrome API（历史记录、书签、下载、通知、侧边面板、离屏页面、网页登录、标签页音频、新标签页、用户脚本、代理等等）由 Zigzag 自己通过一个小桥接来响应，并按每个扩展自己的权限检查。扩展提供的搜索引擎（`search_provider`）会加入设置里的选项，只有你选了才会用。原生消息传递负责连接 1Password 和其他扩展的辅助 App。 |
| **沙盒** | 网站上的图片和 PDF 在两个沙盒化的 XPC 辅助程序 `ZigzagImageDecoder` 和 `ZigzagPDFRenderer` 里读取，它们没有网络，也不能访问文件，所以格式有问题的图片或 PDF 碰不到你的密码和个人资料。PDF 查看器绘制的是辅助程序渲染好的页面；App 自己从不直接打开网站的 PDF。 |
| **安全连接** | 证书警告会在“详细信息”下说明哪里有问题。网站通过 HSTS 标头，或者在 Chromium 的预加载列表上（内置，大约 95,000 个域名，只在需要显示警告时就地读取）要求只用安全连接的，就不会有“仍然访问此网站”，和 Safari、Chrome 一样。网站要求用证书来识别你时，会提供你钥匙串里它能接受的证书，和 Safari 一样：在“钥匙串访问”里打开 .p12 文件就能添加。 |
| **广告拦截** | EasyList、EasyPrivacy 和 EasyList China 事先用 SafariConverterLib 转换成内容规则列表（`WKContentRuleListStore`），只编译一次并缓存。uBlock Origin 的列表在过期时下载，由 Ghostery 的 adblocker 引擎在它自己的 JavaScript 上下文里匹配，每个网页开始加载时，会拿到它的网站需要的 scriptlet 和隐藏规则。 |
| **深色网页** | Dark Reader 的动态主题和它的网站修复，内置，运行在单独的脚本环境里。会先告诉网页窗口是深色的，所以有自己深色主题的网站会用自己的，不会被改动。 |
| **Cookie 弹窗** | DuckDuckGo 的 Autoconsent 和它的规则，内置，运行在单独的脚本环境里。 |
| **密码** | 存成钥匙串项目，所以 iCloud 钥匙串会同步它们，触控 ID 可以解锁。通行密钥通过 Apple 的浏览器通行密钥权限。自动填充是一个很小的内容脚本，只填写你看得见的输入框。 |
| **导入** | 读取每个浏览器自己的文件：Arc 的 `StorableSidebar.json`、Chromium 的书签和 SQLite 历史记录、Safari 的 `Bookmarks.plist`、Firefox 的 `places.sqlite`、Orion 的 `favourites.plist` 和 `history`。Chromium 的密码在 macOS 问过你之后，用那个浏览器钥匙串项目里的密钥解密。 |
| **你的数据** | 空间、固定项和收藏在 `Library.json`，个人资料在 `Profiles.json`，打开的标签页在 `Session.json`，历史记录在 SQLite 里（每份个人资料一个文件），全都在 `~/Library/Application Support/Zigzag` 下。写入会防抖并且是原子的，读不了的文件会被放到一边，绝不会被覆盖。 |
| **阅读器** | Mozilla 的 Readability，在网页里运行，用 Zigzag 自己的字体排印显示。 |
| **网页 App** | 安装为 App 的网站，是 `~/Applications/Zigzag Apps` 里一个独立的小 App，每次启动都交给 Zigzag，所以网页在 Zigzag 里运行，带着你的登录状态、扩展和拦截。 |
| **更新** | Sparkle 2，从 zigzagbrowser.com 获取 EdDSA 签名的更新，分稳定版和 Beta 版两个更新源。发布的版本用 Developer ID 签名并经过公证。 |

源代码按功能组织：`Sidebar`、`Tabs`、`Web`、`Extensions`、`Passwords`、`Import`、`Profiles`、`CommandBar`、`Desk`（所有标签页一览）、`WebApps`、`Developer`、`MCP`（AI 应用）、`Settings`、`Window` 和 `Design`（Zigzag 自己绘制的控件和设计令牌）。2,000 多个测试覆盖了导入、密码、扩展、地址处理、历史记录、AI 应用和安全修复。

## 隐私

没有账户，没有分析，没有遥测。你怎么浏览，什么都不会发给我。除了你打开的网页，Zigzag 自己只会建立这些连接：

- **更新。** 每隔几个小时，以及 Mac 唤醒之后，Zigzag 会读取 zigzagbrowser.com 上的更新源。请求里只有 Zigzag 的版本号，没有别的；不会发送系统概况。新版本也从那里下载。
- **搜索建议。** 你在地址栏输入时，文字会发给你的搜索引擎来获取建议，不带 Cookie。Google、DuckDuckGo、Brave、Bing、Kagi 和 Ecosia 提供建议；用其他搜索引擎时，什么都不会发送。可以在“设置 › 搜索”里关掉。
- **网站图标。** 图标来自每个网站本身，已固定标签页、收藏，以及还没打开过的导入书签也是这样。
- **过滤列表。** 启动时，以及之后列表过期时（每几个小时到每天一次），Zigzag 会从 uBlock Origin 自己的地址（GitHub Pages、Cloudflare Pages 或 jsDelivr）下载 uBlock Origin 的过滤列表，从 Ghostery 的 CDN 下载它的 scriptlet。还会从 zigzagbrowser.com 下载 Zigzag 自己的一份很短的网站修复列表。这些请求不带 Cookie，也不包含任何关于你或你浏览的内容。
- **扩展。** 安装扩展时从 Chrome 网上应用店下载。启动时，每天最多一次，Zigzag 会问商店你的扩展有没有更新，这会把扩展的 ID 和版本发给 Google。
- **设置向导。** 欢迎界面会显示几个来自 Google 图标服务的网站图标，并加载维基百科首页作为预览。

翻译在你的 Mac 上进行，用的是 Apple 的设备端翻译。欺诈网站警告是 WebKit 自己的，和 Safari 的一样。密码留在你 Mac 的钥匙串里，只通过你自己的 iCloud 钥匙串同步。“帮助 › 报告问题”会写一份你可以先读一遍的报告，除非你自己发送，否则什么都不会发出去。Mac 上的“密码”列表会在 `~/Library/Logs/Zigzag/passwords.log` 里记一份很小的操作日志，从不记录登录信息或网站，并且只留在你的 Mac 上。你的 Zigzag 卡片是在你的 Mac 上，用你账户的名字和 Zigzag 第一次运行的日期生成的，它的图片里只有卡片上显示的内容。

## 安装

从 [zigzagbrowser.com](https://zigzagbrowser.com/download) 下载 DMG，打开它，把 Zigzag 拖到“应用程序”。或者用 Homebrew：

    brew install --cask zigaowang/tap/zigzag

更新会自动安装。每个版本改了什么，见[发行说明](https://zigzagbrowser.com/release-notes)和[CHANGELOG.zh-Hans.md](CHANGELOG.zh-Hans.md)。

## 反馈

- **Bug 和想法：** [提交议题](https://github.com/ZigaoWang/zigzag/issues/new/choose)，或者在 App 里选择“帮助 › 发送反馈…”。如果是 bug，“帮助 › 报告问题…”会写一份报告，你可以在发送前先读一遍。
- **邮件：** a@zigao.wang
- **安全问题：** 见 [SECURITY.md](SECURITY.md)。请不要发在公开的议题里。

## 从源代码构建

需要：macOS 15.4 或更高版本、Xcode 27 或更高版本，以及 [XcodeGen](https://github.com/yonaskolb/XcodeGen)。

```sh
brew install xcodegen
git clone https://github.com/ZigaoWang/zigzag.git
cd zigzag
xcodegen generate
open Zigzag.xcodeproj
```

运行 **Zigzag** scheme。Debug 构建会作为一个单独的 App “Zigzag Dev”运行，有自己的数据，所以绝不会碰到你平时用的 Zigzag。

签名是按我的团队设置的。要在你的 Mac 上构建，改 `project.yml` 里的两处，然后再运行一次 `xcodegen generate`：

- `DEVELOPMENT_TEAM`：你自己的团队 ID（Xcode › Settings › Accounts 里能看到）。
- Debug 的 `PRODUCT_BUNDLE_IDENTIFIER`：换成你自己的，比如 `com.yourname.zigzag.dev`，因为`wang.zigao.zigzag.dev` 是注册在我的团队下的。

运行测试：

```sh
xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag
```

## 参与贡献

欢迎贡献。项目怎么构建、测试，代码风格是什么样的，请看 [CONTRIBUTING.md](CONTRIBUTING.md)。

## 许可证

Zigzag 的代码采用 [Apache License, Version 2.0](LICENSE) 许可。随便用、随便改、随便 fork、随便发布，商用也可以。

“Zigzag”这个名字、App 图标和标志不在许可范围内：它们是商标，保留所有权利。fork 需要用自己的名字和图标。见 [TRADEMARKS.md](TRADEMARKS.md) 和 [NOTICE](NOTICE)。Zigzag 用到的第三方作品列在[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) 里。

## 致谢

感谢 [LINUX DO](https://linux.do) 社区很早就试用 Zigzag，并分享了他们的反馈。

<p align="center">
  <a href="https://linux.do"><img src="https://shorturl.at/ggSqS" alt="LINUX DO" /></a>
</p>
