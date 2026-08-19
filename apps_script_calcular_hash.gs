/*
  Apps Script VINCULADO a planilha (nao e um Web App como os outros dois
  scripts do projeto) - adiciona um menu "Sistemas Eleitorais" com o item
  "Calcular Hashes MD5" que preenche a coluna Hash da aba de Sistemas
  Eleitorais com o MD5 OFICIAL que o proprio Google Drive ja calculou
  sozinho no momento do upload de cada arquivo (nao precisa baixar o
  arquivo pra calcular nada - so le um metadado, entao funciona rapido
  mesmo em arquivos de 500MB+).

  Por que MD5 (e nao SHA256): o Drive so expoe MD5 nativamente via a API
  (campo "md5Checksum"). Pra qualquer outro algoritmo seria preciso baixar
  o arquivo inteiro pro Apps Script calcular na mao (Utilities.computeDigest),
  o que estoura o limite de memoria/tempo de execucao do Apps Script (6 min)
  em arquivos grandes. Por isso o ScannerRedeZona.ps1 tambem usa MD5 (nao
  SHA256) pra conferir integridade dos pacotes baixados/copiados.

  VERSAO 2: NAO usa mais o servico avancado "Drive API" (Advanced Service) -
  na pratica, nesse ambiente (TRE-MA), esse servico dava "File not found"
  pra arquivos que o servico BASICO (DriveApp) acha sem problema (mesma
  conta, mesmo arquivo) - sinal de algum bloqueio especifico do servico
  avancado no ambiente corporativo. A versao 2 faz a chamada REST direto
  via UrlFetchApp usando o MESMO token OAuth que o DriveApp ja usa com
  sucesso, contornando o problema - e de quebra simplifica a configuracao
  (nao precisa mais adicionar servico nenhum no editor).

  COMO CONFIGURAR (uma vez so):
    1. Na planilha, abra Extensoes > Apps Script.
    2. Apague o conteudo padrao de "Code.gs" e cole este arquivo inteiro.
       NAO precisa adicionar nenhum servico em "Servicos" (icone de +) -
       essa versao usa so UrlFetchApp e DriveApp, que ja vem prontos.
    3. Confirme/ajuste NOME_ABA abaixo pra bater com o nome real da aba que
       tem as colunas Sistema/Versao/.../LinkDrive/.../Hash (hoje:
       "SISTEMAS-ELEITORAIS").
    4. Salve o projeto (icone de disquete).
    5. Rode a funcao "diagnosticarAcessoDrive" DIRETO NO EDITOR (selecione
       ela no menu suspenso ao lado do botao "Executar" e clique
       "Executar") antes de usar o menu - ela pede a autorizacao (tela de
       "app nao verificado" e normal - Avancado > Acessar [nome do
       projeto]) e mostra um resumo do que esta ou nao funcionando. O
       resultado aparece como uma caixa de dialogo NA PROPRIA PLANILHA
       (troque de aba pra ver, nao fica no console do editor).
    6. Feche e reabra a planilha (ou recarregue a pagina) - deve aparecer
       um menu novo "Sistemas Eleitorais" na barra de menus, ao lado de
       "Ajuda".

  COMO USAR: sempre que adicionar/trocar um LinkDrive na planilha, va no
  menu "Sistemas Eleitorais" > "Calcular Hashes e Tamanhos" - preenche (ou
  atualiza) as colunas Hash e Tamanho de toda linha com LinkDrive
  preenchido. Uma linha so e PULADA se JA tiver os dois preenchidos (Hash
  E Tamanho) - pra forcar recalcular uma linha especifica, apague o valor
  de pelo menos uma das duas celulas dela antes de rodar.

  A coluna Tamanho (bytes, numero puro) e usada pelo ScannerRedeZona.ps1
  pra conferir automaticamente (sem clique nenhum, so metadado, sem reler
  o arquivo pela rede) se o que ja esta copiado no destino bate com o
  tamanho oficial - isso funciona ate pra pacotes copiados HA TEMPO,
  antes dessa planilha ter Tamanho preenchido, ja que a comparacao roda
  toda vez que a tela de Pacotes carrega o status.
*/

var NOME_ABA = "SISTEMAS-ELEITORAIS";

function onOpen() {
  SpreadsheetApp.getUi()
    .createMenu("Sistemas Eleitorais")
    .addItem("Calcular Hashes e Tamanhos", "calcularHashesMD5")
    .addItem("Diagnosticar Acesso ao Drive", "diagnosticarAcessoDrive")
    .addToUi();
}

function extrairIdArquivoDrive(link) {
  if (!link) return null;
  var m = link.match(/\/file\/d\/([a-zA-Z0-9_-]+)/) || link.match(/[?&]id=([a-zA-Z0-9_-]+)/);
  return m ? m[1] : link.trim();
}

/*
  Busca metadados do arquivo via REST direto (drive.googleapis.com), usando
  o token OAuth da propria sessao do script (ScriptApp.getOAuthToken()) -
  o MESMO tipo de credencial que o DriveApp usa por baixo dos panos, entao
  se DriveApp.getFileById ja funciona pra esse arquivo, essa chamada tende
  a funcionar tambem (diferente do servico avancado "Drive API", que na
  pratica falhou nesse ambiente). muteHttpExceptions:true pra conseguir ler
  o corpo do erro real em vez de so uma excecao generica.
*/
function obterMetadadosArquivoRest(id, campos) {
  var token = ScriptApp.getOAuthToken();
  var url = "https://www.googleapis.com/drive/v3/files/" + encodeURIComponent(id) + "?fields=" + encodeURIComponent(campos) + "&supportsAllDrives=true";
  var resp = UrlFetchApp.fetch(url, {
    method: "get",
    headers: { Authorization: "Bearer " + token },
    muteHttpExceptions: true
  });
  var codigo = resp.getResponseCode();
  var corpo = resp.getContentText();
  if (codigo !== 200) {
    throw new Error("HTTP " + codigo + ": " + corpo);
  }
  return JSON.parse(corpo);
}

