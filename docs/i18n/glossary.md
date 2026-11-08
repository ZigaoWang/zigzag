# Simplified Chinese glossary

The words Zigzag uses most, and what they become in Simplified Chinese (zh-Hans). Translating the catalog
(`Zigzag/Resources/Localizable.xcstrings`) starts from this table, so one English word is one Chinese word everywhere.

Where macOS or Safari already has a word for the same thing, Zigzag uses Apple's, so it reads like the rest of the Mac:
边栏, not 侧边栏; 共享, not 分享; 重新载入, not 刷新. Rows marked **Decide** have a real choice to make first.

Brand and product names stay as they are in every sentence: Zigzag, Arc, Chrome, Safari, Firefox, Brave, Edge,
macOS, iCloud, Google. A space goes between Chinese and a Latin word or a number ("从 Chrome 导入", "3 个标签页"),
as Apple writes it.

## Places and things

| English | 简体中文 | Alternatives | Why |
|---|---|---|---|
| Space | 空间 | 工作区 | Arc's Chinese users say 空间, and macOS calls Mission Control's Spaces 空间. **Decide**: 空间 could be confused with Mission Control's; 工作区 is clearer but colder and not what Arc users know. |
| Tab | 标签页 | | Safari and Chrome. |
| New Tab | 新建标签页 | | Safari's button and menu item. |
| Pinned (the section) | 已固定 | 固定标签页 | Safari's Pin Tab is 固定标签页; as a heading 已固定 is shorter. |
| Pin Tab | 固定标签页 | | Safari's menu item. |
| Back to Pinned Page | 回到固定的页面 | 返回固定页面 | Plain and short; 回到 reads warmer than 返回. |
| Favorites | 个人收藏 | 收藏, 常用 | Safari's Favorites are 个人收藏. **Decide**: 个人收藏 is Apple's, but in Zigzag Favorites are the row of icons on top; 收藏 is shorter in tight places. |
| Bookmarks | 书签 | | Safari, Chrome. |
| Folder | 文件夹 | | macOS. |
| Sidebar | 边栏 | 侧边栏 | macOS and Safari say 边栏 (显示边栏). |
| Window | 窗口 | | macOS. |
| Private window | 无痕浏览窗口 | 隐私浏览窗口, 无痕窗口 | Safari's New Private Window is 新建无痕浏览窗口. |
| Split View | 分屏浏览 | 分栏 | macOS calls its Split View 分屏浏览. |
| Peek | 速览 | 预览, keep "Peek" | **Decide**: no Apple word; Quick Look is 快速查看, so 速览 is close without clashing. 预览 clashes with the Preview app. |
| Command Bar | 命令栏 | 指令栏 | **Decide**: Arc's community says 命令栏; 指令栏 also seen. |
| Site controls (the site panel) | 网站设置 | 网站控制 | Safari's per-site settings are 网站设置; "控制" sounds technical. |
| Address (field) | 地址栏 | 智能搜索栏 | Safari calls it 智能搜索栏, but Zigzag's field is plainer; 地址栏 is what people say. |
| Downloads | 下载 | 下载项 | Safari's list is 下载项; as a title and button, 下载 is enough. |
| History | 历史记录 | | Safari. |
| Settings | 设置 | | macOS since Ventura. |
| Extensions | 扩展 | 扩展程序 | Safari says 扩展; Chrome says 扩展程序. Zigzag runs Chrome extensions, but on a Mac 扩展 reads native. |
| Passwords | 密码 | | macOS Passwords app. |
| Passkeys | 通行密钥 | | Apple's term. |
| Sign-ins (staying signed in, imported) | 登录状态 | 登录信息 | **Decide**: Zigzag means "you stay signed in to your sites"; 登录状态 says that, 登录信息 sounds like saved passwords. |
| Reader | 阅读器 | | Safari's 显示阅读器 / 隐藏阅读器. |
| Capture (screenshot of the page) | 截图 | 截取, 屏幕快照 | macOS's Screenshot app is 截屏; for a page, 截图 is what people say. |
| Archive (old tabs put away) | 归档 | 存档 | Arc's Chinese users say 归档. |
| Getting Started (the guide) | 入门 | 新手指南 | Short, Apple-like. |
| What's New | 新功能 | 更新内容 | Apple uses 新功能. |

## Actions

| English | 简体中文 | Alternatives | Why |
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

## How it reads

- Ellipsis stays a single `…`, as Apple writes 共享… and 查找….
- Full-width punctuation in Chinese sentences (，。：“”), never a half-width comma inside Chinese.
- Counts take a measure word: 3 个标签页, 2 个空间, 5 个密码. Chinese has one plural form, so the catalog's
  plural variations need only "other".
- Keyboard keys stay as symbols (⌘T). The space bar's name is 空格键, never 空间.
- 你, not 您, matching Apple's zh-Hans voice and Zigzag's warm, plain English.
