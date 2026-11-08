# Simplified Chinese glossary

The words Zigzag uses most, and what they become in Simplified Chinese (zh-Hans). Translating the catalog
(`Zigzag/Resources/Localizable.xcstrings`) starts from this table, so one English word is one Chinese word everywhere.

Where macOS or Safari already has a word for the same thing, Zigzag uses Apple's, so it reads like the rest of the Mac:
边栏, not 侧边栏; 共享, not 分享; 重新载入, not 刷新. Every term here is decided; the last column keeps the words
considered and not used, so a translator doesn't bring them back.

Brand and product names stay as they are in every sentence: Zigzag, Arc, Chrome, Safari, Firefox, Brave, Edge,
macOS, iCloud, Google, 1Password.

## Typography

The rules the catalog follows, checked by `LocalizationTests`:

- **A space between Chinese and a Latin word or a number**, as Apple's zh-Hans UI writes it (使用 iCloud 钥匙串,
  在“访达”中显示, Finder's 12 项): 从 Chrome 导入, 关闭 3 个标签页, 第 2 步，共 7 步. No space beside full-width
  punctuation or quotes: “%@”的页面, 已从“个人”归档.
- A placeholder gets the same spacing as what fills it: a site, a browser, a count or an extension's name is
  Latin or a number, so it gets spaces (已清除 %@ 的 Cookie); a weekday or a language is Chinese, so none
  (%@下午, 此页面为%@).
- **Full-width punctuation** in Chinese sentences: ，。：；？！（）. A sentence that is all Latin keeps its own
  (© 2026 Zigao Wang. Apache License 2.0.). Lists of short items join with 、 (6 个密码、历史记录).
- **Quotes** “” around names the person gave (a space, a file) and around Zigzag's and macOS's own buttons and
  places named in a sentence (点按“始终允许”, “系统设置 › 隐私与安全性”). Not around an extension's name: when it
  has none, the sentence gets 一个扩展 or 此扩展 in its place.
- Menu paths keep Zigzag's ›, inside one pair of quotes: “设置 › 扩展”.
- Times of day in History's session names: 上午 (5–12), 下午 (12–17), 晚上 (17–21), 夜里 (21–24), 凌晨 (0–5).
- Plurals: Chinese has one form, so one reads like many (关闭 1 个标签页). Sentences that said “it” for one and
  “they” for many are worded to fit both.

## Places and things

