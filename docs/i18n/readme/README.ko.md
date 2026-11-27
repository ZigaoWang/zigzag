<p align="center">
  <a href="https://zigzagbrowser.com"><img src="../../../docs/brand/readme-hero.jpg" width="960" alt="Zigzag: 기분 좋고, 가볍습니다. 무료 오픈 소스 Mac용 경량 브라우저입니다. Split View로 열린 Zigzag 윈도우에 Fonts In Use와 Grilli Type이 나란히 있고, 사이드바에는 스페이스와 고정된 탭이 보입니다."></a>
</p>

<div align="center">

<p align="center"><sub><a href="../../../README.md">English</a> | <a href="README.zh-Hans.md">简体中文</a> | <a href="README.zh-Hant.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | 한국어 | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.es.md">Español</a> | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | <a href="README.nl.md">Nederlands</a> | <a href="README.pl.md">Polski</a> | <a href="README.tr.md">Türkçe</a></sub></p>

이 페이지는 README.md의 번역입니다. 내용이 다를 경우 영어 버전을 기준으로 합니다.

</div>

<p align="center">
  <a href="https://zigzagbrowser.com/download"><b>Mac용 다운로드</b></a><br>
  <sub>또는 <code>brew install --cask zigaowang/tap/zigzag</code></sub><br>
  <sub>무료 오픈 소스입니다. macOS 15.4 이상이 필요합니다.</sub>
</p>

<p align="center">
  탭이 사이드바에 있고, 스페이스별로 묶입니다. WebKit 위에서 Swift로 만든 네이티브 Mac 앱으로,<br>
  설치 후 용량은 약 55 MB입니다. 계정도, 텔레메트리도 없습니다.
</p>

## 만든 이유

안녕하세요, 상하이의 고등학생 Zigao입니다. 저는 매일 Arc를 썼습니다. The Browser Company가 12월 22일에 Arc를 종료한다고 했을 때, 탭이 위쪽에 가로로 늘어선 브라우저로는 정말 돌아가고 싶지 않았습니다. 써 본 대안은 Chromium 포크이거나 AI 중심으로 만든 브라우저뿐이었습니다. 그래서 직접 만들었고, 그 뒤로 줄곧 메인 브라우저로 쓰고 있습니다.

**왜 Chromium이 아니라 WebKit인가요?** 처음에는 Helium을 포크해서 시작했습니다. 소스가 약 100 GB였고, 제 Mac에서 빌드 한 번에 3~4시간이 걸렸습니다. 혼자서 계속하기에는 무리였습니다. WebKit은 macOS에 이미 들어 있고, 배터리와 메모리를 덜 쓰며, 보안 수정도 macOS 업데이트로 전달됩니다. 그래도 Chrome 웹 스토어에서 바로 설치해 Chrome 확장 프로그램을 쓸 수 있습니다.

**왜 Zen이나 Orion이 아닌가요?** 이 프로젝트를 시작하기 전에 둘 다 써 봤고, 둘 다 훌륭합니다. Zen은 Firefox 기반이라 Firefox 확장 프로그램을 쓰고, 제게는 Mac 앱처럼 느껴지지 않았습니다. Orion은 그보다 가깝지만 오픈 소스가 아닙니다. 저는 Arc처럼 쓸 수 있고, 네이티브로 느껴지며, 오픈 소스이고, Chrome 확장 프로그램이 동작하는 브라우저를 원했습니다.

## Arc에서 옮겨 오기

**Arc 환경을 그대로 가져올 수 있습니다.** ‘파일 › 다른 브라우저에서 가져오기…’에서 Arc를 선택하면 스페이스, 고정된 탭, 고정된 폴더, 즐겨찾기, 방문 기록, 암호, 로그인 상태, 확장 프로그램이 넘어옵니다. 열린 탭도 Split View까지 함께 가져올 수 있고, 클릭하기 전까지는 로드되지 않습니다. 깨끗하게 시작하려면 ‘열린 탭’ 선택을 해제하세요. 스페이스가 Arc 프로필 여러 개에 나뉘어 있으면, Arc 프로필마다 Zigzag 프로필 하나로 넘어옵니다.

