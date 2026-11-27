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
