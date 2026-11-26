<p align="center">
  <a href="https://zigzagbrowser.com"><img src="../../../docs/brand/readme-hero.jpg" width="960" alt="Zigzag: Se siente genial. No pesa nada. El navegador ligero para Mac, gratuito y de código abierto. Una ventana de Zigzag en Split View, Fonts In Use junto a Grilli Type, con la barra lateral de espacios y pestañas fijadas."></a>
</p>

<div align="center">

<p align="center"><sub><a href="../../../README.md">English</a> | <a href="README.zh-Hans.md">简体中文</a> | <a href="README.zh-Hant.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | Español | <a href="README.pt-BR.md">Português (Brasil)</a> | <a href="README.ru.md">Русский</a> | <a href="README.nl.md">Nederlands</a> | <a href="README.pl.md">Polski</a> | <a href="README.tr.md">Türkçe</a></sub></p>

Esta página es una traducción de README.md; si hay diferencias, la versión en inglés es la de referencia.

</div>

<p align="center">
  <a href="https://zigzagbrowser.com/download"><b>Descargar para Mac</b></a><br>
  <sub>o <code>brew install --cask zigaowang/tap/zigzag</code></sub><br>
  <sub>Gratuito y de código abierto. Requiere macOS 15.4 o posterior.</sub>
</p>

<p align="center">
  Tus pestañas en una barra lateral, agrupadas en espacios. Una app nativa para Mac hecha en Swift sobre WebKit,<br>
  de unos 35 MB instalada, sin cuenta y sin telemetría.
</p>

## Por qué lo hice

Hola, soy Zigao, estudiante de bachillerato en Shanghái. Usaba Arc todos los días. Cuando The Browser Company anunció que cerraba Arc el 22 de diciembre, no quería volver a las pestañas en la parte superior, y las alternativas que probé eran bifurcaciones de Chromium o navegadores construidos en torno a la IA. Así que hice el mío, y desde entonces es mi navegador principal.

**¿Por qué WebKit y no Chromium?** En realidad empecé bifurcando Helium. El código fuente ocupaba unos 100 GB y cada compilación tardaba de 3 a 4 horas en mi Mac, algo que no puedo mantener yo solo. WebKit ya viene con macOS, gasta menos batería y memoria, y Apple entrega sus correcciones de seguridad con las actualizaciones de macOS. Aun así tienes extensiones de Chrome, que se instalan directamente desde Chrome Web Store.

**¿Por qué no Zen u Orion?** Probé los dos antes de empezar y son buenos. Zen funciona sobre Firefox, así que usa extensiones de Firefox y a mí no me parece una app de Mac. Orion se acerca más, pero no es de código abierto. Quería algo que funcionara como Arc, que se sintiera nativo, que fuera de código abierto y que ejecutara mis extensiones de Chrome.

## Si vienes de Arc

**Tu Arc se viene contigo.** Archivo › Importar desde otro navegador…, elige Arc y se importan tus espacios, pestañas fijadas, carpetas fijadas, favoritos, historial, contraseñas, inicios de sesión y extensiones. Tus pestañas abiertas también pueden venir, con sus Split View y todo, y esperan a cargarse hasta que hagas clic en ellas; deja sin marcar Pestañas abiertas para empezar desde cero. Si tus espacios están en más de un perfil de Arc, cada perfil de Arc se importa como un perfil propio de Zigzag.

**1Password funciona.** Instálalo desde Chrome Web Store dentro de Zigzag, como harías en Arc. Se comunica con la app de 1Password. La primera vez, añade Zigzag en 1Password › Ajustes › Navegador. Bitwarden también funciona.