**1Password도 됩니다.** Arc에서처럼 Zigzag 안에서 Chrome 웹 스토어에서 설치하세요. 1Password 앱과 연동되어 동작합니다. 처음 한 번만 1Password의 ‘설정 › 브라우저’에서 Zigzag를 추가하면 됩니다. Bitwarden도 됩니다.

**서비스가 중단될 일이 없습니다.** 계정이 없고, Zigzag는 제 서버에 의존하지 않습니다. 제가 운영하는 것은 업데이트 피드와 광고 차단 수정 목록 하나뿐이며, 그것들이 사라져도 Zigzag는 계속 동작합니다. Zigzag가 스스로 연결하는 곳은 모두 [개인정보 보호](#개인정보-보호)에 나와 있습니다.

## 둘러보기

<p align="center">
  <img src="../../../docs/spaces.gif" width="960" alt="Zigzag에서 스페이스 세 개를 전환하는 모습. 스페이스마다 색상과 탭이 다릅니다">
</p>

<table>
  <tr>
    <td width="50%"><img src="../../../site/assets/clips/split.jpg" alt="Split View: Fonts In Use와 Grilli Type이 나란히 열려 있습니다"><br><b>Split View.</b> 탭을 페이지로 끌어다 놓으면 옆에 나란히 열립니다. 한 번에 최대 4개까지 열 수 있습니다.</td>
    <td width="50%"><img src="../../../docs/all-tabs.jpg" alt="스페이스 세 개의 모든 탭이 카드로 표시되어 있습니다"><br><b>모든 탭을 한눈에.</b> ⇧⌘\ 로 모든 스페이스를 봅니다. 입력하면 걸러 줍니다.</td>
  </tr>
  <tr>
    <td width="50%"><img src="../../../site/assets/win-peek.webp" alt="열어 둔 페이지 위에 겹쳐 표시된 타이포그래피 관련 Wikipedia 문서"><br><b>Zigzag Mini.</b> 링크를 Shift 키를 누른 채 클릭하면 보고 있던 자리를 잃지 않고 훑어볼 수 있습니다.</td>
    <td width="50%"><img src="../../../site/assets/clips/reader.jpg" alt="읽기 도우미로 표시한 The Public Domain Review의 에세이"><br><b>읽기 도우미.</b> 긴 글을 군더더기 없이 읽습니다.</td>
  </tr>
</table>

<p align="center"><sub>움직이는 모습은 <a href="https://zigzagbrowser.com">zigzagbrowser.com</a>에서 더 볼 수 있습니다.</sub></p>

## 기능

| | |
|---|---|
| **스페이스** | 스페이스마다 색상, 아이콘, 고정된 탭, 폴더가 따로 있습니다. 사이드바를 스와이프하거나 마우스 휠을 옆으로 밀면 전환됩니다. |
| **즐겨찾기** | 가장 많이 쓰는 사이트를 타일로 만들어 모든 스페이스 위에 둡니다. 탭, 고정된 탭, 즐겨찾기마다 이모지나 기호를 붙일 수 있습니다. |
| **프로필** | 업무와 개인용을 나눠서 씁니다. 프로필마다 확장 프로그램, 로그인 상태, 방문 기록, 즐겨찾기가 따로 있고, 모든 스페이스는 프로필 하나에 속합니다. |
| **스페이스별 사이트** | 사이트 제어 또는 ‘설정 › 스페이스’에서 사이트의 스페이스를 정하면, 다른 앱, ⌘T, 다른 스페이스 등 어디에서 오든 그 사이트의 링크가 해당 스페이스에서 열립니다. Arc의 Air Traffic Control과 같습니다. 경로마다 다른 스페이스를 정할 수도 있습니다. 예를 들어 `github.com/org1`은 한 스페이스로, `github.com/org2`는 다른 스페이스로 보냅니다. 전용 프로필이 있는 스페이스는 Firefox의 컨테이너처럼 동작합니다. |
| **명령 막대** | ⌘T 또는 ⌘L. 열린 탭, 방문 기록, 사이트를 찾습니다. `you`를 입력하고 Tab 키를 누르면 YouTube 검색이 됩니다. 막대를 윈도우 안 어디로든 끌어다 놓으면 그 뒤로는 그 위치에서 열립니다. |
| **탭 그룹** | 탭 몇 개를 골라 그룹으로 묶으면 사이드바에서 하나의 폴더가 되어, 한꺼번에 열고 닫고, 이름을 바꾸고, 옮길 수 있습니다. 탭을 오른쪽으로 끌면 위의 탭 아래에 중첩되고, 왼쪽으로 끌면 다시 빠져나옵니다. |
| **라이브 폴더** | 피드나 사이트, 또는 GitHub에서 스스로 채워지는 고정된 폴더입니다. GitHub에서는 풀 리퀘스트, 리뷰 요청, 저장소의 열린 이슈와 풀 리퀘스트를 가져옵니다. 새로운 페이지에는 점이 붙습니다. |
| **Split View** | 탭 최대 4개. 탭을 페이지 가장자리로 끌면 절반, 모서리로 끌면 4분의 1 크기가 됩니다. 페이지의 띠를 끌어 옮기고, Split View를 고정하면 유지됩니다. |
| **윈도우** | 탭을 다른 윈도우로 끌면 다시 로드하지 않고 그대로 옮겨 갑니다. ‘설정 › 탭 › 윈도우 간 스페이스 탭 공유’를 켜면 Arc처럼 같은 스페이스의 모든 윈도우에 같은 탭이 표시됩니다. 사이드바는 왼쪽이나 오른쪽에 둘 수 있습니다. |
| **웹 앱** | ‘앱으로 설치’를 쓰면 사이트가 별도의 앱이 되어 응용 프로그램 폴더, Dock, ⌘Tab에 나타나고, 도구 막대가 사이트의 색상으로 표시됩니다. |
| **미니 플레이어** | 비디오가 재생되는 동안 탭을 떠나면 비디오가 작은 플레이어로 따라옵니다. 어느 가장자리에서든 크기를 바꿀 수 있고, 윈도우 밖 다른 앱 위를 포함해 어디든 둘 수 있습니다. 원치 않으면 플레이어의 메뉴에서 끌 수 있습니다. 다른 앱으로 전환하면 비디오가 PIP로 그 위에 떠 있습니다. |
| **스트리밍** | 보호된 음악과 비디오가 Safari처럼 WebKit의 FairPlay Streaming으로 재생됩니다. Spotify 웹 플레이어가 동작하고, Safari를 지원하는 다른 서비스도 마찬가지입니다. |
| **지금 재생 중** | 백그라운드에서 소리를 내는 탭마다 사이드바 아래쪽에 카드가 생기며, 최대 3개까지 표시됩니다. 카드에서 일시 정지하거나 음소거할 수 있습니다. |
| **모든 탭** | ⇧⌘\ 로 모든 스페이스를 한꺼번에 봅니다. 입력해서 걸러 내고, 탭을 다른 스페이스로 끌어 옮길 수 있습니다. |
| **지우기** | 한동안 안 본 탭은 닫고, 작업 중인 탭은 남깁니다. 가리키면 어떤 탭이 닫힐지 보여 줍니다. Split View는 통째로 남거나 통째로 닫힙니다. 실행 취소하면 다시 돌아옵니다. |
| **Zigzag Mini** | ⌃⌘N으로 빠르게 볼 페이지 하나를 작은 윈도우로 열고, ⌘O로 브라우저 윈도우로 옮깁니다. 링크를 Shift 키를 누른 채 클릭하거나 ‘Zigzag Mini에서 링크 열기’를 선택하면 윈도우 위에 Zigzag Mini로 열립니다. ⌘O를 누르면 클릭한 탭 옆의 새로운 탭이 되고, Esc를 누르면 닫힙니다. 다른 앱의 링크도 Little Arc처럼 여기에서 열립니다(‘설정 › Zigzag Mini’에서 끌 수 있습니다). ‘Zigzag Mini에서 열기’는 탭을 Zigzag Mini로 옮깁니다. |
| **암호** | Mac의 키체인에 저장되고 iCloud 키체인으로 동기화됩니다. Touch ID, 암호 생성기, 취약하거나 재사용된 암호 검사를 지원합니다. 패스키도 됩니다. |
| **다크 페이지** | 밝은 사이트를 Dark Reader 엔진으로 어둡게 표시하며, 수천 개 사이트용 수정이 적용되어 사진은 그대로 보입니다. 고유한 다크 모양이 있는 사이트는 그대로 유지됩니다. 더 어둡게 쓰려면 완전한 검은색도 고를 수 있습니다. 모든 사이트에 켜거나 사이트별로 켤 수 있습니다. |
| **광고 차단** | 기본으로 내장되어 켜져 있습니다. EasyList, EasyPrivacy, EasyList China 규칙 약 130,000개를 WebKit 콘텐츠 규칙 목록으로 컴파일해 적용하고, 스스로 업데이트되는 uBlock Origin 필터 목록도 함께 사용합니다. |
| **WebRTC** | ‘WebRTC로부터 IP 주소 보호’를 켜면 프록시나 VPN을 쓰는 동안 사이트가 WebRTC로 실제 IP 주소를 알아낼 수 없습니다. 허용한 사이트에서는 통화가 동작하고, 차단된 상태에서 WebRTC를 시도하는 사이트가 있으면 그 사실을 알려 주며 ‘이 사이트에서 허용’을 선택할 수 있습니다. |
| **쿠키 배너** | DuckDuckGo의 Autoconsent 규칙으로 대신 거절해 주며, 수락하는 일은 없습니다. 직접 답하고 싶다면 모든 사이트에서 또는 사이트 하나에서 그대로 둘 수 있습니다. |
| **사이트 제어** | 사이트마다 패널 하나가 있습니다. 확대/축소, 권한(카메라, 마이크, 위치, 알림, 팝업, 앱 열기, 화면 공유, WebRTC)을 각각 묻기, 허용, 차단 중에서 정하고, JavaScript 켜기/끄기, 인증서, 확장 프로그램, 다크 페이지, 광고 차단, 쿠키 배너 스위치가 모여 있습니다. 사이트가 이 중 하나를 요청하면 페이지 위의 카드 하나로 묻고, 이번만 또는 항상으로 답할 수 있으며, 거절한 사이트는 더 이상 묻지 않습니다. |
| **Boosts** | ‘요소 숨기기’는 배너나 사이드바처럼 사이트에서 원하지 않는 부분을 숨기고, ‘스타일 편집…’은 사이트에 직접 쓴 CSS를 적용합니다. 둘 다 사이트 제어의 ⋯ 메뉴에 있으며 사이트별로 유지됩니다. |
| **개발자 모드** | 직접 만드는 사이트를 위한 모드로, 처음에는 `localhost`가 대상입니다. 오류 개수가 표시되는 콘솔, ‘요소 검사’, 기기 크기, 라이트와 다크, 프린트 스타일, JavaScript, 이미지, 스타일 끄기, 다른 사용자 에이전트, 휴대폰에서 페이지를 여는 QR 코드를 제공합니다. |
| **확장 프로그램** | Chrome 웹 스토어에서 설치하며, 스토어의 버튼에는 ‘Zigzag에 추가’라고 표시됩니다. 1Password, Bitwarden, Dark Reader, Tampermonkey와 인기 있는 대부분의 확장 프로그램이 동작합니다. 동작하지 않는 것은 아래를 참고하세요. |
| **가져오기** | Arc, Chrome, Safari, Dia, Edge, Brave, Vivaldi, Opera, Comet, Helium, Yandex, Whale, Chromium, Thorium, Firefox, Zen, Orion에서 책갈피, 방문 기록, 암호, 로그인 상태, 확장 프로그램을 가져옵니다. |
| **다운로드** | 파일 형식별로 전용 폴더에 보내거나, PDF처럼 안전한 파일은 저장된 뒤 바로 엽니다. 규칙을 만들면 링크나 다운로드를 앱, 스크립트, aria2 같은 다운로드 관리자에 전달하며, 먼저 확인을 받습니다. [docs/download-rules.md](../../../docs/download-rules.md)를 참고하세요. |
| **자동화** | AppleScript, 단축어, `osascript`로 탭 목록을 보고, 탭을 열고, 페이지를 읽을 수 있습니다. Safari와 Chrome이 받는 방식 그대로 작성합니다. [docs/automation.md](../../../docs/automation.md)를 참고하세요. |
| **AI 앱** | 켜기 전에는 꺼져 있습니다. 켜면 Mac의 AI 앱이 MCP로 탭을 사용할 수 있으며, 개인 정보 보호 윈도우와 암호에는 접근할 수 없습니다. [docs/automation.md](../../../docs/automation.md#ai-apps-mcp)를 참고하세요. |
| **데이터** | ‘파일 › 데이터 내보내기…’는 어떤 브라우저에서든 가져올 수 있는 표준 HTML 파일로 책갈피를 저장하고, 다른 Mac에서 복원할 수 있는 Zigzag 전체 백업도 저장합니다. |
| **언어** | 영어, 중국어(간체), 중국어(번체), 일본어, 한국어, 독일어, 프랑스어, 이탈리아어, 스페인어, 포르투갈어(브라질), 러시아어, 네덜란드어, 폴란드어, 튀르키예어. |
| **그 밖에** | 읽기 도우미, PDF 뷰어, iPhone, iPad, 다른 Mac으로의 Handoff, 영역, 페이지 일부, 전체 페이지 캡처(⇧⌘2), 온디바이스 번역, 일치하는 항목을 모두 표시하는 페이지에서 찾기, ‘최근에 닫은 항목’과 최근 7일이 있는 방문 기록 메뉴, 기본 페이지 확대/축소, 원하면 페이지 위에 두는 주소 막대, PIP, 개인 정보 보호 윈도우, 웹 속성 보기. |

## 부족한 점

매일 쓰는 브라우저이지만 Zigzag는 아직 어리고, 버그가 있을 수 있습니다. Arc 사용자가 알아챌 만한 점은 다음과 같습니다.

- Mac 간 동기화나 iPhone 동기화는 없습니다. 암호는 iCloud 키체인으로 동기화되지만 스페이스와 탭은 동기화되지 않습니다.
- 스페이스 아이콘은 Arc에서 넘어오지 않으므로 Zigzag에서 다시 골라야 합니다. 스페이스 색상은 가장 가까운 Zigzag 색상으로 넘어옵니다.
- Easel과 Notes는 없고, Boosts는 CSS만 지원합니다(‘요소 숨기기’와 ‘스타일 편집…’이며 사이트별 스크립트는 없습니다). 브라우저에 내장된 AI는 없습니다. AI 앱은 켠 경우에만 MCP로 Zigzag를 사용할 수 있습니다.
- Chrome 확장 프로그램 API 몇 가지는 아직 없습니다. 탭 그룹 API, 디버거 설정, Chrome 자체의 Google 계정 로그인(`identity.getAuthToken`), 예전 방식의 요청 차단 webRequest가 그렇습니다. 프록시 확장 프로그램은 고정된 HTTP, HTTPS, SOCKS5 프록시는 설정할 수 있지만 PAC 스크립트는 안 되므로, FoxyProxy의 Proxy by Patterns 모드는 동작하지 않습니다.
- EasyList와 그 밖의 내장 차단 목록은 스스로 업데이트되지 않고 Zigzag 업데이트와 함께 갱신됩니다. 스스로 업데이트되는 것은 uBlock Origin 목록뿐입니다.
- macOS 15.4 이상에서만 동작합니다.

## 구성 방식

Zigzag는 `WKWebView`를 중심으로 한 Swift 6와 AppKit 코드 약 170,000줄입니다. Chromium도 Electron도 없습니다. 엔진은 macOS에 포함된 WebKit이어서 앱이 작고, 엔진의 보안 수정도 제가 아니라 macOS 업데이트로 전달됩니다.

| 구성 요소 | 방식 |
|---|---|
| **페이지** | 탭마다 `WKWebView` 하나. 한동안 쓰지 않은 탭은 잠재울 수 있습니다. 웹 뷰는 해제되고 탭은 스냅숏과 상태를 유지하다가, 돌아오면 다시 로드합니다. 개인 정보 보호 윈도우는 영구 저장하지 않는 데이터 저장소를 씁니다. |
| **확장 프로그램** | WebKit의 웹 확장 프로그램 지원(`WKWebExtensionController`)을 씁니다. macOS 15.4 이상이 필요한 이유입니다. Zigzag가 Chrome 웹 스토어에서 CRX3 패키지를 내려받고, 서명을 확인한 다음 로드합니다. WebKit에 없는 Chrome API(방문 기록, 책갈피, 다운로드, 알림, 사이드 패널, 오프스크린 페이지, 웹 로그인, 탭 오디오, 새로운 탭 페이지, 사용자 스크립트, 프록시 등)는 작은 브리지를 통해 Zigzag가 직접 처리하며, 각 확장 프로그램의 권한에 맞춰 검사합니다. 확장 프로그램이 제공하는 검색 엔진(`search_provider`)은 설정의 선택지에 추가되고, 직접 고를 때만 사용됩니다. 네이티브 메시징으로 1Password 등 확장 프로그램의 도우미 앱과 연결합니다. |
| **샌드박스** | 웹 사이트의 이미지와 PDF는 네트워크와 파일 접근이 없는 샌드박스 XPC 도우미 두 개, `ZigzagImageDecoder`와 `ZigzagPDFRenderer`에서 읽습니다. 그래서 잘못된 이미지나 PDF가 암호나 프로필에 닿을 수 없습니다. PDF 뷰어는 도우미가 렌더링한 페이지를 그리며, 앱이 사이트의 PDF를 직접 여는 일은 없습니다. |
| **보안 연결** | 인증서 경고는 ‘세부 사항’에서 무엇이 문제인지 알려 줍니다. HSTS 헤더나 Chromium의 사전 로드 목록(내장, 약 95,000개 이름이며 경고에 필요할 때만 그 자리에서 읽습니다)으로 보안 연결만 쓰겠다고 밝힌 사이트에는 Safari와 Chrome처럼 ‘그래도 이 사이트 방문하기’ 선택지가 없습니다. 사이트가 사용자를 확인할 인증서를 요청하면 Safari처럼 키체인에서 그 사이트가 받아들일 만한 인증서를 보여 줍니다. 인증서를 추가하려면 .p12 파일을 키체인 접근으로 여세요. |
| **광고 차단** | EasyList, EasyPrivacy, EasyList China를 SafariConverterLib으로 미리 변환해 콘텐츠 규칙 목록(`WKContentRuleListStore`)으로 만들고, 한 번 컴파일해 캐시에 보관합니다. 만료될 때마다 내려받는 uBlock Origin 목록은 별도의 JavaScript 컨텍스트에서 Ghostery의 adblocker 엔진이 매칭하며, 페이지마다 로드가 시작될 때 해당 사이트에 필요한 스크립틀릿과 숨김 규칙이 적용됩니다. |
| **다크 페이지** | Dark Reader의 동적 테마와 사이트별 수정을 내장하고, 별도의 스크립트 월드에서 실행합니다. 윈도우가 다크라는 사실을 페이지에 먼저 알려 주므로, 고유한 다크 테마가 있는 사이트는 그 테마를 쓰고 그대로 둡니다. |
| **쿠키 배너** | DuckDuckGo의 Autoconsent와 그 규칙을 내장하고, 별도의 스크립트 월드에서 실행합니다. |
| **암호** | 키체인 항목으로 저장되므로 iCloud 키체인이 동기화하고 Touch ID로 잠금을 풉니다. 패스키는 Apple의 브라우저 패스키 권한을 거칩니다. 자동 완성은 보이는 필드만 채우는 작은 콘텐츠 스크립트입니다. |
| **가져오기** | 각 브라우저의 파일을 직접 읽습니다. Arc의 `StorableSidebar.json`, Chromium의 책갈피와 SQLite 방문 기록, Safari의 `Bookmarks.plist`, Firefox의 `places.sqlite`, Orion의 `favourites.plist`와 `history`입니다. Chromium 암호는 macOS가 허용 여부를 물은 뒤, 해당 브라우저의 키체인 항목에 있는 키로 복호화합니다. |
| **데이터** | 스페이스, 고정된 탭, 즐겨찾기는 `Library.json`, 프로필은 `Profiles.json`, 열린 탭은 `Session.json`, 방문 기록은 SQLite(프로필마다 파일 하나)에 있으며, 모두 `~/Library/Application Support/Zigzag` 아래에 있습니다. 쓰기는 디바운스되고 원자적이며, 읽을 수 없는 파일은 덮어쓰지 않고 따로 보관합니다. |
| **읽기 도우미** | Mozilla의 Readability를 페이지에서 실행하고, Zigzag 고유의 타이포그래피로 보여 줍니다. |
| **웹 앱** | 앱으로 설치한 사이트는 `~/Applications/Zigzag Apps`에 있는 작은 앱이며, 실행할 때마다 Zigzag에 넘깁니다. 그래서 페이지는 Zigzag 안에서 로그인 상태, 확장 프로그램, 차단 기능과 함께 실행됩니다. |
| **업데이트** | Sparkle 2를 쓰며, zigzagbrowser.com에서 EdDSA 서명된 업데이트를 안정 또는 베타 피드로 받습니다. 릴리스는 Developer ID로 서명하고 공증합니다. |

소스는 기능별로 나뉘어 있습니다. `Sidebar`, `Tabs`, `Web`, `Extensions`, `Passwords`, `Import`, `Profiles`, `CommandBar`, `Desk`(모든 탭), `WebApps`, `Developer`, `MCP`(AI 앱), `Settings`, `Window`, `Design`(Zigzag가 직접 그린 컨트롤과 디자인 토큰)입니다. 테스트 4,000개 이상이 가져오기, 암호, 확장 프로그램, 주소 처리, 방문 기록, AI 앱, 보안 수정을 다룹니다.

## 개인정보 보호

계정도, 분석도, 텔레메트리도 없습니다. 어떻게 브라우징하는지는 저에게 전혀 전송되지 않습니다. 열어 보는 페이지를 제외하면, Zigzag가 스스로 연결하는 곳은 다음뿐입니다.

- **업데이트.** 몇 시간마다, 그리고 Mac이 잠자기에서 깨어난 뒤에 Zigzag가 zigzagbrowser.com의 업데이트 피드를 읽습니다. 요청에는 Zigzag 버전만 담기고, 시스템 프로필은 전송되지 않습니다. 새로운 버전도 같은 곳에서 내려받습니다.
- **검색 제안.** 주소 막대에 입력하는 동안 제안을 받기 위해 입력한 텍스트가 검색 엔진으로 전송되며, 쿠키는 포함되지 않습니다. Google, DuckDuckGo, Brave, Bing, Kagi, Ecosia가 제안을 제공하고, 다른 검색 엔진에서는 아무것도 전송되지 않습니다. ‘설정 › 검색’에서 끌 수 있습니다.
- **사이트 아이콘.** 아이콘은 각 사이트에서 직접 가져오며, 고정된 탭, 즐겨찾기, 아직 열어 보지 않은 가져온 책갈피에도 마찬가지입니다.
- **필터 목록.** 실행할 때, 그리고 만료될 때마다(몇 시간에서 하루에 한 번 사이) Zigzag가 uBlock Origin의 필터 목록을 uBlock Origin의 주소(GitHub Pages, Cloudflare Pages, jsDelivr)에서, 스크립틀릿을 Ghostery의 CDN에서 내려받습니다. Zigzag의 짧은 사이트 수정 목록도 zigzagbrowser.com에서 내려받습니다. 요청에는 쿠키도, 사용자나 브라우징에 관한 정보도 담기지 않습니다.
- **확장 프로그램.** 설치하면 Chrome 웹 스토어에서 내려받습니다. 실행할 때, 하루에 최대 한 번 Zigzag가 확장 프로그램에 업데이트가 있는지 스토어에 묻고, 이때 확장 프로그램의 ID와 버전이 Google에 전송됩니다.
- **설정.** 환영 화면은 Google 아이콘 서비스의 사이트 아이콘 몇 개를 보여 주고, 미리보기로 Wikipedia 첫 페이지를 로드합니다.

번역은 Apple의 온디바이스 번역으로 Mac에서 실행됩니다. 사기 웹 사이트 경고는 Safari와 같은 WebKit 고유의 기능입니다. 암호는 Mac의 키체인에만 있고, 사용자 본인의 iCloud 키체인을 통해서만 동기화됩니다. ‘도움말 › 문제 보고…’는 보내기 전에 읽어 볼 수 있는 보고서를 작성하며, 사용자가 보내지 않으면 아무것도 전송되지 않습니다. Mac의 암호 목록은 `~/Library/Logs/Zigzag/passwords.log`에 작업 단계를 짧게 기록하지만 로그인 정보나 사이트는 담지 않으며, 이 기록은 Mac에만 남습니다. Zigzag 카드는 계정 이름과 Zigzag를 처음 실행한 날로 Mac에서 만들어지며, 카드 이미지에는 카드에 표시된 내용만 들어 있습니다.

## 설치

[zigzagbrowser.com](https://zigzagbrowser.com/download)에서 DMG를 내려받아 열고, Zigzag를 응용 프로그램 폴더로 끌어다 놓으세요. Homebrew를 쓴다면 다음과 같이 합니다.

    brew install --cask zigaowang/tap/zigzag

업데이트는 저절로 설치됩니다. 버전마다 무엇이 바뀌었는지는 [릴리스 노트](https://zigzagbrowser.com/release-notes)와 [CHANGELOG.md](../../../CHANGELOG.md)에 있습니다.

## 피드백

- **버그와 아이디어:** [이슈 열기](https://github.com/ZigaoWang/zigzag/issues/new/choose), 또는 앱에서 ‘도움말 › 피드백 보내기…’. 버그는 ‘도움말 › 문제 보고…’로 보내기 전에 읽어 볼 수 있는 보고서를 작성하세요.
- **이메일:** a@zigao.wang
- **보안 문제:** [SECURITY.md](../../../SECURITY.md)를 참고하세요. 공개 이슈에는 올리지 마세요.

## 소스에서 빌드하기

요구 사항: macOS 15.4 이상, Xcode 27 이상, [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/ZigaoWang/zigzag.git
cd zigzag
xcodegen generate
open Zigzag.xcodeproj
```

**Zigzag** 스킴을 실행하세요. 디버그 빌드는 별도의 앱 ‘Zigzag Dev’로 실행되며 데이터도 따로 쓰므로, 평소 쓰는 Zigzag에는 영향을 주지 않습니다.

서명은 제 팀 기준으로 설정되어 있습니다. 사용자의 Mac에서 빌드하려면 `project.yml`에서 두 가지를 바꾸고 `xcodegen generate`를 다시 실행하세요.

- `DEVELOPMENT_TEAM`: 사용자의 팀 ID입니다(Xcode › Settings › Accounts에서 볼 수 있습니다).
- Debug의 `PRODUCT_BUNDLE_IDENTIFIER`: `com.yourname.zigzag.dev`처럼 직접 정한 값입니다. `wang.zigao.zigzag.dev`는 제 팀에 등록되어 있기 때문입니다.

테스트 실행:

```sh
xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag
```

## 기여하기

기여를 환영합니다. 프로젝트를 어떻게 빌드하고, 테스트하고, 스타일을 맞추는지는 [CONTRIBUTING.md](../../../CONTRIBUTING.md)를 읽어 보세요.

## 라이선스

Zigzag의 코드는 [Apache License, Version 2.0](../../../LICENSE)에 따라 라이선스됩니다. 상업적이든 아니든 사용하고, 수정하고, 포크하고, 배포할 수 있습니다.

‘Zigzag’라는 이름, 앱 아이콘, 로고는 라이선스 대상이 아닙니다. 상표이며 모든 권리가 유보됩니다. 포크는 별도의 이름과 아이콘이 필요합니다. [TRADEMARKS.md](../../../TRADEMARKS.md)와 [NOTICE](../../../NOTICE)를 참고하세요. Zigzag가 사용하는 서드파티 저작물은 [THIRD_PARTY_NOTICES.md](../../../THIRD_PARTY_NOTICES.md)에 정리되어 있습니다.

## 감사의 말

Zigzag를 일찍 써 보고 피드백을 나눠 준 [LINUX DO](https://linux.do) 커뮤니티에 감사드립니다.

<p align="center">
  <a href="https://linux.do"><img src="https://shorturl.at/ggSqS" alt="LINUX DO" /></a>
</p>
