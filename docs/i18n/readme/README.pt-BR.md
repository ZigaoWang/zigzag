<p align="center">
  <a href="https://zigzagbrowser.com"><img src="../../../docs/brand/readme-hero.jpg" width="960" alt="Zigzag: ótimo de usar, leve como o ar. O navegador leve para Mac, gratuito e de código aberto. Uma janela do Zigzag em Split View, com Fonts In Use ao lado de Grilli Type e a barra lateral de espaços e abas fixadas."></a>
</p>

<div align="center">

<p align="center"><sub><a href="../../../README.md">English</a> | <a href="README.zh-Hans.md">简体中文</a> | <a href="README.zh-Hant.md">繁體中文</a> | <a href="README.ja.md">日本語</a> | <a href="README.ko.md">한국어</a> | <a href="README.de.md">Deutsch</a> | <a href="README.fr.md">Français</a> | <a href="README.it.md">Italiano</a> | <a href="README.es.md">Español</a> | Português (Brasil) | <a href="README.ru.md">Русский</a> | <a href="README.nl.md">Nederlands</a> | <a href="README.pl.md">Polski</a> | <a href="README.tr.md">Türkçe</a></sub></p>

Esta página é uma tradução do README.md; se houver diferenças, a versão em inglês é a referência.

</div>

<p align="center">
  <a href="https://zigzagbrowser.com/download"><b>Baixar para Mac</b></a><br>
  <sub>ou <code>brew install --cask zigaowang/tap/zigzag</code></sub><br>
  <sub>Gratuito e de código aberto. macOS 15.4 ou posterior.</sub>
</p>

<p align="center">
  Suas abas em uma barra lateral, agrupadas em espaços. Um app nativo para Mac em Swift sobre o WebKit,<br>
  com cerca de 35 MB instalado, sem conta e sem telemetria.
</p>

## Por que eu fiz

Oi, eu sou o Zigao, estudante do ensino médio em Xangai. Eu usava o Arc todos os dias. Quando a The Browser Company disse que ia encerrar o Arc em 22 de dezembro, eu realmente não queria voltar para as abas no topo da janela, e as alternativas que testei eram forks do Chromium ou navegadores construídos em torno de IA. Então fiz o meu próprio, e desde então ele é meu navegador principal.

**Por que WebKit e não Chromium?** Comecei fazendo um fork do Helium. O código-fonte tinha cerca de 100 GB e cada build levava de 3 a 4 horas no meu Mac, algo que não consigo manter sozinho. O WebKit já vem com o macOS, gasta menos bateria e memória, e a Apple entrega as correções de segurança dele junto com as atualizações do macOS. Você continua com as extensões do Chrome, instaladas direto da Chrome Web Store.

**Por que não o Zen ou o Orion?** Testei os dois antes de começar isto, e são bons. O Zen roda em Firefox, então usa extensões do Firefox e, para mim, não parece um app de Mac. O Orion é mais próximo, mas não é de código aberto. Eu queria algo que funcionasse como o Arc, fosse nativo, tivesse código aberto e rodasse minhas extensões do Chrome.

## Vindo do Arc

**Seu Arc vai com você.** Arquivo › Importar de outro navegador…, escolha o Arc, e seus espaços, abas fixadas, pastas fixadas, favoritos, histórico, senhas, logins e extensões vêm junto. Suas abas abertas também podem vir, com as Split Views e tudo, e só carregam quando você clica nelas; deixe Abas abertas desmarcado para começar do zero. Se seus espaços estão em mais de um perfil do Arc, cada perfil do Arc vem como um perfil próprio no Zigzag.

**O 1Password funciona.** Instale-o pela Chrome Web Store dentro do Zigzag, como faria no Arc. Ele se comunica com o app do 1Password. Na primeira vez, adicione o Zigzag em 1Password › Configurações › Navegador. O Bitwarden também funciona.

