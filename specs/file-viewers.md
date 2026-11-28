# File viewers

## Markdown
- Open a .md or .markdown file on your Mac → it shows formatted in the tab, with its pictures, and the address bar names the file.
  Test: MarkdownPageTests.aLocalFileOpensFormattedWithItsPicturesAndNoScripts
- A web page sent as text/markdown, or as text/plain at a .md address → shows formatted; other plain text stays plain text.
  Test: MarkdownPageTests.markdownResponsesAreTheOnesShown
  Test: MarkdownPageTests.aTextPlainMarkdownFileFromALocalServerOpensFormatted
- A file sent as a download, or past 16 MB → opens as it would without the viewer.
  Test: MarkdownPageTests.markdownResponsesAreTheOnesShown
- Tables, task lists, strikethrough and fenced code → shown as on GitHub; each heading gets GitHub's anchor.
  Test: MarkdownPageTests.rendersGitHubTablesTaskListsAndFencedCode
  Test: MarkdownPageTests.headingsGetGitHubAnchorsAndNeverTakeTheSourceAnchor
- Raw HTML in the file → shown as text; comments are left out, and only plain inline tags like `<br>`, `<kbd>` and `<sup>` work.
  Test: MarkdownPageTests.rawHTMLAndScriptsShowAsTextAndNeverRun
- The page runs no scripts, frames or forms, whatever the file holds.
  Test: MarkdownPageTests.thePageRunsNothing
  Test: MarkdownPageTests.aLocalFileOpensFormattedWithItsPicturesAndNoScripts
- Links → go to the web, mail and phone links as usual; a local file's links to other local files open them; `javascript:`, `data:` and Zigzag's own pages lose their link and keep their words.
  Test: MarkdownPageTests.linksAndPicturesGoOnlyWhereAPageCould
  Test: MarkdownPageTests.theViewerKeepsTheFilesAddressAndSendsATabNowhereElseOfZigzags
- Relative links and pictures → found next to the file, on your Mac or on the web.
  Test: MarkdownPageTests.relativeLinksAndPicturesResolveAgainstTheFile
- A picture beside a local file → shown only from the file's own folder, as a local page could read it; a link out of the folder isn't followed.
  Test: MarkdownPageTests.picturesBesideAFileStayInsideItsFolder
- Source at the top → the file's plain text; Preview goes back. Each tab keeps its own choice through a reload, and Back undoes it.
  Test: MarkdownPageTests.sourceSwitchShowsTheTextAndIsKeptPerTab
- A file of several MB → set off the main thread, Zigzag keeps answering while it opens.
  Test: MarkdownPageTests.aBigFileRendersQuicklyAndOffTheMainThread

## Office and Apple documents
- Open a Word, Excel, PowerPoint, Pages, Numbers, Keynote or RTF file on your Mac → it shows read-only in the tab in macOS's own Quick Look view, and the address bar names the file.
  Test: FileViewerTests.aDocxAndXlsxOnYourMacOpenInQuickLook
- A site sends one of those documents → it's fetched again with the tab's cookies into a private temporary folder, marked as downloaded, and shown the same way; the copy goes when the tab leaves it.
  Test: FileViewerTests.aWebDocumentDownloadsThenPreviews
- A document sent as an attachment, a form's reply, an error, or one past 200 MB → downloads as it would without the viewer.
  Test: FileViewerTests.responsesThatOpenInQuickLook
- A slim bar at the top → the file's name, Open in its app, and Show in Finder for a file on your Mac or Download for one from the web. Open in its app downloads a web file first, so changes are kept.
  Test: FileViewerTests.aDocxAndXlsxOnYourMacOpenInQuickLook
- The page under the viewer runs nothing and sends the tab nowhere; Quick Look reads the file out of process, as Finder's preview does.
  Test: FileViewerTests.responsesThatOpenInQuickLook

## Folders
- Open a folder on your Mac → a list of its files with name, kind, size and date, instead of WebKit's bare listing; the address bar names the folder.
  Test: FileViewerTests.aFolderListsSortsAndOpens
- Click a column's heading → sorted by it; click it again → the other way. Size and date start largest and newest first.
  Test: FileViewerTests.aFolderListsSortsAndOpens
- Hidden files stay hidden; Show Hidden Files lists them, Hide Hidden Files hides them again.
  Test: FileViewerTests.aFolderListsSortsAndOpens
- Click a folder → its list; a file a tab shows (a page, picture, PDF, text, Markdown, Office or Apple document) → opens in the tab; any other file → Quick Look.
  Test: FileViewerTests.aFolderListsSortsAndOpens
- The list runs no scripts: sorting and hidden files are links to the same list, and it can send the tab only to itself or to Quick Look for a file in it.
  Test: FileViewerTests.aFolderPageSendsItsTabOnlyToItselfOrItsFiles