| English | 简体中文 | Not used | Why |
|---|---|---|---|
| Space | 空间 | 工作区 | Arc's Chinese users say 空间, and macOS calls Mission Control's Spaces 空间. 工作区 was clearer next to Mission Control but colder, and not what Arc users know. |
| Tab | 标签页 | | Safari and Chrome. |
| New Tab | 新建标签页 | | Safari's button and menu item. |
| Pinned (the section) | 已固定 | 固定标签页 | Safari's Pin Tab is 固定标签页; as a heading 已固定 is shorter. |
| Pin Tab | 固定标签页 | | Safari's menu item. |
| Back to Pinned Page | 回到固定的页面 | 返回固定页面 | Plain and short; 回到 reads warmer than 返回. |
| Favorites | 收藏 | 个人收藏, 常用 | Zigzag's Favorites are the row of icons on top, and 收藏 fits it and tight places. Safari's 个人收藏 is longer and names a different thing; 常用 sounds like most visited. |
| Bookmarks | 书签 | | Safari, Chrome. |
| Folder | 文件夹 | | macOS. |
| Sidebar | 边栏 | 侧边栏 | macOS and Safari say 边栏 (显示边栏). |
| Window | 窗口 | | macOS. |
| Private window | 无痕浏览窗口 | 隐私浏览窗口, 无痕窗口 | Safari's New Private Window is 新建无痕浏览窗口. |
| Split View | 分屏浏览 | 分栏 | macOS calls its Split View 分屏浏览. |
| Peek | 速览 | 预览, keep "Peek" | No Apple word; Quick Look is 快速查看, so 速览 is close without clashing. 预览 clashes with the Preview app; English would read as untranslated. |
| Command Bar | 命令栏 | 指令栏 | Arc's Chinese users say 命令栏; 指令栏 is seen less. |
| Site controls (the site panel) | 网站设置 | 网站控制 | Safari's per-site settings are 网站设置; "控制" sounds technical. |
| Address (field) | 地址栏 | 智能搜索栏 | Safari calls it 智能搜索栏, but Zigzag's field is plainer; 地址栏 is what people say. |
| Downloads | 下载 | 下载项 | Safari's list is 下载项; as a title and button, 下载 is enough. |
| History | 历史记录 | | Safari. |
| Settings | 设置 | | macOS since Ventura. |
| Extensions | 扩展 | 扩展程序 | Safari says 扩展; Chrome says 扩展程序. Zigzag runs Chrome extensions, but on a Mac 扩展 reads native. |
| Passwords | 密码 | | macOS Passwords app. |
| Passkeys | 通行密钥 | | Apple's term. |
| Sign-ins (staying signed in, imported) | 登录状态 | 登录信息 | Zigzag means "you stay signed in to your sites"; 登录状态 says that, 登录信息 sounds like saved passwords. |
| Reader | 阅读器 | | Safari's 显示阅读器 / 隐藏阅读器. |
| Capture (screenshot of the page) | 截图 | 截取, 屏幕快照 | macOS's Screenshot app is 截屏; for a page, 截图 is what people say. |
| Archive (old tabs put away) | 归档 | 存档 | Arc's Chinese users say 归档. |
| Getting Started (the guide) | 入门 | 新手指南 | Short, Apple-like. |
| What's New | 新功能 | 更新内容 | Apple uses 新功能. |
| Chrome Web Store | Chrome 网上应用店 | Chrome 应用商店 | Google's own Chinese name for it. |

## Actions

| English | 简体中文 | Not used | Why |
|---|---|---|---|
| Clear (history, cache, cookies) | 清除 | 清空 | Safari: 清除历史记录. |
| Close Tab | 关闭标签页 | | Safari. |
| Reopen Closed Tab | 重新打开已关闭的标签页 | | Safari's 重新打开最近关闭的标签页, shortened. |
| Duplicate Tab | 复制标签页 | | Safari. |
| Move Tab to New Window | 将标签页移到新窗口 | | Safari's menu item exactly. |
| Mute Tab | 将标签页静音 | 静音 | Safari. |
| Reload | 重新载入 | 刷新 | Safari: 重新载入页面. |
| Back / Forward | 后退 / 前进 | | Safari. |
| Share… | 共享… | 分享… | macOS's Share menu is 共享. |
| Import | 导入 | | Safari: 从浏览器导入. |
| Undo | 撤销 | | macOS. |
| Translate Page | 翻译网页 | | Safari. |
| Picture in Picture | 画中画 | | macOS. |
| Find… | 查找… | | macOS. |
| Zoom In / Out | 放大 / 缩小 | | macOS. |
| Set as Default Browser | 设为默认浏览器 | | macOS's own wording in Desktop & Dock. |
| Not Now | 以后 | 以后再说, 现在不 | Apple's button. |
| Copy | 拷贝 | 复制 | macOS's Edit menu. 复制 is Duplicate (复制标签页). |
| Save | 存储 | 保存 | macOS's File menu (存储为…). |

## How it reads

- Ellipsis stays a single `…`, as Apple writes 共享… and 查找….
- Full-width punctuation in Chinese sentences (，。：“”), never a half-width comma inside Chinese.
- Counts take a measure word: 3 个标签页, 2 个空间, 5 个密码. Chinese has one plural form, so the catalog's
  plural variations need only "other".
- Keyboard keys stay as symbols (⌘T). The space bar's name is 空格键, never 空间.
- 你, not 您, matching Apple's zh-Hans voice and Zigzag's warm, plain English.