function diagnosticarAcessoDrive() {
  var ui = SpreadsheetApp.getUi();
  var aba = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(NOME_ABA);
  if (!aba) {
    ui.alert("Aba '" + NOME_ABA + "' nao encontrada. Ajuste a constante NOME_ABA no script.");
    return;
  }

  var dados = aba.getDataRange().getValues();
  var cabecalho = dados[0];
  var colLinkDrive = cabecalho.indexOf("LinkDrive");
  if (colLinkDrive === -1 || dados.length < 2) {
    ui.alert("Nao encontrei a coluna 'LinkDrive' (ou a aba esta vazia) pra testar.");
    return;
  }

  var primeiroLink = null;
  for (var i = 1; i < dados.length && !primeiroLink; i++) {
    if (dados[i][colLinkDrive]) primeiroLink = dados[i][colLinkDrive];
  }
  if (!primeiroLink) {
    ui.alert("Nenhuma linha com LinkDrive preenchido pra testar.");
    return;
  }
  var id = extrairIdArquivoDrive(primeiroLink);

  var linhas = [];
  linhas.push("Conta rodando o script: " + (Session.getEffectiveUser().getEmail() || "(vazio)"));
  linhas.push("Arquivo testado (ID): " + id);
  linhas.push("");

  try {
    var arquivoBasico = DriveApp.getFileById(id);
    linhas.push("[OK] DriveApp.getFileById (servico basico): '" + arquivoBasico.getName() + "'");
  } catch (errBasico) {
    linhas.push("[FALHA] DriveApp.getFileById (servico basico): " + errBasico.message);
  }

  try {
    var metadados = obterMetadadosArquivoRest(id, "id,name,md5Checksum,size");
    linhas.push("[OK] REST direto (UrlFetchApp): '" + metadados.name + "', md5Checksum=" + (metadados.md5Checksum || "(vazio)") + ", size=" + (metadados.size || "(vazio)"));
  } catch (errRest) {
    linhas.push("[FALHA] REST direto (UrlFetchApp): " + errRest.message);
  }

  linhas.push("");
  linhas.push("Se os dois testes deram OK, a funcao 'Calcular Hashes MD5' deve funcionar normal agora.");
  linhas.push("Se o REST direto tambem falhar, me manda o texto completo do erro (inclui o codigo HTTP e o corpo da resposta do Google).");

  ui.alert(linhas.join("\n"));
}

function calcularHashesMD5() {
  var ui = SpreadsheetApp.getUi();
  var aba = SpreadsheetApp.getActiveSpreadsheet().getSheetByName(NOME_ABA);
  if (!aba) {
    ui.alert("Aba '" + NOME_ABA + "' nao encontrada. Ajuste a constante NOME_ABA no script.");
    return;
  }

  var dados = aba.getDataRange().getValues();
  if (dados.length < 2) {
    ui.alert("Planilha vazia (so tem cabecalho).");
    return;
  }

  var cabecalho = dados[0];
  var colLinkDrive = cabecalho.indexOf("LinkDrive");
  var colHash = cabecalho.indexOf("Hash");
  var colTamanho = cabecalho.indexOf("Tamanho");
  var colSistema = cabecalho.indexOf("Sistema");

  if (colLinkDrive === -1 || colHash === -1 || colTamanho === -1) {
    ui.alert("Nao encontrei as colunas 'LinkDrive', 'Hash' e/ou 'Tamanho' no cabecalho da aba '" + NOME_ABA + "'. Confira os nomes exatos das colunas (crie a coluna 'Tamanho' se ainda nao existir).");
    return;
  }

  var atualizadas = 0;
  var puladas = 0;
  var erros = [];

  for (var i = 1; i < dados.length; i++) {
    var linha = dados[i];
    var link = linha[colLinkDrive];
    var hashAtual = linha[colHash];
    var tamanhoAtual = linha[colTamanho];
    var nomeSistema = colSistema !== -1 ? linha[colSistema] : ("linha " + (i + 1));

    if (!link) continue;                              // sem LinkDrive, nada a calcular
    if (hashAtual && tamanhoAtual) { puladas++; continue; }  // ja tem os dois - nao recalcula

    var id = extrairIdArquivoDrive(link);
    if (!id) {
      erros.push(nomeSistema + ": nao consegui extrair o ID do LinkDrive");
      continue;
    }

    try {
      var metadados = obterMetadadosArquivoRest(id, "md5Checksum,size");
      if (!metadados.md5Checksum || !metadados.size) {
        erros.push(nomeSistema + ": Drive nao devolveu md5Checksum/size (arquivo pode nao ter sido totalmente indexado ainda)");
        continue;
      }
      aba.getRange(i + 1, colHash + 1).setValue(metadados.md5Checksum);
      aba.getRange(i + 1, colTamanho + 1).setValue(Number(metadados.size));
      atualizadas++;
    } catch (err) {
      erros.push(nomeSistema + ": " + err.message);
    }
  }

  var resumo = "Hashes/tamanhos calculados: " + atualizadas + "\nJa preenchidos (pulados): " + puladas;
  if (erros.length > 0) {
    resumo += "\n\nErros (" + erros.length + "):\n" + erros.join("\n");
    resumo += "\n\nSe todos os erros forem parecidos, use o menu 'Diagnosticar Acesso ao Drive' pra ver mais detalhe.";
  }
  ui.alert(resumo);
}