**No se puede apagar.** No hay cuenta y Zigzag no depende de ningún servidor mío. Lo único que alojo es el feed de actualizaciones y una lista corta de correcciones para el bloqueo de anuncios, y si desaparecieran, Zigzag seguiría funcionando. [Privacidad](#privacidad) enumera todo a lo que Zigzag se conecta por su cuenta.

## Míralo

<p align="center">
  <img src="../../../docs/spaces.gif" width="960" alt="Cambio entre tres espacios en Zigzag, cada uno con su propio color y sus pestañas">
</p>

<table>
  <tr>
    <td width="50%"><img src="../../../site/assets/clips/split.jpg" alt="Split View: Fonts In Use junto a Grilli Type"><br><b>Split View.</b> Arrastra una pestaña a la página para abrirla al lado, hasta cuatro a la vez.</td>
    <td width="50%"><img src="../../../docs/all-tabs.jpg" alt="Todas las pestañas de tres espacios mostradas como tarjetas"><br><b>Todas las pestañas a la vez.</b> ⇧⌘\ muestra todos los espacios. Escribe para filtrar.</td>
  </tr>
  <tr>
    <td width="50%"><img src="../../../site/assets/win-peek.webp" alt="Un artículo de Wikipedia sobre tipografía sobre la página desde la que se abrió"><br><b>Zigzag Mini.</b> Haz ⇧-clic en un enlace para echarle un vistazo sin perder tu sitio.</td>
    <td width="50%"><img src="../../../site/assets/clips/reader.jpg" alt="Un ensayo de The Public Domain Review en el Lector"><br><b>Lector.</b> Lecturas largas, sin distracciones.</td>
  </tr>
</table>

<p align="center"><sub>Más, en movimiento, en <a href="https://zigzagbrowser.com">zigzagbrowser.com</a>.</sub></p>

## Qué hace

| | |
|---|---|
| **Espacios** | Cada uno con su propio color, icono, pestañas fijadas y carpetas. Desliza sobre la barra lateral, o mueve la rueda del ratón hacia un lado, para cambiar. |
| **Favoritos** | Tus sitios más usados como mosaicos, encima de todos los espacios. Cualquier pestaña, pestaña fijada o favorito puede llevar su propio emoji o símbolo. |
| **Perfiles** | Mantén separados el trabajo y lo personal. Cada perfil tiene sus propias extensiones, inicios de sesión, historial y favoritos, y cada espacio está en uno. |
| **Sitios en espacios** | Elige un espacio para un sitio en Ajustes del sitio o en Ajustes › Espacios, y sus enlaces se abren allí vengan de donde vengan: de otra app, de ⌘T o de otro espacio, como con Air Traffic Control de Arc. Las rutas también pueden ir a sus propios espacios, como `github.com/org1` a uno y `github.com/org2` a otro. Un espacio con su propio perfil funciona como un contenedor de Firefox. |
| **Barra de comandos** | ⌘T o ⌘L. Encuentra pestañas abiertas, historial y sitios. Escribe `you`, pulsa Tab y estás buscando en YouTube. Arrastra la barra a cualquier punto de la ventana y a partir de entonces se abre ahí. |
| **Grupos de pestañas** | Selecciona varias pestañas y elige Agrupar pestañas, y se convierten en una carpeta de la barra lateral que se abre y se cierra, se renombra y se mueve como una sola. Arrastra una pestaña hacia la derecha para anidarla bajo la pestaña de arriba, y hacia la izquierda para sacarla. |
| **Carpetas dinámicas** | Una carpeta fijada que se llena sola desde un feed o un sitio, o desde GitHub: pull requests, solicitudes de revisión, o las incidencias y pull requests abiertas de tus repositorios. Las páginas nuevas llevan un punto. |
| **Split View** | Hasta cuatro pestañas: arrastra una pestaña a los bordes de la página para ocupar una mitad, o a las esquinas para ocupar un cuarto. Arrastra una página por su franja para moverla y fija un Split View para conservarlo. |
| **Ventanas** | Arrastra una pestaña a otra ventana y se mueve tal como está, sin volver a cargarse. Activa Ajustes › Pestañas › Las ventanas comparten las pestañas de un espacio y todas las ventanas de un espacio muestran las mismas pestañas, como en Arc. La barra lateral va a la izquierda o a la derecha. |
| **Apps web** | Instalar como app convierte un sitio en una app propia, en tu carpeta Aplicaciones, en el Dock y en ⌘Tab, con una barra de herramientas del color del sitio. |
| **Minirreproductor** | Sal de una pestaña mientras se reproduce su vídeo y el vídeo te sigue en un reproductor pequeño. Cambia su tamaño desde cualquier borde y colócalo donde quieras, incluso fuera de la ventana, sobre otras apps. Desactívalo desde su menú si prefieres no tenerlo. Cambia a otra app y el vídeo flota sobre ella en Imagen en imagen. |
| **Streaming** | La música y el vídeo protegidos se reproducen como en Safari, mediante FairPlay Streaming de WebKit: el reproductor web de Spotify funciona, y también otros servicios compatibles con Safari. |
| **En reproducción** | Cada pestaña que reproduce sonido en segundo plano recibe una tarjeta al pie de la barra lateral, hasta tres, para pausarla o silenciarla. |
| **Todas las pestañas** | ⇧⌘\ muestra todos los espacios a la vez. Escribe para filtrar y arrastra una pestaña a otro espacio. |
| **Limpiar** | Cierra las pestañas que has dejado de usar y conserva las que estás usando. Apunta a él para ver cuáles cerraría. Un Split View se queda o se va entero. Deshacer las recupera. |
| **Zigzag Mini** | ⌃⌘N abre una ventana pequeña para una página rápida, y ⌘O la pasa a la ventana de tu navegador. Haz ⇧-clic en un enlace, o elige Abrir enlace en Zigzag Mini, y se abre en uno sobre tu ventana; ⌘O lo pone en una pestaña junto a aquella en la que hiciste clic, y Esc lo cierra. Los enlaces de otras apps se abren en él, como en Little Arc (desactívalo en Ajustes › Zigzag Mini), y Abrir en Zigzag Mini pasa una pestaña a uno. |
| **Contraseñas** | En el llavero de tu Mac, sincronizadas con el llavero de iCloud. Touch ID, un generador y una comprobación de las débiles y las reutilizadas. Las llaves de acceso funcionan. |
| **Páginas oscuras** | Sitios claros dibujados en oscuro con el motor de Dark Reader y sus correcciones para miles de sitios, de modo que las fotos conservan su aspecto. Los sitios con un aspecto oscuro propio lo mantienen. Negro puro si lo prefieres más oscuro. Activadas en todas partes o por sitio. |
| **Bloqueo de anuncios** | Integrado y activado: unas 130 000 reglas de EasyList, EasyPrivacy y EasyList China, compiladas en listas de reglas de contenido de WebKit, más las listas de filtros de uBlock Origin, que se actualizan solas. |
| **WebRTC** | Activa Proteger la dirección IP de WebRTC y los sitios no pueden conocer tu dirección IP real a través de WebRTC mientras usas un proxy o una VPN. Las llamadas funcionan en los sitios que permitas, y un sitio que intenta usar WebRTC mientras está bloqueado lo avisa, con Permitir en este sitio. |
| **Avisos de cookies** | Rechazados por ti, nunca aceptados, con las reglas de Autoconsent de DuckDuckGo. Déjalos como están en todas partes o en un solo sitio si prefieres responder tú. |
| **Ajustes del sitio** | Un panel por sitio: zoom, permisos (cámara, micrófono, ubicación, notificaciones, ventanas emergentes, abrir apps, compartir pantalla, WebRTC), cada uno en Preguntar, Permitir o Bloquear, JavaScript activado o desactivado, el certificado, las extensiones y los interruptores de las páginas oscuras, el bloqueo de anuncios y los avisos de cookies. Cuando un sitio pide uno de estos permisos, lo pide en una sola tarjeta sobre la página, por esta vez o siempre, y un sitio al que dijiste que no deja de preguntar. |
| **Boosts** | Ocultar elemento oculta las partes de un sitio que no quieres, como un banner o una barra lateral, y Editar estilo da a un sitio tu propio CSS. Ambos están en el menú ⋯ de Ajustes del sitio y se quedan con el sitio. |
| **Modo de desarrollo** | Para los sitios que programas, `localhost` para empezar: la consola con un contador de errores, Inspeccionar elemento, tamaños de dispositivo, claro y oscuro, estilos de impresión, JavaScript, imágenes o estilos desactivados, otro agente de usuario y un código QR para abrir la página en tu móvil. |
| **Extensiones** | Desde Chrome Web Store, donde el botón de la propia tienda dice Añadir a Zigzag. 1Password, Bitwarden, Dark Reader, Tampermonkey y la mayoría de las populares funcionan; más abajo se explica cuáles no. |
| **Importar** | Marcadores, historial, contraseñas, inicios de sesión y extensiones de Arc, Chrome, Safari, Dia, Edge, Brave, Vivaldi, Opera, Comet, Helium, Yandex, Whale, Chromium, Thorium, Firefox, Zen y Orion. |
| **Descargas** | Envía los archivos de un tipo a su propia carpeta, o abre los seguros, como los PDF, en cuanto se guardan. Las reglas envían un enlace o una descarga a una app, a un script o a un gestor de descargas como aria2, preguntándote antes. Consulta [docs/download-rules.md](../../../docs/download-rules.md). |
| **Automatización** | AppleScript, Atajos y `osascript` pueden listar y abrir pestañas y leer páginas, escritos como los aceptan Safari y Chrome. Consulta [docs/automation.md](../../../docs/automation.md). |
| **Apps de IA** | Desactivado hasta que lo actives: las apps de IA de tu Mac pueden usar tus pestañas mediante MCP, nunca las ventanas privadas ni las contraseñas. Consulta [docs/automation.md](../../../docs/automation.md#ai-apps-mcp). |
| **Tus datos** | Archivo › Exportar tus datos… guarda tus marcadores en un archivo HTML estándar que cualquier navegador importa, y una copia de seguridad completa de Zigzag que puedes restaurar en otro Mac. |
| **Idiomas** | Inglés, chino simplificado, chino tradicional, japonés, coreano, alemán, francés, italiano, español, portugués de Brasil, ruso, neerlandés, polaco y turco. |
| **Y además** | Lector, visor de PDF, Handoff a tu iPhone, iPad u otro Mac, Captura de un área, de una parte de la página o de la página completa (⇧⌘2), traducción en el dispositivo, búsqueda en la página que marca cada coincidencia, un menú Historial con Cerradas recientemente y los últimos siete días, un zoom de página predeterminado, una barra de direcciones sobre la página si prefieres tenerla ahí, Imagen en imagen, ventanas privadas, Inspector web. |

## Lo que falta

Es mi navegador de todos los días, pero Zigzag es joven y encontrarás errores. Lo que notarán los usuarios de Arc:

- No hay sincronización entre Macs ni con el iPhone. Las contraseñas se sincronizan con el llavero de iCloud; los espacios y las pestañas no.
- Los iconos de los espacios no se importan desde Arc; elígelos de nuevo en Zigzag. Los colores de los espacios se importan como el color de Zigzag más parecido.
- No hay Easels ni Notes, y los Boosts son solo CSS (Ocultar elemento y Editar estilo, sin scripts por sitio). No hay IA integrada en el navegador: las apps de IA solo pueden usar Zigzag mediante MCP si lo activas.
- Faltan todavía algunas API de extensiones de Chrome: la API de grupos de pestañas, los ajustes del depurador, el inicio de sesión con cuenta de Google propio de Chrome (`identity.getAuthToken`) y el antiguo bloqueo de peticiones de webRequest. Las extensiones de proxy pueden establecer un proxy HTTP, HTTPS o SOCKS5 fijo, pero no un script PAC, así que el modo Proxy by Patterns de FoxyProxy no funciona.
- EasyList y las demás listas de bloqueo integradas se actualizan con Zigzag, no por su cuenta; solo las de uBlock Origin lo hacen.
- Solo macOS 15.4 o posterior.

## Cómo está hecho

Zigzag tiene unas 120 000 líneas de Swift 6 y AppKit alrededor de `WKWebView`. No hay Chromium ni Electron: el
motor es el WebKit que viene con macOS, y por eso la app es pequeña y las correcciones de seguridad del motor
llegan con las actualizaciones de macOS en lugar de llegar de mí.

| Parte | Cómo |
|---|---|
| **Páginas** | Un `WKWebView` por pestaña. Las pestañas que llevas un rato sin usar pueden suspenderse: la vista web se libera y la pestaña conserva su instantánea y su estado, y se vuelve a cargar cuando regresas. Las ventanas privadas usan un almacén de datos no persistente. |
| **Extensiones** | La compatibilidad de WebKit con extensiones web (`WKWebExtensionController`, el motivo del mínimo de macOS 15.4). Zigzag descarga el paquete CRX3 de Chrome Web Store, comprueba sus firmas y lo carga. Las API de Chrome que WebKit no tiene (historial, marcadores, descargas, notificaciones, paneles laterales, páginas fuera de pantalla, inicio de sesión web, audio de pestañas, páginas de pestaña nueva, scripts de usuario, proxies y más) las responde el propio Zigzag mediante un pequeño puente, comprobadas con los permisos de cada extensión. Un buscador que aporta una extensión (`search_provider`) se suma a las opciones de Ajustes y solo se usa cuando lo eliges. La mensajería nativa conecta las apps auxiliares de 1Password y de otras extensiones. |
| **Aislamiento** | Las imágenes y los PDF de los sitios web se leen en dos helpers XPC aislados, `ZigzagImageDecoder` y `ZigzagPDFRenderer`, sin red ni acceso a archivos, de modo que una imagen o un PDF mal formados no pueden llegar a tus contraseñas ni a tus perfiles. El visor de PDF dibuja las páginas que renderiza el helper; la app nunca abre por sí misma el PDF de un sitio. |
| **Conexiones seguras** | Las advertencias de certificado dicen qué falla en Detalles. Un sitio que pidió solo conexiones seguras, mediante su encabezado HSTS o en la lista de precarga de Chromium (incluida en la app, unos 95 000 nombres, leída en su sitio solo cuando una advertencia lo necesita), no ofrece Visitar este sitio de todos modos, como en Safari y Chrome. A un sitio que pide un certificado para identificarte se le ofrecen los de tu llavero que aceptaría, como en Safari: añade uno abriendo su .p12 en Acceso a Llaveros. |
| **Bloqueo de anuncios** | EasyList, EasyPrivacy y EasyList China convertidas de antemano con SafariConverterLib en listas de reglas de contenido (`WKContentRuleListStore`), compiladas una vez y guardadas en caché. Las listas de uBlock Origin, descargadas conforme caducan, las evalúa el motor de bloqueo de Ghostery en su propio contexto de JavaScript, y cada página recibe los scriptlets y las reglas de ocultación que su sitio necesita al empezar a cargarse. |
| **Páginas oscuras** | El tema dinámico de Dark Reader y sus correcciones por sitio, incluidos en la app, en un mundo de scripts propio. A las páginas se les dice primero que la ventana es oscura, de modo que un sitio con su propio tema oscuro lo usa y se deja como está. |
| **Avisos de cookies** | Autoconsent de DuckDuckGo y sus reglas, incluidos en la app, en un mundo de scripts propio. |
| **Contraseñas** | Se guardan como elementos del llavero, de modo que el llavero de iCloud las sincroniza y Touch ID las desbloquea. Las llaves de acceso pasan por el permiso de llaves de acceso para navegadores de Apple. El autorrelleno es un pequeño content script que solo rellena los campos que puedes ver. |
| **Importar** | Lee los archivos propios de cada navegador: `StorableSidebar.json` de Arc, los marcadores y el historial SQLite de Chromium, `Bookmarks.plist` de Safari, `places.sqlite` de Firefox, `favourites.plist` e `history` de Orion. Las contraseñas de Chromium se descifran con la clave del elemento del llavero de ese navegador, después de que macOS te lo pregunte. |
| **Tus datos** | Espacios, pestañas fijadas y favoritos en `Library.json`, perfiles en `Profiles.json`, pestañas abiertas en `Session.json`, historial en SQLite (un archivo por perfil), todo en `~/Library/Application Support/Zigzag`. Las escrituras se agrupan con retardo y son atómicas, y un archivo que no se puede leer se aparta, nunca se sobrescribe. |
| **Lector** | Readability de Mozilla, ejecutado en la página y mostrado con la tipografía propia de Zigzag. |
| **Apps web** | Un sitio instalado como app es una pequeña app propia en `~/Applications/Zigzag Apps` que entrega cada apertura a Zigzag, de modo que la página se ejecuta en Zigzag con tus inicios de sesión, tus extensiones y tu bloqueo. |
| **Actualizaciones** | Sparkle 2, con actualizaciones firmadas con EdDSA desde zigzagbrowser.com, en un feed estable o beta. Las versiones se firman con Developer ID y se notarizan. |

El código fuente está organizado por función: `Sidebar`, `Tabs`, `Web`, `Extensions`, `Passwords`, `Import`, `Profiles`,
`CommandBar`, `Desk` (todas las pestañas a la vez), `WebApps`, `Developer`, `MCP` (apps de IA), `Settings`, `Window` y
`Design` (los controles dibujados por el propio Zigzag y los tokens de diseño). Más de 2000 pruebas cubren la importación, las contraseñas, las extensiones,
el tratamiento de direcciones, el historial, las apps de IA y las correcciones de seguridad.

## Privacidad

Sin cuenta, sin analíticas, sin telemetría. Nada de cómo navegas se me envía. Estas son las únicas
conexiones que Zigzag hace por su cuenta, además de las páginas que abres:

- **Actualizaciones.** Cada pocas horas, y después de que tu Mac se reactive, Zigzag lee el feed de actualizaciones en zigzagbrowser.com. La
  petición indica la versión de Zigzag y nada más; no se envía ningún perfil del sistema. Una versión nueva también se descarga desde ahí.
- **Sugerencias de búsqueda.** Mientras escribes en la barra de direcciones, el texto va a tu buscador para obtener sugerencias,
  sin cookies. Google, DuckDuckGo, Brave, Bing, Kagi y Ecosia las ofrecen; con cualquier otro buscador no se
  envía nada. Desactívalas en Ajustes › Buscar.
- **Iconos de sitios.** Los iconos vienen de cada sitio, también para pestañas fijadas, favoritos y marcadores importados que
  todavía no has abierto.
- **Listas de filtros.** Al iniciar y después conforme caducan, cada pocas horas o una vez al día, Zigzag descarga las listas de filtros de uBlock
  Origin desde las direcciones propias de uBlock Origin (GitHub Pages, Cloudflare Pages o jsDelivr) y sus
  scriptlets desde el CDN de Ghostery. También descarga desde zigzagbrowser.com la lista corta de correcciones de sitios de Zigzag.
  Las peticiones no llevan cookies ni nada sobre ti o tu navegación.
- **Extensiones.** Instalar una la descarga de Chrome Web Store. Al iniciar, como máximo una vez al día, Zigzag
  pregunta a la tienda si tus extensiones tienen actualizaciones, lo que envía sus ID y versiones a Google.
- **Configuración inicial.** Las pantallas de bienvenida muestran unos pocos iconos de sitios del servicio de iconos de Google y cargan la portada de Wikipedia
  como vista previa.

La traducción se ejecuta en tu Mac, con la traducción en el dispositivo de Apple. Las advertencias de sitios web fraudulentos son las propias de WebKit,
las mismas que las de Safari. Las contraseñas se quedan en el llavero de tu Mac y se sincronizan solo mediante tu propio llavero de iCloud.
Ayuda › Informar de un problema escribe un informe que puedes leer antes, y no se envía nada a menos que lo envíes tú.
La lista de contraseñas del Mac guarda un pequeño registro de sus pasos en `~/Library/Logs/Zigzag/passwords.log`, nunca un inicio de sesión ni
un sitio, y se queda en tu Mac. Tu Tarjeta de Zigzag se crea en tu Mac a partir del nombre de tu cuenta y del día en que Zigzag
se ejecutó por primera vez, y su imagen contiene solo lo que muestra la tarjeta.

## Instalación

Descarga el DMG desde [zigzagbrowser.com](https://zigzagbrowser.com/download), ábrelo y arrastra Zigzag a
Aplicaciones. O, con Homebrew:

    brew install --cask zigaowang/tap/zigzag

Las actualizaciones se instalan solas. Lo que cambió en cada versión está en las
[notas de la versión](https://zigzagbrowser.com/release-notes) y en [CHANGELOG.md](../../../CHANGELOG.md).

## Comentarios

- **Errores e ideas:** [abre una incidencia](https://github.com/ZigaoWang/zigzag/issues/new/choose), o usa Ayuda › Enviar comentarios… en la app. Para un error, Ayuda › Informar de un problema… escribe un informe que puedes leer antes de enviarlo.
- **Correo electrónico:** a@zigao.wang
- **Problemas de seguridad:** consulta [SECURITY.md](../../../SECURITY.md). Por favor, no los publiques en incidencias públicas.

## Compilar desde el código fuente

Requisitos: macOS 15.4 o posterior, Xcode 27 o posterior y [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/ZigaoWang/zigzag.git
cd zigzag
xcodegen generate
open Zigzag.xcodeproj
```

Ejecuta el esquema **Zigzag**. Las compilaciones de depuración se ejecutan como una app aparte, “Zigzag Dev”, con sus propios datos, así que nunca
tocan tu Zigzag de todos los días.

La firma está configurada para mi equipo. Para compilar en tu Mac, cambia dos cosas en `project.yml` y ejecuta
`xcodegen generate` de nuevo:

- `DEVELOPMENT_TEAM`: el ID de tu propio equipo (Xcode › Ajustes › Cuentas lo muestra).
- El `PRODUCT_BUNDLE_IDENTIFIER` de Debug: uno tuyo, como `com.yourname.zigzag.dev`, ya que
  `wang.zigao.zigzag.dev` está registrado a nombre de mi equipo.

Ejecuta las pruebas:

```sh
xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag
```

## Contribuir

Las contribuciones son bienvenidas. Lee [CONTRIBUTING.md](../../../CONTRIBUTING.md) para saber cómo se compila, se prueba y se
da estilo al proyecto.

## Licencia

El código de Zigzag se distribuye bajo la [Apache License, Version 2.0](../../../LICENSE). Úsalo, cámbialo, bifúrcalo y distribúyelo,
con fines comerciales o no.

El nombre “Zigzag”, el icono de la app y el logotipo no están cubiertos por la licencia: son marcas, con todos los derechos
reservados. Una bifurcación necesita su propio nombre e icono. Consulta [TRADEMARKS.md](../../../TRADEMARKS.md) y [NOTICE](../../../NOTICE).
El trabajo de terceros que usa Zigzag figura en [THIRD_PARTY_NOTICES.md](../../../THIRD_PARTY_NOTICES.md).

## Agradecimientos

Gracias a la comunidad de [LINUX DO](https://linux.do) por probar Zigzag desde el principio y compartir sus comentarios.

<p align="center">
  <a href="https://linux.do"><img src="https://shorturl.at/ggSqS" alt="LINUX DO" /></a>
</p>
