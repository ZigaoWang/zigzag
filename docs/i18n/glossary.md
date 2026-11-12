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
| Profile | 个人资料 | 描述文件, 配置文件, 用户 | What Chrome and Edge call a browser profile, so it's the word people already know for one. 描述文件 is what macOS calls configuration profiles (System Settings › 描述文件), installed settings that manage a Mac, so it reads as that; 配置文件 as a settings file; 用户 as an account. Counted with 份 (每份个人资料, 同一份个人资料), and 此个人资料 for this one. The first profile, until it's named, is 默认. The one Settings shows, as a heading, is 当前个人资料. |
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
| Zigzag Mini | Zigzag Mini | 迷你窗口, 小窗口, 迷你 Arc | A name, like the app's, so it stays in Latin letters (新建 Zigzag Mini). Arc called it Little Arc. Where a plain noun reads better in a sentence, 迷你窗口. |
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
| Cookie banners (a site's consent pop-up) | Cookie 弹窗 | Cookie 横幅, Cookie 提示, 同意弹窗 | Cookie stays Latin, as in 已清除 %@ 的 Cookie; 弹窗 is what people call these. Its choices: 尽可能拒绝, 不处理. |
| Dark pages, Dark page (one site's) | 深色网页 | 暗色网页, 夜间模式 | macOS says 深色 for Dark Mode. |
| Force dark (a site's) | 强制深色 | 强制暗色 | 深色 as above; 强制 is the plain word for doing it anyway. |
| Capture (screenshot of the page) | 截图 | 截取, 屏幕快照 | macOS's Screenshot app is 截屏; for a page, 截图 is what people say. |
| Archive (old tabs put away) | 归档 | 存档 | Arc's Chinese users say 归档. |
| Getting Started (the guide) | 入门 | 新手指南 | Short, Apple-like. |
| What's New | 新功能 | 更新内容 | Apple uses 新功能. |
| Chrome Web Store | Chrome 网上应用店 | Chrome 应用商店 | Google's own Chinese name for it. |
| Automation (the Settings section) | 自动化 | | macOS's Privacy & Security › Automation is 自动化. |
| AI apps | AI 应用 | AI 程序, 人工智能应用 | Short, and what people say. MCP stays as it is. |
| Key (for AI apps) | 密钥 | 令牌, 钥匙 | What apps send to connect; 密钥 is the plain word for a secret key. |
| Setup (the JSON an app takes) | 配置 | 设置 | 设置 is Settings; 配置 is the setup you paste. |
| Prompt (to paste into an AI app) | 提示词 | 提示, 指令 | What AI apps' Chinese users call it. |
| Scripts (AppleScript, Shortcuts) | 脚本 | | macOS's Script Editor is 脚本编辑器. |
| Emoji (an icon you type or search for) | 表情符号 | 表情, emoji | macOS's Edit menu says 表情与符号; 表情 alone reads as a face's expression. |

## Actions

| English | 简体中文 | Not used | Why |
|---|---|---|---|
| Clear (history, cache, cookies) | 清除 | 清空 | Safari: 清除历史记录. |
| Close Tab | 关闭标签页 | | Safari. |
| Reopen Closed Tab | 重新打开已关闭的标签页 | | Safari's 重新打开最近关闭的标签页, shortened. |
| Duplicate Tab | 复制标签页 | | Safari. |
| Move Tab to New Window | 将标签页移到新窗口 | | Safari's menu item exactly. |
| Mute Tab | 将标签页静音 | 静音 | Safari. |
| Change Icon… (a folder, tab, pinned tab, favorite) | 更改图标… | 更换图标… | Plain, as 更改 is everywhere in macOS. |
| Use Site Icon | 使用网站图标 | 恢复默认图标, 还原图标 | Says which icon comes back: the site's own, 网站 as in 网站设置. |
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
| Fill (a password, a form, from My Card) | 填写 | 填充 | What you'd do by hand, so it reads plainly: 填写存储的密码, 用“我的名片”填写表单, 在“%@”中存储和填写. |
| AutoFill (the feature, as a heading) | 自动填充 | 自动填写 | Apple's own name for it in Safari and macOS; only as that name, never as the verb in a sentence. |

## How it reads

- Ellipsis stays a single `…`, as Apple writes 共享… and 查找….
- Full-width punctuation in Chinese sentences (，。：“”), never a half-width comma inside Chinese.
- Counts take a measure word: 3 个标签页, 2 个空间, 5 个密码. Chinese has one plural form, so the catalog's
  plural variations need only "other".
- Keyboard keys stay as symbols (⌘T). The space bar's name is 空格键, never 空间.
- 你, not 您, matching Apple's zh-Hans voice and Zigzag's warm, plain English.
