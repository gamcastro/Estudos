/*
  Apps Script "Web App" que recebe, via HTTP POST, o resultado de uma
  verificacao de campanha (ScannerRedeZona.ps1, botao "Verificar Campanha
  ZE X" > "Enviar Resultado...") e ACRESCENTA uma linha na aba
  "RESULTADOS-CAMPANHAS" da planilha "Zonas Eleitorais" (cria a aba com
  cabecalho se ainda nao existir). Cada envio vira uma linha NOVA (nao
  sobrescreve a anterior) - assim fica um historico completo de quando
  cada zona foi conferida, e um "compilado por zona" pode ser montado
  depois (ex: numa planilha a parte, ou numa tela nova da ferramenta)
  filtrando/agrupando essas linhas - por exemplo, pegando so a ULTIMA
  linha de cada combinacao Zona+Campanha pra saber o status mais recente.

  Colunas gravadas (nessa ordem): DataHora | Zona | Sede | Campanha |
  Total | Aptas | Tecnico | MaquinasAptas

  ATENCAO se voce ja tinha esse script implantado ANTES da coluna
  MaquinasAptas existir: a aba RESULTADOS-CAMPANHAS ja criada na
  planilha NAO ganha a coluna nova sozinha (o cabecalho so e criado
  automaticamente na 1a vez que a aba nao existe) - adicione manualmente
  "MaquinasAptas" na celula H1 (depois de "Tecnico") e reimplante o
  script (ver passo 8 abaixo).

  COMO PUBLICAR (mesmo padrao dos outros apps_script_*.gs desta pasta):
    1. Acesse https://script.google.com , crie um projeto novo (pode ser
       um projeto separado dos outros - nao precisa ser o mesmo).
    2. Apague o conteudo padrao de "Code.gs" e cole este arquivo inteiro.
    3. Troque o valor de TOKEN abaixo por um valor secreto so seu - o
       mesmo valor tera que ser configurado no ScannerRedeZona.ps1, na
       janela "Verificar Campanha ZE X" > "Enviar Resultado..." (pede a
       configuracao so na primeira vez que clicar).
    4. Confirme que SPREADSHEET_ID abaixo bate com o ID da planilha "Zonas
       Eleitorais" (o trecho da URL entre /d/ e /edit) - ja preenchido com
       o mesmo ID usado pelas outras abas desta planilha (Zonas,
       GRUPOS-SISTEMAS-ELEITORAIS, CAMPANHAS): 1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I
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
var NOME_ABA = "RESULTADOS-CAMPANHAS";
var TOKEN = "TROQUE_ESTE_VALOR_POR_UM_SEGREDO_SEU";
var CABECALHO = ["DataHora", "Zona", "Sede", "Campanha", "Total", "Aptas", "Tecnico", "MaquinasAptas"];

function doPost(e) {
  try {
    var params = JSON.parse(e.postData.contents);

    if (params.token !== TOKEN) {
      return responderJson({ ok: false, erro: "token invalido" });
    }
    if (!params.zona || !params.campanha) {
      return responderJson({ ok: false, erro: "zona/campanha nao informada" });
    }

    var planilha = SpreadsheetApp.openById(SPREADSHEET_ID);
    var aba = planilha.getSheetByName(NOME_ABA);
    if (!aba) {
      aba = planilha.insertSheet(NOME_ABA);
      aba.appendRow(CABECALHO);
    }

    aba.appendRow([
      new Date(),
      params.zona,
      params.sede || "",
      params.campanha,
      params.total || 0,
      params.aptas || 0,
      params.tecnico || "",
      params.maquinasAptas || ""
    ]);

    return responderJson({ ok: true });
  } catch (err) {
    return responderJson({ ok: false, erro: String(err) });
  }
}

function responderJson(obj) {
  return ContentService.createTextOutput(JSON.stringify(obj))
    .setMimeType(ContentService.MimeType.JSON);
}