**Não dá para desligar.** Não existe conta, e o Zigzag não depende de nenhum servidor meu. As únicas coisas que eu hospedo são o feed de atualizações e uma lista curta de correções do bloqueio de anúncios, e se elas sumissem, o Zigzag continuaria funcionando. [Privacidade](#privacidade) lista tudo a que o Zigzag se conecta por conta própria.

## Veja

<p align="center">
  <img src="../../../docs/spaces.gif" width="960" alt="Alternando entre três espaços no Zigzag, cada um com sua própria cor e suas próprias abas">
</p>

<table>
  <tr>
    <td width="50%"><img src="../../../site/assets/clips/split.jpg" alt="Split View: Fonts In Use ao lado de Grilli Type"><br><b>Split View.</b> Arraste uma aba para a página para abri-la ao lado, até quatro ao mesmo tempo.</td>
    <td width="50%"><img src="../../../docs/all-tabs.jpg" alt="Todas as abas de três espaços exibidas como cartões"><br><b>Todas as abas de uma vez.</b> ⇧⌘\ mostra todos os espaços. Digite para filtrar.</td>
  </tr>
  <tr>
    <td width="50%"><img src="../../../site/assets/win-peek.webp" alt="Um artigo da Wikipédia sobre tipografia sobre a página de onde foi aberto"><br><b>Zigzag Mini.</b> Clique em um link com Shift pressionado para dar uma olhada sem perder seu lugar.</td>
    <td width="50%"><img src="../../../site/assets/clips/reader.jpg" alt="Um ensaio da The Public Domain Review no Leitor"><br><b>Leitor.</b> Leituras longas, sem a bagunça.</td>
  </tr>
</table>

<p align="center"><sub>Mais, em movimento, em <a href="https://zigzagbrowser.com">zigzagbrowser.com</a>.</sub></p>

## O que ele faz

| | |
|---|---|
| **Espaços** | Cada um com sua própria cor, ícone, abas fixadas e pastas. Deslize na barra lateral, ou mova a roda do mouse para o lado, para trocar. |
| **Favoritos** | Seus sites mais usados como blocos, acima de todos os espaços. Qualquer aba, aba fixada ou favorito pode ter seu próprio emoji ou símbolo. |
| **Perfis** | Mantenha trabalho e vida pessoal separados. Cada perfil tem suas próprias extensões, logins, histórico e favoritos, e todo espaço pertence a um. |
| **Sites em espaços** | Escolha um espaço para um site em Ajustes do site ou em Ajustes › Espaços, e os links dele abrem ali, de onde quer que venham: outro app, ⌘T ou outro espaço, como no Air Traffic Control do Arc. Caminhos também podem ir para espaços próprios, como `github.com/org1` para um e `github.com/org2` para outro. Um espaço em um perfil próprio funciona como um contêiner do Firefox. |
| **Barra de comandos** | ⌘T ou ⌘L. Encontra abas abertas, histórico e sites. Digite `you`, pressione Tab, e você está buscando no YouTube. Arraste a barra para qualquer lugar da janela e ela passa a abrir ali. |
| **Grupos de abas** | Selecione algumas abas e escolha Agrupar abas, e elas viram uma pasta na barra lateral que abre e fecha, é renomeada e se move como um só item. Arraste uma aba para a direita para aninhá-la sob a aba de cima, e para a esquerda para tirá-la de lá. |
| **Pastas dinâmicas** | Uma pasta fixada que se preenche sozinha a partir de um feed ou de um site, ou do GitHub: pull requests, pedidos de revisão, ou as issues e pull requests abertas nos seus repositórios. Páginas novas aparecem com um ponto. |
| **Split View** | Até quatro abas: arraste uma aba para as bordas da página para ocupar metade, ou para os cantos para ocupar um quarto. Arraste uma página pela faixa dela para movê-la e fixe uma Split View para mantê-la. |
| **Janelas** | Arraste uma aba para outra janela e ela se move como está, sem carregar de novo. Ative Ajustes › Abas › As janelas compartilham as abas de um espaço, e todas as janelas de um espaço listam as mesmas abas, como no Arc. A barra lateral fica à esquerda ou à direita. |
| **Web apps** | Instalar como app transforma um site em um app próprio, na sua pasta Aplicativos, no Dock e no ⌘Tab, com uma barra de ferramentas na cor do site. |
| **Mini player** | Saia de uma aba enquanto o vídeo toca e o vídeo segue você em um player pequeno. Redimensione por qualquer borda e coloque onde quiser, até fora da janela, sobre outros apps. Desative pelo menu dele se preferir não usar. Mude para outro app e o vídeo flutua sobre ele em Picture in Picture. |
| **Streaming** | Músicas e vídeos protegidos tocam como no Safari, pelo FairPlay Streaming do WebKit: o player web do Spotify funciona, assim como outros serviços compatíveis com o Safari. |
| **Em reprodução** | Toda aba que toca som em segundo plano ganha um cartão no pé da barra lateral, até três, para pausar ou silenciar. |
| **Todas as abas** | ⇧⌘\ mostra todos os espaços de uma vez. Digite para filtrar, arraste uma aba para outro espaço. |
| **Limpar** | Fecha as abas das quais você se afastou e mantém as que está usando. Aponte para ver quais ele fecharia. Uma Split View fica ou sai inteira. Desfazer traz as abas de volta. |
| **Zigzag Mini** | ⌃⌘N abre uma janela pequena para uma página rápida, e ⌘O a move para a janela do seu navegador. Clique em um link com Shift pressionado, ou escolha Abrir link no Zigzag Mini, e ele abre em um sobre sua janela; ⌘O o coloca em uma aba ao lado daquela em que você clicou, e Esc o fecha. Links de outros apps abrem nele, como no Little Arc (desative em Ajustes › Zigzag Mini), e Abrir no Zigzag Mini move uma aba para um. |
| **Senhas** | No Chaves do seu Mac, sincronizadas pelo Chaves do iCloud. Touch ID, um gerador e uma verificação de senhas fracas e repetidas. Chaves de acesso funcionam. |
| **Páginas escuras** | Sites claros desenhados em escuro pelo mecanismo do Dark Reader, com as correções dele para milhares de sites, para que as fotos fiquem fiéis. Sites com visual escuro próprio o mantêm. Preto puro se você gosta mais escuro. Ativado em todo lugar ou por site. |
| **Bloqueio de anúncios** | Integrado e ativado: cerca de 130.000 regras do EasyList, EasyPrivacy e EasyList China, compiladas em listas de regras de conteúdo do WebKit, mais as listas de filtros do uBlock Origin, que se atualizam sozinhas. |
| **WebRTC** | Ative Proteger o endereço IP contra WebRTC, e os sites não conseguem descobrir seu endereço IP real pelo WebRTC enquanto você usa um proxy ou VPN. As chamadas funcionam nos sites que você permitir, e um site que tenta usar o WebRTC enquanto ele está bloqueado avisa, com Permitir para este site. |
| **Pop-ups de cookies** | Recusados por você, nunca aceitos, com as regras do Autoconsent do DuckDuckGo. Deixe-os como estão em todo lugar ou em um site, se preferir responder você mesmo. |
| **Ajustes do site** | Um painel por site: zoom, permissões (câmera, microfone, localização, notificações, janelas pop-up, abertura de apps, compartilhamento de tela, WebRTC), cada uma definida como Perguntar, Permitir ou Bloquear, JavaScript ativado ou desativado, o certificado, extensões e chaves para páginas escuras, bloqueio de anúncios e pop-ups de cookies. Quando um site pede uma dessas permissões, o pedido aparece em um único cartão sobre a página, para desta vez ou sempre, e um site ao qual você disse não deixa de pedir. |
| **Boosts** | Ocultar elemento esconde as partes de um site que você não quer, como um banner ou uma barra lateral, e Editar estilo dá a um site um CSS seu. Os dois ficam no menu ⋯ de Ajustes do site e permanecem com o site. |
| **Modo de desenvolvedor** | Para os sites que você cria, `localhost` para começar: o console com contagem de erros, Inspecionar elemento, tamanhos de dispositivo, claro e escuro, estilos de impressão, JavaScript, imagens ou estilos desativados, outro user agent e um QR code para abrir a página no celular. |
| **Extensões** | Da Chrome Web Store, onde o botão da própria loja diz Adicionar ao Zigzag. 1Password, Bitwarden, Dark Reader, Tampermonkey e a maioria das populares funcionam; veja abaixo o que não funciona. |
| **Importar** | Marcadores, histórico, senhas, logins e extensões do Arc, Chrome, Safari, Dia, Edge, Brave, Vivaldi, Opera, Comet, Helium, Yandex, Whale, Chromium, Thorium, Firefox, Zen e Orion. |
| **Downloads** | Envie arquivos de um tipo para uma pasta própria, ou abra os seguros, como PDFs, assim que forem salvos. Regras entregam um link ou um download a um app, um script ou um gerenciador de downloads como o aria2, perguntando antes. Veja [docs/download-rules.md](../../../docs/download-rules.md). |
| **Automação** | AppleScript, Atalhos e `osascript` podem listar e abrir abas e ler páginas, escritos como o Safari e o Chrome os aceitam. Veja [docs/automation.md](../../../docs/automation.md). |
| **Apps de IA** | Desativados até você ativar: apps de IA no seu Mac podem usar suas abas por MCP, nunca janelas privadas nem senhas. Veja [docs/automation.md](../../../docs/automation.md#ai-apps-mcp). |
| **Seus dados** | Arquivo › Exportar seus dados… salva seus marcadores como um arquivo HTML padrão que qualquer navegador importa, e um backup completo do Zigzag que você pode restaurar em outro Mac. |
| **Idiomas** | Inglês, chinês simplificado, chinês tradicional, japonês, coreano, alemão, francês, italiano, espanhol, português do Brasil, russo, holandês, polonês e turco. |
| **E mais** | Leitor, visualizador de PDF, Handoff para seu iPhone, iPad ou outro Mac, Captura de uma área, de uma parte da página ou da página inteira (⇧⌘2), tradução no dispositivo, busca na página que marca todas as ocorrências, um menu Histórico com Fechados recentemente e os últimos sete dias, um zoom de página padrão, uma barra de endereço acima da página se você preferir, Picture in Picture, janelas privadas, Inspetor Web. |

## O que falta

É meu navegador do dia a dia, mas o Zigzag é novo e você vai encontrar bugs. O que usuários do Arc vão notar:

- Sem sincronização entre Macs nem com o iPhone. As senhas sincronizam pelo Chaves do iCloud; espaços e abas não.
- Os ícones dos espaços não vêm do Arc; escolha-os de novo no Zigzag. As cores dos espaços vêm como a cor mais próxima do Zigzag.
- Sem Easels nem Notes, e os Boosts são só CSS (Ocultar elemento e Editar estilo, sem scripts por site). Sem IA integrada ao navegador: apps de IA só podem usar o Zigzag por MCP se você ativar.
- Algumas APIs de extensões do Chrome ainda não existem: a API de grupos de abas, ajustes do depurador, o login com a conta Google do próprio Chrome (`identity.getAuthToken`) e o antigo bloqueio de requisições webRequest. Extensões de proxy podem definir um proxy HTTP, HTTPS ou SOCKS5 fixo, mas não um script PAC, então o modo Proxy by Patterns do FoxyProxy não funciona.
- O EasyList e as outras listas de bloqueio integradas se atualizam com o Zigzag, não sozinhas; só as listas do uBlock Origin fazem isso.
- Somente macOS 15.4 ou posterior.

## Como ele é feito

O Zigzag tem cerca de 120.000 linhas de Swift 6 e AppKit em torno do `WKWebView`. Não há Chromium nem Electron: o mecanismo é o WebKit que vem com o macOS, e é por isso que o app é pequeno e que as correções de segurança do mecanismo chegam com as atualizações do macOS, e não de mim.

| Parte | Como |
|---|---|
| **Páginas** | Um `WKWebView` por aba. Abas que você não usa há algum tempo podem ser suspensas: a web view é liberada e a aba guarda seu instantâneo e seu estado, e recarrega quando você volta. Janelas privadas usam um armazenamento de dados não persistente. |
| **Extensões** | O suporte a extensões web do WebKit (`WKWebExtensionController`, o motivo do mínimo de macOS 15.4). O Zigzag baixa o pacote CRX3 da Chrome Web Store, confere as assinaturas e o carrega. As APIs do Chrome que o WebKit não tem (histórico, marcadores, downloads, notificações, painéis laterais, páginas offscreen, login na web, áudio de aba, páginas de nova aba, user scripts, proxies e mais) são respondidas pelo próprio Zigzag por uma pequena ponte, conferidas com as permissões de cada extensão. Um mecanismo de busca fornecido por uma extensão (`search_provider`) entra nas opções em Ajustes e só é usado depois que você o escolhe. O native messaging conecta os apps auxiliares do 1Password e de outras extensões. |
| **Sandbox** | Imagens e PDFs de sites são lidos em dois helpers XPC em sandbox, `ZigzagImageDecoder` e `ZigzagPDFRenderer`, sem rede e sem acesso a arquivos, para que uma imagem ou um PDF malformado não alcance suas senhas nem seus perfis. O visualizador de PDF desenha as páginas que o helper renderiza; o app nunca abre o PDF de um site por conta própria. |
| **Conexões seguras** | Os avisos de certificado dizem o que está errado em Detalhes. Um site que pediu somente conexões seguras, pelo cabeçalho HSTS ou pela lista de pré-carregamento do Chromium (incluída no app, cerca de 95.000 nomes, lida no lugar apenas quando um aviso precisa dela), não oferece Visitar mesmo assim, como no Safari e no Chrome. Um site que pede um certificado para identificar você recebe os certificados do seu Chaves que ele aceitaria, como no Safari: adicione um abrindo o .p12 dele no Acesso às Chaves. |
| **Bloqueio de anúncios** | EasyList, EasyPrivacy e EasyList China convertidos com antecedência pelo SafariConverterLib em listas de regras de conteúdo (`WKContentRuleListStore`), compilados uma vez e mantidos em cache. As listas do uBlock Origin, baixadas conforme expiram, são aplicadas pelo mecanismo de bloqueio do Ghostery em um contexto JavaScript próprio, e cada página recebe os scriptlets e as regras de ocultação de que o site dela precisa assim que começa a carregar. |
| **Páginas escuras** | O tema dinâmico do Dark Reader e suas correções de sites, incluídos no app, em um script world próprio. As páginas são informadas primeiro de que a janela é escura, então um site com tema escuro próprio o usa e é deixado como está. |
| **Pop-ups de cookies** | O Autoconsent do DuckDuckGo e suas regras, incluídos no app, em um script world próprio. |
| **Senhas** | Salvas como itens do Chaves, para que o Chaves do iCloud as sincronize e o Touch ID as desbloqueie. As chaves de acesso passam pelo entitlement de chaves de acesso para navegadores da Apple. O Preenchimento Automático é um pequeno content script que só preenche campos que você consegue ver. |
| **Importar** | Lê os arquivos de cada navegador: o `StorableSidebar.json` do Arc, os marcadores e o histórico SQLite do Chromium, o `Bookmarks.plist` do Safari, o `places.sqlite` do Firefox, o `favourites.plist` e o `history` do Orion. As senhas do Chromium são descriptografadas com a chave do item do Chaves daquele navegador, depois que o macOS pergunta a você. |
| **Seus dados** | Espaços, itens fixados e favoritos em `Library.json`, perfis em `Profiles.json`, abas abertas em `Session.json`, histórico em SQLite (um arquivo por perfil), tudo em `~/Library/Application Support/Zigzag`. As gravações são adiadas e atômicas, e um arquivo que não pode ser lido é posto de lado, nunca sobrescrito. |
| **Leitor** | O Readability da Mozilla, executado na página, exibido com a tipografia própria do Zigzag. |
| **Web apps** | Um site instalado como app é um pequeno app próprio em `~/Applications/Zigzag Apps` que entrega cada abertura ao Zigzag, então a página roda no Zigzag com seus logins, extensões e bloqueio. |
| **Atualizações** | Sparkle 2, com atualizações assinadas com EdDSA vindas de zigzagbrowser.com, em um feed estável ou beta. As versões são assinadas com Developer ID e notarizadas. |

O código-fonte é organizado por recurso: `Sidebar`, `Tabs`, `Web`, `Extensions`, `Passwords`, `Import`, `Profiles`, `CommandBar`, `Desk` (todas as abas de uma vez), `WebApps`, `Developer`, `MCP` (apps de IA), `Settings`, `Window` e `Design` (os controles desenhados do próprio Zigzag e os tokens de design). Mais de 2.000 testes cobrem importação, senhas, extensões, tratamento de endereços, histórico, apps de IA e as correções de segurança.

## Privacidade

Sem conta, sem análise de uso, sem telemetria. Nada sobre como você navega é enviado para mim. Estas são as únicas conexões que o Zigzag faz por conta própria, além das páginas que você abre:

- **Atualizações.** A cada poucas horas, e depois que o Mac sai do repouso, o Zigzag lê o feed de atualizações em zigzagbrowser.com. A requisição informa a versão do Zigzag e nada mais; nenhum perfil do sistema é enviado. Uma nova versão também é baixada de lá.
- **Sugestões de busca.** Enquanto você digita na barra de endereço, o texto vai para o seu mecanismo de busca para gerar sugestões, sem cookies. Google, DuckDuckGo, Brave, Bing, Kagi e Ecosia oferecem sugestões; com qualquer outro mecanismo, nada é enviado. Desative em Ajustes › Busca.
- **Ícones de sites.** Os ícones vêm do próprio site, inclusive para abas fixadas, favoritos e marcadores importados que você ainda não abriu.
- **Listas de filtros.** Na abertura e depois conforme expiram, a cada poucas horas até uma vez por dia, o Zigzag baixa as listas de filtros do uBlock Origin dos endereços do próprio uBlock Origin (GitHub Pages, Cloudflare Pages ou jsDelivr) e os scriptlets dele do CDN do Ghostery. Também baixa de zigzagbrowser.com a lista curta de correções de sites do próprio Zigzag. As requisições não levam cookies, nem nada sobre você ou sua navegação.
- **Extensões.** Instalar uma extensão a baixa da Chrome Web Store. Na abertura, no máximo uma vez por dia, o Zigzag pergunta à loja se suas extensões têm atualizações, o que envia os IDs e as versões delas ao Google.
- **Configuração inicial.** As telas de boas-vindas mostram alguns ícones de sites do serviço de ícones do Google e carregam a página inicial da Wikipédia como prévia.

A tradução roda no seu Mac, com a Tradução no dispositivo da Apple. Os avisos de sites fraudulentos são os do próprio WebKit, os mesmos do Safari. As senhas ficam no Chaves do seu Mac e só sincronizam pelo seu próprio Chaves do iCloud. Ajuda › Relatar um problema escreve um relatório que você pode ler antes, e nada é enviado a menos que você envie. A lista de Senhas do Mac mantém um pequeno registro de seus passos em `~/Library/Logs/Zigzag/passwords.log`, nunca um login nem um site, e ele fica no seu Mac. Seu Cartão Zigzag é feito no seu Mac a partir do nome da sua conta e do dia em que o Zigzag foi aberto pela primeira vez, e a imagem dele contém só o que o cartão mostra.

## Instalação

Baixe o DMG em [zigzagbrowser.com](https://zigzagbrowser.com/download), abra-o e arraste o Zigzag para Aplicativos. Ou, com o Homebrew:

    brew install --cask zigaowang/tap/zigzag

As atualizações se instalam sozinhas. O que mudou em cada versão está nas [notas de versão](https://zigzagbrowser.com/release-notes) e no [CHANGELOG.md](../../../CHANGELOG.md).

## Feedback

- **Bugs e ideias:** [abra uma issue](https://github.com/ZigaoWang/zigzag/issues/new/choose), ou Ajuda › Enviar feedback… no app. Para um bug, Ajuda › Relatar um problema… escreve um relatório que você pode ler antes de enviar.
- **E-mail:** a@zigao.wang
- **Problemas de segurança:** veja [SECURITY.md](../../../SECURITY.md). Por favor, não os publique em issues públicas.

## Compilar a partir do código-fonte

Requisitos: macOS 15.4 ou posterior, Xcode 27 ou posterior e [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```sh
brew install xcodegen
git clone https://github.com/ZigaoWang/zigzag.git
cd zigzag
xcodegen generate
open Zigzag.xcodeproj
```

Execute o scheme **Zigzag**. Os builds de Debug rodam como um app separado, o “Zigzag Dev”, com dados próprios, então nunca mexem no seu Zigzag do dia a dia.

A assinatura está configurada para a minha equipe. Para compilar no seu Mac, mude duas coisas em `project.yml` e execute `xcodegen generate` de novo:

- `DEVELOPMENT_TEAM`: o ID da sua própria equipe (Xcode › Ajustes › Contas mostra).
- O `PRODUCT_BUNDLE_IDENTIFIER` do Debug: um seu, como `com.seunome.zigzag.dev`, já que `wang.zigao.zigzag.dev` está registrado na minha equipe.

Execute os testes:

```sh
xcodebuild test -project Zigzag.xcodeproj -scheme Zigzag
```

## Contribuir

Contribuições são bem-vindas. Leia o [CONTRIBUTING.md](../../../CONTRIBUTING.md) para saber como o projeto é construído, testado e estilizado.

## Licença

O código do Zigzag é licenciado sob a [Apache License, Version 2.0](../../../LICENSE). Use, altere, faça fork e distribua, comercialmente ou não.

O nome “Zigzag”, o ícone do app e o logotipo não são cobertos pela licença: são marcas registradas, todos os direitos reservados. Um fork precisa de nome e ícone próprios. Veja [TRADEMARKS.md](../../../TRADEMARKS.md) e [NOTICE](../../../NOTICE). Os trabalhos de terceiros que o Zigzag usa estão listados em [THIRD_PARTY_NOTICES.md](../../../THIRD_PARTY_NOTICES.md).

## Agradecimentos

Obrigado à comunidade [LINUX DO](https://linux.do) por testar o Zigzag cedo e compartilhar seus comentários.

<p align="center">
  <a href="https://linux.do"><img src="https://shorturl.at/ggSqS" alt="LINUX DO" /></a>
</p>
