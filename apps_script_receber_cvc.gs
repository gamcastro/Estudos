/*
  Apps Script "Web App" que recebe o arquivo CVC via HTTP POST (do
  ScannerRedeZona.ps1) e salva direto na pasta do Google Drive - sem
  precisar de OAuth/login nenhum do lado do PowerShell, porque quem faz a
  gravacao no Drive e o proprio Apps Script, rodando com a permissao de
  quem publicou (voce).

  COMO PUBLICAR:
    1. Acesse https://script.google.com , crie um projeto novo (nao precisa
       estar preso a nenhuma planilha).
    2. Apague o conteudo padrao de "Code.gs" e cole este arquivo inteiro.
    3. Troque o valor de TOKEN abaixo por um valor secreto so seu (qualquer
       string, tipo uma senha) - o mesmo valor tera que ser configurado no
       ScannerRedeZona.ps1, na tela "Configurar Envio Drive...".
    4. Confirme que FOLDER_ID abaixo bate com o ID da pasta do Drive (o
       trecho da URL depois de /folders/) - ja esta preenchido com o ID da
       pasta que voce passou: 1ssTe5V1qtDRtWTPJCS5Npw8EiiFJCp6o
    5. Menu "Implantar" > "Nova implantacao" > tipo "Aplicativo da web".
       - "Executar como": Eu (sua conta) - importante, e o que da ao script
         a permissao de gravar na pasta.
       - "Quem tem acesso": Qualquer pessoa - precisa ser assim para o
         PowerShell conseguir chamar sem fazer login OAuth. A seguranca
         fica por conta do TOKEN (quem nao souber o token, o script recusa).
    6. Na primeira implantacao o Google vai pedir para autorizar o script a
       acessar seu Drive - autorize (tela de "app nao verificado" e normal,
       clique em Avancado > Acessar [nome do projeto], mesmo assim).
    7. Copie a URL do "Aplicativo da web" (termina em /exec) - e essa URL
       que vai no ScannerRedeZona.ps1.
    8. Sempre que EDITAR este script depois, e preciso fazer uma NOVA
       implantacao (ou "Gerenciar implantacoes" > editar > Nova versao) -
       so salvar o codigo nao atualiza a URL /exec que ja esta publicada.
*/

var FOLDER_ID = "1ssTe5V1qtDRtWTPJCS5Npw8EiiFJCp6o";
var TOKEN = "TROQUE_ESTE_VALOR_POR_UM_SEGREDO_SEU";

function doPost(e) {
  try {
    var params = JSON.parse(e.postData.contents);

    if (params.token !== TOKEN) {
      return responderJson({ ok: false, erro: "token invalido" });
    }
    if (!params.nomeArquivo || !params.conteudoBase64) {
      return responderJson({ ok: false, erro: "nomeArquivo ou conteudoBase64 ausente" });
    }

    var pasta = DriveApp.getFolderById(FOLDER_ID);
    var bytes = Utilities.base64Decode(params.conteudoBase64);
    var blob = Utilities.newBlob(bytes, "application/octet-stream", params.nomeArquivo);

    // Se ja existir um arquivo com o mesmo nome (reenvio do mesmo CVC),
    // manda pra lixeira antes de gravar o novo - evita ficar acumulando
    // "ZMA072WKS72384(1).cvc", "(2).cvc" etc a cada reenvio.
    var existentes = pasta.getFilesByName(params.nomeArquivo);
    while (existentes.hasNext()) {
      existentes.next().setTrashed(true);
    }

    var arquivo = pasta.createFile(blob);

    return responderJson({ ok: true, id: arquivo.getId(), url: arquivo.getUrl() });
  } catch (err) {
    return responderJson({ ok: false, erro: String(err) });
  }
}

function responderJson(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
