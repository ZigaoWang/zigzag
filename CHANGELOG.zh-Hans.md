<!--
The Chinese release notes, kept beside CHANGELOG.md with the same shape: each release adds its section here too,
with the same version heading and date, a summary line, and ### 新功能 and ### 修复 for New and Fixed. Keep the
issue links and the names of the people thanked as they are, and the words the app uses (docs/i18n/glossary.md
and Zigzag/Resources/Localizable.xcstrings). A release with no section here shows its English notes in Chinese,
and scripts/release.sh warns about it.
-->
# 更新日志

Zigzag 的每个版本，最新的在最上面。App 会显示你正在用的版本的发行说明，所有版本的发行说明都在
[zigzagbrowser.com/release-notes](https://zigzagbrowser.com/release-notes)。

## [Unreleased]

### 修复
- 网页会议里共享屏幕时，现在可以只共享一个窗口，而不只是整个屏幕。网站请求共享你的屏幕时，Zigzag 会像 Safari 一样提供“共享窗口…”和“共享屏幕…”，选了哪个，就会出现 macOS 对应的选取器。([#211](https://github.com/ZigaoWang/zigzag/issues/211))
### 新功能
- 从 Arc 导入时也会带上每个空间打开的标签页，顺序和 Arc 里一样，分屏浏览的页面仍然并排。它们要等你点按才载入，几百个标签页不会一下子全部载入，再次导入也不会把同一个标签页打开两次。导入窗口里“空间和固定标签页”旁边的“打开的标签页”可以不导入它们。感谢 [alextend](https://github.com/alextend)。([#210](https://github.com/ZigaoWang/zigzag/issues/210))

### 修复
- 画中画的视频在你切换到别的 App 或别的桌面时会一直留在屏幕上，像在 Safari 里一样浮在所有窗口上面，直到你关掉它。以前它会被下一个 App 挡住，也只留在开始播放的那个桌面上。感谢 [alextend](https://github.com/alextend)。([#210](https://github.com/ZigaoWang/zigzag/issues/210))
- 没有标签页的空间会显示一张空的页面卡片，带阴影，颜色也和边栏不同，不再是边栏的颜色铺满整个窗口。感谢 [alextend](https://github.com/alextend)。([#210](https://github.com/ZigaoWang/zigzag/issues/210))

## [0.9.0] - 2026-11-12

分屏浏览最多放四个页面，网站可以安装成独立的应用，边栏可以放在左边或右边，标签页在窗口之间移动时保持原样。深色网页改用 Dark Reader，广告拦截加入了 uBlock Origin 的过滤列表，Cookie 弹窗会自动帮你拒绝，“网站设置”也重新做了。

### 新功能
- “设置 › 隐私”（有多份个人资料时是“网站数据”）里的“网站存储的数据”，标题旁边新增了搜索，边输入边找到网站，匹配的部分会标出来，找不到时也会说明。每个网站会显示它存储了多少数据，列表可以按名称或大小排序，“全部移除…”会在确认后清除所有网站的数据，搜索时只清除显示的网站。要移除单个网站，把指针移到它那一行，点按出现的废纸篓，和其他设置行一样。 ([#207](https://github.com/ZigaoWang/zigzag/issues/207))
- “设置 › 开发者”的最后新增“功能标志”，像 Safari 的“开发 › 功能标志”一样，列出这台 Mac 上 WebKit 提供的功能标志：每个都有开关、WebKit 给它的名字和一行说明，分在“稳定”“预览”“可测试”和“开发者”下面，“成熟”“不稳定”和“内部”收在“全部显示”里，还可以按名字或键搜索。只有你改过的功能标志会被记下，并标上“已更改”，其他的都跟随 WebKit 的默认设置；“恢复默认设置”会把它们全部还原。更改会应用到之后打开或重新载入的页面，旁边有“重新载入所有标签页”。开发者模式打开时才会显示。感谢 [micsama](https://github.com/micsama) 提出这个想法，感谢 [vandenbulckjean](https://github.com/vandenbulckjean) 做的开发者设置。([#173](https://github.com/ZigaoWang/zigzag/issues/173))
- 发行说明跟随 App 的语言；0.9.0 及之前的几个版本有了中文发行说明。
- 空间的编辑面板（新建空间时也会打开）会说明：同一份个人资料中的空间共用登录状态、历史记录和扩展。它的“个人资料”菜单里有“新建个人资料”，一点就给这个空间建一份自己的个人资料，并以空间命名。有多份个人资料时，空间切换器和空间的右键菜单也会像边栏一样显示每个空间用的是哪份个人资料。感谢 [spongehah](https://github.com/spongehah)。([#201](https://github.com/ZigaoWang/zigzag/issues/201))
- 开发者模式改为在“网站设置”的 ⋯ 菜单、命令栏或“显示 › 开发者”（⌥⇧⌘D）里选“开启开发者模式”来开关，“网站设置”的列表里不再另有一个开关，那个列表是给所有人用的。感谢 [Lakeland97](https://github.com/Lakeland97)。([#198](https://github.com/ZigaoWang/zigzag/issues/198))
- “网站设置”里的“深色网页”从两个开关变成了一个下拉菜单：“自动”跟随“设置 › 外观 › 深色网页”，“打开”和“关闭”不管设置怎样都只对这个网站生效，“强制深色”会把看起来已经是深色的网站也画成深色。选“自动”时，下面会写出现在是开还是关。以前做过的选择保持不变。感谢 [Lakeland97](https://github.com/Lakeland97)。([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- 为某个网站关闭“深色网页”时，会让它显示浅色外观，所以跟随 Mac 浅色或深色的网站，即使 Mac 是深色的也会显示浅色。没有打开深色网页的地方，网页跟随 Mac 的浅色或深色，而不是空间的颜色或无痕浏览窗口的颜色。你在网站自己的设置里选的主题由网站保存，会保持你选的样子。感谢 [Lakeland97](https://github.com/Lakeland97)。([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- “打开 App”现在是一项网站权限，和摄像头一样。网页想打开某个 App（比如 App Store 或 Zoom）时，Zigzag 会询问你，可以选“打开”（仅这一次）、“始终打开”（以后都打开这个 App）或“不打开”。网站问过一次之后，它的“网站设置”里的“权限”和“设置 › 隐私”里就会多出“打开 App”一行，可选“询问”“允许”和“阻止”，选“阻止”后这个网站就打不开任何 App。你自己键入或打开的地址仍然会直接打开对应的 App。感谢 [Lakeland97](https://github.com/Lakeland97)。([#192](https://github.com/ZigaoWang/zigzag/issues/192))
- “设置 › 扩展”里的“从文件夹安装…”可以从 Mac 上的文件夹安装 Chrome 扩展。它取代了以前只在开发者模式下才出现的“加载已解压的扩展…”。([#194](https://github.com/ZigaoWang/zigzag/issues/194))
- “设置 › 扩展”会找出 Mac 上 App 里自带的 Chrome 扩展，比如从 App Store 下载的 StopTheMadness Pro，列在“来自这台 Mac 上的 App”下面，带一个“安装”按钮。扩展直接从 App 里读取，不会被改动，所以 App 更新时扩展也跟着更新。感谢 [Lakeland97](https://github.com/Lakeland97)。([#194](https://github.com/ZigaoWang/zigzag/issues/194))
- “设置 › 隐私”的网站列表里，每个网站下面会列出它的权限，和它的“网站设置”一样可选“询问”“允许”和“阻止”，不用打开网站就能修改或收回权限。感谢 [Lakeland97](https://github.com/Lakeland97)。([#174](https://github.com/ZigaoWang/zigzag/issues/174))
- “设置 › 通用”里每个已安装应用的那一行，以及应用自己的“文件”菜单里，都有“在‘访达’中显示”，会在它所在的文件夹里选中这个应用。感谢 [Lakeland97](https://github.com/Lakeland97)。([#165](https://github.com/ZigaoWang/zigzag/issues/165))
- 把链接、地址或一段文字拖到地址上（边栏里、页面上方的栏里、分屏页面的顶条或 Zigzag Mini 都行）：链接或地址会在那里打开，其他文字会用你的搜索引擎搜索。地址周围会出现一圈描边，提示会落在哪里。感谢 [Lakeland97](https://github.com/Lakeland97)。([#182](https://github.com/ZigaoWang/zigzag/issues/182))
- “设置 › 外观”里的“边栏大小”可以把边栏设为小、中、大，就像 macOS 自己的边栏图标大小一样：标签页、文件夹、空间名称、收藏和地址一起放大或缩小，文字、图标和每一行都跟着变，选了马上生效。“中”就是一直以来的大小。感谢 [rocavence](https://github.com/rocavence)。([#183](https://github.com/ZigaoWang/zigzag/issues/183))
- 新标签页可以开在同一网站已有的标签页旁边：在“设置 › 标签页”里把“新标签页位置”设为“在同一网站的标签页旁边”。链接、从命令栏打开的页面或其他 App 打开的链接，会排在这个网站最后一个标签页后面；如果那个标签页嵌套在别的标签页下面，就放进同一组。还没有打开过的网站，页面会放在你之前选的位置。感谢 [bkonia](https://github.com/bkonia)。([#188](https://github.com/ZigaoWang/zigzag/issues/188))
- 开发者模式，和 Arc 一样，给你正在做的网站用。在任一网站的“网站设置”的 ⋯ 菜单或命令栏里选“开启开发者模式”，或者选“显示 › 开发者 › 为此网站开启开发者模式”（⌥⇧⌘D）。马上生效，并弹出提示，可以撤销。`localhost` 和 `127.0.0.1` 默认就在开发者模式中，“设置 › 开发者”会列出所有处于开发者模式的网站。处于开发者模式的标签页在边栏里的图标角上有一个小锤子，颜色跟着空间走，收藏的图标也有；指针移到上面会显示网站。页面上方的栏会用等宽字体显示完整地址，还有“拷贝链接”，以及分组排列的工具：带错误计数的 JavaScript 控制台、检查元素、网页的外观和尺寸，以及忽略缓存重新载入、清除网站缓存或 Cookie 后重新载入。在分屏浏览中，或关闭“在页面上方显示工具”时，这些工具在网站设置里；所有工具也都在“显示 › 开发者”和命令栏里。无痕浏览窗口不能开关开发者模式。在“设置 › 开发者”里关掉开发者模式，这些就都不会出现。感谢 [vandenbulckjean](https://github.com/vandenbulckjean)。([#141](https://github.com/ZigaoWang/zigzag/issues/141))
- “网页尺寸”可以让开发者模式中的页面变成真实设备的尺寸（iPhone、Pixel、Galaxy、iPad）、笔记本或台式机的窗口尺寸，或者你自己定的尺寸，横竖都行。这些尺寸在页面上方的栏里、“显示 › 开发者 › 网页尺寸”里，也可以在命令栏里按名称找到；“切换网页尺寸”（⌥⇧⌘M）会在页面上次用的尺寸和填满窗口之间切换。页面放在一块背景上，画出边缘，按钮旁边显示尺寸：名称，以及可以点按并键入的宽和高，按 ↑ 和 ↓ 每次调 1 点（按住 ⇧ 每次调 10 点）。网页检查器会停靠在它旁边。拖动右边、底边或角上的把手可以改成别的尺寸。比窗口还大的尺寸会按那个尺寸排版，再整体缩小显示，按钮旁边会写出缩放比例（“1920 × 1080，缩放至 54%”）。在“设置 › 开发者”里可以添加你自己的尺寸。感谢 [vandenbulckjean](https://github.com/vandenbulckjean)。([#141](https://github.com/ZigaoWang/zigzag/issues/141))
- “网页外观”可以让开发者模式中的页面显示浅色或深色外观，不管 Mac 当前是哪种；“显示打印样式”会按打印时的样子排版。⋯ 下面还有：停用 JavaScript、给每个元素加轮廓、用户代理（iPhone 或 iPad 上的 Safari、Chrome 或 Firefox，只发给处于开发者模式的网站）、用其他浏览器打开（“打开方式”），以及“在手机上打开”，也就是页面在局域网上的地址的二维码，其中的 localhost 会换成这台 Mac 在局域网上的地址。每个选择只对那个标签页有效，标签页转到别的网站时暂时搁置，关闭标签页后就没了。感谢 [vandenbulckjean](https://github.com/vandenbulckjean)。([#141](https://github.com/ZigaoWang/zigzag/issues/141))
- “设置 › 开发者”里的“信任这台 Mac 上服务器的证书”默认关闭，打开后，这台 Mac 上使用自签证书的 https 开发服务器会直接打开，不再弹出警告，信任的是它第一次出示的证书。感谢 [vandenbulckjean](https://github.com/vandenbulckjean)。([#141](https://github.com/ZigaoWang/zigzag/issues/141))
- 空间编辑器里“效果”旁边，以及空间的右键菜单里，有“使用默认颜色”，可以把空间恢复成创建时的颜色，重新跟随 Mac 的浅色和深色，去掉渐变、透明和颗粒。颜色改过之后才会出现，按 ⌘Z 可以撤销。感谢 [Lakeland97](https://github.com/Lakeland97)。([#190](https://github.com/ZigaoWang/zigzag/issues/190))
- 分屏浏览最多可以放四个标签页。把标签页拖到页面上：拖到边上占一半，拖到角上占四分之一，会有一个带小标签的预览显示它会落在哪里。三个标签页是一半加两个四分之一，四个是田字格；中间的分隔线可以拖动，整组在边栏里只占一行，重启后也会恢复。感谢 [Lakeland97](https://github.com/Lakeland97)。([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- 在分屏浏览中，拖动页面的顶条可以移动它：拖到另一个页面上，两个互换位置；拖到页面的边或角上，它就占那一半或四分之一；拖到边栏的标签页里，它就离开分屏，变成单独的标签页；拖出窗口，就在新窗口里打开（按住 Option 则在 Zigzag Mini 中打开）。按 Esc 取消，按 ⌘Z 放回原处。([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- “放大窗格”可以把分屏中的一个页面临时放大，盖在其他页面上，什么都不会移动：按住 ⇧ 点按边栏那一行里它的部分，或者用它顶条上的按钮，或者按 ⇧⌘↩。点按旁边、按 Esc 或再放大一次，就会恢复。([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- 分屏浏览中每个页面都有自己的网站设置，从它顶条里地址末尾的按钮打开，顶条太窄时在它的 ⋯ 里。边栏地址旁边的网站设置按钮对应你当前所在的页面。([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- 分屏在边栏里的那一行会均匀显示三四个图标，指向某个图标会显示它的页面名称，连按两下可以给你点的那个页面重新命名。([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- “文件”菜单和网站设置的 ⋯ 菜单里的“安装为应用”，可以把网站变成“应用程序”文件夹里的一个独立应用，在程序坞和 ⌘Tab 里有自己的图标。它会马上在自己的窗口里打开，登录状态和你在 Zigzag 里一样，指向其他网站的链接会在 Zigzag 中打开。“设置 › 通用”会列出你的应用，可以在那里移除。感谢 [Lakeland97](https://github.com/Lakeland97)。([#165](https://github.com/ZigaoWang/zigzag/issues/165))
- 已安装应用的工具栏会用网站自己的颜色，就像 Chrome 和 Safari 里的网页应用一样，中间显示应用名称。可以只隐藏工具栏、只留下页面，窗口按钮浮在页面上：用“显示 › 隐藏工具栏”，或者右键点按工具栏，或者在“设置 › 通用”里关掉这个应用的“工具栏”开关。([#165](https://github.com/ZigaoWang/zigzag/issues/165))
- 已安装应用的窗口在最前面时，会有它自己的菜单：“隐藏”和“退出”用的是它的名字，⌘Q 只退出这个应用，浏览器的“新建标签页”等菜单项不会出现。([#165](https://github.com/ZigaoWang/zigzag/issues/165))
- 边栏可以放在右边：在“设置 › 外观”里打开“边栏放在右侧”，或者选“显示 › 将边栏移到右侧”。页面移到左边，窗口按钮留在左上角，面板和小播放器也跟着调整，隐藏的边栏会从右边缘滑出。“显示边栏”按钮移到页面上方那一栏的右端，不管边栏显示还是隐藏，它都待在同一个位置。感谢 [Lakeland97](https://github.com/Lakeland97)。([#166](https://github.com/ZigaoWang/zigzag/issues/166))
- 深色网页改用 [Dark Reader](https://darkreader.org) 的引擎来绘制，带着它对几千个网站的修正。网站自己的颜色会被逐一调暗，而不是先用滤镜把整个页面反色、再事后修补，所以用新式颜色写的网站（比如 Cloudflare 的控制台）不会再大半还是浅色。感谢 [Lakeland97](https://github.com/Lakeland97)。([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- 网站设置里的“强制深色”会把网站画成深色，哪怕它看起来已经是深色的，适合那些有部分区域仍然是浅色的网站。([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- 广告拦截也用上了 uBlock Origin 的过滤列表，由 Ghostery 的开源广告拦截引擎来匹配。Zigzag 会自己下载这些列表并保持更新，所以 YouTube 等经常改广告投放方式的网站，不用等 Zigzag 更新也能正常用。在 YouTube 上，它们取代了 Zigzag 自己的脚本，那个脚本有时会让视频停在“Something went wrong. Please try again later.”。([#129](https://github.com/ZigaoWang/zigzag/issues/129))
- Cookie 弹窗会自动帮你拒绝：网站的同意弹窗要求的 Cookie，Zigzag 会替你拒绝，只需要隐藏的弹窗就直接隐藏，从来不会替你同意。它认得 OneTrust、Cookiebot、Didomi、Sourcepoint 等一千多种弹窗，用的是 DuckDuckGo 的 [Autoconsent](https://github.com/duckduckgo/autoconsent)，和 DuckDuckGo 浏览器用的是同一套规则。想自己处理的话，在“设置 › 隐私”里把“Cookie 弹窗”设为“不处理”；也可以在某个网站的网站设置里单独开关，拒绝过之后那里会显示“已在此网站上拒绝”。感谢 [Lakeland97](https://github.com/Lakeland97)。([#175](https://github.com/ZigaoWang/zigzag/issues/175))
- “网站设置”重新做了。第一页显示网站、快捷操作、当前页面的开关，以及“连接”“权限”“扩展”各一行，一眼就能看到概况（“安全”“已允许 2 项”）。每一行点进去都是同一个面板里的单独一页，可以返回。缩放是“− 100% +”，点按百分比就会把页面恢复到 100%。感谢 [Lakeland97](https://github.com/Lakeland97)。([#174](https://github.com/ZigaoWang/zigzag/issues/174))
- 网站设置里的“连接”会显示网站的证书链，从网站一直到根证书：每张证书颁发给谁、由谁颁发、有效期、密钥和 SHA-256 指纹，以及 macOS 是否信任它。普通的 http 页面只会显示“不安全”。([#174](https://github.com/ZigaoWang/zigzag/issues/174))
- 网站设置里的“权限”会列出网站请求过的摄像头和麦克风、位置、通知和弹出式窗口，每项都可以设为“询问”“允许”或“阻止”。被阻止的弹出式窗口会直接拦下，不再提示；“重置权限”会忘掉你给这个网站的所有回答。“扩展”会列出你的扩展、每个扩展是否在这个网站上运行，以及“管理扩展”。([#174](https://github.com/ZigaoWang/zigzag/issues/174))
- Zigzag Mini 的顶栏会用页面的颜色，和已安装应用的工具栏一样，所以深色网站上面不会顶着一条浅色的栏，页面也和它严丝合缝地接在一起。
- 小播放器可以离开窗口：把它拖到屏幕上任何地方，盖在其他 App 上面也行，它会在每个空间里都保持在最上面，就像画中画一样。在窗口外松手，它会停到最近的屏幕角落；在窗口上松手，就和以前一样停在页面的角落。感谢 [Lakeland97](https://github.com/Lakeland97)。([#172](https://github.com/ZigaoWang/zigzag/issues/172))
- 视频全屏时可以只填满它所在的页面，边栏和窗口的其他部分都还在：在“设置 › 标签页”里把“全屏幕视频填满”设为“网页”，或者在某个网站的网站设置里打开“全屏幕只填满网页”，比如只给 YouTube 用。在分屏浏览中，视频只填满它自己那一块。按 Esc 或播放器自己的按钮可以退出。感谢 [Lakeland97](https://github.com/Lakeland97)。([#168](https://github.com/ZigaoWang/zigzag/issues/168))
- 标签页在窗口之间移动时保持原样，不会重新载入：把标签页拖到另一个窗口的边栏里（会有一条线显示落点），或者拖到它的页面上。在 Zigzag 外面松手，它就在自己的新窗口里打开。窗口里没有标签页了就会关闭，和 Chrome 一样，按 ⌘Z 可以把标签页找回来。感谢 [Lakeland97](https://github.com/Lakeland97)。([#167](https://github.com/ZigaoWang/zigzag/issues/167))
- 标签页右键菜单里的“在 Zigzag Mini 中打开”，会把页面原样移到 Zigzag Mini 窗口里，连历史记录一起，按 ⌘Z 可以把标签页放回去。把标签页拖出窗口时按住 Option 也一样。感谢 [Lakeland97](https://github.com/Lakeland97)。([#164](https://github.com/ZigaoWang/zigzag/issues/164))
- 给空间、文件夹或标签页选图标时，可以在图标网格下面的输入框里键入“cat”或“rocket”这样的名称，找到对应的表情符号。点按一个或按 Return 选中，按 Esc 回到图标。以前键入的字母会消失。感谢 [thekevinbrown](https://github.com/thekevinbrown)。([#163](https://github.com/ZigaoWang/zigzag/issues/163))
- 用鼠标中键点按地址可以关闭当前标签页，和中键点按边栏里它那一行一样。感谢 [Lakeland97](https://github.com/Lakeland97)。([#171](https://github.com/ZigaoWang/zigzag/issues/171))
- 休眠标签页的预览会说明它为什么休眠、大约释放了多少内存，比如“为省内存已休眠，释放了约 180 MB。”。它的图标外面换成了一圈均匀的细虚线，不再是粗点。([#140](https://github.com/ZigaoWang/zigzag/issues/140))
- “Zigzag 已更新”的提示 15 秒后会自己消失，和通知一样，鼠标指针停在上面时不会消失。“新功能”仍然在“帮助”菜单里。
- “更改图标”里的第一个选项显示网站自己的图标，一看就知道它是用来恢复网站图标的。

### 修复
- 分屏浏览的每个页面四个角都是同样的圆角，不管挨着窗口的哪条边、页面之间的空隙还是上方的工具栏：左右排、上下排、三个或四个页面，边栏在左边或右边，全屏时也一样。以前挨着窗口边缘的角是方的，全屏时和其他角对不上。 ([#203](https://github.com/ZigaoWang/zigzag/issues/203))
- 边栏里分屏浏览的那一行和周围的标签页对齐了：每个页面的图标都在标签页图标的位置上，第一个正好在上面那些图标的正下方，有空间时显示标题，你所在的那一行里当前页面会亮起来。已固定列表和文件夹里也一样，边栏的每种大小都是如此。 ([#203](https://github.com/ZigaoWang/zigzag/issues/203))
- 三个或四个页面的分屏浏览现在可以像两个页面的一样固定、加入收藏和放进文件夹：在边栏里是一行，在收藏里是一个方块，每个页面一个小图标，按页面的位置排好。点开后所有页面按原来的布局打开，重启后还在，取消固定或拖回“标签页”时也保持原样。以前固定时只会固定其中一个页面，其余的留在原处，按 ⌘Z 后还会少一个页面；现在按一次 ⌘Z 就能把每个页面放回原位。在固定分屏的那一行里双击某个页面，可以给这个页面改名。 ([#203](https://github.com/ZigaoWang/zigzag/issues/203))
- “网站存储的数据”下的“全部显示”现在一点就开，网站再多列表也能流畅滚动。以前所有网站的行会一次全部生成，点按时会卡一下，滚动也很慢。 ([#207](https://github.com/ZigaoWang/zigzag/issues/207))
- 中语智汇（web.zyamoy.com）和其他启动时要用 FingerprintJS 2 的网站能正常打开了，不会再一片空白。广告和跟踪器拦截会拦下这个库，这些网站少了它就停住了；现在会给它们一个无害的替身，不会透露你 Mac 的任何信息。 ([#202](https://github.com/ZigaoWang/zigzag/issues/202))
- DeepSeek 不会再提示你检查浏览器插件了。广告和跟踪器拦截会拦下它的遥测请求，它以为是广告拦截插件在捣乱；现在被拦下的遥测会在页面里直接得到一个空回应，什么都不会发出去，网站照常使用。 ([#208](https://github.com/ZigaoWang/zigzag/issues/208))
- 退出再重新打开 Zigzag 后恢复的标签页，在真正载入之前不会再看起来像已经载入了。页面没在运行的标签页，不管是怎么变成这样的，现在看起来都一样：在标签页列表里，图标周围有一圈和休眠标签页一样的细虚线；固定的页面和收藏只在页面真正载入时才有那圈细边。把指针移到上面，预览卡片会说明原因：为省内存已休眠，或者 Zigzag 重新打开后还没有载入。和以前一样，点按就会载入。 ([#205](https://github.com/ZigaoWang/zigzag/issues/205))
- 页面进入全屏时顶部不会再先出现一条白边，进入全屏时会测量自身大小的网站能拿到正确的尺寸。
- 设置 › 扩展里会直接写出扩展哪些功能用不了，比如“侧边栏和通知在 Zigzag 里用不了。”，不再只写“2 个功能用不了”，把名字藏在提示里。
- 隐藏的边栏不管你把指针移到窗口边缘有多快，滑出来的样子都一样了。以前快速移过去时，指针可能冲出边缘，边栏会滑出、缩回、再滑出；现在快速移动也算是想打开它，边栏会像慢慢移过去时一样，一次顺畅地滑出来。只是路过边缘时，边栏仍然保持隐藏。 ([#206](https://github.com/ZigaoWang/zigzag/issues/206))
- 深色网页能察觉网站自己切换主题了。一开始是深色、后来用网站自己的主题菜单换成浅色的网站，会被画成深色；换成深色的网站会保持原样，不用重新载入。感谢 [Lakeland97](https://github.com/Lakeland97)。([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- 网页载入后换了颜色时，比如深色的应用画在白色页面上，或者网站切换了主题，页面上方的栏、分屏浏览的标题栏和 Zigzag Mini 的顶栏也会跟着变，不会一直是白色。感谢 [Lakeland97](https://github.com/Lakeland97)。([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- YouTube Music 在你没在看的标签页里也会接着播下一首了。以前每首歌放完就卡在加载，要暂停再播放才继续：窗口外的网页加载不了下一首，所以正在播放声音的标签页现在会留在窗口里（看不见），小播放器在两首歌之间消失时也会把网页留在窗口里。感谢 [Lakeland97](https://github.com/Lakeland97)。([#199](https://github.com/ZigaoWang/zigzag/issues/199))
- 在“设置 › 通用”里点“设为默认”后，macOS 一确认按钮就会更新，不用再点第二次。感谢 [ze-mu-zhou](https://github.com/ze-mu-zhou)。([#195](https://github.com/ZigaoWang/zigzag/issues/195))
- “翻译”会翻译网页里所有不是你的语言的内容，不再只翻译整页都是别的语言的网页。英文网页里的一段中文或一句日文引语会单独翻译，中文网页里的英文代码保持原样。只有整页都已是你的语言时，才会提示“此页面已是”你的语言。在同一个窗口里再翻译一个同语言的网页，或者从已翻译的网页前往另一个网页后再翻译，也都可以了。感谢 [Lakeland97](https://github.com/Lakeland97)。([#197](https://github.com/ZigaoWang/zigzag/issues/197))
- 隐藏的边栏滑出和收回更顺滑了，全屏时也一样。
- 滑出来的边栏和固定显示的边栏颜色一致了，不会再偏灰。
- Motrix 扩展可以和 Motrix App 配对了。之前点“配对”还没连到 App 就提示连接失败：扩展认不出 Zigzag 给它自己文件的地址，现在只在需要的那一项检查里给它 Chrome 的地址。
- Tampermonkey BETA 和正式版 Tampermonkey 一样能用了。以前它一启动就停住，弹出窗口打不开，脚本也不会运行；现在它能正常启动，打开脚本的 .user.js 地址会出现它的安装页，装好的脚本也会运行，不允许内联脚本的网站上也一样。 ([#200](https://github.com/ZigaoWang/zigzag/issues/200))
- 边栏在右边、地址栏在边栏里时，页面会一直延伸到窗口顶部，和边栏在左边时一样，上面不再多出一条。窗口按钮在边栏顶部那一行的开头，接着是边栏按钮，后退、前进和重新载入在那一行的末尾，和边栏在左边时同一行。地址栏在页面上方时，它们留在那一栏的开头。([#166](https://github.com/ZigaoWang/zigzag/issues/166))
- 安装没有后台页面的扩展（比如一些只修改页面的扩展）不会再让 Zigzag 退出。([#194](https://github.com/ZigaoWang/zigzag/issues/194))
- 设置开着时切换“无边框页面”，设置不会再保持原来的大小排版：分区列表旁边不再多一条滚动条、下面不再有一条白边，开关也和搜索栏对齐了。现在设置会随着页面留出或收回边距一起移动，页面的圆角和阴影也跟着移动，不再直接跳到最终位置。感谢 [vandenbulckjean](https://github.com/vandenbulckjean)。([#184](https://github.com/ZigaoWang/zigzag/issues/184))
- 设为“询问”的权限每次都会询问，和 Safari 一样：你对网站摄像头、麦克风、位置或通知请求的回答只对当前页面有效，下次访问时网站会再问一次。“允许”和“阻止”会保留，可以在网站设置、“设置 › 隐私”，或者地址栏的摄像头按钮里用“在此网站上始终允许”来设。感谢 [Lakeland97](https://github.com/Lakeland97)。([#174](https://github.com/ZigaoWang/zigzag/issues/174))
- 页面内查找的计数和它实际逐个经过的匹配完全一致，和 Safari 一样：隐藏的文字、脚本和跨两个段落的词不再计入，框架里的匹配会计入。页面载入完成后会重新计数。感谢 [Lakeland97](https://github.com/Lakeland97)。([#180](https://github.com/ZigaoWang/zigzag/issues/180))
- 分屏中被放大的页面，在页面互换、移动或改变布局时会回到原位，和有页面加入或离开时一样。([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- 地址栏在页面上方、分屏上下排列时，放大上面的页面不会再让那一栏自己的按钮和地址又出现在旁边。([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- 小播放器的窗口在另一个空间时，它会去屏幕的角落，而不是一个你看不见的窗口的角落；在那个窗口原本所在的位置松手，也不会再吸附过去。小播放器拿着键盘焦点时关闭窗口，不会再让那个窗口闪到前面一下。([#172](https://github.com/ZigaoWang/zigzag/issues/172))
- 速览的周围会用页面自己的颜色，和分屏浏览的页面一样，所以深色页面的顶部不会再有一条浅色的条。([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- 扩展在页面右键菜单里的项目只出现一次，不会重复两次（比如 Bitwarden 的）。感谢 [rocavence](https://github.com/rocavence)。([#186](https://github.com/ZigaoWang/zigzag/issues/186))
- 重启安装更新后，之前打开的一切都会恢复，包括 Zigzag Mini 窗口；你的窗口、空间、标签页和分屏会在更新重启 Zigzag 的那一刻存储下来。
- 关掉深色网页时，本身就是深色的网站，它上方的栏、Zigzag Mini 的顶栏和已安装应用的工具栏也会恢复成深色，而不是白色。感谢 [Lakeland97](https://github.com/Lakeland97)。([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- 边栏在右边、地址栏在标签页旁边时，页面上方那一条不再只孤零零地放着窗口按钮：后退、前进和重新载入紧跟在后面，和页面上方的栏一样。感谢 [Lakeland97](https://github.com/Lakeland97)。([#181](https://github.com/ZigaoWang/zigzag/issues/181))
- 网站设置里很长的网站名称不会再丢掉开头（“…mini.google.com”）：它会稍微缩小以完整显示，子域名比表明网站归属的域名颜色更淡；只有还是放不下时，才会省掉整段子域名，域名本身永远不省。完整名称在工具提示里，VoiceOver 也会读出。速览、Zigzag Mini、分屏页面的顶条和已安装应用的栏也会完整保留网站的域名，被截短的长个人资料名称在指针悬停时会完整显示。感谢 [Lakeland97](https://github.com/Lakeland97)。([#189](https://github.com/ZigaoWang/zigzag/issues/189))
- 地址在页面上方时，分屏浏览中被放大的窗格会把它的顶条（地址和按钮）一起带到上面，不再把顶条留在那一栏里。([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- 从分屏浏览的窗格打开的网站设置，会在窗格移动时关闭（比如分屏结束、窗格被放大或两个窗格互换），不再停留在窗格顶条原来的位置。([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- 一个窗口里开着网站设置或下载时，在另一个窗口里点按同一个按钮，第一次点按就会在那里打开，而不只是关掉另一个窗口里的。链接预览和阅读器里的 Esc 也不会再等另一个窗口里开着的面板。
- 已安装应用的窗口刚关闭后，从程序坞或“访达”再次打开它，会打开它的窗口，不会只剩下一个没有窗口的程序坞图标。([#165](https://github.com/ZigaoWang/zigzag/issues/165))
- 在分屏浏览中把固定页面的窗格拖出窗口，不会再打开一个空窗口并卸载那个固定页面。固定页面属于每个窗口，所以它会留在原处。([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- 在“显示所有标签页”中，固定页面和标签页组成的分屏，卡片上会显示两个页面，各在自己那一边；你在固定页面上时，选中的也是这张卡片。以前只显示标签页。
- 开着扩展浏览一段时间后，后退、前进或点按链接不会再让 Zigzag 崩溃。以前每换一次网站，扩展的脚本就可能多出一份副本，多到最后没法交给新页面。感谢 [Lakeland97](https://github.com/Lakeland97)。([#178](https://github.com/ZigaoWang/zigzag/issues/178))
- 打开深色网页时，自带深色外观的网站（比如 GitHub 或 YouTube Music）会完全保持原样，哪怕页面上内容很少，也不会被涂成半浅半深。第一次访问或重启后，它不会再在深色主题出现前闪白一下，上方的栏也是深色的。Zigzag 会按个人资料记住哪些网站是深色的，清除网站数据或历史记录时一并忘掉。([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- 在分屏浏览中，鼠标的后退和前进按钮以及轻扫手势，会作用于指针下面的页面，并让它成为当前页面，而不是作用于你上一次所在的页面。感谢 [Lakeland97](https://github.com/Lakeland97)。([#170](https://github.com/ZigaoWang/zigzag/issues/170))
- 分屏浏览中每个页面上方的顶条在深色页面上也看得清：地址和按钮会变成浅色，和页面上方的栏一样。([#160](https://github.com/ZigaoWang/zigzag/issues/160))
- 边栏隐藏时，指针只是路过窗口边缘、要去别处（比如那一边的另一台显示器），不会再把边栏拉出来停在那里。指针停在边缘或刚越过边缘时边栏才会打开，指针离远了才会收起。编辑地址时、网站设置或下载开着时，或者命令栏开着时，边栏也不会再从下面滑进来。感谢 [vandenbulckjean](https://github.com/vandenbulckjean) 的修复。([#176](https://github.com/ZigaoWang/zigzag/issues/176))
- “显示所有标签页”打开时很流畅，第一次也是，关闭并切到另一个标签页时也不会卡一下。
- 速览的顶条和分屏浏览的一样细，边框也更细，页面能用的空间更大。速览里的页面保留各自的滚动条，和 Safari 一样，不再给每个页面都加上一条一直显示的滚动条。
- 页面顶部的提示消失时会滑回上面，和出现时的方向一样，而不是突然消失。带按钮的提示（比如“撤销”或“固定此页面”）有关闭按钮，关闭固定标签页后的提示也更短了。
- 窗口比较矮时，设置里的分区列表可以滚动，不会超出底部。感谢 [Lakeland97](https://github.com/Lakeland97)。([#169](https://github.com/ZigaoWang/zigzag/issues/169))
- 在“设置 › 隐私”里，开关“拦截广告和跟踪器”时，开关会一直留在右边缘。
- 扩展一打开就知道有哪些固定标签页和收藏，所以 1Password 的通行密钥等扩展功能在它们上面也能用，不会再报“Tab not found”。
- Cloudflare 的“确认你是真人”验证（Turnstile）不会再在每次续期时记录一条错误，比如在 linux.do 上。

## [0.8.6] - 2026-11-12

### 新功能
- 设置的各个分区归到了几个标题下：浏览器、工具、隐私与安全和高级。

### 修复
- 在 macOS 27 上，即使是 Dashlane 或 1Password 这样的密码管理器（而不是 Zigzag）负责填写，登录栏也会显示钥匙图标并打开 Mac 的自动填充面板，可以在那里选它的登录信息。([#57](https://github.com/ZigaoWang/zigzag/issues/57))
- ⌘Z 和 ⇧⌘Z 会先交给页面处理，所以 Google 表格这样的网页应用可以撤销它们自己的更改。页面不处理这个按键时，Zigzag 自己对边栏的撤销仍然有效。感谢 [Lakeland97](https://github.com/Lakeland97)。
- Google 表格打开后不会再过一会儿就变模糊：页面现在知道自己所在窗口的大小了。([#161](https://github.com/ZigaoWang/zigzag/issues/161))
- 打开深色网页时，新标签页和从休眠中唤醒的标签页不会再闪白，网站存储的深色配色会在第一帧就检查。感谢 [Lakeland97](https://github.com/Lakeland97)。([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- 载入进度条回到了页面顶部；0.8.5 把它画到了底部。
- 在“更改图标”里，再点按一次已选中的图标，或者删掉表情符号，就会恢复网站自己的图标。([#153](https://github.com/ZigaoWang/zigzag/issues/153))

## [0.8.5] - 2026-11-12

### 新功能
- 在“设置 › 自动化”里打开后，AI 应用可以通过 MCP 使用 Zigzag：列出、打开和读取你的标签页，截图，点按和键入。它只在这台 Mac 上可用，需要密钥，并且永远不会碰无痕浏览窗口、密码或 Zigzag 自己的页面。被 AI 应用使用的标签页会显示出来，并带有“停止”。“拷贝配置”和“拷贝提示词”让你粘贴一次就能连上一个应用。([#99](https://github.com/ZigaoWang/zigzag/issues/99))
- 设置分了组，“自动化”有了自己的面板。([#99](https://github.com/ZigaoWang/zigzag/issues/99))
- 可以给标签页、固定标签页或收藏换上自己的表情符号或符号：右键点按 › “更改图标…”，用“使用网站图标”换回来。([#153](https://github.com/ZigaoWang/zigzag/issues/153))
- 第一次访问之后，深色网页会用浅色网站自己配色的深色版本来绘制它，照片和颜色保持真实，页面从第一帧起就是深色的。对读不出配色的网站，仍然用原来的滤镜。([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- 深色网页对框架里的图片、Web 组件和背景处理得更好，还新增了纯黑背景选项。([#134](https://github.com/ZigaoWang/zigzag/issues/134))
- 小播放器可以从任意边或角调整大小，会吸附到页面的角落（按住 ⌘ 可以放在任何位置），记住大小和位置，并支持空格键和 Esc。([#156](https://github.com/ZigaoWang/zigzag/issues/156))
- 在 Chrome 网上应用店里，商店自己的按钮会显示“添加到 Zigzag”，并通过 Zigzag 安装。感谢 [philigrin](https://github.com/philigrin) 找到了做法。([#130](https://github.com/ZigaoWang/zigzag/issues/130))
- 关闭一个折叠了嵌套标签页的标签页时，嵌套的标签页也会一起关闭，可以撤销。([#155](https://github.com/ZigaoWang/zigzag/issues/155))

### 修复
- 文件夹里的页面开着时，文件夹也能重新合上了。([#154](https://github.com/ZigaoWang/zigzag/issues/154))
- 小播放器只会跟随你正在看的视频，不会跟随你离开的页面上那种静音预览。([#156](https://github.com/ZigaoWang/zigzag/issues/156))
- 双指轻扫后退和前进的方向和你的 Mac 滚动方向一致，和 Safari 一样。感谢 [philigrin](https://github.com/philigrin)。([#147](https://github.com/ZigaoWang/zigzag/issues/147))
- 嵌入在页面中、来自你从没打开过的网站的内容也能拿到它的 Cookie，所以共享的聊天作品之类的嵌入内容能打开了。感谢 [vandenbulckjean](https://github.com/vandenbulckjean)。([#143](https://github.com/ZigaoWang/zigzag/issues/143))
- 停靠在侧边的网页检查器会留在它自己的标签页上，不会被地址栏挡住。感谢 [vandenbulckjean](https://github.com/vandenbulckjean)。([#148](https://github.com/ZigaoWang/zigzag/issues/148))
- 地址栏在页面上方时，显示和隐藏边栏的滑动很流畅，地址末尾也留有空间。感谢 [vandenbulckjean](https://github.com/vandenbulckjean)。([#151](https://github.com/ZigaoWang/zigzag/issues/151))
- 当你唯一的 Chrome 系浏览器是 Vivaldi、Arc 或某个测试版时，1Password 也能连上它的 Mac App。([#145](https://github.com/ZigaoWang/zigzag/issues/145))

## [0.8.4] - 2026-11-11

### 新功能
- “密码…”会在页面的输入栏旁直接打开 Mac 的自动填充面板，由 macOS 填写登录信息。它也在输入栏右键菜单的“自动填充”下，以及登录栏的钥匙图标上。([#132](https://github.com/ZigaoWang/zigzag/issues/132))
- YouTube 广告会被拦截，而且不会影响 YouTube 自己的对话框和滚动。如果你用了 uBlock Origin Lite 或 AdGuard 这样的广告拦截扩展，在 YouTube 上会交给它处理。([#129](https://github.com/ZigaoWang/zigzag/issues/129))
- 从有多份个人资料的 Chrome 或其他浏览器导入时，每份个人资料都会变成一个以它命名的空间。再次导入会加到同样的空间里。([#131](https://github.com/ZigaoWang/zigzag/issues/131))
- “帮助 › 键盘快捷键”会打开快捷键列表。([#122](https://github.com/ZigaoWang/zigzag/issues/122))
- 设置搜索可以用你习惯的说法找到启动、主页、深色模式和默认浏览器的设置。([#121](https://github.com/ZigaoWang/zigzag/issues/121))
- 被 Zigzag 休眠的标签页，图标外面会有一圈虚线，和 Chrome 一样，指针指向时会说明原因。([#140](https://github.com/ZigaoWang/zigzag/issues/140))

### 修复
- 后台标签页不会再因为耗电多而毫无预警地被休眠：Zigzag 会先提示它 2 分钟后休眠，并提供“保持唤醒”让它继续运行。安静的标签页也不会再替别的标签页背锅。([#140](https://github.com/ZigaoWang/zigzag/issues/140))
- Mac 上开着代理（比如 Clash）时，地址输错了会提示 Zigzag 打不开这个网站并指出是代理，而不是怪到网络头上。服务器返回空错误时会显示错误页面，而不是一片空白。([#137](https://github.com/ZigaoWang/zigzag/issues/137))
- 入门指南和 App 对上了：概览显示的是真实页面，指南留在窗口里面，每一步都会写出你设置的快捷键。([#133](https://github.com/ZigaoWang/zigzag/issues/133))
- 分屏中的固定页面在边栏里只显示为一行。([#114](https://github.com/ZigaoWang/zigzag/issues/114))
- 很窄的分屏窗格也会保留地址和关闭按钮。([#115](https://github.com/ZigaoWang/zigzag/issues/115))
- 开关打开时会填上你的强调色。([#116](https://github.com/ZigaoWang/zigzag/issues/116))
- 没有扩展时，网站设置会提供“获取扩展”。([#117](https://github.com/ZigaoWang/zigzag/issues/117))
- 中文里所有地方的 profile 都统一叫“个人资料”，翻译那一行会写出语言名称。([#118](https://github.com/ZigaoWang/zigzag/issues/118))
- “新建空间”在所有地方的写法都一样了。([#119](https://github.com/ZigaoWang/zigzag/issues/119))
- 历史记录在每一行只显示一次时间。([#120](https://github.com/ZigaoWang/zigzag/issues/120))
- 网站数据的标签去掉了一个多余的句号。([#122](https://github.com/ZigaoWang/zigzag/issues/122))
- 命令栏里“设置”只列出一次，各行也不会再用灰字重复自己的标题。([#135](https://github.com/ZigaoWang/zigzag/issues/135), [#136](https://github.com/ZigaoWang/zigzag/issues/136))
- Zigzag Mini 的最近列表不再列出载入失败的页面。([#136](https://github.com/ZigaoWang/zigzag/issues/136))

## [0.8.3] - 2026-11-11

### 新功能
- 边栏的 + 按钮，以及在边栏空白处右键点按，都会打开 Zigzag 自己的菜单：新建标签页、新建文件夹和新建空间…，带各自的快捷键。([#100](https://github.com/ZigaoWang/zigzag/issues/100))
- Zigzag 会跟随“增强对比度”和“降低透明度”：线条、边缘和浅色文字更明显，面板变成不透明。([#105](https://github.com/ZigaoWang/zigzag/issues/105))
- Claude 的侧边面板可以在 Zigzag 中打开了，可以登录并和它聊天。([#112](https://github.com/ZigaoWang/zigzag/issues/112))

### 修复
- 隐藏 YouTube 的广告拦截器警告后，页面可以重新滚动了。([#113](https://github.com/ZigaoWang/zigzag/issues/113))
- 最小化的小播放器会继续播放静音或无声的视频。([#111](https://github.com/ZigaoWang/zigzag/issues/111))
- ⌃Tab 切换器留在边栏旁边的页面上，标签页多时会分行排列。([#110](https://github.com/ZigaoWang/zigzag/issues/110))
- 网站设置不会再把某个操作单独留在一行，网站开关的间距也和 Zigzag 其他地方一致了。([#104](https://github.com/ZigaoWang/zigzag/issues/104))
- 设置里的删除按钮在指针指向某一行时出现，所有地方都一样。([#101](https://github.com/ZigaoWang/zigzag/issues/101))
- 有多份个人资料时，“设置 › 密码”读起来更清楚；窗口窄时，快捷键的提示会换行；中文里“填写”统一用一个词。([#106](https://github.com/ZigaoWang/zigzag/issues/106), [#107](https://github.com/ZigaoWang/zigzag/issues/107), [#108](https://github.com/ZigaoWang/zigzag/issues/108))
- 存储会话时会跳过没有任何变化的写入。([#89](https://github.com/ZigaoWang/zigzag/issues/89))

## [0.8.2] - 2026-11-11

### 修复
- 地址栏在页面上方时，分屏浏览只有一套控件：每个页面自己的栏会并入顶部那一行，不再重复显示后退、重新载入和地址。([#97](https://github.com/ZigaoWang/zigzag/issues/97))
- iCloud 密码等需要和 Mac 上某个 App 通信的扩展，在每份个人资料里都会保持连接，不会过几分钟就要你输入新的验证码。([#98](https://github.com/ZigaoWang/zigzag/issues/98))
- “密码…”会一直开着，直到你选了一个登录信息或去做别的事，不会一打开就关上。([#96](https://github.com/ZigaoWang/zigzag/issues/96))
- 你打开过的固定页面，即使所在的文件夹合上了，也会显示在文件夹下面，和 Arc 一样。([#94](https://github.com/ZigaoWang/zigzag/issues/94))
- 按住 ⌥⌘ 拖动可以从窗口的任何地方移动窗口，设置和空窗口也一样。([#95](https://github.com/ZigaoWang/zigzag/issues/95))
- Zigzag 启动快了一点，“帮助 › 报告问题”生成的卡顿报告会说明当时在运行什么。([#89](https://github.com/ZigaoWang/zigzag/issues/89))
