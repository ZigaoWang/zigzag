# Registro de alterações

Estas são as notas de versão do Zigzag em português do Brasil, traduzidas do CHANGELOG.md. O app mostra as notas da versão que você está usando, e [zigzagbrowser.com/release-notes](https://zigzagbrowser.com/release-notes) mostra todas as versões. As versões anteriores à 0.10.0 estão em inglês no [CHANGELOG.md](../../../CHANGELOG.md).

## [Unreleased]

## [0.10.0] - 2026-11-25

Zigzag em mais treze idiomas, do japonês e coreano ao alemão, francês, espanhol e russo; regras de download que entregam o arquivo salvo; pastas dinâmicas que mostram quando foram atualizadas pela última vez; e digitar em pinyin chinês e mudar para o inglês sem espaços sobrando.

### Novo
- O Zigzag agora está em japonês, com os termos da Apple em japonês para o macOS e o Safari. Ele segue o idioma do seu Mac, ou escolha o idioma em Ajustes › Geral › Idioma.
- O Zigzag agora está em coreano, alemão, francês, italiano, espanhol, português do Brasil, russo, holandês, polonês e turco, com os termos da Apple em cada idioma. Ele segue o idioma do seu Mac, ou escolha um em Ajustes › Geral › Idioma.
- Uma regra de download pode entregar o arquivo em vez do endereço: defina Entregar como Arquivo, e o Zigzag primeiro baixa o arquivo com a sessão da página e depois entrega o arquivo salvo ao app, script ou serviço. Os links continuam entregando o endereço, e os modelos de uma entrega de arquivo podem usar {file} ou {file_url} para o arquivo salvo. Agradecimentos a [Lakeland97](https://github.com/Lakeland97). ([#529](https://github.com/ZigaoWang/zigzag/issues/529))
- O menu de uma pasta dinâmica agora começa com a hora da última atualização, como Atualizada há 5 minutos, ou Atualizando… enquanto ela é buscada.
- As janelas Nova pasta dinâmica e Editar pasta dinâmica pedem a origem primeiro, alinham os menus com os campos e explicam abaixo deles o que a pasta vai mostrar e que ela é verificada a cada 30 minutos (de hora em hora no Modo de Pouca Energia). Um nome deixado em branco mostra o nome que a pasta vai receber, e um nome de usuário que o GitHub não aceita é marcado.

### Corrigido
- Com o Zigzag Mini aberto sobre uma página, rolar sobre a página escurecida não move mais a página atrás dele. Agradecimentos a [Lakeland97](https://github.com/Lakeland97). ([#531](https://github.com/ZigaoWang/zigzag/pull/531))
- A explicação antes de permitir que sites acessem apps neste Mac agora mostra os passos em ordem: ative o ajuste, depois ative cada site nos Ajustes do site dele, e desativar o ajuste interrompe todos os sites. Agradecimentos a [Lakeland97](https://github.com/Lakeland97). ([#533](https://github.com/ZigaoWang/zigzag/issues/533))
- Nos Ajustes, uma lista sob um título com botões ou uma busca ao lado, como Guardado pelos sites ou Entregar downloads e links, não começa mais logo abaixo desses controles. Ela mantém abaixo deles o mesmo espaço que todos os outros títulos. Agradecimentos a [Lakeland97](https://github.com/Lakeland97). ([#527](https://github.com/ZigaoWang/zigzag/issues/527))
- Mudar do pinyin chinês para o inglês no meio de uma palavra não deixa mais espaços entre as letras, numa página ou na barra de endereço, como no Chrome.
- Um espaço com transparência e vidro Transparente não deixa mais os gráficos do Mac ocupados enquanto o Zigzag está parado, mesmo numa página em branco ou nos Ajustes. O macOS redesenhava a janela inteira e a sombra dela a cada quadro; agora só desenha quando algo muda. A barra de progresso do cartão de atualização também para de deslizar enquanto está oculta.
