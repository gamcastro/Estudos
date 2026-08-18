/*
  Apps Script "Web App" que recebe, via HTTP POST, a rede Substituta e a
  Observacao de uma Zona Eleitoral (do ScannerRedeZona.ps1, tela "Gerenciar
  Zonas") e grava direto nas colunas D ("Substituta") e E ("Observacao") da
  linha correspondente na planilha "Zonas Eleitorais", aba "Zonas".

  Colunas esperadas na aba "Zonas" (nessa ordem, com cabecalho na linha 1):
    A = Zona Eleitoral   B = Sede   C = Rede Padrao   D = Substituta   E = Observacao

  COMO PUBLICAR (mesmo padrao do apps_script_receber_cvc.gs):
    1. Acesse https://script.google.com , crie um projeto novo (pode ser um
       projeto separado do que recebe o CVC - nao precisa ser o mesmo).
    2. Apague o conteudo padrao de "Code.gs" e cole este arquivo inteiro.
    3. Troque o valor de TOKEN abaixo por um valor secreto so seu - o mesmo
       valor tera que ser configurado no ScannerRedeZona.ps1, na tela
       "Gerenciar Zonas" > "Salvar na Planilha" (pede a configuracao a
       primeira vez que voce salvar).
    4. Confirme que SPREADSHEET_ID abaixo bate com o ID da planilha (o
       trecho da URL entre /d/ e /edit) - ja esta preenchido com:
       1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I
    5. Menu "Implantar" > "Nova implantacao" > tipo "Aplicativo da web".
       - "Executar como": Eu (sua conta) - precisa ter permissao de EDICAO
         na planilha (nao so leitura), senao a gravacao falha.
       - "Quem tem acesso": Qualquer pessoa.
    6. Na primeira implantacao o Google vai pedir para autorizar o script a
       acessar suas planilhas - autorize (tela de "app nao verificado" e
       normal, clique em Avancado > Acessar [nome do projeto]).
    7. Copie a URL do "Aplicativo da web" (termina em /exec) - e essa URL
       que vai no ScannerRedeZona.ps1.
    8. Sempre que EDITAR este script depois, e preciso fazer uma NOVA
       implantacao (ou "Gerenciar implantacoes" > editar > Nova versao) -
       so salvar o codigo nao atualiza a URL /exec que ja esta publicada.
*/

var SPREADSHEET_ID = "1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I";
var NOME_ABA = "Zonas";
var TOKEN = "TROQUE_ESTE_VALOR_POR_UM_SEGREDO_SEU";

function doPost(e) {
  try {
    var params = JSON.parse(e.postData.contents);

    if (params.token !== TOKEN) {
      return responderJson({ ok: false, erro: "token invalido" });
    }
    if (!params.zona) {
      return responderJson({ ok: false, erro: "zona nao informada" });
    }

    var planilha = SpreadsheetApp.openById(SPREADSHEET_ID);
    var aba = planilha.getSheetByName(NOME_ABA);
    if (!aba) {
      return responderJson({ ok: false, erro: "aba '" + NOME_ABA + "' nao encontrada" });
    }

    var dados = aba.getDataRange().getValues();
    var zonaAlvo = String(params.zona).trim();
    var linhaEncontrada = -1;
    for (var i = 1; i < dados.length; i++) {  // i=0 e o cabecalho
      var zonaLinha = String(dados[i][0]).trim();
      // aceita com ou sem zeros a esquerda (ex: "15" bate com "015")
      if (zonaLinha === zonaAlvo || Number(zonaLinha) === Number(zonaAlvo)) {
        linhaEncontrada = i + 1;  // getRange e 1-based
        break;
      }
    }

    if (linhaEncontrada === -1) {
      return responderJson({ ok: false, erro: "zona '" + zonaAlvo + "' nao encontrada na planilha" });
    }

    aba.getRange(linhaEncontrada, 4).setValue(params.rede || "");        // coluna D = Substituta
    aba.getRange(linhaEncontrada, 5).setValue(params.observacao || "");  // coluna E = Observacao

    return responderJson({ ok: true, linha: linhaEncontrada });
  } catch (err) {
    return responderJson({ ok: false, erro: String(err) });
  }
}

function responderJson(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
