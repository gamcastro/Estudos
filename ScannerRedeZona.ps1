<#
.SINOPSE
    Scanner de rede (GUI) para descobrir dispositivos ativos - PCs e impressoras
    Pantum - em uma zona eleitoral do interior, padrao 10.198.<ZONA>.XXX (TRE-MA).
    Inclui deteccao de servico VNC (porta 5900) e atalho para abrir o VNC Viewer
    direto na linha do computador.

.PADRAO DO TOOLKIT trema-manutencao-tic
    - Auto-elevacao UAC
    - Codificacao UTF-8 com BOM
    - Log colorido em RichTextBox
    - Ferramenta autocontida, portatil via USB (sem dependencias externas)

.VNC VIEWER
    Na primeira vez que voce clicar em "Abrir VNC" (ou der duplo-clique numa
    linha) sem o caminho do vncviewer.exe configurado, o script tenta localizar
    automaticamente em instalacoes comuns (UltraVNC, TightVNC, RealVNC, TigerVNC).
    Se nao encontrar, abre uma janela para voce localizar o executavel manualmente
    - o caminho fica salvo em "vnc_config.txt" ao lado deste script, entao so
    precisa configurar uma vez por pendrive/maquina.

    O VNC Viewer e lancado via Start-ProcessoNaoElevado (Shell.Application COM)
    em vez de Start-Process direto, porque este script roda auto-elevado e um
    processo filho lancado por Start-Process herda essa elevacao - o que altera
    o comportamento de rede do VNC Viewer e faz a conexao falhar silenciosamente.
    Ver a funcao Start-ProcessoNaoElevado para detalhes; use o mesmo padrao em
    qualquer script do toolkit que lance programas de terceiros.

.DETECCAO DE IMPRESSORAS
    Nao usamos equipamentos JetDirect (HP). A deteccao e feita pelas portas
    padrao de mercado que a Pantum tambem atende: 9100 (RAW/AppSocket),
    515 (LPR) e 631 (IPP).
#>

# ============================================================
# AUTO-ELEVACAO UAC (padrao do toolkit)
# ============================================================
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process powershell.exe -ArgumentList $args -Verb RunAs
    exit
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

# O PowerShell 5.1 usa a configuracao de TLS do .NET Framework, que em
# Windows Server mais antigo/menos atualizado pode nao incluir TLS 1.2 por
# padrao. O Google (e varios outros servicos HTTPS modernos) exige TLS 1.2+,
# entao sem isso o Invoke-WebRequest falha com "underlying connection was
# closed" mesmo que o navegador acesse a mesma URL sem problema (navegadores
# negociam TLS por conta propria, independente dessa configuracao do .NET).
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================================
# ESTADO GLOBAL
# ============================================================
$script:Pool         = $null
$script:Jobs         = New-Object System.Collections.Generic.List[object]
$script:Resultados   = New-Object System.Collections.Generic.List[object]
$script:MaquinasDesligadasOcs = New-Object System.Collections.Generic.List[object]   # maquinas da zona cadastradas no OCS que nao responderam a varredura
$script:Concluidos   = 0
$script:Total        = 0
$script:Escaneando   = $false
$script:VncViewerPath = $null

# Usuario de AD "instalador" - liberado por maquina (atributo userWorkstations)
# pra poder logar so nas estacoes especificas onde foi autorizado. A lista e
# consultada UMA VEZ por varredura (e a mesma pra zona inteira, nao muda por
# maquina) e guardada aqui pra cada linha da grade so precisar comparar o
# hostname contra ela. $null = ainda nao consultado ou a consulta falhou
# (nesse caso a coluna fica "-" pra todo mundo, ja que nao da pra saber).
$script:NomeUsuarioInstalador = "instalador"
$script:MaquinasLiberadasInstalador = $null

# Controles da barra de progresso da janela "Sistemas Eleitorais" (ver
# Show-JanelaSistemasEleitorais) - ficam em $script: pra esse callback
# poder ser definido UMA VEZ SO, em nivel de script (sem closure
# nenhuma), e continuar funcionando corretamente nao importa de qual
# funcao/scriptblock aninhado seja invocado depois (Invoke-AcaoBaixarPacote
# -> Invoke-DownloadArquivoComProgresso / Copy-ArquivoComRobocopy) -
# dentro de FUNCOES normais (nao-closure), $script: sempre resolve certo
# contra este escopo aqui.
#
# CUIDADO ao usar essas variaveis $script: DENTRO de um scriptblock que
# foi criado com .GetNewClosure() (ex: os handlers de clique da propria
# Show-JanelaPacotes): confirmado na pratica que .GetNewClosure() cria um
# escopo "$script:" PROPRIO/ISOLADO pro scriptblock resultante, separado
# do $script: deste arquivo - variaveis LOCAIS (sem prefixo) capturam
# certo (ex: $dlg), mas "$script:barraProgressoPacoteAtual" ali dentro
# aponta pro $script: isolado do closure (sempre $null), nao pra este
# aqui, mesmo tendo sido atribuida segundos antes. Dava "The property
# 'Value' cannot be found on this object" (ou seja, chegava $null). A
# solucao dentro de um .GetNewClosure() e copiar pra um alias LOCAL (ex:
# "$barraProgressoLocal = $script:barraProgressoPacoteAtual") ANTES do
# .GetNewClosure() e usar o alias local no corpo do scriptblock.
$script:barraProgressoPacoteAtual = $null
$script:lblProgressoPacoteAtual = $null
$script:AoAtualizarProgressoPacoteCallback = {
    <#
        Alem de mudar .Value/.Text, forca .Refresh() (repintura SINCRONA,
        imediata) em cada controle - so trocar a propriedade e chamar
        DoEvents() nao bastou na pratica: num loop rapido (muitas
        atualizacoes por segundo em link veloz), a mensagem de repintura
        podia nunca "vencer a fila" do DoEvents a tempo de aparecer na
        tela antes da proxima rodada. .Refresh() pinta na hora, sem
        depender da fila de mensagens.
    #>
    param($Percent, $TextoStatus)
    if ($script:barraProgressoPacoteAtual) {
        $script:barraProgressoPacoteAtual.Value = [Math]::Min([Math]::Max([int]$Percent, 0), 100)
        $script:barraProgressoPacoteAtual.Refresh()
    }
    if ($script:lblProgressoPacoteAtual) {
        $script:lblProgressoPacoteAtual.Text = $TextoStatus
        $script:lblProgressoPacoteAtual.Refresh()
    }
    [System.Windows.Forms.Application]::DoEvents()
}

$script:PortasFallback   = @(445, 9100, 631)   # usadas quando o ICMP esta bloqueado
$script:PortasImpressora = @(9100, 515, 631)   # RAW/AppSocket, LPR, IPP
$script:PortaVnc         = 5900
$script:PortaRcIvanti    = 9535   # Ivanti/LANDesk Remote Control legado (RCViewer.exe)
$script:UrlOcsApiBase    = "http://inventario.tre-ma.jus.br/ocsapi/v1"
# Console web do OCS Inventory (diferente da API acima) - usado so para
# montar o link direto da tela de exclusao de computador, ja que a API REST
# do OCS so suporta GET (confirmado na doc oficial: POST/DELETE/PUT "not
# implemented") - excluir so da pra fazer pelo console mesmo.
$script:UrlOcsWebConsole = "https://inventario.tre-ma.jus.br/ocsreports"
$script:MesesParaCandidatoExclusaoOcs = 6
$script:MapaModelos = @{
    "C4400"                            = "Mini-Positivo"
    "HP Elite Mini 800 G9 Desktop PC"  = "Mini-HP"
    "D6200"                            = "Positivo Master"
    "OptiPlex 3020M"                   = "Mini-Dell"
}

# Sistemas eleitorais adicionais (alem do VERSAO_SIS), lidos da mesma secao
# "registry" do OCS Inventory (HKLM\SOFTWARE\Sistemas Eleitorais\...). Cada
# entrada aqui e resolvida automaticamente durante a propria varredura
# (dentro do $scriptBlock por IP), independente de aparecer ou nao como
# coluna na grade principal.
# ComNomeAmigavel controla se essa coluna participa do mapeamento por nome
# amigavel da planilha de Versoes de Sistemas (ver Resolve-NomeAmigavelVersao)
# - BitLocker nao tem "nome de praia" como os sistemas eleitorais, entao fica
# de fora; SIS (tratado a parte, nao faz parte desta lista) tambem fica fora.
# NaGradePrincipal controla se vira coluna na tela principal - PADA-UE, FBR e
# os sistemas adicionados pra janela "Verificar Sistemas Eleitorais" (ver
# Show-JanelaSistemasEleitorais) ficam de fora da grade principal por
# enquanto (dado e coletado normalmente, so nao vira coluna ali).
# NomeVersaoAtual e a chave usada pra procurar a "versao mais atual" na
# planilha de Versoes de Sistemas (coluna "Sistema" dela) - normalmente e
# IGUAL a Chave (o nome que o OCS reporta), MAS BitLocker/CriptoSIS e uma
# excecao confirmada: o OCS reporta a chave de registro como "BITLOCKER",
# só que a planilha de Versoes/Pacotes cadastra essa mesma linha como
# "CRIPTOSIS" (nome comercial) - por isso os dois campos divergem so nesse
# caso.
$script:SistemasEleitoraisExtra = @(
    [PSCustomObject]@{ Chave = "BITLOCKER"; NomeVersaoAtual = "CRIPTOSIS"; Propriedade = "VersaoBitlocker"; Coluna = "Bitlocker"; Titulo = "Criptosis"; Largura = 90; ComNomeAmigavel = $false; NaGradePrincipal = $true }
    # Chave interna continua "GEDAI" (e o que o OCS Inventory reporta no
    # registro, confirmado na pratica) - o produto so passou a se chamar
    # "GEDAI-UE" comercialmente, entao o Titulo (nome de EXIBICAO) foi
    # atualizado. NomeVersaoAtual TAMBEM precisa ser "GEDAI-UE" (nao
    # "GEDAI") - confirmado que a coluna "Sistema" da planilha de Versoes
    # usa o nome comercial com "-UE", diferente da chave de registro do OCS.
    [PSCustomObject]@{ Chave = "GEDAI";     NomeVersaoAtual = "GEDAI-UE";  Propriedade = "VersaoGedai";     Coluna = "Gedai";     Titulo = "GEDAI-UE";  Largura = 150; ComNomeAmigavel = $true; NaGradePrincipal = $true }
    [PSCustomObject]@{ Chave = "HOLOCRON";  NomeVersaoAtual = "HOLOCRON";  Propriedade = "VersaoHolocron";  Coluna = "Holocron";  Titulo = "Holocron";  Largura = 150; ComNomeAmigavel = $true; NaGradePrincipal = $true }
    # ATENCAO: "PADA-UE" e "FBR" abaixo sao um PALPITE de qual e o campo NAME
    # exato que o OCS Inventory usa pra esses dois sistemas na secao
    # "registry" (seguindo o mesmo padrao curto do GEDAI/HOLOCRON) - ainda
    # NAO confirmado. Se ao mostrar em algum lugar o valor aparecer sempre
    # "-", confira no OCS Inventory (Inventario > Software/Registro da
    # maquina) qual e o NAME exato dessas chaves e ajuste aqui.
    [PSCustomObject]@{ Chave = "PADA-UE";   NomeVersaoAtual = "PADA-UE";   Propriedade = "VersaoPadaUe";     Coluna = "PadaUe";    Titulo = "PADA-UE";   Largura = 150; ComNomeAmigavel = $true; NaGradePrincipal = $false }
    [PSCustomObject]@{ Chave = "FBR";       NomeVersaoAtual = "FBR";       Propriedade = "VersaoFbr";        Coluna = "Fbr";       Titulo = "FBR";       Largura = 150; ComNomeAmigavel = $true; NaGradePrincipal = $false }
    # Chave "TRANSPORTADORTDTOT" (sem espaco) confirmada no cadastro de
    # registro do OCS Inventory (HKLM\SOFTWARE\Sistemas Eleitorais\
    # TransportadorTDTOT, campo NAME = valor da coluna "Versao"). Ja a
    # coluna "Sistema" da planilha de Versoes usa "TRANSPORTADOR TDTOT"
    # COM ESPACO pra essa mesma linha - por isso NomeVersaoAtual diverge
    # da Chave aqui tambem. Sem nome amigavel (nao tem "nome de praia" na
    # planilha, igual BitLocker/SIS) - mostra a versao crua mesmo.
    [PSCustomObject]@{ Chave = "TRANSPORTADORTDTOT"; NomeVersaoAtual = "TRANSPORTADOR TDTOT"; Propriedade = "VersaoTransportadorTdtot"; Coluna = "TransportadorTdtot"; Titulo = "Transportador TDTOT"; Largura = 150; ComNomeAmigavel = $false; NaGradePrincipal = $true }
    # Confirmados no cadastro de registro do OCS Inventory (mesma tela do
    # TRANSPORTADORTDTOT). NaGradePrincipal = $false pra nao lotar a grade
    # principal de colunas - aparecem na janela "Verificar Sistemas
    # Eleitorais" (menu de contexto, maquinas com SIS instalado).
    [PSCustomObject]@{ Chave = "EXECJAVA";          NomeVersaoAtual = "EXECJAVA";                    Propriedade = "VersaoExecJava";          Coluna = "ExecJava";          Titulo = "ExecJava";                  Largura = 150; ComNomeAmigavel = $false; NaGradePrincipal = $false }
    # Chave de registro "TRANSPORTADOR-HMG" (abreviada), mas a coluna
    # "Sistema" da planilha de Versoes usa o nome por extenso
    # "TRANSPORTADOR HOMOLOGACAO" pra essa linha - mais uma divergencia
    # entre Chave (OCS) e NomeVersaoAtual (planilha).
    [PSCustomObject]@{ Chave = "TRANSPORTADOR-HMG"; NomeVersaoAtual = "TRANSPORTADOR HOMOLOGAÇÃO"; Propriedade = "VersaoTransportadorHmg";  Coluna = "TransportadorHmg";  Titulo = "Transportador Homologacao"; Largura = 150; ComNomeAmigavel = $false; NaGradePrincipal = $false }
    [PSCustomObject]@{ Chave = "CERTIFICADO P12";   NomeVersaoAtual = "CERTIFICADO P12";   Propriedade = "VersaoCertificadoP12";    Coluna = "CertificadoP12";    Titulo = "Certificado P12";           Largura = 150; ComNomeAmigavel = $false; NaGradePrincipal = $false }
)

$script:ArquivoConfigVnc = Join-Path $PSScriptRoot "vnc_config.txt"
$script:ArquivoConfigRc  = Join-Path $PSScriptRoot "rcviewer_config.txt"
$script:SnmpCommunity    = "public"   # comunidade SNMP v1/v2c padrao das impressoras Pantum do TRE-MA

# --- Envio de arquivo CVC (compartilhamento InstSeg\CVC da estacao) para a
# pasta compartilhada no Google Drive (link "Qualquer pessoa com o link").
# O envio e feito via um Web App do Google Apps Script (ver
# apps_script_receber_cvc.gs) que recebe o arquivo por HTTP POST e grava
# direto na pasta - configuravel uma vez em "Configurar Envio Drive...",
# igual ao padrao do VNC Viewer/RCViewer. Se o envio automatico falhar (Web
# App nao configurado, fora do ar, etc), cai para o fallback manual: copia
# o arquivo para uma pasta local e abre a pasta do Drive no navegador, para
# o tecnico arrastar o arquivo ate ela. ---
$script:UrlDrivePastaCvc   = "https://drive.google.com/drive/folders/1ssTe5V1qtDRtWTPJCS5Npw8EiiFJCp6o"
$script:PastaLocalEnvioCvc = Join-Path $env:TEMP "CVC_GoogleDrive"
$script:ArquivoConfigDrive = Join-Path $PSScriptRoot "drive_upload_config.json"

# --- Planilha de Zonas Eleitorais (Zona, Sede, Rede Padrao, Substituta,
# Observacao) - fonte unica de verdade para as redes de cada zona. A coluna
# "Substituta" e o override temporario (ex: link caido, rede alternativa) -
# editavel pela tela "Gerenciar Zonas", que grava de volta na PROPRIA
# planilha via um Web App do Google Apps Script (ver
# apps_script_atualizar_zonas.gs), assim qualquer tecnico com a ferramenta
# ja ve a mesma informacao, sem precisar copiar arquivo de override entre
# maquinas.
# ATENCAO: para o link abaixo funcionar, a planilha (ou pelo menos a aba
# "Zonas") precisa estar compartilhada como "Qualquer pessoa com o link -
# Leitor". Isso expoe TODAS as abas do arquivo a quem tiver o link, nao so
# "Zonas" - se as outras abas tiverem conteudo sensivel, mova "Zonas" para
# uma planilha separada e compartilhe so essa.
$script:UrlPlanilhaZonasCSV  = "https://docs.google.com/spreadsheets/d/1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I/export?format=csv&gid=0"
$script:ArquivoZonasCache    = Join-Path $PSScriptRoot "zonas_cache.csv"
$script:ArquivoConfigZonasWebApp = Join-Path $PSScriptRoot "zonas_webapp_config.json"
$script:TabelaZonas          = @{}   # int (zona) -> PSCustomObject { Sede; RedePadrao; Substituta; Observacao }
$script:ZonaAtual            = 0
$script:RedeCompartilhada    = $false   # true quando a rede da varredura atual e compartilhada entre zonas (ex: Sao Luis)

# --- Aba SEPARADA "GRUPOS-SISTEMAS-ELEITORAIS" da MESMA planilha de Zonas
# (mesmo SpreadsheetId, gid proprio dessa aba) - mapeia grupo do AD (ex:
# "GEDAI2K12GAdmin") -> Sistema + Perfil de acesso (ex: "GEDAI-UE" /
# "Administrador"), usada na janela "Usuarios da ZE" pra mostrar o que
# cada grupo do usuario realmente da acesso, alem so do nome cru do
# grupo. Cache local por igual motivo das outras planilhas (continua
# funcionando com a ultima versao baixada se a planilha ficar fora do ar).
$script:UrlPlanilhaGruposSistemasCSV = "https://docs.google.com/spreadsheets/d/1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I/export?format=csv&gid=634558318"
$script:ArquivoGruposSistemasCache   = Join-Path $PSScriptRoot "grupos_sistemas_cache.csv"
$script:TabelaGruposSistemas         = @{}   # "GRUPO" (maiusculo) -> PSCustomObject { Sistema; Perfil }

# --- Planilha SEPARADA de Sistemas Eleitorais (Sistema, Versao,
# NomeAmigavel, LinkDrive, PastaDestino, Atual) - FONTE UNICA pra dois
# recursos: (1) mapeia a versao "crua" que o OCS Inventory reporta no
# registro (ex: GEDAI = "6.27") para um nome amigavel (ex: "Praia de
# Genipabu") e marca qual e a versao mais recente conhecida de cada
# sistema, pra sinalizar instalacoes desatualizadas na grade; (2) lista os
# pacotes de instalacao (LinkDrive + PastaDestino preenchidos) disponiveis
# na janela "Pacotes de Instalacao". Diferente da planilha de Zonas, essa e
# OPCIONAL e comeca sem URL nenhuma configurada: enquanto nao configurada
# (tela "Configuracoes > Versoes de Sistemas") ou fora do ar, a ferramenta
# simplesmente mostra a versao crua e nao oferece pacotes, como sempre
# mostrou - sem erro.
# Arquivos referenciados em LinkDrive precisam estar compartilhados como
# "Qualquer pessoa com o link - Leitor" (ver Invoke-DownloadGoogleDrivePublico).
# A entrega na maquina de destino reaproveita o MESMO compartilhamento
# "InstSeg" ja usado pelo envio de CVC (\\IP\InstSeg\...) - essa pasta ja
# fica compartilhada pra "todos" em toda estacao (D:\Comum\InstSeg pra
# baixo), entao nao precisa de credencial nenhuma, igual o CVC ja nao
# precisava. Por isso a coluna PastaDestino da planilha e um caminho
# RELATIVO a essa pasta compartilhada (ex: "Eleicoes 2026"), nao um
# caminho local tipo "C:\...".
$script:ArquivoConfigVersoes = Join-Path $PSScriptRoot "versoes_config.json"
$script:ArquivoVersoesCache  = Join-Path $PSScriptRoot "versoes_cache.csv"
$script:TabelaVersoes         = @{}   # "SISTEMA|VERSAO" -> PSCustomObject { NomeAmigavel }
$script:VersaoAtualPorSistema = @{}   # "SISTEMA" -> Versao marcada como mais recente na planilha
$script:PastaCacheDownloads   = Join-Path $env:TEMP "ScannerRedeZona_Pacotes"
$script:TabelaPacotes         = New-Object System.Collections.Generic.List[object]   # lista de { Pacote; IdArquivo; PastaDestino; Versao }

# ============================================================
# BLOCO DE TRABALHO EXECUTADO EM CADA RUNSPACE (1 por IP)
# ============================================================
$scriptBlock = {
    param($ip, $timeoutMs, $portasFallback, $portasImpressora, $portaVnc, $portaRc, $urlOcsApiBase, $zonaAtual, $redeCompartilhada, $mapaModelos, $sistemasEleitoraisExtra)

    function Test-PortaTCP {
        param([string]$IPAlvo, [int]$Porta, [int]$TimeoutMs = 250)
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $conn = $client.BeginConnect($IPAlvo, $Porta, $null, $null)
            $ok = $conn.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected
            $client.Close()
            return $ok
        } catch { return $false }
    }

    $resultado = [PSCustomObject]@{
        IP                 = $ip
        Online             = $false
        Hostname           = ""
        TempoMs            = $null
        PossivelImpressora = $false
        PortasAbertas      = ""
        DetectadoPor       = ""
        VncAtivo           = $false
        RcIvantiAtivo      = $false
        VersaoSis          = "-"
        Modelo             = "-"
    }
    foreach ($sis in $sistemasEleitoraisExtra) {
        $resultado | Add-Member -NotePropertyName $sis.Propriedade -NotePropertyValue "-"
    }

    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $reply = $ping.Send($ip, $timeoutMs)
        if ($reply.Status -eq 'Success') {
            $resultado.Online = $true
            $resultado.TempoMs = $reply.RoundtripTime
            $resultado.DetectadoPor = "ping"
        }
    } catch {}

    if (-not $resultado.Online) {
        foreach ($porta in $portasFallback) {
            if (Test-PortaTCP -IPAlvo $ip -Porta $porta -TimeoutMs 200) {
                $resultado.Online = $true
                $resultado.DetectadoPor = "porta $porta (icmp bloqueado)"
                break
            }
        }
    }

    # 2a tentativa (ping com timeout bem maior) se nem o ping rapido nem
    # nenhuma porta de fallback acharam nada - mitiga falso-negativo por
    # rajada: varrer ate 60 IPs quase ao mesmo tempo pode sofrer
    # throttling/perda pontual num firewall/appliance de seguranca mais
    # restritivo (ex: rede compartilhada da capital), mesmo que um ping
    # avulso, fora da rajada, responda sem problema nenhum.
    if (-not $resultado.Online) {
        try {
            $reply2 = $ping.Send($ip, [Math]::Max($timeoutMs * 3, 1000))
            if ($reply2.Status -eq 'Success') {
                $resultado.Online = $true
                $resultado.TempoMs = $reply2.RoundtripTime
                $resultado.DetectadoPor = "ping (2a tentativa)"
            }
        } catch {}
    }

    if ($resultado.Online) {
        $abertas = @()
        foreach ($porta in $portasImpressora) {
            if (Test-PortaTCP -IPAlvo $ip -Porta $porta -TimeoutMs 200) { $abertas += $porta }
        }
        if ($abertas.Count -gt 0) {
            $resultado.PossivelImpressora = $true
            $resultado.PortasAbertas = ($abertas -join ",")
        }

        if (Test-PortaTCP -IPAlvo $ip -Porta $portaVnc -TimeoutMs 200) {
            $resultado.VncAtivo = $true
        }

        if (Test-PortaTCP -IPAlvo $ip -Porta $portaRc -TimeoutMs 200) {
            $resultado.RcIvantiAtivo = $true
        }

        try {
            $dns = [System.Net.Dns]::GetHostEntry($ip)
            $resultado.Hostname = $dns.HostName
        } catch {
            try {
                $nbt = & nbtstat -A $ip 2>$null
                $linha = $nbt | Select-String -Pattern '<00>\s+UNIQUE' | Select-Object -First 1
                if ($linha) {
                    $resultado.Hostname = ($linha.ToString().Trim() -split '\s+')[0]
                } else {
                    $resultado.Hostname = "(sem resolucao de nome)"
                }
            } catch {
                $resultado.Hostname = "(sem resolucao de nome)"
            }
        }

        if ($resultado.Hostname -match '(?i)pantum') {
            $resultado.PossivelImpressora = $true
        }

        $temNomeValido = $resultado.Hostname -and $resultado.Hostname -ne "(sem resolucao de nome)"

        # Consulta OCS Inventory (VERSAO_SIS + Modelo) direto durante a
        # varredura, em paralelo com o resto. So faz sentido com hostname
        # resolvido e para quem nao e impressora. Numa rede compartilhada
        # (Sao Luis), so consulta quem ja bate com a zona atual pelo padrao
        # do hostname - senao consultaria TODAS as maquinas do predio a cada
        # varredura.
        if ($temNomeValido -and -not $resultado.PossivelImpressora -and $urlOcsApiBase) {
            $consultarOcs = $true
            if ($redeCompartilhada) {
                $zonaPad = "{0:D3}" -f $zonaAtual
                $hostUpper = $resultado.Hostname.ToUpper()
                $consultarOcs = (
                    $hostUpper.Contains("ZMA$zonaPad") -or
                    $hostUpper.Contains("CMA$zonaPad") -or
                    $hostUpper.Contains("ZE-$zonaPad") -or
                    $hostUpper.Contains("ZE$zonaPad")
                )
            }

            if ($consultarOcs) {
                $encontradoNoOcs = $false
                $nomeCurto = ($resultado.Hostname -split '\.')[0]
                foreach ($chaveParam in @("NAME", "name")) {
                    try {
                        $urlBusca = "$urlOcsApiBase/computers/search?start=0&limit=5&$chaveParam=$nomeCurto"
                        $respBusca = Invoke-RestMethod -Uri $urlBusca -TimeoutSec 5
                        if (@($respBusca).Count -gt 0) {
                            $encontradoNoOcs = $true
                            $hwId = @($respBusca)[0].ID

                            try {
                                $urlReg = "$urlOcsApiBase/computer/$hwId/registry"
                                $respReg = Invoke-RestMethod -Uri $urlReg -TimeoutSec 5
                                $secaoRegistry = $null
                                try { $secaoRegistry = $respReg."$hwId".registry } catch {}
                                if ($secaoRegistry) {
                                    $entradaSis = @($secaoRegistry) | Where-Object { $_.NAME -eq "VERSAO_SIS" } | Select-Object -First 1
                                    if ($entradaSis) { $resultado.VersaoSis = $entradaSis.REGVALUE }

                                    foreach ($sis in $sistemasEleitoraisExtra) {
                                        $entradaExtra = @($secaoRegistry) | Where-Object { $_.NAME -eq $sis.Chave } | Select-Object -First 1
                                        if ($entradaExtra -and $entradaExtra.REGVALUE) { $resultado.($sis.Propriedade) = $entradaExtra.REGVALUE }
                                    }
                                }
                            } catch {}

                            try {
                                $urlBios = "$urlOcsApiBase/computer/$hwId/bios"
                                $respBios = Invoke-RestMethod -Uri $urlBios -TimeoutSec 5
                                $secaoBios = $null
                                try { $secaoBios = $respBios."$hwId".bios } catch {}
                                if ($secaoBios) {
                                    $modeloOriginal = @($secaoBios)[0].SMODEL
                                    if ($modeloOriginal) {
                                        if ($mapaModelos -and $mapaModelos.ContainsKey($modeloOriginal)) {
                                            $resultado.Modelo = $mapaModelos[$modeloOriginal]
                                        } else {
                                            $resultado.Modelo = $modeloOriginal
                                        }
                                    }
                                }
                            } catch {}

                            break
                        }
                    } catch {}
                }
                if (-not $encontradoNoOcs) {
                    $resultado.Modelo = "Nao encontrado no OCS"
                }
            }
        }
    }

    return $resultado
}

# ============================================================
# FORM PRINCIPAL
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "TRE-MA / SEASU-COINF-STIC - Scanner de Rede por Zona Eleitoral"
$form.Size = New-Object System.Drawing.Size(1385, 706)
$form.StartPosition = "CenterScreen"
$form.MinimumSize = $form.Size
$form.WindowState = [System.Windows.Forms.FormWindowState]::Maximized
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$lblZona = New-Object System.Windows.Forms.Label
$lblZona.Text = "Numero da Zona:"
$lblZona.Location = New-Object System.Drawing.Point(15, 18)
$lblZona.AutoSize = $true
$form.Controls.Add($lblZona)

$numZona = New-Object System.Windows.Forms.NumericUpDown
$numZona.Location = New-Object System.Drawing.Point(140, 15)
$numZona.Width = 70
$numZona.Minimum = 1
$numZona.Maximum = 253
$numZona.Value = 1
$form.Controls.Add($numZona)

$chkFiltrarZona = New-Object System.Windows.Forms.CheckBox
$chkFiltrarZona.Text = "Mostrar so hosts desta zona (rede compartilhada entre zonas, ex: mesmo predio)"
$chkFiltrarZona.Location = New-Object System.Drawing.Point(230, 17)
$chkFiltrarZona.AutoSize = $true
$chkFiltrarZona.Checked = $true
$form.Controls.Add($chkFiltrarZona)

$btnIniciar = New-Object System.Windows.Forms.Button
$btnIniciar.Text = "Iniciar Varredura"
$btnIniciar.Location = New-Object System.Drawing.Point(710, 13)
$btnIniciar.Width = 110
$btnIniciar.Height = 26
$btnIniciar.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
$btnIniciar.ForeColor = [System.Drawing.Color]::White
$form.Controls.Add($btnIniciar)

$btnCancelar = New-Object System.Windows.Forms.Button
$btnCancelar.Text = "Cancelar"
$btnCancelar.Location = New-Object System.Drawing.Point(825, 13)
$btnCancelar.Width = 105
$btnCancelar.Height = 26
$btnCancelar.Enabled = $false
$form.Controls.Add($btnCancelar)

# --- Linha de info: Sede + rede que sera varrida, atualiza ao digitar a zona ---
$lblSedeInfo = New-Object System.Windows.Forms.Label
$lblSedeInfo.Text = "Sede: -    Rede a varrer: -"
$lblSedeInfo.Location = New-Object System.Drawing.Point(15, 46)
$lblSedeInfo.AutoSize = $true
$lblSedeInfo.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
$lblSedeInfo.ForeColor = [System.Drawing.Color]::FromArgb(0, 90, 158)
$form.Controls.Add($lblSedeInfo)

$btnGerenciarZonas = New-Object System.Windows.Forms.Button
$btnGerenciarZonas.Text = "Gerenciar Redes Zonas"
$btnGerenciarZonas.Location = New-Object System.Drawing.Point(305, 611)
$btnGerenciarZonas.Width = 165
$btnGerenciarZonas.Height = 28
$btnGerenciarZonas.Anchor = "Bottom,Left"
$form.Controls.Add($btnGerenciarZonas)

$btnUsuariosZona = New-Object System.Windows.Forms.Button
$btnUsuariosZona.Text = "Usuarios da ZE 1"
$btnUsuariosZona.Location = New-Object System.Drawing.Point(710, 43)
$btnUsuariosZona.Width = 150
$btnUsuariosZona.Height = 24
$form.Controls.Add($btnUsuariosZona)

$numZona.Add_ValueChanged({ Update-LabelSedeInfo })
$btnGerenciarZonas.Add_Click({ Show-GerenciarZonas })
$btnUsuariosZona.Add_Click({ Show-JanelaUsuariosZona -Zona ([int]$numZona.Value) })

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(15, 76)
$progressBar.Width = 1350
$progressBar.Height = 18
$form.Controls.Add($progressBar)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Pronto. Informe a zona e clique em Iniciar Varredura."
$lblStatus.Location = New-Object System.Drawing.Point(15, 98)
$lblStatus.AutoSize = $true
$form.Controls.Add($lblStatus)

# --- DataGridView de resultados ---
$grid = New-Object System.Windows.Forms.DataGridView
$grid.Location = New-Object System.Drawing.Point(15, 124)
$grid.Size = New-Object System.Drawing.Size(1350, 320)
$grid.Anchor = "Top,Bottom,Left,Right"
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.ReadOnly = $true
$grid.RowHeadersVisible = $false
$grid.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
$grid.MultiSelect = $false
$grid.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None
$grid.AllowUserToOrderColumns = $false

function Add-ColunaGrid {
    param($Nome, $Titulo, $Largura)
    $col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $col.Name = $Nome
    $col.HeaderText = $Titulo
    $col.Width = $Largura
    [void]$grid.Columns.Add($col)
}
Add-ColunaGrid "IP" "IP" 110
Add-ColunaGrid "Tipo" "Tipo" 150
Add-ColunaGrid "Hostname" "Hostname" 250
Add-ColunaGrid "Modelo" "Modelo" 190
Add-ColunaGrid "Tempo" "Tempo (ms)" 75
Add-ColunaGrid "Detectado" "Detectado Por" 270
Add-ColunaGrid "Vnc" "VNC" 85
Add-ColunaGrid "Rc" "RC Ivanti" 90
Add-ColunaGrid "Sis" "SIS" 70
Add-ColunaGrid "Instalador" "Instalador" 130
foreach ($sis in $script:SistemasEleitoraisExtra) {
    if (-not $sis.NaGradePrincipal) { continue }
    Add-ColunaGrid $sis.Coluna $sis.Titulo $sis.Largura
}

$form.Controls.Add($grid)

# --- Log colorido ---
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = "Log:"
$lblLog.Location = New-Object System.Drawing.Point(15, 451)
$lblLog.AutoSize = $true
$lblLog.Anchor = "Bottom,Left"
$form.Controls.Add($lblLog)

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Location = New-Object System.Drawing.Point(15, 471)
$rtbLog.Size = New-Object System.Drawing.Size(1350, 130)
$rtbLog.Anchor = "Bottom,Left,Right"
$rtbLog.ReadOnly = $true
$rtbLog.BackColor = [System.Drawing.Color]::Black
$rtbLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($rtbLog)

function Add-Log {
    param([string]$Texto, [string]$Cor = "White")
    $rtbLog.SelectionStart = $rtbLog.TextLength
    $rtbLog.SelectionLength = 0
    $rtbLog.SelectionColor = [System.Drawing.Color]::$Cor
    $rtbLog.AppendText("$Texto`r`n")
    $rtbLog.ScrollToCaret()
}

# ============================================================
# ZONAS ELEITORAIS: planilha Google Sheets (Zona -> Sede) + overrides
# locais de rede (para links temporarios)
# ============================================================
function Remove-Acentos {
    param([string]$Texto)
    if (-not $Texto) { return "" }
    $normalizado = $Texto.Normalize([System.Text.NormalizationForm]::FormD)
    $sb = New-Object System.Text.StringBuilder
    foreach ($c in $normalizado.ToCharArray()) {
        if ([System.Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne [System.Globalization.UnicodeCategory]::NonSpacingMark) {
            [void]$sb.Append($c)
        }
    }
    return $sb.ToString().Normalize([System.Text.NormalizationForm]::FormC)
}

function ConvertTo-PrefixoRede {
    <#
        Converte uma rede no formato "10.198.4.0/24" (como vem da coluna
        "Rede Padrao"/"Substituta" da planilha) para o prefixo "10.198.4."
        que o resto da ferramenta usa internamente para montar IPs (ex:
        "10.198.4.15"). Tambem aceita "10.198.4.0" sem mascara, ou "10.198.4"
        (3 octetos, atalho comum). Devolve $null se vier vazio ou nao
        reconhecer o formato.
    #>
    param([string]$Rede)
    if (-not $Rede) { return $null }
    $Rede = $Rede.Trim()
    if (-not $Rede) { return $null }
    if ($Rede.EndsWith(".") -and ($Rede -notmatch '/')) { return $Rede }   # ja esta no formato prefixo

    $semMascara = ($Rede -split '/')[0].TrimEnd('.')
    $partes = $semMascara -split '\.'
    if ($partes.Count -eq 4) { return "$($partes[0]).$($partes[1]).$($partes[2])." }
    if ($partes.Count -eq 3) { return "$($partes[0]).$($partes[1]).$($partes[2])." }
    return $null
}

function ConvertTo-CidrRede {
    <#
        Normaliza o que o tecnico digita no campo "Substituta" (ex:
        "10.50.3", "10.50.3.", "10.50.3.0/24") para o formato CIDR
        "10.50.3.0/24", igual ao usado na coluna "Rede Padrao" da planilha -
        mantem a planilha com formato consistente independente de como foi
        digitado na tela.
    #>
    param([string]$Rede)
    if (-not $Rede) { return "" }
    $Rede = $Rede.Trim()
    if (-not $Rede) { return "" }
    $semMascara = ($Rede -split '/')[0].TrimEnd('.')
    $partes = $semMascara -split '\.'
    if ($partes.Count -eq 3 -or $partes.Count -eq 4) {
        return "$($partes[0]).$($partes[1]).$($partes[2]).0/24"
    }
    return $Rede   # formato nao reconhecido - grava cru em vez de tentar adivinhar
}

function Import-TabelaZonas {
    <#
        Carrega Zona -> {Sede, RedePadrao, Substituta, Observacao} a partir
        da planilha Google Sheets publicada como CSV (exige a planilha/aba
        compartilhada como "Qualquer pessoa com o link - Leitor"). Se a
        busca falhar (sem internet, planilha com acesso restrito, etc.),
        cai para o cache local salvo na ultima vez que funcionou.
    #>
    param([switch]$ForcarCache)

    $script:TabelaZonas = @{}
    $linhas = $null

    if (-not $ForcarCache) {
        try {
            $resp = Invoke-WebRequest -Uri $script:UrlPlanilhaZonasCSV -TimeoutSec 8 -UseBasicParsing
            # O PowerShell 5.1 pode decodificar a resposta com a codificacao
            # errada quando o servidor nao informa o charset explicitamente
            # (interpreta bytes UTF-8 como uma pagina de codigo de 1 byte,
            # corrompendo acentos: "SÃO LUÍS" vira "SÃO LUÃS"). Para evitar
            # isso, pegamos os bytes brutos da resposta e decodificamos como
            # UTF-8 manualmente, sem depender da deteccao automatica.
            $bytesResposta = $resp.RawContentStream.ToArray()
            $textoUtf8 = [System.Text.Encoding]::UTF8.GetString($bytesResposta)
            $linhas = $textoUtf8 | ConvertFrom-Csv
            if ($linhas -and $linhas.Count -gt 0) {
                $linhas | Export-Csv -Path $script:ArquivoZonasCache -NoTypeInformation -Encoding UTF8
            }
        } catch {
            Add-Log "[AVISO] Nao foi possivel buscar a planilha de zonas online: $($_.Exception.Message)" "Yellow"
            $linhas = $null
        }
    }

    if (-not $linhas -and (Test-Path $script:ArquivoZonasCache)) {
        Add-Log "Usando cache local de zonas (ultima planilha baixada com sucesso)." "Yellow"
        $linhas = Import-Csv -Path $script:ArquivoZonasCache
    }

    if (-not $linhas) {
        Add-Log "[ERRO] Nenhuma tabela de zonas disponivel (nem online, nem cache local)." "OrangeRed"
        return $false
    }

    foreach ($l in $linhas) {
        $numZona = 0
        if ([int]::TryParse($l.'Zona Eleitoral', [ref]$numZona)) {
            $script:TabelaZonas[$numZona] = [PSCustomObject]@{
                Sede       = $l.Sede
                RedePadrao = $l.'Rede Padrão'
                Substituta = $l.Substituta
                Observacao = $l.'Observação'
            }
        }
    }
    return $true
}

function Import-TabelaGruposSistemas {
    <#
        Carrega Grupo (do AD) -> {Sistema, Perfil} a partir da aba
        "GRUPOS-SISTEMAS-ELEITORAIS" (mesma planilha de Zonas, gid
        proprio). Mesmo esquema de cache local das outras planilhas -
        cai pra ultima versao baixada com sucesso se a planilha estiver
        fora do ar. Usada so pela janela "Usuarios da ZE" (nao bloqueia
        nada na varredura principal se falhar).
    #>
    param([switch]$ForcarCache)

    $script:TabelaGruposSistemas = @{}
    $linhas = $null

    if (-not $ForcarCache) {
        try {
            $resp = Invoke-WebRequest -Uri $script:UrlPlanilhaGruposSistemasCSV -TimeoutSec 8 -UseBasicParsing
            $bytesResposta = $resp.RawContentStream.ToArray()
            $textoUtf8 = [System.Text.Encoding]::UTF8.GetString($bytesResposta)
            $linhas = $textoUtf8 | ConvertFrom-Csv
            if ($linhas -and $linhas.Count -gt 0) {
                $linhas | Export-Csv -Path $script:ArquivoGruposSistemasCache -NoTypeInformation -Encoding UTF8
            }
        } catch {
            Add-Log "[AVISO] Nao foi possivel buscar a planilha de grupos/sistemas online: $($_.Exception.Message)" "Yellow"
            $linhas = $null
        }
    }

    if (-not $linhas -and (Test-Path $script:ArquivoGruposSistemasCache)) {
        Add-Log "Usando cache local de grupos/sistemas (ultima planilha baixada com sucesso)." "Yellow"
        $linhas = Import-Csv -Path $script:ArquivoGruposSistemasCache
    }

    if (-not $linhas) { return $false }

    foreach ($l in $linhas) {
        $grupo = if ($l.Grupo) { $l.Grupo.Trim() } else { $null }
        if (-not $grupo) { continue }
        $script:TabelaGruposSistemas[$grupo.ToUpper()] = [PSCustomObject]@{
            Sistema = $l.Sistema
            Perfil  = $l.Perfil
        }
    }
    return $true
}

function Get-InfoGrupoSistema {
    <#
        Le $script:TabelaGruposSistemas - existe como FUNCAO separada (em
        vez de acessar $script:TabelaGruposSistemas direto de dentro de um
        scriptblock .GetNewClosure()) por causa do mesmo problema de escopo
        ja mapeado nesta ferramenta: um scriptblock .GetNewClosure() so
        enxerga um "retrato" de $script: tirado no momento em que foi
        criado - se o handler de selecao da grade fosse criado ANTES da
        planilha terminar de carregar (que e exatamente o caso aqui, ela
        carrega dentro do evento Shown, DEPOIS que os handlers de clique ja
        foram todos criados), ele nunca veria os dados carregados depois.
        Uma FUNCAO chamada de dentro do closure nao tem esse problema -
        sempre le o $script: real, na hora da chamada.
    #>
    param([string]$NomeGrupo)
    if (-not $NomeGrupo) { return $null }
    return $script:TabelaGruposSistemas[$NomeGrupo.ToUpper()]
}

function Resolve-RedeDaZona {
    <#
        Decide o prefixo de rede a varrer para uma zona, nesta ordem de
        prioridade: (1) coluna "Substituta" da planilha (override temporario,
        editavel pela tela Gerenciar Zonas), (2) coluna "Rede Padrao" da
        planilha, (3) se a planilha nao tiver essa zona ou vier com as
        colunas de rede vazias, calcula como antes (10.11.81. para Sao
        Luis, 10.198.<zona>. para o resto) - assim a ferramenta continua
        funcionando mesmo com a planilha incompleta ou fora do ar.
    #>
    param([int]$Zona)

    $zonaInfo = $script:TabelaZonas[$Zona]
    $sede = if ($zonaInfo) { $zonaInfo.Sede } else { $null }

    $prefixoSubstituta = if ($zonaInfo) { ConvertTo-PrefixoRede $zonaInfo.Substituta } else { $null }
    if ($prefixoSubstituta) {
        return [PSCustomObject]@{ Prefixo = $prefixoSubstituta; Origem = "Substituta (planilha)"; Sede = $sede; Observacao = $zonaInfo.Observacao; EhSubstituta = $true }
    }

    $prefixoPadrao = if ($zonaInfo) { ConvertTo-PrefixoRede $zonaInfo.RedePadrao } else { $null }
    if ($prefixoPadrao) {
        return [PSCustomObject]@{ Prefixo = $prefixoPadrao; Origem = "Rede Padrao (planilha)"; Sede = $sede; Observacao = $null; EhSubstituta = $false }
    }

    $sedeSemAcento = (Remove-Acentos $sede).ToUpper().Trim()
    if ($sedeSemAcento -eq "SAO LUIS") {
        return [PSCustomObject]@{ Prefixo = "10.11.81."; Origem = "Sao Luis (calculado, planilha incompleta)"; Sede = $sede; Observacao = $null; EhSubstituta = $false }
    }

    return [PSCustomObject]@{ Prefixo = "10.198.$Zona."; Origem = "Padrao interior (calculado, planilha incompleta)"; Sede = $sede; Observacao = $null; EhSubstituta = $false }
}

function Test-RedeEhCompartilhada {
    <#
        Uma rede e "compartilhada" quando mais de uma zona eleitoral resolve
        para o mesmo prefixo - normalmente porque varias zonas dividem o
        mesmo predio/rede (ex: zonas 004/005/006 todas atendidas por
        10.198.4.0/24, a rede da zona mais baixa do grupo; ou as zonas de
        Sao Luis, todas em 10.11.81.0/24). Detectado dinamicamente
        percorrendo a planilha (via Resolve-RedeDaZona de cada zona) em vez
        de fixo so para Sao Luis - cobre qualquer grupo que a planilha
        descrever, sem precisar hardcodar cada caso aqui no script.
    #>
    param([string]$Prefixo)
    if (-not $Prefixo) { return $false }

    $contagem = 0
    foreach ($z in $script:TabelaZonas.Keys) {
        $res = Resolve-RedeDaZona -Zona $z
        if ($res.Prefixo -eq $Prefixo) {
            $contagem++
            if ($contagem -gt 1) { return $true }
        }
    }
    return $false
}

function Test-HostnamePertenceZona {
    <#
        Em redes compartilhadas entre varias zonas (ex: 10.11.81.0/24, que
        atende TODAS as zonas com sede em Sao Luis), o IP sozinho nao
        identifica a zona - e preciso olhar o padrao do hostname, que
        costuma embutir o numero da zona com 3 digitos logo apos um prefixo
        (ex: ZMA001WKS63127 = zona 001, CMA005WKS45054 = zona 005,
        ZE-076 = zona 076). Host sem nome resolvido nao pode ser atribuido
        com confianca a nenhuma zona.
    #>
    param([string]$Hostname, [int]$Zona)
    if (-not $Hostname -or $Hostname -eq "(sem resolucao de nome)") { return $false }

    $zonaPad = "{0:D3}" -f $Zona
    $hostUpper = $Hostname.ToUpper()
    return (
        $hostUpper.Contains("ZMA$zonaPad") -or
        $hostUpper.Contains("CMA$zonaPad") -or
        $hostUpper.Contains("ZE-$zonaPad") -or
        $hostUpper.Contains("ZE$zonaPad")
    )
}

# ============================================================
# PLANILHA DE VERSOES DE SISTEMAS (Sistema -> Nome Amigavel / versao mais
# atual) - configuravel em "Configuracoes > Versoes de Sistemas"
# ============================================================
function Get-ConfigVersoes {
    if (-not (Test-Path $script:ArquivoConfigVersoes)) { return $null }
    try {
        $cfg = Get-Content -Path $script:ArquivoConfigVersoes -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.SpreadsheetId) { return $cfg }
    } catch {}
    return $null
}

function Set-ConfigVersoes {
    param([string]$SpreadsheetId, [string]$Gid = "0")
    [PSCustomObject]@{ SpreadsheetId = $SpreadsheetId; Gid = $Gid } |
        ConvertTo-Json | Set-Content -Path $script:ArquivoConfigVersoes -Encoding UTF8
}

function Resolve-IdEGidPlanilha {
    <#
        Aceita tanto o ID puro da planilha quanto a URL inteira colada do
        navegador (https://docs.google.com/spreadsheets/d/<ID>/edit#gid=123456)
        e devolve @{ Id; Gid }, pra o tecnico nao precisar recortar nada na
        mao - inclusive quando a planilha tem VARIAS abas (Zonas, Versoes,
        Pacotes etc na mesma planilha, cada uma com um gid diferente): so
        colar a URL da aba certa que o gid certo ja vem junto. Se a URL nao
        tiver gid (ou for so o ID puro), assume gid=0 (1a aba).
    #>
    param([string]$Entrada)
    if (-not $Entrada) { return $null }
    $Entrada = $Entrada.Trim()

    $id = if ($Entrada -match "/d/([a-zA-Z0-9_-]+)") { $Matches[1] } else { $Entrada }
    $gid = if ($Entrada -match "[#&?]gid=(\d+)") { $Matches[1] } else { "0" }

    return [PSCustomObject]@{ Id = $id; Gid = $gid }
}

function Resolve-NomeExibicaoSistema {
    <#
        Alguns "Sistema" da planilha tem nome de exibicao diferente da
        chave interna usada pra bater com o registro do OCS (ex: chave
        interna continua "GEDAI", confirmado no registro do OCS, mas o
        produto se chama comercialmente "GEDAI-UE" hoje) - reaproveita o
        campo Titulo ja definido em $script:SistemasEleitoraisExtra pra
        essa troca, que e a MESMA fonte usada nos cabecalhos da grade
        principal (assim so precisa mudar em um lugar). Sistemas fora
        dessa lista (ex: CRIPTOSIS, EXECJAVA, TRANSPORTADOR...) mostram o
        proprio nome da planilha, sem alteracao.
    #>
    param([string]$Sistema)
    if (-not $Sistema) { return $Sistema }
    $entrada = $script:SistemasEleitoraisExtra | Where-Object { $_.Chave -eq $Sistema.ToUpper().Trim() } | Select-Object -First 1
    if ($entrada) { return $entrada.Titulo }
    return $Sistema
}

function Resolve-IdArquivoDrive {
    <#
        Aceita o link de compartilhamento inteiro do ARQUIVO (formatos
        ".../file/d/<ID>/view..." ou "...?id=<ID>") ou so o ID puro, e
        devolve so o ID - basta colar na planilha o link de "Compartilhar"
        do arquivo no Drive, sem precisar recortar nada na mao.
    #>
    param([string]$Entrada)
    if (-not $Entrada) { return $null }
    $Entrada = $Entrada.Trim()
    if ($Entrada -match "/file/d/([a-zA-Z0-9_-]+)") { return $Matches[1] }
    if ($Entrada -match "[?&]id=([a-zA-Z0-9_-]+)") { return $Matches[1] }
    return $Entrada
}

function ConvertTo-CaminhoRelativoInstSeg {
    <#
        A coluna PastaDestino da planilha aceita tanto um caminho JA
        relativo ao compartilhamento InstSeg (ex: "Eleicoes 2026\Pacotes")
        quanto um caminho local completo copiado da propria estacao (ex:
        "D:\Comum\InstSeg\Eleicoes 2026") - nesse 2o caso, corta tudo ate
        (e incluindo) o "InstSeg\" e fica so com o resto, que e o que
        importa pra montar \\IP\InstSeg\<resto>.
    #>
    param([string]$Caminho)
    if (-not $Caminho) { return $Caminho }
    $Caminho = $Caminho.Trim().Trim('\')
    if ($Caminho -match '(?i)InstSeg\\(.*)$') { return $Matches[1] }
    return $Caminho
}

function Import-TabelaVersoes {
    <#
        Fonte UNICA de verdade pra tudo relacionado a sistemas eleitorais:
        carrega, de UMA planilha/aba so, tanto o mapeamento Sistema+Versao
        -> Nome Amigavel (usado na grade principal) quanto a lista de
        pacotes de instalacao (usada na janela "Pacotes de Instalacao").
        Colunas esperadas: Sistema | Versao | NomeAmigavel | LinkDrive |
        PastaDestino | Atual | NomeArquivo | Hash | Tamanho (aba
        compartilhada como "Qualquer pessoa com o link - Leitor").
        LinkDrive e PastaDestino sao OPCIONAIS por linha - se faltar um
        dos dois, essa linha participa so do mapeamento de versao/nome
        amigavel, sem virar pacote baixavel. NomeArquivo tambem e
        opcional - se preenchido, a ferramenta ja sabe o nome exato do
        arquivo esperado no destino SEM precisar baixar nada primeiro
        (senao, so descobre apos o 1o download, pelo cabecalho do Drive).
        Hash (MD5) e Tamanho (bytes) sao opcionais, preenchidos pelo Apps
        Script "Calcular Hashes e Tamanhos" (ver
        apps_script_calcular_hash.gs) - usados pra conferir integridade
        do que foi copiado sem precisar reler o arquivo pela rede toda
        vez (Tamanho e checado automatico, mesmo em pacotes ja copiados
        ha tempo; Hash so sob demanda, no botao "Verificar Hash"). Se
        ainda nao estiver configurada, cai pro cache local; sem planilha
        configurada E sem cache, simplesmente nao preenche nada - a
        ferramenta continua funcionando normal (versao crua na grade,
        sem menu de pacotes),
        porque esse recurso inteiro e opcional.
    #>
    param([switch]$ForcarCache)

    $script:TabelaVersoes = @{}
    $script:VersaoAtualPorSistema = @{}
    $script:TabelaPacotes = New-Object System.Collections.Generic.List[object]

    $cfg = Get-ConfigVersoes
    if (-not $cfg) { return $false }

    $linhas = $null
    if (-not $ForcarCache) {
        try {
            $gid = if ($cfg.Gid) { $cfg.Gid } else { "0" }
            $urlCsv = "https://docs.google.com/spreadsheets/d/$($cfg.SpreadsheetId)/export?format=csv&gid=$gid"
            $resp = Invoke-WebRequest -Uri $urlCsv -TimeoutSec 8 -UseBasicParsing
            # Mesmo motivo do Import-TabelaZonas: decodificar como UTF-8 na
            # mao pra nao corromper acentos (ex: "Genipabu" com til/acento
            # em outra palavra da planilha).
            $bytesResposta = $resp.RawContentStream.ToArray()
            $textoUtf8 = [System.Text.Encoding]::UTF8.GetString($bytesResposta)
            $linhas = $textoUtf8 | ConvertFrom-Csv
            if ($linhas -and $linhas.Count -gt 0) {
                $linhas | Export-Csv -Path $script:ArquivoVersoesCache -NoTypeInformation -Encoding UTF8
            }
        } catch {
            Add-Log "[AVISO] Nao foi possivel buscar a planilha de sistemas eleitorais online: $($_.Exception.Message)" "Yellow"
            $linhas = $null
        }
    }

    if (-not $linhas -and (Test-Path $script:ArquivoVersoesCache)) {
        Add-Log "Usando cache local de sistemas eleitorais (ultima planilha baixada com sucesso)." "Yellow"
        $linhas = Import-Csv -Path $script:ArquivoVersoesCache
    }

    if (-not $linhas) { return $false }

    foreach ($l in $linhas) {
        $sistema = if ($l.Sistema) { $l.Sistema.ToUpper().Trim() } else { $null }
        $versao  = if ($l.Versao) { $l.Versao.Trim() } else { $null }
        if (-not $sistema -or -not $versao) { continue }

        $script:TabelaVersoes["$sistema|$versao"] = [PSCustomObject]@{ NomeAmigavel = $l.NomeAmigavel }

        $ehAtual = $l.Atual -and @("SIM", "S", "TRUE", "1", "X") -contains $l.Atual.ToUpper().Trim()
        if ($ehAtual) { $script:VersaoAtualPorSistema[$sistema] = $versao }

        if ($l.LinkDrive -and $l.PastaDestino) {
            $script:TabelaPacotes.Add([PSCustomObject]@{
                Pacote       = Resolve-NomeExibicaoSistema $sistema
                Sistema      = $sistema
                NomeAmigavel = $l.NomeAmigavel
                IdArquivo    = Resolve-IdArquivoDrive $l.LinkDrive
                PastaDestino = ConvertTo-CaminhoRelativoInstSeg $l.PastaDestino
                Versao       = $versao
                NomeArquivo  = if ($l.NomeArquivo) { $l.NomeArquivo.Trim() } else { $null }
                Hash         = if ($l.Hash) { $l.Hash.Trim().ToUpper() } else { $null }
                TamanhoEsperado = $(
                    $tmp = 0L
                    if ($l.Tamanho -and [long]::TryParse($l.Tamanho.Trim(), [ref]$tmp)) { $tmp } else { $null }
                )
            })
        }
    }
    return $true
}

function Resolve-NomeAmigavelVersao {
    <#
        Devolve @{ NomeAmigavel; EhAtual } para a versao instalada de um
        sistema (ex: Sistema="GEDAI", Versao="6.27"), de acordo com a
        planilha de versoes - ou $null se nao houver mapeamento pra essa
        combinacao (quem chama entao continua mostrando a versao crua).
        EhAtual vem $null (nem $true nem $false) quando a planilha nao tem
        NENHUMA versao marcada "Atual" pra esse sistema - nesse caso nao da
        pra saber se esta desatualizado, entao nao sinalizamos nada.
    #>
    param([string]$Sistema, [string]$Versao)
    if (-not $Versao -or $Versao -eq "-") { return $null }

    $sistemaUpper = $Sistema.ToUpper()
    $chave = "$sistemaUpper|$($Versao.Trim())"
    if (-not $script:TabelaVersoes.ContainsKey($chave)) { return $null }

    $versaoAtual = $script:VersaoAtualPorSistema[$sistemaUpper]
    return [PSCustomObject]@{
        NomeAmigavel = $script:TabelaVersoes[$chave].NomeAmigavel
        EhAtual      = if ($versaoAtual) { $versaoAtual -eq $Versao.Trim() } else { $null }
    }
}

function Get-NomeArquivoDeContentDisposition {
    <# Extrai o nome de arquivo original do cabecalho Content-Disposition (se vier). #>
    param($Headers)
    if (-not $Headers) { return $null }
    $cd = ($Headers["Content-Disposition"] -join ";")
    if (-not $cd) { return $null }
    if ($cd -match "filename\*=UTF-8''([^;]+)") { return [uri]::UnescapeDataString($Matches[1]) }
    if ($cd -match 'filename="([^"]+)"') { return $Matches[1] }
    if ($cd -match 'filename=([^;]+)') { return $Matches[1].Trim() }
    return $null
}

function Invoke-DownloadArquivoComProgresso {
    <#
        Baixa uma URL ja resolvida (sem pagina de confirmacao pela frente)
        direto pro disco, em blocos de 256KB, reportando progresso no log a
        cada 5% (com velocidade media) e chamando DoEvents a cada bloco pra
        a janela nao travar durante downloads grandes. Usa HttpWebRequest
        em vez de Invoke-WebRequest justamente pra poder ler em blocos -
        precisa do MESMO CookieContainer da negociacao anterior
        (Invoke-WebRequest -SessionVariable), senao o Google devolve a
        pagina de confirmacao de novo em vez do arquivo.

        $AoAtualizarProgresso (opcional) - scriptblock chamado a cada 5%
        com ($Percent, $TextoStatus), pra quem chamou atualizar algo visual
        (barra de progresso, label) alem do log.
    #>
    param([string]$Url, [System.Net.CookieContainer]$Cookies, [string]$DestinoLocal, [string]$NomePacote = "pacote", [scriptblock]$AoAtualizarProgresso = $null, [System.Windows.Forms.DataGridView]$GridStatus = $null, [int]$LinhaIndice = -1)

    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.CookieContainer = $Cookies
    $req.Timeout = 600000
    $req.ReadWriteTimeout = 600000
    $req.UserAgent = "Mozilla/5.0 (ScannerRedeZona-TRE-MA)"

    $resp = $req.GetResponse()
    try {
        $totalBytes = $resp.ContentLength
        $streamResposta = $resp.GetResponseStream()
        $streamArquivo = [System.IO.File]::Create($DestinoLocal)
        try {
            # Bloco de 256KB - testado na pratica (numa versao anterior da
            # copia pro InstSeg) que blocos maiores (4MB) NAO mudam a taxa
            # media (gargalo e banda do link, nao latencia/numero de
            # idas-e-voltas) - so pioram a granularidade do progresso, sem
            # ganho nenhum. Esse download (Google Drive, HTTP) continua
            # usando este loop manual - a copia pro InstSeg (SMB) e que
            # passou a usar robocopy (ver Copy-ArquivoComRobocopy), que
            # tem retry/resume nativos que fazem mais sentido num
            # compartilhamento de rede instavel do que numa API HTTP.
            $buffer = New-Object byte[] 262144
            $totalLido = 0
            $ultimoPercentLogado = -5
            $cronometro = [System.Diagnostics.Stopwatch]::StartNew()

            while (($lidos = $streamResposta.Read($buffer, 0, $buffer.Length)) -gt 0) {
                Write-BlocoStreamComDoEvents -Stream $streamArquivo -Buffer $buffer -Count $lidos
                $totalLido += $lidos

                if ($totalBytes -gt 0) {
                    $percent = [Math]::Floor(($totalLido / $totalBytes) * 100)
                    # Garante que o 100% sempre aparece, mesmo que o
                    # ultimo bloco pule direto por cima do proximo
                    # multiplo de 5%.
                    if ($percent -ge ($ultimoPercentLogado + 5) -or $percent -ge 100) {
                        $mbLido = [Math]::Round($totalLido / 1MB, 1)
                        $mbTotal = [Math]::Round($totalBytes / 1MB, 1)
                        $velocidade = if ($cronometro.Elapsed.TotalSeconds -gt 0) { [Math]::Round(($totalLido / 1MB) / $cronometro.Elapsed.TotalSeconds, 1) } else { 0 }
                        $textoStatus = "Baixando '$NomePacote': $percent% ($mbLido / $mbTotal MB, $velocidade MB/s)"
                        Add-Log $textoStatus "Gray"
                        if ($AoAtualizarProgresso) { & $AoAtualizarProgresso $percent $textoStatus }
                        Update-StatusPacoteAtivo -Texto $textoStatus -GridStatus $GridStatus -LinhaIndice $LinhaIndice
                        $ultimoPercentLogado = $percent
                    }
                }
                [System.Windows.Forms.Application]::DoEvents()
            }
        } finally {
            $streamArquivo.Close()
            $streamResposta.Close()
        }
        return (Get-NomeArquivoDeContentDisposition -Headers $resp.Headers)
    } finally {
        $resp.Close()
    }
}

function Invoke-DownloadGoogleDrivePublico {
    <#
        Baixa um arquivo publico do Google Drive ("Qualquer pessoa com o
        link - Leitor") pelo ID, pro caminho local indicado. Arquivos
        pequenos vem direto na 1a resposta; arquivos grandes (o Google nao
        consegue rodar antivirus neles) devolvem uma pagina HTML de
        confirmacao em vez do arquivo em si - essa pagina NAO e documentada
        oficialmente pelo Google e o formato pode mudar sem aviso (ja
        mudou no passado, segundo relatos). Tentamos os dois formatos
        conhecidos atualmente; se nenhum bater, devolve erro claro com
        instrucao de onde ajustar.

        Devolve o NOME DE ARQUIVO ORIGINAL (achado no cabecalho
        Content-Disposition da resposta), ou $null se nao vier - o
        conteudo em si sempre e gravado em $DestinoLocal independente
        disso. Quem chama usa esse nome pra saber como se chama o pacote
        de verdade (ex: "GEDAI-UE_v82000-Praia_de_Genipabu.000.627.W.000.FULL"),
        ja que o ID do Drive sozinho nao diz isso.
    #>
    param([string]$FileId, [string]$DestinoLocal, [string]$NomePacote = "pacote", [scriptblock]$AoAtualizarProgresso = $null, [System.Windows.Forms.DataGridView]$GridStatus = $null, [int]$LinhaIndice = -1)

    $ProgressPreference = 'SilentlyContinue'   # a barra de progresso nativa do Invoke-WebRequest deixa downloads grandes bem mais lentos
    $urlInicial = "https://drive.google.com/uc?export=download&id=$FileId"

    $resp1 = Invoke-WebRequest -Uri $urlInicial -SessionVariable sessaoWeb -UseBasicParsing -TimeoutSec 30
    $tipoConteudo = ($resp1.Headers["Content-Type"] -join ";")
    $ehHtml = $tipoConteudo -match "text/html"

    if (-not $ehHtml) {
        [System.IO.File]::WriteAllBytes($DestinoLocal, $resp1.Content)
        return (Get-NomeArquivoDeContentDisposition -Headers $resp1.Headers)
    }

    $html = $resp1.Content

    # Se o arquivo nao estiver REALMENTE publico ("Qualquer pessoa com o
    # link"), em vez do arquivo (ou da pagina de confirmacao de arquivo
    # grande) o Google devolve uma pagina de login/acesso negado - sem essa
    # checagem, o parser abaixo tentava interpretar essa pagina como se
    # fosse o formulario de confirmacao e acabava gerando uma URL invalida
    # (erro confuso "Invalid URI: The hostname could not be parsed").
    if ($html -match "(?i)accounts\.google\.com" -or $html -match "(?i)ServiceLogin" -or $html -match "(?i)You need permission" -or $html -match "(?i)Sign in to continue") {
        throw "O arquivo nao esta publico no Google Drive (o Google pediu login em vez de mandar o arquivo). Verifique o compartilhamento do arquivo: precisa ser 'Qualquer pessoa com o link', nao so o dominio TRE-MA."
    }

    $urlFinal = $null

    # Formato mais recente conhecido: <form action="https://drive.usercontent.google.com/download">
    # com varios <input type="hidden"> - remonta como querystring GET.
    if ($html -match 'action="([^"]+)"') {
        $acao = $Matches[1] -replace "&amp;", "&"
        $campos = [ordered]@{}
        foreach ($m in [regex]::Matches($html, '<input\s+type="hidden"\s+name="([^"]+)"\s+value="([^"]*)"')) {
            $campos[$m.Groups[1].Value] = $m.Groups[2].Value
        }
        if ($campos.Count -gt 0) {
            $qs = ($campos.GetEnumerator() | ForEach-Object { "$($_.Key)=$([uri]::EscapeDataString($_.Value))" }) -join "&"
            $urlFinal = "$acao`?$qs"
        }
    }

    # Formato mais antigo conhecido: link com "confirm=<token>" na propria pagina
    if (-not $urlFinal -and $html -match 'confirm=([0-9A-Za-z_-]+)&amp;id=') {
        $urlFinal = "https://drive.google.com/uc?export=download&confirm=$($Matches[1])&id=$FileId"
    }

    if (-not $urlFinal) {
        throw "Nao consegui reconhecer a pagina de confirmacao de download grande do Google Drive (formato mudou) - ajustar o parser em Invoke-DownloadGoogleDrivePublico."
    }

    return (Invoke-DownloadArquivoComProgresso -Url $urlFinal -Cookies $sessaoWeb.Cookies -DestinoLocal $DestinoLocal -NomePacote $NomePacote -AoAtualizarProgresso $AoAtualizarProgresso -GridStatus $GridStatus -LinhaIndice $LinhaIndice)
}

function Get-CaminhosCachePacote {
    <#
        Monta os 3 caminhos de cache local de um pacote: o arquivo baixado
        em si, o sidecar com o nome original (achado no cabecalho
        Content-Disposition do Drive) e o sidecar com o hash MD5 ja
        calculado - os dois sidecars sao reaproveitados entre downloads e
        copias futuras, sem precisar recalcular toda vez. MD5 (nao SHA256)
        de proposito - e o MESMO algoritmo que o Google Drive ja calcula
        sozinho pra cada arquivo (coluna Hash da planilha, preenchida via
        Apps Script), entao da pra comparar direto com a origem sem
        precisar calcular nada do lado do Drive.
    #>
    param($Pacote)
    $nomeArquivoCache = "$($Pacote.IdArquivo)_$($Pacote.Pacote -replace '[\\/:*?"<>|]', '_')"
    $base = Join-Path $script:PastaCacheDownloads $nomeArquivoCache
    return [PSCustomObject]@{
        ArquivoLocal = $base
        ArquivoNome  = "$base.nome"
        ArquivoHash  = "$base.md5"
    }
}

function Get-CaminhoDestinoUnc {
    param($Resultado, $Pacote)
    return "\\$($Resultado.IP)\InstSeg\$($Pacote.PastaDestino.Trim('\'))"
}

function Get-NomeArquivoConhecidoPacote {
    <#
        Descobre o nome de arquivo esperado do pacote no destino, na ordem:
        (1) coluna NomeArquivo da planilha, se preenchida - mais confiavel,
        o tecnico sabe exatamente qual e o nome antes de baixar qualquer
        coisa; (2) sidecar .nome do cache local, gravado apos um download
        anterior (Content-Disposition do Drive) - so existe se esse pacote
        ja foi baixado do Drive alguma vez, em QUALQUER maquina. Devolve
        $null se nenhuma das duas fontes tiver o nome ainda.
    #>
    param($Pacote)
    if ($Pacote.NomeArquivo) { return $Pacote.NomeArquivo }
    $caminhos = Get-CaminhosCachePacote -Pacote $Pacote
    if (Test-Path $caminhos.ArquivoNome) { return (Get-Content -Path $caminhos.ArquivoNome -Raw -Encoding UTF8).Trim() }
    return $null
}

function Get-ArquivosInstSeg {
    <#
        Lista (recursivo, ate 6 niveis) TODOS os arquivos do
        compartilhamento \\IP\InstSeg de uma maquina, de uma vez so - usada
        pra conferir varios pacotes sem repetir a varredura de rede pra
        cada um (o link da zona pode ser lento). Devolve $null se o
        compartilhamento nao estiver acessivel.
    #>
    param($Resultado)
    $raizInstSeg = "\\$($Resultado.IP)\InstSeg"
    if (-not (Test-Path $raizInstSeg)) { return $null }
    try {
        return @(Get-ChildItem -Path $raizInstSeg -File -Recurse -Depth 6 -ErrorAction SilentlyContinue)
    } catch {
        return $null
    }
}

function Find-PacoteEmArquivosInstSeg {
    <#
        Procura, na lista de arquivos ja levantada por Get-ArquivosInstSeg,
        um arquivo cujo NOME bata EXATAMENTE com o NomeArquivo configurado
        na planilha pra esse pacote (comparacao ja e case-insensitive por
        padrao no PowerShell). E TOLERANTE SO QUANTO A PASTA - acha o
        arquivo em qualquer lugar do InstSeg, nao so na PastaDestino
        configurada (cobre o caso real de usuario final baixando
        manualmente e guardando numa pasta a criterio proprio, ex: "Praia
        de Genipabu" em vez de "Eleicoes 2026"). NAO E tolerante quanto ao
        NOME - um arquivo .zip, renomeado, ou so "parecido" (ex: mesma
        palavra "GEDAI" no nome) NAO conta como copiado, so o nome exato
        oficial da coluna NomeArquivo. Sem NomeArquivo configurado pra esse
        pacote, nao ha o que procurar - devolve $null.
    #>
    param($Pacote, $ArquivosInstSeg)
    if (-not $ArquivosInstSeg -or -not $Pacote.NomeArquivo) { return $null }
    return ($ArquivosInstSeg | Where-Object { $_.Name -eq $Pacote.NomeArquivo } | Select-Object -First 1)
}

function Update-StatusPacoteAtivo {
    <#
        Atualiza o texto de status do pacote em 2 lugares ao mesmo tempo:
        o rotulo do rodape ($script:lblProgressoPacoteAtual) e, se
        informados, a celula "StatusPacote" de uma linha especifica de
        uma grade (ex: a linha que o usuario acabou de clicar "Baixar e
        Copiar" em Show-JanelaSistemasEleitorais) - da pra acompanhar o
        estagio atual (baixando, copiando, conferindo tamanho...) direto
        na grade, sem precisar so do rodape.

        $GridStatus/$LinhaIndice chegam aqui como PARAMETROS normais (nao
        via variavel de closure) de proposito: a funcao que dispara tudo
        isso (Invoke-AcaoBaixarPacote) e chamada de dentro de um handler
        de clique que ja usa .GetNewClosure() - `$script:` dentro de
        closures aninhadas ja causou bug confirmado nesta ferramenta
        (resolve pra um escopo isolado, sempre $null, mesmo com a
        variavel real setada segundos antes). Passar como parametro de
        funcao normal e o jeito comprovadamente seguro, independente de
        quantos niveis de closure existirem no meio do caminho.
    #>
    param([string]$Texto, [System.Windows.Forms.DataGridView]$GridStatus = $null, [int]$LinhaIndice = -1)

    if ($script:lblProgressoPacoteAtual) {
        $script:lblProgressoPacoteAtual.Text = $Texto
        $script:lblProgressoPacoteAtual.Refresh()
    }
    if ($GridStatus -and $LinhaIndice -ge 0 -and $LinhaIndice -lt $GridStatus.Rows.Count) {
        $GridStatus.Rows[$LinhaIndice].Cells["StatusPacote"].Value = $Texto
        $GridStatus.Refresh()
    }
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-InfoArquivoComDoEvents {
    <#
        Test-Path + Get-Item num arquivo especifico (caminho UNC), rodando
        num runspace em segundo plano com a UI so bombeando DoEvents
        enquanto espera - mesmo padrao ja usado noutras chamadas de rede
        desta ferramenta. Um Test-Path/Get-Item direto na thread da UI
        pode levar varios segundos sem devolver o controle nenhuma vez
        quando o link da zona esta lento/instavel (confirmado na pratica:
        travava a janela justo depois de terminar uma copia grande).
        Devolve $null se o arquivo nao existir (ou a chamada falhar).
    #>
    param([string]$Caminho, [int]$TimeoutSec = 10)

    $scriptBlockInfoArquivo = {
        param($Caminho)
        if (-not (Test-Path -LiteralPath $Caminho)) { return $null }
        try { return Get-Item -LiteralPath $Caminho -ErrorAction Stop } catch { return $null }
    }
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript($scriptBlockInfoArquivo).AddArgument($Caminho)
        $handle = $ps.BeginInvoke()
        $cronometro = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $handle.IsCompleted -and $cronometro.Elapsed.TotalSeconds -lt $TimeoutSec) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 30
        }
        if (-not $handle.IsCompleted) { $ps.Stop(); return $null }
        return $ps.EndInvoke($handle) | Select-Object -First 1
    } finally {
        $ps.Dispose()
    }
}

function Get-StatusPacoteNoDestino {
    <#
        Confere se o pacote ja esta na maquina de destino, SEM baixar nem
        copiar nada. Primeiro tenta o caminho EXATO esperado
        (\\IP\InstSeg\PastaDestino\NomeArquivo); se nao achar ali (ou nem
        souber o nome esperado ainda), cai pra uma busca tolerante em TODO
        o compartilhamento InstSeg (Find-PacoteEmArquivosInstSeg) - cobre o
        caso de alguem ter baixado manualmente numa pasta/nome diferente do
        padrao. $ArquivosInstSeg (opcional, de Get-ArquivosInstSeg) evita
        repetir a varredura de rede quando chamado varias vezes seguidas
        pra maquina.
        Se a planilha tiver a coluna Tamanho (bytes) pra esse pacote,
        TamanhoConfere vem $true/$false comparando contra o tamanho real
        do arquivo no destino - SEM RELER O CONTEUDO (so metadado,
        instantaneo), e funciona ate pra pacotes copiados HA TEMPO, ja que
        roda toda vez que o status e calculado (nao so na hora da copia).
        Vem $null se a planilha nao tiver Tamanho pra comparar.

        Devolve @{ Existe; NomeConhecido; Tamanho; TamanhoConfere; Data;
        ArquivoDestino; PastaDestinoUnc; ForaDoPadrao }.
    #>
    param($Resultado, $Pacote, $ArquivosInstSeg = $null)

    $pastaDestinoUnc = Get-CaminhoDestinoUnc -Resultado $Resultado -Pacote $Pacote
    $nomeConhecido = Get-NomeArquivoConhecidoPacote -Pacote $Pacote

    if ($nomeConhecido) {
        $arquivoDestino = Join-Path $pastaDestinoUnc $nomeConhecido
        $info = Get-InfoArquivoComDoEvents -Caminho $arquivoDestino
        if ($info) {
            $tamanhoConfere = if ($Pacote.TamanhoEsperado) { $info.Length -eq $Pacote.TamanhoEsperado } else { $null }
            return [PSCustomObject]@{ Existe = $true; NomeConhecido = $true; Tamanho = $info.Length; TamanhoConfere = $tamanhoConfere; Data = $info.LastWriteTime; ArquivoDestino = $arquivoDestino; PastaDestinoUnc = $pastaDestinoUnc; ForaDoPadrao = $false }
        }
    }

    $achadoFora = Find-PacoteEmArquivosInstSeg -Pacote $Pacote -ArquivosInstSeg $ArquivosInstSeg
    if ($achadoFora) {
        $tamanhoConfere = if ($Pacote.TamanhoEsperado) { $achadoFora.Length -eq $Pacote.TamanhoEsperado } else { $null }
        return [PSCustomObject]@{ Existe = $true; NomeConhecido = [bool]$nomeConhecido; Tamanho = $achadoFora.Length; TamanhoConfere = $tamanhoConfere; Data = $achadoFora.LastWriteTime; ArquivoDestino = $achadoFora.FullName; PastaDestinoUnc = $pastaDestinoUnc; ForaDoPadrao = $true }
    }

    return [PSCustomObject]@{ Existe = $false; NomeConhecido = [bool]$nomeConhecido; Tamanho = $null; TamanhoConfere = $null; Data = $null; ArquivoDestino = $null; PastaDestinoUnc = $pastaDestinoUnc; ForaDoPadrao = $false }
}

function Write-BlocoStreamComDoEvents {
    <#
        Escreve um bloco no stream de forma ASSINCRONA (BeginWrite/EndWrite),
        bombeando DoEvents a cada 100ms enquanto espera o Write terminar -
        em vez de um Write() sincrono comum, que bloqueia a thread da UI
        ATE a rede confirmar aquele bloco inteiro. Num link de zona
        instavel, um unico bloco de 256KB pode levar varios segundos pra
        confirmar - e nesse intervalo, com Write() sincrono, NENHUM
        DoEvents roda, entao o Windows marca a janela como "Not
        Responding" ate aquele bloco especifico terminar (mesmo com
        DoEvents sendo chamado logo depois de CADA bloco - o problema e
        DURANTE um bloco lento, nao entre blocos).
    #>
    param([System.IO.Stream]$Stream, [byte[]]$Buffer, [int]$Count)

    $resultadoAsync = $Stream.BeginWrite($Buffer, 0, $Count, $null, $null)
    while (-not $resultadoAsync.AsyncWaitHandle.WaitOne(100)) {
        [System.Windows.Forms.Application]::DoEvents()
    }
    $Stream.EndWrite($resultadoAsync)
}

function Move-ArquivoRenomeandoComDoEvents {
    <#
        Renomeia um arquivo ja copiado no destino (UNC) - usado depois de
        um robocopy, que sempre preserva o nome de ORIGEM no destino (nao
        da pra pedir pra ele renomear durante a copia). O cache local de
        pacotes usa um nome interno com hash do Drive (ex:
        "1F3mEuF7CgwrZAxb4nSl5_..._PADA-UE"), quase sempre diferente do
        nome final esperado (coluna NomeArquivo da planilha) - sem esse
        passo, o arquivo ficava no InstSeg com o nome de cache errado (ja
        visto na pratica), e a ferramenta nunca reconhecia como copiado.
        Rename e so metadado (SMB), nao rele/reescreve os bytes - rapido
        mesmo em link ruim, mas roda em runspace+DoEvents mesmo assim,
        pelo mesmo motivo de qualquer chamada de rede nesta ferramenta.
        Se ja existir um arquivo com o nome final (ex: copia anterior),
        apaga antes de renomear. Devolve $true/$false.
    #>
    param([string]$CaminhoAtual, [string]$NovoNome, [int]$TimeoutSec = 20)

    $scriptBlockRenomear = {
        param($CaminhoAtual, $NovoNome)
        try {
            $pastaDestino = Split-Path $CaminhoAtual -Parent
            $caminhoFinal = Join-Path $pastaDestino $NovoNome
            if ((Test-Path -LiteralPath $caminhoFinal) -and $caminhoFinal -ne $CaminhoAtual) {
                Remove-Item -LiteralPath $caminhoFinal -Force -ErrorAction SilentlyContinue
            }
            Rename-Item -LiteralPath $CaminhoAtual -NewName $NovoNome -Force -ErrorAction Stop
            return $true
        } catch {
            return $false
        }
    }
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript($scriptBlockRenomear).AddArgument($CaminhoAtual).AddArgument($NovoNome)
        $handle = $ps.BeginInvoke()
        $cronometro = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $handle.IsCompleted -and $cronometro.Elapsed.TotalSeconds -lt $TimeoutSec) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 30
        }
        if (-not $handle.IsCompleted) { $ps.Stop(); return $false }
        return ([bool](Get-InfoArquivoComDoEvents -Caminho (Join-Path (Split-Path $CaminhoAtual -Parent) $NovoNome)))
    } finally {
        $ps.Dispose()
    }
}

function Format-DuracaoLegivel {
    <#
        Converte segundos corridos pra um texto curto em horas/minutos/
        segundos (ex: 45 -> "45s", 264 -> "4min 24s", 3725 -> "1h 02min 05s")
        - so mostra a unidade maior quando ela realmente entra (nao mostra
        "0h" pra copias rapidas). Usado no status de copia via robocopy, que
        pode passar de varios minutos em link lento e ficar ilegivel so em
        segundos corridos.
    #>
    param([double]$TotalSegundos)
    $ts = [TimeSpan]::FromSeconds([Math]::Max([Math]::Round($TotalSegundos), 0))
    if ($ts.TotalHours -ge 1) {
        return "{0}h {1:D2}min {2:D2}s" -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds
    } elseif ($ts.TotalMinutes -ge 1) {
        return "{0}min {1:D2}s" -f [int]$ts.TotalMinutes, $ts.Seconds
    } else {
        return "{0}s" -f $ts.Seconds
    }
}

function Copy-ArquivoComRobocopy {
    <#
        Copia um arquivo local pro destino (UNC do InstSeg) usando o
        robocopy.exe (nativo do Windows, sem instalar nada) em vez do
        FileStream manual - ganha retry automatico (/R) e retomada de
        copia interrompida (/Z), uteis nos links de zona instaveis ja
        vistos nesta ferramenta (quedas de velocidade no meio da
        transferencia).

        IMPORTANTE: NAO usa /MT (multithread do robocopy) - /MT
        paraleliza entre VARIOS arquivos de uma lista, nao pedacos de UM
        arquivo so, e aqui sempre copiamos 1 arquivo por vez, entao nao
        traria ganho de velocidade nenhum. Testado na pratica que o
        gargalo destes links e BANDA do link (nao overhead de protocolo/
        numero de operacoes), entao o ganho real de trocar pro robocopy
        e confiabilidade (retry/resume), NAO velocidade.

        Como ler o progresso do STDOUT do robocopy de forma confiavel
        quando redirecionado e complicado (formato muda, risco de
        deadlock de pipe cheio), o progresso aqui e ESTIMADO por polling
        periodico (a cada ~2s) do tamanho atual do arquivo de destino,
        comparado ao tamanho do arquivo de origem - mesma ideia de
        "quanto ja chegou", so que medido de fora em vez de contado bloco
        a bloco.

        TESTADO NA PRATICA e ABANDONADO: medir progresso pelo TAMANHO do
        arquivo de destino nao funciona com robocopy - com /Z (modo
        restartable), o Windows/robocopy pre-aloca o tamanho final do
        arquivo quase imediatamente (poucos segundos), entao o "tamanho
        atual" chega em ~100% muito antes da copia de verdade terminar -
        a barra pulava rapido pra quase 100% e ficava "parada" ali pelo
        tempo real da transferencia (confirmado: 192s numa copia que "já
        mostrava" 99% aos poucos segundos). Por isso o status agora e por
        TEMPO DECORRIDO (sem fingir uma % que nao reflete a realidade),
        atualizado tanto no rotulo quanto (se informado) na celula da
        grade da linha ativa - ver Update-StatusPacoteAtivo.

        IMPORTANTE: robocopy sempre preserva o NOME DE ORIGEM no destino
        (o cache local usa um nome interno com hash, diferente do nome
        final esperado da planilha) - ao terminar a copia com sucesso,
        renomeia pro nome final via Move-ArquivoRenomeandoComDoEvents.

        $AoAtualizarProgresso (opcional) - so chamado 1x no final (100%),
        pra mover a barra numerica pro fim; durante a copia em si, o
        status e so texto (via Update-StatusPacoteAtivo), sem % numerico.
    #>
    param([string]$Origem, [string]$Destino, [string]$NomePacote = "pacote", [scriptblock]$AoAtualizarProgresso = $null, [System.Windows.Forms.DataGridView]$GridStatus = $null, [int]$LinhaIndice = -1)

    $origemDir = Split-Path $Origem -Parent
    $nomeArquivo = Split-Path $Origem -Leaf
    $destinoDir = Split-Path $Destino -Parent
    $nomeFinalDesejado = Split-Path $Destino -Leaf
    $caminhoComNomeOrigem = Join-Path $destinoDir $nomeArquivo
    $totalBytes = (Get-Item $Origem).Length

    # /Z = restartable (retoma copia interrompida em vez de comecar do
    # zero num link que caiu no meio); /J = I/O nao-bufferizado
    # (recomendado p/ arquivos grandes); /R:5 /W:10 = tenta de novo ate
    # 5x, esperando 10s entre tentativas (o padrao do robocopy e 1
    # MILHAO de tentativas - sempre precisa limitar); /NP evita
    # progresso por byte no console (nao da pra ler de forma confiavel
    # via redirecionamento); /NJH /NJS /NDL /NFL /NC /NS reduzem o log a
    # praticamente nada.
    $argsRobocopy = @(
        "`"$origemDir`""
        "`"$destinoDir`""
        "`"$nomeArquivo`""
        "/Z", "/J", "/R:5", "/W:10", "/NP", "/NJH", "/NJS", "/NDL", "/NFL", "/NC", "/NS"
    )

    $pastaLogsTemp = Join-Path $env:TEMP "ScannerRedeZona_RobocopyLogs"
    if (-not (Test-Path $pastaLogsTemp)) { New-Item -ItemType Directory -Path $pastaLogsTemp -Force | Out-Null }
    $sufixoLog = [Guid]::NewGuid().ToString('N')
    $logSaida = Join-Path $pastaLogsTemp "robocopy_$sufixoLog.log"
    $logErro = Join-Path $pastaLogsTemp "robocopy_$sufixoLog.err.log"

    try {
        # -RedirectStandardOutput/-Error gravam DIRETO em arquivo (nao
        # via pipe) - evita o classico deadlock de "pipe cheio" que
        # rolaria se tentassemos ler o stdout ao vivo sem drenar direito.
        $processo = Start-Process -FilePath "robocopy.exe" -ArgumentList $argsRobocopy -NoNewWindow -PassThru -RedirectStandardOutput $logSaida -RedirectStandardError $logErro

        $mbTotal = [Math]::Round($totalBytes / 1MB, 1)
        $cronometro = [System.Diagnostics.Stopwatch]::StartNew()
        $proximaAtualizacao = [System.Diagnostics.Stopwatch]::StartNew()
        $textoStatus = "Copiando '$NomePacote' (robocopy, $mbTotal MB) ha $(Format-DuracaoLegivel 0)..."
        Update-StatusPacoteAtivo -Texto $textoStatus -GridStatus $GridStatus -LinhaIndice $LinhaIndice
        Add-Log $textoStatus "Gray"
        while (-not $processo.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200

            if ($proximaAtualizacao.Elapsed.TotalSeconds -ge 3) {
                $proximaAtualizacao.Restart()
                $textoStatus = "Copiando '$NomePacote' (robocopy, $mbTotal MB) ha $(Format-DuracaoLegivel $cronometro.Elapsed.TotalSeconds)..."
                Update-StatusPacoteAtivo -Texto $textoStatus -GridStatus $GridStatus -LinhaIndice $LinhaIndice
                Add-Log $textoStatus "Gray"
            }
        }
        $processo.WaitForExit()
    } finally {
        Remove-Item -Path $logSaida, $logErro -Force -ErrorAction SilentlyContinue
    }

    # Codigo de saida do robocopy e um BITMASK, nao "0 = sucesso" como a
    # maioria dos programas: 0-7 sao variacoes de sucesso (1 = copiou
    # arquivo(s), 2 = achou extras no destino, 4 = alguns arquivos/pastas
    # incompativeis - raro copiando 1 arquivo so); 8+ indica falha real.
    if ($processo.ExitCode -ge 8) {
        throw "robocopy falhou (codigo de saida $($processo.ExitCode)) ao copiar '$NomePacote' para '$Destino'."
    }

    # robocopy terminou e copiou o arquivo com o NOME DE ORIGEM (do
    # cache local) - renomeia pro nome final esperado, se forem
    # diferentes (quase sempre sao, ja que o cache usa nome com hash).
    if ($nomeFinalDesejado -ne $nomeArquivo) {
        if (-not (Move-ArquivoRenomeandoComDoEvents -CaminhoAtual $caminhoComNomeOrigem -NovoNome $nomeFinalDesejado)) {
            throw "robocopy copiou o arquivo, mas falhou ao renomear de '$nomeArquivo' para '$nomeFinalDesejado' no destino."
        }
    }

    $textoConcluido = "Copiando '$NomePacote' (robocopy, $mbTotal MB) concluido em $(Format-DuracaoLegivel $cronometro.Elapsed.TotalSeconds)."
    Add-Log $textoConcluido "Gray"
    Update-StatusPacoteAtivo -Texto $textoConcluido -GridStatus $GridStatus -LinhaIndice $LinhaIndice
    if ($AoAtualizarProgresso) { & $AoAtualizarProgresso 100 $textoConcluido }
}

function Invoke-AcaoBaixarPacote {
    <#
        Baixa o pacote do Google Drive (com cache local - so baixa de novo
        se ainda nao tiver em disco) e copia pra pasta configurada na
        maquina de destino via \\IP\InstSeg\<PastaDestino> - o MESMO
        compartilhamento ja usado pelo envio de CVC, que ja fica aberto
        pra "todos" em toda estacao (D:\Comum\InstSeg pra baixo) e por
        isso NAO precisa de credencial nenhuma (confirmado pelo usuario:
        o Explorer abre \\IP\InstSeg direto, sem pedir login).

        Depois de BAIXAR (antes de copiar), calcula o hash MD5 do arquivo
        local (so na 1a vez - fica cacheado no sidecar .md5) e, se a
        planilha tiver a coluna Hash preenchida (o MD5 oficial que o
        proprio Google Drive ja calculou no upload), compara - isso e
        BARATO (leitura local, sem rede) e confirma que o DOWNLOAD do
        Drive veio integro, sem precisar reler nada pela rede da zona
        depois.

        Depois de COPIAR pro destino, a conferencia automatica e so de
        TAMANHO (metadado, instantaneo) - nao rele o arquivo inteiro pela
        rede a cada copia, porque em pacotes de 500MB isso levaria tanto
        tempo quanto a copia em si. Pra uma conferencia mais forte (hash
        completo) depois de copiado, use o botao "Verificar Hash" na
        janela de Pacotes, sob demanda.

        Fluxo sincrono/bloqueante de proposito - pacotes grandes podem
        levar minutos, mas tanto o download quanto a copia agora reportam
        progresso (log + $AoAtualizarProgresso opcional) e chamam DoEvents
        a cada bloco, entao a janela nao fica "travada" sem explicacao.
        Devolve $true se copiou E o tamanho confere, $false em qualquer
        outro caso (falha, ou tamanho divergente).
    #>
    param($Resultado, $Pacote, [scriptblock]$AoAtualizarProgresso = $null, [System.Windows.Forms.DataGridView]$GridStatus = $null, [int]$LinhaIndice = -1)

    if (-not $Pacote -or -not $Pacote.IdArquivo) {
        [System.Windows.Forms.MessageBox]::Show("Pacote sem ID de arquivo do Drive valido.", "Aviso", "OK", "Warning") | Out-Null
        return $false
    }
    if (-not $Pacote.PastaDestino) {
        [System.Windows.Forms.MessageBox]::Show("Pasta de destino nao informada na planilha para este pacote.", "Erro", "OK", "Error") | Out-Null
        return $false
    }

    $grid.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $pastaDestinoUnc = Get-CaminhoDestinoUnc -Resultado $Resultado -Pacote $Pacote
    $caminhos = Get-CaminhosCachePacote -Pacote $Pacote
    try {
        if (-not (Test-Path $script:PastaCacheDownloads)) {
            New-Item -ItemType Directory -Path $script:PastaCacheDownloads -Force | Out-Null
        }

        if (Test-Path $caminhos.ArquivoLocal) {
            Add-Log "Pacote '$($Pacote.Pacote)' ja esta em cache local ($($caminhos.ArquivoLocal)) - pulando novo download." "Gray"
            Update-StatusPacoteAtivo -Texto "Ja em cache local - pulando download..." -GridStatus $GridStatus -LinhaIndice $LinhaIndice
            $nomeArquivoOriginal = if (Test-Path $caminhos.ArquivoNome) { (Get-Content -Path $caminhos.ArquivoNome -Raw -Encoding UTF8).Trim() } else { $null }
        } else {
            Add-Log "Baixando pacote '$($Pacote.Pacote)' do Google Drive (pode demorar bastante em arquivos grandes)..." "Cyan"
            Update-StatusPacoteAtivo -Texto "Baixando do Google Drive..." -GridStatus $GridStatus -LinhaIndice $LinhaIndice
            $cronometroDownload = [System.Diagnostics.Stopwatch]::StartNew()
            try {
                $nomeArquivoOriginal = Invoke-DownloadGoogleDrivePublico -FileId $Pacote.IdArquivo -DestinoLocal $caminhos.ArquivoLocal -NomePacote $Pacote.Pacote -AoAtualizarProgresso $AoAtualizarProgresso -GridStatus $GridStatus -LinhaIndice $LinhaIndice
            } catch {
                if (Test-Path $caminhos.ArquivoLocal) { Remove-Item $caminhos.ArquivoLocal -Force -ErrorAction SilentlyContinue }
                throw
            }
            if ($nomeArquivoOriginal) {
                Set-Content -Path $caminhos.ArquivoNome -Value $nomeArquivoOriginal -Encoding UTF8
            } else {
                Add-Log "[AVISO] Nao veio o nome original do arquivo no cabecalho do Drive - vou usar o nome do pacote da planilha como nome de arquivo no destino." "Yellow"
            }
            $tamanhoMb = [Math]::Round((Get-Item $caminhos.ArquivoLocal).Length / 1MB, 1)
            Add-Log "Download concluido: $tamanhoMb MB em $([Math]::Round($cronometroDownload.Elapsed.TotalSeconds, 1))s." "Cyan"
        }

        # Hash MD5 do cache local - calculado so uma vez (fica no sidecar
        # .md5) e comparado contra a coluna Hash da planilha, SE tiver
        # (MD5 oficial que o proprio Drive ja calculou no upload). Isso e
        # leitura LOCAL (disco, nao rede), entao e barato mesmo em arquivo
        # grande - e pega logo de cara se o DOWNLOAD do Drive veio
        # corrompido, sem precisar esperar chegar na parte de copiar.
        $hashLocal = if (Test-Path $caminhos.ArquivoHash) {
            (Get-Content -Path $caminhos.ArquivoHash -Raw -Encoding UTF8).Trim()
        } else {
            Add-Log "Calculando hash MD5 do pacote (cache local)..." "Gray"
            Update-StatusPacoteAtivo -Texto "Calculando hash MD5 (local)..." -GridStatus $GridStatus -LinhaIndice $LinhaIndice
            $h = (Get-FileHash -Path $caminhos.ArquivoLocal -Algorithm MD5).Hash
            Set-Content -Path $caminhos.ArquivoHash -Value $h -Encoding UTF8
            $h
        }
        if ($Pacote.Hash) {
            if ($hashLocal -eq $Pacote.Hash) {
                Add-Log "Hash MD5 do download confere com o oficial do Drive (planilha)." "Gray"
            } else {
                Add-Log "[ERRO] Hash MD5 do pacote baixado NAO confere com o oficial da planilha (baixado=$hashLocal planilha=$($Pacote.Hash)) - o DOWNLOAD do Drive pode ter vindo corrompido. Apague o cache local ($($caminhos.ArquivoLocal)) e baixe de novo." "OrangeRed"
                [System.Windows.Forms.MessageBox]::Show("ATENCAO: o hash MD5 do arquivo baixado nao confere com o oficial da planilha - o download pode ter vindo corrompido do Drive.`r`n`r`nApague o arquivo em cache e tente baixar de novo:`r`n$($caminhos.ArquivoLocal)", "Hash do download nao confere", "OK", "Warning") | Out-Null
            }
        }

        if (-not (Test-Path $pastaDestinoUnc)) {
            New-Item -ItemType Directory -Path $pastaDestinoUnc -Force | Out-Null
        }
        $nomeArquivoDestino = if ($Pacote.NomeArquivo) { $Pacote.NomeArquivo } elseif ($nomeArquivoOriginal) { $nomeArquivoOriginal } else { $Pacote.Pacote -replace '[\\/:*?"<>|]', '_' }
        $arquivoDestinoUnc = Join-Path $pastaDestinoUnc $nomeArquivoDestino

        Add-Log "Copiando pacote para '$arquivoDestinoUnc'..." "Cyan"
        $cronometroCopia = [System.Diagnostics.Stopwatch]::StartNew()
        Copy-ArquivoComRobocopy -Origem $caminhos.ArquivoLocal -Destino $arquivoDestinoUnc -NomePacote $Pacote.Pacote -AoAtualizarProgresso $AoAtualizarProgresso -GridStatus $GridStatus -LinhaIndice $LinhaIndice

        Update-StatusPacoteAtivo -Texto "Conferindo tamanho no destino..." -GridStatus $GridStatus -LinhaIndice $LinhaIndice
        if ($AoAtualizarProgresso) { & $AoAtualizarProgresso 100 "Conferindo tamanho de '$($Pacote.Pacote)' no destino..." }

        # Conferencia automatica pos-copia e SO DE TAMANHO (metadado,
        # instantaneo) - reler o arquivo inteiro pela rede da zona a cada
        # copia pra hash levaria tanto tempo quanto a copia em si em
        # pacotes de 500MB. O botao "Verificar Hash" na janela de Pacotes
        # faz a conferencia forte (hash completo), sob demanda.
        #
        # Os dois Get-Item (local + remoto/UNC) rodam num runspace em
        # segundo plano, com a thread principal so bombeando DoEvents
        # enquanto espera - mesmo padrao ja usado pra listar o InstSeg em
        # Show-JanelaPacotes. Get-Item no arquivo remoto e uma chamada de
        # rede (SMB) que pode demorar alguns segundos num link de zona
        # ruim; rodando direto na thread da UI (sem DoEvents no meio), a
        # janela ficava "Not Responding" bem nesse intervalo, entre o
        # ultimo % logado e a caixa de mensagem final.
        $scriptBlockChecarTamanhos = {
            param($CaminhoLocal, $CaminhoRemoto)
            [PSCustomObject]@{
                TamanhoLocal  = (Get-Item -Path $CaminhoLocal).Length
                TamanhoRemoto = (Get-Item -Path $CaminhoRemoto).Length
            }
        }
        $psChecagem = [powershell]::Create()
        try {
            [void]$psChecagem.AddScript($scriptBlockChecarTamanhos).AddArgument($caminhos.ArquivoLocal).AddArgument($arquivoDestinoUnc)
            $handleChecagem = $psChecagem.BeginInvoke()
            while (-not $handleChecagem.IsCompleted) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 50
            }
            $resultadoChecagem = $psChecagem.EndInvoke($handleChecagem)
        } finally {
            $psChecagem.Dispose()
        }
        $tamanhoLocal = $resultadoChecagem.TamanhoLocal
        $tamanhoRemoto = $resultadoChecagem.TamanhoRemoto
        $bateTamanho = $tamanhoLocal -eq $tamanhoRemoto

        if ($bateTamanho) {
            Add-Log "Pacote '$($Pacote.Pacote)' copiado com sucesso para '$($Resultado.Hostname)' ($arquivoDestinoUnc) em $([Math]::Round($cronometroCopia.Elapsed.TotalSeconds, 1))s - tamanho confere ($([Math]::Round($tamanhoRemoto / 1MB, 1)) MB)." "Green"
            [System.Windows.Forms.MessageBox]::Show("Pacote '$($Pacote.Pacote)' copiado com sucesso para:`r`n$arquivoDestinoUnc`r`n`r`nTamanho conferido ($([Math]::Round($tamanhoRemoto / 1MB, 1)) MB). Use 'Verificar Hash' na janela de Pacotes pra uma conferencia mais forte (mais lenta) quando quiser.", "Concluido", "OK", "Information") | Out-Null
        } else {
            Add-Log "[ERRO] Pacote '$($Pacote.Pacote)' copiado, mas o TAMANHO nao confere (local=$tamanhoLocal remoto=$tamanhoRemoto) - a copia pode ter sido truncada no link da zona. Copie de novo." "OrangeRed"
            [System.Windows.Forms.MessageBox]::Show("ATENCAO: o pacote foi copiado, mas o tamanho nao confere com o original - a copia pode ter sido truncada (comum em links de zona instaveis). Recomendado copiar de novo.`r`n`r`nDestino: $arquivoDestinoUnc", "Tamanho nao confere", "OK", "Warning") | Out-Null
        }
        return $bateTamanho
    } catch {
        Add-Log "[ERRO] Falha ao baixar/copiar o pacote '$($Pacote.Pacote)': $($_.Exception.Message)" "OrangeRed"
        [System.Windows.Forms.MessageBox]::Show("Falha ao baixar/copiar o pacote:`r`n$($_.Exception.Message)`r`n`r`nSe a conexao via $pastaDestinoUnc falhar mesmo com a rede aparentemente ok, pode ser o mesmo tipo de bloqueio de firewall/antivirus ja visto com VNC/RC (testar a porta 445 com o mesmo metodo do vnc_diagnostico.ps1 ajuda a confirmar).", "Erro", "OK", "Error") | Out-Null
        return $false
    } finally {
        $grid.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

function Invoke-AcaoVerificarHashPacote {
    <#
        Reconfere o hash MD5 do arquivo JA copiado no destino - util pra
        checar a integridade de uma copia feita anteriormente, sob demanda,
        sem gastar banda de novo com download/copia. Ainda assim precisa
        ler o arquivo inteiro de volta pelo link da zona pra calcular o
        hash, o que pode demorar em arquivos grandes/links lentos (por
        isso NAO roda automatico depois de cada copia - so quando pedido).

        Compara contra, em ordem de preferencia: (1) coluna Hash da
        planilha (MD5 OFICIAL que o proprio Google Drive calculou no
        upload - a referencia mais forte, independente do que a ferramenta
        baixou); (2) hash do cache local (calculado por esta ferramenta no
        momento do download) - usado so se a planilha nao tiver Hash pra
        esse pacote.

        $StatusInfo (opcional) reaproveita o status JA calculado pela
        grade (Get-StatusPacoteNoDestino) em vez de refazer a varredura
        recursiva do InstSeg inteiro de novo - so recalcula do zero se nao
        vier nada (fallback de seguranca).
    #>
    param($Resultado, $Pacote, $StatusInfo = $null, [System.Windows.Forms.DataGridView]$GridStatus = $null, [int]$LinhaIndice = -1)

    $statusInfo = $StatusInfo
    if (-not $statusInfo) {
        $statusInfo = Get-StatusPacoteNoDestino -Resultado $Resultado -Pacote $Pacote -ArquivosInstSeg (Get-ArquivosInstSeg -Resultado $Resultado)
    }
    if (-not $statusInfo.Existe) {
        [System.Windows.Forms.MessageBox]::Show("Esse pacote ainda nao foi copiado pra essa maquina.", "Aviso", "OK", "Warning") | Out-Null
        return
    }

    $origemHash = "planilha (oficial do Drive)"
    $hashReferencia = $Pacote.Hash
    if (-not $hashReferencia) {
        $caminhos = Get-CaminhosCachePacote -Pacote $Pacote
        if (Test-Path $caminhos.ArquivoHash) {
            $hashReferencia = (Get-Content -Path $caminhos.ArquivoHash -Raw -Encoding UTF8).Trim()
            $origemHash = "cache local (baixado por esta ferramenta)"
        }
    }
    if (-not $hashReferencia) {
        [System.Windows.Forms.MessageBox]::Show("Sem hash de referencia pra comparar (nem a coluna Hash da planilha, nem cache local desta ferramenta pra esse pacote).", "Aviso", "OK", "Warning") | Out-Null
        return
    }

    Add-Log "Verificando hash MD5 de '$($Pacote.Pacote)' em '$($statusInfo.ArquivoDestino)' contra referencia da $origemHash (pode demorar em arquivos grandes/links lentos)..." "Cyan"
    $cronometro = [System.Diagnostics.Stopwatch]::StartNew()
    Update-StatusPacoteAtivo -Texto "Verificando hash MD5 (lendo arquivo inteiro pela rede)..." -GridStatus $GridStatus -LinhaIndice $LinhaIndice

    # Le o arquivo INTEIRO pela rede da zona pra calcular o hash - roda num
    # runspace em segundo plano (mesmo padrao ja usado pra listar o
    # InstSeg e pra conferir tamanho pos-copia), com a thread da UI so
    # bombeando DoEvents enquanto espera. Nao usa Get-FileHash (usa
    # System.Security.Cryptography.MD5 direto, lendo em blocos de 4MB) -
    # o buffer interno do Get-FileHash e pequeno demais pra um link com
    # latencia alta (mesmo motivo do buffer de 256KB->4MB na copia: em
    # link de zona ruim, o gargalo costuma ser NUMERO de idas-e-voltas
    # pela rede, nao banda - blocos maiores reduzem drasticamente isso).
    $scriptBlockHashRemoto = {
        param($Caminho)
        $md5 = [System.Security.Cryptography.MD5]::Create()
        try {
            $stream = [System.IO.File]::OpenRead($Caminho)
            try {
                $buffer = New-Object byte[] 4194304
                while (($lidos = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                    [void]$md5.TransformBlock($buffer, 0, $lidos, $null, 0)
                }
                [void]$md5.TransformFinalBlock((New-Object byte[] 0), 0, 0)
                return ([System.BitConverter]::ToString($md5.Hash) -replace '-', '')
            } finally {
                $stream.Close()
            }
        } finally {
            $md5.Dispose()
        }
    }
    $psHash = [powershell]::Create()
    try {
        [void]$psHash.AddScript($scriptBlockHashRemoto).AddArgument($statusInfo.ArquivoDestino)
        $handleHash = $psHash.BeginInvoke()
        $proximaAtualizacaoHash = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $handleHash.IsCompleted) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
            if ($proximaAtualizacaoHash.Elapsed.TotalSeconds -ge 3) {
                $proximaAtualizacaoHash.Restart()
                Update-StatusPacoteAtivo -Texto "Verificando hash MD5 ha $([Math]::Round($cronometro.Elapsed.TotalSeconds))s..." -GridStatus $GridStatus -LinhaIndice $LinhaIndice
            }
        }
        $hashRemoto = $psHash.EndInvoke($handleHash)
        if ($psHash.Streams.Error.Count -gt 0) { throw $psHash.Streams.Error[0].Exception }
    } catch {
        Add-Log "[ERRO] Falha ao ler o arquivo no destino pra calcular o hash: $($_.Exception.Message)" "OrangeRed"
        [System.Windows.Forms.MessageBox]::Show("Falha ao ler o arquivo no destino:`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
        return
    } finally {
        $psHash.Dispose()
    }

    if ($hashRemoto -eq $hashReferencia) {
        Add-Log "Hash MD5 confere para '$($Pacote.Pacote)' em '$($Resultado.Hostname)' ($([Math]::Round($cronometro.Elapsed.TotalSeconds, 1))s, referencia: $origemHash)." "Green"
        Update-StatusPacoteAtivo -Texto "Hash MD5 conferido - integro." -GridStatus $GridStatus -LinhaIndice $LinhaIndice
        [System.Windows.Forms.MessageBox]::Show("O sistema '$($Pacote.Pacote)' esta INTEGRO em '$($Resultado.Hostname)' ($($Resultado.IP)).`r`n`r`nHash MD5 origem ($origemHash):`r`n$hashReferencia`r`n`r`nHash MD5 destino ($($statusInfo.ArquivoDestino)):`r`n$hashRemoto`r`n`r`nOs dois hashes conferem.", "Integridade OK", "OK", "Information") | Out-Null
    } else {
        Add-Log "[ERRO] Hash MD5 NAO confere para '$($Pacote.Pacote)' em '$($Resultado.Hostname)' (destino=$hashRemoto referencia=$hashReferencia, $origemHash)." "OrangeRed"
        Update-StatusPacoteAtivo -Texto "Hash MD5 NAO confere - possivel corrupcao." -GridStatus $GridStatus -LinhaIndice $LinhaIndice
        [System.Windows.Forms.MessageBox]::Show("ATENCAO: o sistema '$($Pacote.Pacote)' em '$($Resultado.Hostname)' ($($Resultado.IP)) NAO esta integro - o arquivo no destino pode estar corrompido.`r`n`r`nHash MD5 origem ($origemHash):`r`n$hashReferencia`r`n`r`nHash MD5 destino ($($statusInfo.ArquivoDestino)):`r`n$hashRemoto`r`n`r`nRecomendado copiar de novo.", "Hash NAO confere", "OK", "Warning") | Out-Null
    }
}

function Invoke-AcaoAbrirPastaPacote {
    <#
        Abre o Explorer na pasta onde o pacote REALMENTE esta - se foi
        achado fora do padrao (usuario final baixou manualmente numa pasta
        a criterio proprio), abre ESSA pasta em vez da esperada, senao o
        tecnico veria uma pasta vazia/errada. So cai pra pasta esperada
        (\\IP\InstSeg\PastaDestino) se nada foi encontrado em lugar nenhum.
        Nao-elevado, mesmo padrao usado no resto do script pra lancar
        programas externos.

        $StatusInfo (opcional) reaproveita o status JA calculado pela
        grade (Get-StatusPacoteNoDestino) em vez de refazer a varredura
        recursiva do InstSeg inteiro de novo so pra abrir uma pasta - era
        isso que deixava o clique lento/travando a janela. So recalcula do
        zero se nao vier nada (fallback de seguranca).
    #>
    param($Resultado, $Pacote, $StatusInfo = $null)

    $statusInfo = $StatusInfo
    if (-not $statusInfo) {
        $statusInfo = Get-StatusPacoteNoDestino -Resultado $Resultado -Pacote $Pacote -ArquivosInstSeg (Get-ArquivosInstSeg -Resultado $Resultado)
    }

    $pastaParaAbrir = if ($statusInfo.Existe -and $statusInfo.ArquivoDestino) {
        Split-Path $statusInfo.ArquivoDestino -Parent
    } else {
        $statusInfo.PastaDestinoUnc
    }

    if (-not (Test-Path $pastaParaAbrir)) {
        [System.Windows.Forms.MessageBox]::Show("A pasta ainda nao existe no destino:`r`n$pastaParaAbrir`r`n`r`n(normal se nenhum pacote foi copiado pra la ainda)", "Pasta nao encontrada", "OK", "Warning") | Out-Null
        return
    }
    Start-ProcessoNaoElevado -Caminho $pastaParaAbrir
}

# ============================================================
# LANCAMENTO NAO-ELEVADO DE PROCESSOS EXTERNOS
# ============================================================
function Start-ProcessoNaoElevado {
    <#
        Lanca um processo garantindo que ele NAO herde o contexto elevado (UAC)
        deste script. Processos externos (nao PowerShell) lancados via
        Start-Process a partir de um script auto-elevado herdam a elevacao do
        processo pai, o que pode alterar o comportamento de rede do processo
        filho de forma silenciosa (ja visto com o VNC Viewer: a conexao falhava
        sem erro claro quando lancado assim).

        O ShellExecute via Shell.Application roda atraves do explorer.exe, que
        fica no nivel de integridade normal do usuario mesmo que este script
        esteja elevado - entao o processo filho sobe "nao elevado", com
        comportamento de rede identico ao de um lancamento manual.

        Nota para o toolkit trema-manutencao-tic: usar esta funcao (em vez de
        Start-Process direto) sempre que um script lancar um programa de
        terceiros (visualizadores, utilitarios). O problema costuma passar
        despercebido em teste manual e so aparece quando chamado de dentro do
        launcher elevado.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Caminho,
        [string]$Argumentos = "",
        [string]$PastaTrabalho = ""
    )
    if (-not $PastaTrabalho -and (Test-Path $Caminho -ErrorAction SilentlyContinue)) {
        $PastaTrabalho = Split-Path $Caminho -Parent
    }

    $shellApp = New-Object -ComObject "Shell.Application"
    $shellApp.ShellExecute($Caminho, $Argumentos, $PastaTrabalho, "open", 1)
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shellApp)
}

# ============================================================
# CONSOLE WEB DA IMPRESSORA PANTUM (sem SNMP)
# ============================================================
function Get-InfoImpressoraPantum {
    <#
        Le a pagina "Product Information" do console web embutido da Pantum
        (ex: http://<ip>/index.html) e extrai os campos exibidos nela.
        Nao usa SNMP - so HTTP simples, igual ao navegador faria.
    #>
    param([string]$IP, [int]$TimeoutSec = 5)

    $urls = @("http://$IP/index.html", "http://$IP/")
    $html = $null
    foreach ($url in $urls) {
        try {
            $resp = Invoke-WebRequest -Uri $url -TimeoutSec $TimeoutSec -UseBasicParsing
            $html = $resp.Content
            break
        } catch {}
    }
    if (-not $html) { return $null }

    $texto = $html -replace '(?s)<script.*?</script>', ' '
    $texto = $texto -replace '(?s)<style.*?</style>', ' '
    $texto = $texto -replace '<[^>]+>', "`n"
    $texto = [System.Net.WebUtility]::HtmlDecode($texto)
    $linhas = $texto -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }

    # Os rotulos aparecem sempre nesta ordem na pagina "Product Information".
    # Percorremos sequencialmente: se o token logo apos o rotulo for outro
    # rotulo conhecido, o valor esta vazio (campo em branco, ex: "Contact").
    $rotulosOrdem = @(
        @{ Chave = "ProductName";     Rotulo = "Product Name" },
        @{ Chave = "SerialNo";        Rotulo = "Serial No." },
        @{ Chave = "Location";        Rotulo = "Location" },
        @{ Chave = "Contact";         Rotulo = "Contact" },
        @{ Chave = "PrinterStatus";   Rotulo = "Printer Status" },
        @{ Chave = "CartridgeStatus"; Rotulo = "Cartridge Status" },
        @{ Chave = "DrumStatus";      Rotulo = "Drum unit status" }
    )
    $todosRotulos = $rotulosOrdem | ForEach-Object { $_.Rotulo }

    $resultado = [ordered]@{}
    $idx = 0
    foreach ($r in $rotulosOrdem) {
        while ($idx -lt $linhas.Count -and $linhas[$idx] -ne $r.Rotulo) { $idx++ }
        if ($idx -ge $linhas.Count) { $resultado[$r.Chave] = ""; continue }
        $idx++  # consome o proprio rotulo
        if ($idx -lt $linhas.Count -and ($todosRotulos -notcontains $linhas[$idx])) {
            $resultado[$r.Chave] = $linhas[$idx]
            $idx++
        } else {
            $resultado[$r.Chave] = ""
        }
    }

    # Pagina nao reconhecida (ex: firmware diferente, pediu login) - nenhum
    # campo essencial foi encontrado
    if (-not $resultado.ProductName -and -not $resultado.SerialNo -and -not $resultado.PrinterStatus) {
        return $null
    }

    return [PSCustomObject]$resultado
}

function Get-PreferenciasImpressaoPantum {
    <#
        Busca a tela "Definicoes > Preferencias de Impressao" (Tamanho/Tipo/
        Origem de papel etc.) direto do endpoint AJAX que a propria pagina usa
        internamente (descoberto via DevTools > Network: omDB.shtml?PRINT).

        FORMATO REAL DA RESPOSTA (confirmado via captura real):
            SN.DATA.omUserpapersize = new OM('MQ==', 'omUserpapersize', SN.TYPE.Selection, MODULE_PRINT, 0);
        Ou seja: um bloco JS com varias chamadas "new OM(valorBase64, nomeCampo, ...)".
        O valor vem em Base64 (decodifica para um INDICE de selecao do
        dropdown, ex: "1", nao o texto "A4" - o texto amigavel so existe no
        HTML/JS da propria pagina, que a gente nao tem visibilidade completa).

        Tentativas anteriores (sem sessao/cookie, sem headers de XHR) nao
        retornaram dados. Aqui: (1) carrega index.html primeiro para
        estabelecer sessao/cookie, igual o navegador faz antes do XHR real;
        (2) reaproveita essa sessao na chamada ao omDB.shtml; (3) manda os
        headers que o jQuery normalmente envia em requisicoes AJAX
        (X-Requested-With, Referer). Loga detalhes (status HTTP, mensagem de
        erro, inicio da resposta) para diagnostico caso ainda falhe.
    #>
    param([string]$IP, [int]$TimeoutSec = 5)

    $urlIndex = "http://$IP/index.html"
    $urlPrefs = "http://$IP/omDB.shtml?PRINT"

    try {
        Invoke-WebRequest -Uri $urlIndex -TimeoutSec $TimeoutSec -UseBasicParsing -SessionVariable sessaoWeb | Out-Null
    } catch {
        Add-Log "[DEBUG] Falha ao carregar $urlIndex (para estabelecer sessao): $($_.Exception.Message)" "Yellow"
        $sessaoWeb = $null
    }

    $headers = @{
        "X-Requested-With" = "XMLHttpRequest"
        "Referer"          = "http://$IP/print.html"
    }

    try {
        if ($sessaoWeb) {
            $resp = Invoke-WebRequest -Uri $urlPrefs -TimeoutSec $TimeoutSec -UseBasicParsing -WebSession $sessaoWeb -Headers $headers
        } else {
            $resp = Invoke-WebRequest -Uri $urlPrefs -TimeoutSec $TimeoutSec -UseBasicParsing -Headers $headers
        }
    } catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch {}
        }
        Add-Log "[DEBUG] Falha ao buscar ${urlPrefs}: $($_.Exception.Message) (HTTP status: $statusCode)" "OrangeRed"
        return $null
    }

    if (-not $resp.Content -or -not $resp.Content.Trim()) {
        Add-Log "[DEBUG] $urlPrefs respondeu vazio (StatusCode: $($resp.StatusCode))." "OrangeRed"
        return $null
    }

    Add-Log "[DEBUG] $urlPrefs respondeu StatusCode $($resp.StatusCode), $($resp.Content.Length) caractere(s)." "Gray"

    $campos = [ordered]@{}
    $regexOM = [regex]::Matches($resp.Content, "new OM\('([^']*)',\s*'([^']+)'")
    foreach ($m in $regexOM) {
        $valorB64 = $m.Groups[1].Value
        $nomeCampo = $m.Groups[2].Value
        $valorTexto = ""
        if ($valorB64) {
            try {
                $valorTexto = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($valorB64))
            } catch {
                $valorTexto = $valorB64
            }
        }
        $campos[$nomeCampo] = $valorTexto
    }

    if ($campos.Count -eq 0) {
        $trecho = $resp.Content.Substring(0, [Math]::Min(300, $resp.Content.Length))
        Add-Log "[DEBUG] Resposta sem padrao 'new OM(...)' reconhecido. Inicio da resposta: $trecho" "Yellow"
        return $null
    }

    return [PSCustomObject]@{ Url = $urlPrefs; Campos = $campos; Bruto = $resp.Content }
}

# ============================================================
# CLIENTE SNMP MINIMO (GET/GETNEXT via UDP, ASN.1 BER manual)
# ============================================================
# Nao ha cmdlet SNMP nativo no PowerShell/.NET, e para manter a ferramenta
# autocontida (sem depender de modulo externo instalado via internet) este
# bloco implementa o suficiente do protocolo SNMPv2c para fazer GET e
# GETNEXT contra OIDs padrao (MIB-2 / Printer-MIB / Host-Resources-MIB).
# Isso e mais robusto que ler o console web, pois as OIDs sao padronizadas
# e nao mudam se o idioma da interface da impressora for alterado.

function ConvertTo-BerLength {
    param([int]$Length)
    if ($Length -lt 128) { return [byte[]]@($Length) }
    $lenBytes = New-Object System.Collections.Generic.List[byte]
    $temp = $Length
    while ($temp -gt 0) {
        $lenBytes.Insert(0, [byte]($temp -band 0xFF))
        $temp = $temp -shr 8
    }
    # IMPORTANTE: "+" entre arrays em PowerShell concatena (achata) corretamente,
    # mas o resultado vira System.Object[] generico, mesmo com os dois lados
    # sendo byte[]. Sem o [byte[]](...) envolvendo a expressao INTEIRA (nao so
    # um dos lados), o retorno nao e um byte[] de verdade e quebra em qualquer
    # chamada .NET estrita (ex: List[byte].AddRange()).
    return [byte[]](@([byte](0x80 -bor $lenBytes.Count)) + $lenBytes.ToArray())
}

function New-BerTLV {
    param([byte]$Tag, [byte[]]$Value)
    if (-not $Value) { $Value = [byte[]]@() }
    $lenBytes = ConvertTo-BerLength -Length $Value.Length
    return [byte[]](@($Tag) + $lenBytes + $Value)
}

function ConvertTo-BerInteger {
    param([int64]$Value)
    if ($Value -eq 0) { return [byte[]]@(0x00) }
    $bytes = New-Object System.Collections.Generic.List[byte]
    $v = $Value
    $ultimo = if ($v -lt 0) { -1 } else { 0 }
    while ($v -ne $ultimo -or ($bytes.Count -eq 0)) {
        $bytes.Insert(0, [byte]($v -band 0xFF))
        $v = $v -shr 8
        if ($bytes.Count -gt 8) { break }
    }
    if ($Value -gt 0 -and ($bytes[0] -band 0x80)) { $bytes.Insert(0, 0x00) }
    return $bytes.ToArray()
}

function ConvertTo-BerOid {
    param([string]$Oid)
    $partes = $Oid.TrimStart('.').Split('.') | ForEach-Object { [int]$_ }
    $bytes = New-Object System.Collections.Generic.List[byte]
    $bytes.Add([byte](40 * $partes[0] + $partes[1]))
    for ($i = 2; $i -lt $partes.Count; $i++) {
        $val = $partes[$i]
        if ($val -eq 0) { $bytes.Add(0x00); continue }
        $grupo = New-Object System.Collections.Generic.List[byte]
        while ($val -gt 0) {
            $grupo.Insert(0, [byte]($val -band 0x7F))
            $val = $val -shr 7
        }
        for ($j = 0; $j -lt $grupo.Count - 1; $j++) { $grupo[$j] = [byte]($grupo[$j] -bor 0x80) }
        $bytes.AddRange($grupo)
    }
    return $bytes.ToArray()
}

function Read-BerTLV {
    param([byte[]]$Bytes, [int]$Offset)
    $tag = $Bytes[$Offset]
    $lenByte = $Bytes[$Offset + 1]
    $headerLen = 2
    $length = 0
    if ($lenByte -band 0x80) {
        $numLenBytes = $lenByte -band 0x7F
        for ($i = 0; $i -lt $numLenBytes; $i++) { $length = ($length -shl 8) -bor $Bytes[$Offset + 2 + $i] }
        $headerLen = 2 + $numLenBytes
    } else {
        $length = $lenByte
    }
    $valueStart = $Offset + $headerLen
    $valueBytes = if ($length -gt 0) { $Bytes[$valueStart..($valueStart + $length - 1)] } else { [byte[]]@() }
    return [PSCustomObject]@{ Tag = $tag; Length = $length; Value = $valueBytes; NextOffset = $valueStart + $length }
}

function ConvertFrom-BerInteger {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Count -eq 0) { return 0 }
    $val = [int64]0
    foreach ($b in $Bytes) { $val = ($val -shl 8) -bor $b }
    if ($Bytes[0] -band 0x80) { $val = $val - [Math]::Pow(256, $Bytes.Count) }
    return $val
}

function ConvertFrom-BerOid {
    param([byte[]]$Bytes)
    if (-not $Bytes -or $Bytes.Count -eq 0) { return "" }
    $primeiro = [int]$Bytes[0]
    $partes = New-Object System.Collections.Generic.List[int]
    $partes.Add([int][Math]::Floor($primeiro / 40))
    $partes.Add($primeiro % 40)
    $val = 0
    for ($i = 1; $i -lt $Bytes.Count; $i++) {
        $b = $Bytes[$i]
        $val = ($val -shl 7) -bor ($b -band 0x7F)
        if (-not ($b -band 0x80)) { $partes.Add($val); $val = 0 }
    }
    return ($partes -join ".")
}

function New-SnmpRequestPacket {
    param([string[]]$Oids, [string]$Community, [int]$RequestId, [byte]$PduType)

    $varBinds = New-Object System.Collections.Generic.List[byte]
    foreach ($oid in $Oids) {
        $oidTlv = New-BerTLV -Tag 0x06 -Value (ConvertTo-BerOid -Oid $oid)
        $nullTlv = New-BerTLV -Tag 0x05 -Value @()
        $varBindTlv = New-BerTLV -Tag 0x30 -Value ([byte[]]($oidTlv + $nullTlv))
        $varBinds.AddRange([byte[]]$varBindTlv)
    }
    $varBindList = New-BerTLV -Tag 0x30 -Value $varBinds.ToArray()

    $pduValue = [byte[]](
        (New-BerTLV -Tag 0x02 -Value (ConvertTo-BerInteger -Value $RequestId)) +
        (New-BerTLV -Tag 0x02 -Value (ConvertTo-BerInteger -Value 0)) +
        (New-BerTLV -Tag 0x02 -Value (ConvertTo-BerInteger -Value 0)) +
        $varBindList
    )
    $pdu = New-BerTLV -Tag $PduType -Value $pduValue

    $versionTlv = New-BerTLV -Tag 0x02 -Value (ConvertTo-BerInteger -Value 1)  # 1 = SNMPv2c
    $communityTlv = New-BerTLV -Tag 0x04 -Value ([System.Text.Encoding]::ASCII.GetBytes($Community))

    return New-BerTLV -Tag 0x30 -Value ([byte[]]($versionTlv + $communityTlv + $pdu))
}

function Send-SnmpRequest {
    <#
        Envia um GetRequest (PduType 0xA0) ou GetNextRequest (0xA1) via UDP/161
        e retorna um hashtable OID -> objeto {Tag, Valor}. $null se nao houve
        resposta dentro do timeout (SNMP desabilitado, comunidade errada, ou
        UDP 161 bloqueado no caminho).
    #>
    param(
        [string]$IP,
        [string[]]$Oids,
        [string]$Community = "public",
        [int]$TimeoutMs = 1200,
        [byte]$PduType = 0xA0
    )

    $reqId = Get-Random -Minimum 1 -Maximum 65000
    $pacote = New-SnmpRequestPacket -Oids $Oids -Community $Community -RequestId $reqId -PduType $PduType

    $udp = New-Object System.Net.Sockets.UdpClient
    $resposta = $null
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $endpoint = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Parse($IP), 161)
        [void]$udp.Send($pacote, $pacote.Length, $endpoint)
        $remoteEP = New-Object System.Net.IPEndPoint([System.Net.IPAddress]::Any, 0)
        $resposta = $udp.Receive([ref]$remoteEP)
    } catch {
        return $null
    } finally {
        $udp.Close()
    }
    if (-not $resposta) { return $null }

    try {
        $envelope = Read-BerTLV -Bytes $resposta -Offset 0
        $inner = $envelope.Value

        $pVersion = Read-BerTLV -Bytes $inner -Offset 0
        $pCommunity = Read-BerTLV -Bytes $inner -Offset $pVersion.NextOffset
        $pPdu = Read-BerTLV -Bytes $inner -Offset $pCommunity.NextOffset

        $pduInner = $pPdu.Value
        $pReqId = Read-BerTLV -Bytes $pduInner -Offset 0
        $pErrStatus = Read-BerTLV -Bytes $pduInner -Offset $pReqId.NextOffset
        $pErrIndex = Read-BerTLV -Bytes $pduInner -Offset $pErrStatus.NextOffset
        $pVarBindList = Read-BerTLV -Bytes $pduInner -Offset $pErrIndex.NextOffset

        $resultados = [ordered]@{}
        $vbBytes = $pVarBindList.Value
        $vbOffset = 0
        while ($vbOffset -lt $vbBytes.Count) {
            $vb = Read-BerTLV -Bytes $vbBytes -Offset $vbOffset
            $vbInner = $vb.Value
            $oidTlv = Read-BerTLV -Bytes $vbInner -Offset 0
            $valTlv = Read-BerTLV -Bytes $vbInner -Offset $oidTlv.NextOffset

            $oidStr = ConvertFrom-BerOid -Bytes $oidTlv.Value
            $valor = switch ($valTlv.Tag) {
                0x04 { [System.Text.Encoding]::UTF8.GetString($valTlv.Value) }   # OctetString
                0x02 { ConvertFrom-BerInteger -Bytes $valTlv.Value }             # Integer
                0x06 { ConvertFrom-BerOid -Bytes $valTlv.Value }                 # Oid (fim de tabela no GETNEXT)
                0x43 { ConvertFrom-BerInteger -Bytes $valTlv.Value }             # TimeTicks
                default { $null }
            }
            $resultados[$oidStr] = [PSCustomObject]@{ Tag = $valTlv.Tag; Valor = $valor }
            $vbOffset = $vb.NextOffset
        }
        return $resultados
    } catch {
        return $null
    }
}

function Get-SnmpWalk {
    <#
        Percorre uma subarvore via GETNEXT sucessivos, ate sair do prefixo
        $OidRaiz ou atingir $MaxIteracoes. Usado para tabelas de tamanho
        variavel (ex: prtMarkerSuppliesTable, que lista toner/cilindro).
    #>
    param([string]$IP, [string]$Community, [string]$OidRaiz, [int]$TimeoutMs = 1200, [int]$MaxIteracoes = 20)

    $resultado = New-Object System.Collections.Generic.List[object]
    $oidAtual = $OidRaiz
    for ($i = 0; $i -lt $MaxIteracoes; $i++) {
        $r = Send-SnmpRequest -IP $IP -Oids @($oidAtual) -Community $Community -TimeoutMs $TimeoutMs -PduType 0xA1
        if (-not $r -or $r.Count -eq 0) { break }

        $chave = @($r.Keys)[0]
        if ($chave -ne $OidRaiz -and -not $chave.StartsWith("$OidRaiz.")) { break }

        $resultado.Add([PSCustomObject]@{ Oid = $chave; Valor = $r[$chave].Valor })
        $oidAtual = $chave
    }
    return $resultado
}

function Get-InfoImpressoraSNMP {
    <#
        Consulta OIDs padrao MIB-2 / Printer-MIB / Host-Resources-MIB.
        Nao depende do idioma configurado na interface web da impressora.
    #>
    param([string]$IP, [string]$Community = "public", [int]$TimeoutMs = 1200)

    $oidSysDescr    = "1.3.6.1.2.1.1.1.0"
    $oidSysContact  = "1.3.6.1.2.1.1.4.0"
    $oidSysName     = "1.3.6.1.2.1.1.5.0"
    $oidSysLocation = "1.3.6.1.2.1.1.6.0"
    $oidPrinterName = "1.3.6.1.2.1.43.5.1.1.16.1"
    $oidSerialNo    = "1.3.6.1.2.1.43.5.1.1.17.1"
    $oidHrPrnStatus = "1.3.6.1.2.1.25.3.5.1.1.1"

    $r = Send-SnmpRequest -IP $IP -Community $Community -TimeoutMs $TimeoutMs -Oids @(
        $oidSysDescr, $oidSysContact, $oidSysName, $oidSysLocation, $oidPrinterName, $oidSerialNo, $oidHrPrnStatus
    )
    if (-not $r) { return $null }

    $mapaStatus = @{ 1 = "Outro"; 2 = "Desconhecido"; 3 = "Pronta"; 4 = "Imprimindo"; 5 = "Aquecendo" }
    $statusVal = $r[$oidHrPrnStatus].Valor
    $statusTexto = if ($null -ne $statusVal -and $mapaStatus.ContainsKey([int]$statusVal)) { $mapaStatus[[int]$statusVal] } else { "-" }

    $nomeProduto = $r[$oidPrinterName].Valor
    if (-not $nomeProduto) { $nomeProduto = $r[$oidSysDescr].Valor }

    $info = [PSCustomObject]@{
        Fonte           = "SNMP"
        ProductName     = $nomeProduto
        SerialNo        = $r[$oidSerialNo].Valor
        Location        = $r[$oidSysLocation].Valor
        Contact         = $r[$oidSysContact].Valor
        PrinterStatus   = $statusTexto
        Suprimentos     = New-Object System.Collections.Generic.List[object]
    }

    # Consumiveis (toner/cilindro) - tabela prtMarkerSuppliesTable
    $oidDesc  = "1.3.6.1.2.1.43.11.1.1.6"
    $oidLevel = "1.3.6.1.2.1.43.11.1.1.9"
    $oidMax   = "1.3.6.1.2.1.43.11.1.1.8"

    $descs  = Get-SnmpWalk -IP $IP -Community $Community -OidRaiz $oidDesc -TimeoutMs $TimeoutMs
    $levels = Get-SnmpWalk -IP $IP -Community $Community -OidRaiz $oidLevel -TimeoutMs $TimeoutMs
    $maxs   = Get-SnmpWalk -IP $IP -Community $Community -OidRaiz $oidMax -TimeoutMs $TimeoutMs

    foreach ($d in $descs) {
        $indice = $d.Oid.Substring($oidDesc.Length + 1)
        $lvl = $levels | Where-Object { $_.Oid -eq "$oidLevel.$indice" } | Select-Object -First 1
        $mx  = $maxs   | Where-Object { $_.Oid -eq "$oidMax.$indice" }   | Select-Object -First 1

        $percentual = $null
        if ($lvl -and $mx -and [int]$mx.Valor -gt 0 -and [int]$lvl.Valor -ge 0) {
            $percentual = [Math]::Round(([int]$lvl.Valor / [int]$mx.Valor) * 100)
        }
        $info.Suprimentos.Add([PSCustomObject]@{ Descricao = $d.Valor; Percentual = $percentual })
    }

    # Papel nas bandejas (tamanho/tipo) - tabela prtInputTable (Printer-MIB,
    # RFC 1759/3805). ATENCAO: isto reflete o papel FISICAMENTE carregado em
    # cada bandeja, e nao necessariamente a "preferencia padrao" mostrada na
    # tela Definicoes > Preferencias de Impressao do console web (essa parece
    # ser configuracao especifica do fabricante, sem OID padrao conhecido -
    # em especial "Origem de papel" / bandeja default nao tem equivalente
    # padronizado que eu tenha conseguido confirmar). Os nomes de midia podem
    # vir em formato tecnico (ex: nomes PWG), diferente do texto amigavel que
    # aparece no navegador.
    $oidInputMediaName = "1.3.6.1.2.1.43.8.2.1.12"
    $oidInputMediaType = "1.3.6.1.2.1.43.8.2.1.21"
    $oidInputName      = "1.3.6.1.2.1.43.8.2.1.13"

    $mediaNames = Get-SnmpWalk -IP $IP -Community $Community -OidRaiz $oidInputMediaName -TimeoutMs $TimeoutMs
    $mediaTypes = Get-SnmpWalk -IP $IP -Community $Community -OidRaiz $oidInputMediaType -TimeoutMs $TimeoutMs
    $inputNames = Get-SnmpWalk -IP $IP -Community $Community -OidRaiz $oidInputName -TimeoutMs $TimeoutMs

    $info | Add-Member -NotePropertyName Bandejas -NotePropertyValue (New-Object System.Collections.Generic.List[object])

    foreach ($m in $mediaNames) {
        $sufixo = $m.Oid.Substring($oidInputMediaName.Length + 1)
        $tipo = $mediaTypes | Where-Object { $_.Oid -eq "$oidInputMediaType.$sufixo" } | Select-Object -First 1
        $nome = $inputNames | Where-Object { $_.Oid -eq "$oidInputName.$sufixo" } | Select-Object -First 1

        # Muitos firmwares implementam o indice da bandeja mas nao preenchem
        # o nome real da midia, devolvendo literalmente "Unknown" ou vazio.
        # Isso nao e informacao util - melhor nao mostrar do que mostrar
        # "Tray 1: Unknown ()".
        if (-not $m.Valor -or $m.Valor -match '(?i)^unknown$') { continue }

        $nomeBandeja = if ($nome -and $nome.Valor) { $nome.Valor } else { "Bandeja $sufixo" }
        $tamanho = $m.Valor
        $tipoTxt = if ($tipo -and $tipo.Valor -and $tipo.Valor -notmatch '(?i)^unknown$') { $tipo.Valor } else { "" }

        $info.Bandejas.Add([PSCustomObject]@{ Bandeja = $nomeBandeja; Tamanho = $tamanho; Tipo = $tipoTxt })
    }

    if (-not $info.ProductName -and -not $info.SerialNo -and $info.PrinterStatus -eq "-") {
        return $null
    }
    return $info
}

function Show-InfoImpressora {
    param([string]$IP, [PSCustomObject]$Info)

    # Campos fixos (existem nos dois formatos: SNMP e console web)
    $campos = @(
        @{ Rotulo = "Produto:";           Valor = $Info.ProductName },
        @{ Rotulo = "Numero de Serie:";   Valor = $Info.SerialNo },
        @{ Rotulo = "Localizacao:";       Valor = $Info.Location },
        @{ Rotulo = "Contato:";           Valor = $Info.Contact },
        @{ Rotulo = "Status Impressora:"; Valor = $Info.PrinterStatus }
    )

    # SNMP traz uma lista de suprimentos (toner, cilindro, etc. - varia por
    # modelo); o console web (fallback) traz so Cartucho/Cilindro fixos.
    if ($Info.PSObject.Properties.Name -contains "Suprimentos" -and $Info.Suprimentos.Count -gt 0) {
        foreach ($sup in $Info.Suprimentos) {
            $valorSup = if ($null -ne $sup.Percentual) { "$($sup.Percentual)%" } else { "-" }
            $campos += @{ Rotulo = "$($sup.Descricao):"; Valor = $valorSup }
        }
    } else {
        if ($Info.PSObject.Properties.Name -contains "CartridgeStatus") {
            $campos += @{ Rotulo = "Status Cartucho:"; Valor = $Info.CartridgeStatus }
        }
        if ($Info.PSObject.Properties.Name -contains "DrumStatus") {
            $campos += @{ Rotulo = "Status Cilindro:"; Valor = $Info.DrumStatus }
        }
    }

    # Papel nas bandejas (tamanho/tipo), quando o SNMP conseguiu ler a
    # prtInputTable. Reflete o que esta fisicamente carregado, nao
    # necessariamente a preferencia padrao configurada no console web.
    if ($Info.PSObject.Properties.Name -contains "Bandejas" -and $Info.Bandejas.Count -gt 0) {
        foreach ($bandeja in $Info.Bandejas) {
            $descPapel = if ($bandeja.Tipo) { "$($bandeja.Tamanho) ($($bandeja.Tipo))" } else { "$($bandeja.Tamanho)" }
            $campos += @{ Rotulo = "$($bandeja.Bandeja):"; Valor = $descPapel }
        }
    }

    # Preferencias de impressao (Tamanho/Tipo/Origem de papel), lidas direto
    # do endpoint AJAX da propria pagina (omDB.shtml?PRINT). Os valores vem
    # como INDICE de selecao do dropdown (nao o texto), entao traduzimos so
    # os codigos ja confirmados visualmente contra o console web da Pantum
    # BM5100FDW. Codigo diferente do mapeado aparece cru, com aviso, em vez
    # de eu chutar um texto errado.
    if ($Info.PSObject.Properties.Name -contains "Preferencias" -and $Info.Preferencias -and $Info.Preferencias.Campos.Count -gt 0) {
        $cb = $Info.Preferencias.Campos

        # NOTA sobre confiabilidade destes mapas: o valor SNMP/omDB e um
        # indice numerico (codigo interno da Pantum), nao o texto.
        # - Tamanho de Papel: mapa CONFIRMADO via HTML real (value="N" de
        #   cada <option>, obtido via DevTools). Nao e sequencial (tem
        #   "furos" nos numeros) porque e uma tabela de codigos propria da
        #   Pantum, nao a posicao no dropdown.
        # - Tipo e Origem de Papel: mapa INFERIDO pela ordem visual dos itens
        #   no dropdown (o unico valor confirmado de cada campo - indice 0 -
        #   bateu com o primeiro item da lista nos dois casos, entao a
        #   inferencia por posicao e razoavel aqui, mas nao 100% garantida
        #   como o Tamanho de Papel).
        $mapaCampos = @(
            @{
                Chave = "omUserpapersize"; Rotulo = "Tamanho de Papel:"
                # Confirmado via HTML real (value="N" de cada <option>), nao
                # inferido por posicao visual - por isso a lista tem "furos"
                # nos numeros (nao e sequencial 0,1,2...): e uma tabela de
                # codigos propria da Pantum, nao a ordem do dropdown.
                Mapa = @{
                    "1"  = "A4 (210 x 297 mm)"
                    "2"  = "Letter (8.5 x 11 inch)"
                    "4"  = "Legal (8.5 x 14 inch)"
                    "5"  = "JIS B5 (182 x 257 mm)"
                    "6"  = "Monarch Env (3.875 x 7.5 inch)"
                    "7"  = "DL Env (110 x 220 mm)"
                    "8"  = "C5 Env (162 x 229 mm)"
                    "9"  = "NO.10 Env (4.125 x 9.5 inch)"
                    "11" = "A5 (148 x 210 mm)"
                    "12" = "Japanese Postcard (100 x 148 mm)"
                    "14" = "16K (185 x 260 mm)"
                    "15" = "Big 16K (195 x 270 mm)"
                    "16" = "32K (130 x 185 mm)"
                    "17" = "Big 32K (135 x 195 mm)"
                    "18" = "A5L (210 x 148 mm)"
                    "19" = "A6 (105 x 148 mm)"
                    "20" = "ISO B5 (176 x 250 mm)"
                    "21" = "Executive (7.25 x 10.5 inch)"
                    "22" = "Folio (8.5 x 13 inch)"
                    "23" = "Oficio (216.0 x 343.0 mm)"
                    "24" = "Statement (5.5 x 8.5 inch)"
                    "25" = "C6 Env (114 x 162 mm)"
                    "26" = "ZL (120 x 230 mm)"
                    "28" = "B6 (125 x 176 mm)"
                    "29" = "Postcard (148 x 200 mm)"
                    "30" = "Yougata2 (114 x 162 mm)"
                    "31" = "Nagagata3 (120 x 235 mm)"
                    "32" = "Younaga3 (120 x 235 mm)"
                    "33" = "Yougata4 (105 x 235 mm)"
                }
            },
            @{
                Chave = "omUserpapertype"; Rotulo = "Tipo de Papel:"
                Mapa = @{
                    "0" = "Papel comum"
                    "1" = "Papel grosso"
                    "2" = "Envelope"
                    "3" = "Filme transparente"
                    "4" = "Cartolina"
                    "5" = "Lenco de papel"
                    "6" = "Papel de etiqueta"
                    "7" = "Mais Grosso"
                    "8" = "Papel Recicl."
                }
            },
            @{
                Chave = "omUserinputtray"; Rotulo = "Origem de Papel:"
                Mapa = @{
                    "0" = "Selecao automatica"
                    "1" = "Bandeja Multifuncional"
                    "2" = "Bandeja alimentadora automatica"
                    "3" = "Bandeja Opcional 1"
                    "4" = "Bandeja Opcional 2"
                }
            }
        )

        foreach ($item in $mapaCampos) {
            if ($cb.Contains($item.Chave)) {
                $codigo = $cb[$item.Chave]
                $texto = if ($item.Mapa.ContainsKey($codigo)) { $item.Mapa[$codigo] } else { "codigo $codigo (nao mapeado ainda)" }
                $campos += @{ Rotulo = $item.Rotulo; Valor = $texto }
            }
        }
    }

    $fonte = if ($Info.PSObject.Properties.Name -contains "Fonte") { $Info.Fonte } else { "Console Web" }

    $altura = 90 + ($campos.Count * 26) + 70
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Informacoes da Impressora - $IP  (via $fonte)"
    $dlg.Size = New-Object System.Drawing.Size(430, $altura)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $lblFonte = New-Object System.Windows.Forms.Label
    $lblFonte.Text = "Fonte: $fonte"
    $lblFonte.Location = New-Object System.Drawing.Point(20, 12)
    $lblFonte.AutoSize = $true
    $lblFonte.ForeColor = [System.Drawing.Color]::Gray
    $dlg.Controls.Add($lblFonte)

    $y = 38
    foreach ($campo in $campos) {
        $lbl1 = New-Object System.Windows.Forms.Label
        $lbl1.Text = $campo.Rotulo
        $lbl1.Location = New-Object System.Drawing.Point(20, $y)
        $lbl1.AutoSize = $true
        $lbl1.Font = New-Object System.Drawing.Font($dlg.Font, [System.Drawing.FontStyle]::Bold)
        $dlg.Controls.Add($lbl1)

        $valorTxt = if ($campo.Valor) { $campo.Valor } else { "-" }
        $lbl2 = New-Object System.Windows.Forms.Label
        $lbl2.Text = $valorTxt
        $lbl2.Location = New-Object System.Drawing.Point(175, $y)
        $lbl2.AutoSize = $true
        $lbl2.MaximumSize = New-Object System.Drawing.Size(220, 0)

        $ehStatus = $campo.Rotulo -match "Status|%$"
        if ($ehStatus -and $valorTxt -notmatch '(?i)normal|ready|ok|pronto|^\d{2,3}%$') {
            $lbl2.ForeColor = [System.Drawing.Color]::FromArgb(200, 0, 0)
            $lbl2.Font = New-Object System.Drawing.Font($dlg.Font, [System.Drawing.FontStyle]::Bold)
        }
        $dlg.Controls.Add($lbl2)
        $y += 26
    }

    $yBotoes = $y + 15

    $btnAbrirWeb = New-Object System.Windows.Forms.Button
    $btnAbrirWeb.Text = "Abrir Console Web"
    $btnAbrirWeb.Location = New-Object System.Drawing.Point(20, $yBotoes)
    $btnAbrirWeb.Width = 160
    $btnAbrirWeb.Height = 28
    $btnAbrirWeb.Add_Click({ Start-ProcessoNaoElevado -Caminho "http://$IP/" }.GetNewClosure())
    $dlg.Controls.Add($btnAbrirWeb)

    $btnFecharDlg = New-Object System.Windows.Forms.Button
    $btnFecharDlg.Text = "Fechar"
    $btnFecharDlg.Location = New-Object System.Drawing.Point(290, $yBotoes)
    $btnFecharDlg.Width = 100
    $btnFecharDlg.Height = 28
    $btnFecharDlg.Add_Click({ $dlg.Close() }.GetNewClosure())
    $dlg.Controls.Add($btnFecharDlg)

    [void]$dlg.ShowDialog()
}

# ============================================================
# VNC VIEWER: localizacao/configuracao do executavel
# ============================================================
function Get-CaminhoVncViewer {
    if ($script:VncViewerPath -and (Test-Path $script:VncViewerPath)) {
        return $script:VncViewerPath
    }

    if (Test-Path $script:ArquivoConfigVnc) {
        $salvo = (Get-Content $script:ArquivoConfigVnc -Raw -ErrorAction SilentlyContinue)
        if ($salvo) { $salvo = $salvo.Trim() }
        if ($salvo -and (Test-Path $salvo)) {
            $script:VncViewerPath = $salvo
            return $script:VncViewerPath
        }
    }

    $candidatos = @(
        "$env:ProgramFiles\uvnc bvba\UltraVnc\vncviewer.exe",
        "${env:ProgramFiles(x86)}\uvnc bvba\UltraVnc\vncviewer.exe",
        "$env:ProgramFiles\TightVNC\tvnviewer.exe",
        "${env:ProgramFiles(x86)}\TightVNC\tvnviewer.exe",
        "$env:ProgramFiles\RealVNC\VNC Viewer\vncviewer.exe",
        "${env:ProgramFiles(x86)}\RealVNC\VNC Viewer\vncviewer.exe",
        "$env:ProgramFiles\TigerVNC\vncviewer.exe"
    )
    foreach ($c in $candidatos) {
        if ($c -and (Test-Path $c)) {
            $script:VncViewerPath = $c
            Set-Content -Path $script:ArquivoConfigVnc -Value $c -Encoding UTF8
            Add-Log "VNC Viewer detectado automaticamente: $c" "Cyan"
            return $script:VncViewerPath
        }
    }

    Add-Log "VNC Viewer nao encontrado automaticamente. Localize o executavel..." "Yellow"
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title = "Localizar vncviewer.exe"
    $ofd.Filter = "Executavel (*.exe)|*.exe"
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:VncViewerPath = $ofd.FileName
        Set-Content -Path $script:ArquivoConfigVnc -Value $ofd.FileName -Encoding UTF8
        Add-Log "VNC Viewer configurado: $($ofd.FileName)" "Cyan"
        return $script:VncViewerPath
    }

    return $null
}

function Open-VncViewer {
    param([string]$IP)
    if (-not $IP) { return }
    $caminho = Get-CaminhoVncViewer
    if (-not $caminho) {
        Add-Log "[ERRO] VNC Viewer nao configurado. Operacao cancelada." "OrangeRed"
        return
    }
    try {
        Start-ProcessoNaoElevado -Caminho $caminho -Argumentos $IP
        Add-Log "Abrindo VNC Viewer (nao elevado) para $IP..." "Cyan"
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Falha ao abrir o VNC Viewer para ${IP}:`r`n$_", "Erro", "OK", "Error") | Out-Null
        Add-Log "[ERRO] Falha ao abrir VNC para $IP" "OrangeRed"
    }
}

function Get-CaminhoRcViewer {
    if ($script:RcViewerPath -and (Test-Path $script:RcViewerPath)) {
        return $script:RcViewerPath
    }

    if (Test-Path $script:ArquivoConfigRc) {
        $salvo = (Get-Content $script:ArquivoConfigRc -Raw -ErrorAction SilentlyContinue)
        if ($salvo) { $salvo = $salvo.Trim() }
        if ($salvo -and (Test-Path $salvo)) {
            $script:RcViewerPath = $salvo
            return $script:RcViewerPath
        }
    }

    $candidatos = @(
        "$env:ProgramFiles\LANDesk\ManagementSuite\remotecontrol\RC\RCViewer.exe",
        "$env:ProgramFiles\LANDesk\ManagementSuite\remotecontrol\RCViewer\RCViewer.exe",
        "${env:ProgramFiles(x86)}\LANDesk\ManagementSuite\remotecontrol\RC\RCViewer.exe",
        "${env:ProgramFiles(x86)}\LANDesk\ManagementSuite\remotecontrol\RCViewer\RCViewer.exe",
        "${env:ProgramFiles(x86)}\LANDesk\ServerManager\RCViewer\RCViewer.exe"
    )
    foreach ($c in $candidatos) {
        if ($c -and (Test-Path $c)) {
            $script:RcViewerPath = $c
            Set-Content -Path $script:ArquivoConfigRc -Value $c -Encoding UTF8
            Add-Log "RCViewer (Ivanti) detectado automaticamente: $c" "Cyan"
            return $script:RcViewerPath
        }
    }

    Add-Log "RCViewer nao encontrado automaticamente. Localize o executavel..." "Yellow"
    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title = "Localizar RCViewer.exe"
    $ofd.Filter = "Executavel (*.exe)|*.exe"
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:RcViewerPath = $ofd.FileName
        Set-Content -Path $script:ArquivoConfigRc -Value $ofd.FileName -Encoding UTF8
        Add-Log "RCViewer configurado: $($ofd.FileName)" "Cyan"
        return $script:RcViewerPath
    }

    return $null
}

function Open-RcViewer {
    <#
        O RCViewer.exe moderno da Ivanti exige login interativo no Nucleo
        (nao ha switch de linha de comando confiavel para conectar direto
        num IP, diferente do vncviewer.exe). Por isso: abre o RCViewer e
        copia o IP para a area de transferencia, para colar rapido na busca
        de dispositivo depois de logar.
    #>
    param([string]$IP)
    if (-not $IP) { return }
    $caminho = Get-CaminhoRcViewer
    if (-not $caminho) {
        Add-Log "[ERRO] RCViewer nao configurado. Operacao cancelada." "OrangeRed"
        return
    }
    try {
        Start-ProcessoNaoElevado -Caminho $caminho
        [System.Windows.Forms.Clipboard]::SetText($IP)
        Add-Log "Abrindo RCViewer (nao elevado). IP $IP copiado para a area de transferencia - cole na busca de dispositivo apos logar." "Cyan"
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Falha ao abrir o RCViewer:`r`n$_", "Erro", "OK", "Error") | Out-Null
        Add-Log "[ERRO] Falha ao abrir RCViewer" "OrangeRed"
    }
}

# ============================================================
# OCS INVENTORY: consulta via API REST
# ============================================================
# NOTA: a API REST do OCS Inventory NG so suporta GET - confirmado na
# documentacao oficial (wiki.ocsinventory-ng.org/11.Rest-API), que lista
# POST/DELETE/PUT como "not implemented". Ou seja, nao ha como excluir,
# criar ou alterar registros por essa API - qualquer acao de escrita no
# OCS (excluir maquina, etc.) precisa ser feita pelo console web mesmo.

function Get-OcsComputadoresPorIp {
    <#
        Acha as maquinas do OCS Inventory cadastradas numa rede /24 fazendo
        uma busca EXATA por IP (coluna "IPADDR" da tabela hardware) pra
        cada um dos 254 enderecos, em paralelo - confirmado na pratica que
        /computers/search aceita IPADDR como :searchCriteria (nao esta
        documentado com esse exemplo especifico, mas o teste manual
        devolveu "[{"ID":12940}]" pra um IP conhecido).

        Property: MUITO mais rapido que paginar o inventario inteiro (o
        antigo Get-OcsComputadoresDaZona, que baixava o registro COMPLETO
        de uns 2000+ maquinas cadastradas e filtrava por nome no proprio
        script) - a maioria dos 254 IPs de uma rede nao tem nada
        cadastrado, entao a busca devolve vazio na hora; so quem da match
        (normalmente 20-40 maquinas por zona) precisa de uma 2a chamada
        pra pegar hardware/bios/registry completos via /computer/:id.

        Como a busca e por IP (nao por padrao de nome), dispensa
        Test-HostnamePertenceZona pra decidir se uma maquina "e desta
        zona" - o ULTIMO IP CONHECIDO (hardware.IPADDR) ja fica dentro da
        rede fisica da propria zona/predio, mesmo em rede compartilhada
        entre varias zonas (o problema do filtro por nome era justamente
        esse: em rede compartilhada, o nome nao da pra confiar sozinho).
    #>
    param([string]$PrefixoRede, [int]$TimeoutSec = 8, [int]$Paralelismo = 40)

    $scriptBlockPorIp = {
        param($UrlBase, $Ip, $TimeoutSec)
        try {
            $urlBusca = "$UrlBase/computers/search?start=0&limit=5&IPADDR=$Ip"
            $respBusca = Invoke-RestMethod -Uri $urlBusca -TimeoutSec $TimeoutSec
            $ids = @($respBusca) | Where-Object { $_.ID } | Select-Object -ExpandProperty ID -Unique
            if (@($ids).Count -eq 0) { return [PSCustomObject]@{ Comps = @(); Erro = $null } }

            # /computer/:id SEM secao especifica (documentado como "todos os
            # detalhes") na pratica devolve um objeto VAZIO nesse servidor -
            # confirmado com diagnostico (0 propriedades no objeto extraido),
            # apesar de nao dar erro nenhum. Em vez disso, busca as 3 secoes
            # especificas necessarias (hardware/bios/registry) separadamente -
            # o MESMO formato de chamada (/computer/:id/<secao>) que a
            # varredura principal ja usa com sucesso pra VERSAO_SIS/BitLocker/
            # etc. em toda varredura, entao e um formato comprovado.
            $comps = New-Object System.Collections.Generic.List[object]
            $erroDetalhe = $null
            foreach ($id in $ids) {
                try {
                    $respHw = Invoke-RestMethod -Uri "$UrlBase/computer/$id/hardware" -TimeoutSec $TimeoutSec
                    $hw = $respHw."$id".hardware
                    if (-not $hw -or -not $hw.NAME) { continue }

                    $bios = $null
                    try {
                        $respBios = Invoke-RestMethod -Uri "$UrlBase/computer/$id/bios" -TimeoutSec $TimeoutSec
                        $bios = $respBios."$id".bios
                    } catch {}

                    $registry = $null
                    try {
                        $respReg = Invoke-RestMethod -Uri "$UrlBase/computer/$id/registry" -TimeoutSec $TimeoutSec
                        $registry = $respReg."$id".registry
                    } catch {}

                    $comps.Add([PSCustomObject]@{ hardware = $hw; bios = $bios; registry = $registry })
                } catch {
                    $erroDetalhe = $_.Exception.Message
                }
            }
            return [PSCustomObject]@{ Comps = $comps; Erro = $erroDetalhe }
        } catch {
            return [PSCustomObject]@{ Comps = @(); Erro = $_.Exception.Message }
        }
    }

    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $pool = [runspacefactory]::CreateRunspacePool(1, $Paralelismo, $sessionState, $Host)
    $pool.Open()

    $encontrados = New-Object System.Collections.Generic.List[object]
    $erros = 0
    try {
        $jobs = New-Object System.Collections.Generic.List[object]
        for ($i = 1; $i -le 254; $i++) {
            $ip = "$PrefixoRede$i"
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($scriptBlockPorIp).AddArgument($script:UrlOcsApiBase).AddArgument($ip).AddArgument($TimeoutSec)
            $jobs.Add([PSCustomObject]@{ Pipe = $ps; Handle = $ps.BeginInvoke() })
        }

        # Mesma tecnica de DoEvents em polling ja usada no resto da
        # ferramenta pra nao travar a janela enquanto espera as 254
        # chamadas paralelas terminarem.
        while ($jobs | Where-Object { -not $_.Handle.IsCompleted }) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 30
        }

        foreach ($job in $jobs) {
            $r = $job.Pipe.EndInvoke($job.Handle)
            $job.Pipe.Dispose()
            if ($r.Erro) { $erros++; continue }
            foreach ($comp in $r.Comps) { $encontrados.Add($comp) }
        }
    } finally {
        $pool.Close()
        $pool.Dispose()
    }

    if ($erros -gt 0) {
        Add-Log "[AVISO] $erros IP(s) falharam na busca por IPADDR no OCS Inventory (timeout/erro de rede) - podem ter ficado de fora do resultado." "Yellow"
    }
    return $encontrados
}

function Resolve-ModeloAmigavel {
    param([string]$ModeloOriginal)
    if (-not $ModeloOriginal) { return $null }
    if ($script:MapaModelos.ContainsKey($ModeloOriginal)) { return $script:MapaModelos[$ModeloOriginal] }
    return $ModeloOriginal
}

# ============================================================
# ZONAS ELEITORAIS: UI (label de info + tela de gerenciamento)
# ============================================================
function Update-LabelSedeInfo {
    $zona = [int]$numZona.Value
    $resolucao = Resolve-RedeDaZona -Zona $zona
    $zonaTxt = "{0:D3}" -f $zona
    $sedeTxt = if ($resolucao.Sede) { $resolucao.Sede } else { "(nao encontrada na planilha)" }

    $texto = "ZE $zonaTxt $sedeTxt   Rede a varrer: $($resolucao.Prefixo)0/24"
    if ($resolucao.EhSubstituta) {
        $texto += "   (SUBSTITUTA)"
        if ($resolucao.Observacao) { $texto += " - $($resolucao.Observacao)" }
    }
    $lblSedeInfo.Text = $texto

    if ($resolucao.EhSubstituta) {
        $lblSedeInfo.ForeColor = [System.Drawing.Color]::FromArgb(200, 120, 0)
    } elseif (-not $resolucao.Sede) {
        $lblSedeInfo.ForeColor = [System.Drawing.Color]::Gray
    } else {
        $lblSedeInfo.ForeColor = [System.Drawing.Color]::FromArgb(0, 90, 158)
    }

    $btnUsuariosZona.Text = "Usuarios da ZE $zona"
}

function Atualizar-MaximoZona {
    if ($script:TabelaZonas.Count -gt 0) {
        $maxZona = ($script:TabelaZonas.Keys | Measure-Object -Maximum).Maximum
        $numZona.Maximum = [Math]::Max($maxZona, 253)
    }
}

function Show-GerenciarZonas {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Gerenciar Zonas Eleitorais - Redes e Substitutas (planilha)"
    $dlg.Size = New-Object System.Drawing.Size(780, 620)
    $dlg.MinimumSize = New-Object System.Drawing.Size(650, 400)
    $dlg.StartPosition = "CenterParent"
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $lblFiltro = New-Object System.Windows.Forms.Label
    $lblFiltro.Text = "Filtrar (zona ou sede):"
    $lblFiltro.Location = New-Object System.Drawing.Point(15, 16)
    $lblFiltro.AutoSize = $true
    $dlg.Controls.Add($lblFiltro)

    $txtFiltro = New-Object System.Windows.Forms.TextBox
    $txtFiltro.Location = New-Object System.Drawing.Point(160, 13)
    $txtFiltro.Width = 250
    $dlg.Controls.Add($txtFiltro)

    $btnAtualizarPlanilha = New-Object System.Windows.Forms.Button
    $btnAtualizarPlanilha.Text = "Atualizar da Planilha"
    $btnAtualizarPlanilha.Location = New-Object System.Drawing.Point(430, 11)
    $btnAtualizarPlanilha.Width = 150
    $btnAtualizarPlanilha.Height = 26
    $dlg.Controls.Add($btnAtualizarPlanilha)

    $lblContagem = New-Object System.Windows.Forms.Label
    $lblContagem.Text = ""
    $lblContagem.Location = New-Object System.Drawing.Point(600, 16)
    $lblContagem.AutoSize = $true
    $lblContagem.ForeColor = [System.Drawing.Color]::Gray
    $dlg.Controls.Add($lblContagem)

    $gridZonas = New-Object System.Windows.Forms.DataGridView
    $gridZonas.Location = New-Object System.Drawing.Point(15, 46)
    $gridZonas.Size = New-Object System.Drawing.Size(735, 460)
    $gridZonas.Anchor = "Top,Bottom,Left,Right"
    $gridZonas.AllowUserToAddRows = $false
    $gridZonas.AllowUserToDeleteRows = $false
    $gridZonas.RowHeadersVisible = $false
    $gridZonas.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None

    function Add-ColunaGridZonas {
        param($Nome, $Titulo, $Largura, $SoLeitura)
        $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $c.Name = $Nome; $c.HeaderText = $Titulo; $c.Width = $Largura; $c.ReadOnly = $SoLeitura
        [void]$gridZonas.Columns.Add($c)
    }
    Add-ColunaGridZonas "Zona" "Zona" 55 $true
    Add-ColunaGridZonas "Sede" "Sede" 160 $true
    Add-ColunaGridZonas "RedePadrao" "Rede Padrao" 150 $true
    Add-ColunaGridZonas "Override" "Substituta (ex: 10.50.3.0/24)" 170 $false
    Add-ColunaGridZonas "Observacao" "Observacao" 160 $false

    $dlg.Controls.Add($gridZonas)

    $populaGridZonas = {
        param(
            [System.Windows.Forms.DataGridView]$GridZonas,
            [System.Windows.Forms.Label]$LblContagem,
            [string]$Filtro = ""
        )
        $GridZonas.Rows.Clear()
        $filtroLower = $Filtro.Trim().ToLower()
        foreach ($z in ($script:TabelaZonas.Keys | Sort-Object)) {
            $zonaInfo = $script:TabelaZonas[$z]
            $sede = $zonaInfo.Sede
            if ($filtroLower) {
                $bate = ("$z".Contains($filtroLower)) -or ($sede -and $sede.ToLower().Contains($filtroLower))
                if (-not $bate) { continue }
            }

            $redePadraoTxt = if ($zonaInfo.RedePadrao) {
                $zonaInfo.RedePadrao
            } else {
                $sedeSemAcento = (Remove-Acentos $sede).ToUpper().Trim()
                if ($sedeSemAcento -eq "SAO LUIS") { "10.11.81.0/24 (calculado)" } else { "10.198.$z.0/24 (calculado)" }
            }

            $substitutaAtual = if ($zonaInfo.Substituta) { $zonaInfo.Substituta } else { "" }
            $obsAtual = if ($zonaInfo.Observacao) { $zonaInfo.Observacao } else { "" }

            $rowIndex = $GridZonas.Rows.Add("$z", $sede, $redePadraoTxt, $substitutaAtual, $obsAtual)
            if ($substitutaAtual) {
                $GridZonas.Rows[$rowIndex].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 245, 220)
            }
        }
        $LblContagem.Text = "$($GridZonas.Rows.Count) zona(s)"
    }

    & $populaGridZonas -GridZonas $gridZonas -LblContagem $lblContagem
    $txtFiltro.Add_TextChanged({ & $populaGridZonas -GridZonas $gridZonas -LblContagem $lblContagem -Filtro $txtFiltro.Text }.GetNewClosure())

    $btnAtualizarPlanilha.Add_Click({
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $ok = Import-TabelaZonas
        $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
        if ($ok) {
            & $populaGridZonas -GridZonas $gridZonas -LblContagem $lblContagem -Filtro $txtFiltro.Text
            Atualizar-MaximoZona
            Update-LabelSedeInfo
            [System.Windows.Forms.MessageBox]::Show("Planilha de zonas atualizada: $($script:TabelaZonas.Count) zona(s).", "OK", "OK", "Information") | Out-Null
        } else {
            [System.Windows.Forms.MessageBox]::Show("Nao foi possivel atualizar (ver log da janela principal).", "Aviso", "OK", "Warning") | Out-Null
        }
    }.GetNewClosure())

    $lblAjuda = New-Object System.Windows.Forms.Label
    $lblAjuda.Text = "Preencha 'Substituta' (ex: 10.50.3 ou 10.50.3.0/24) para forcar uma rede diferente da padrao nesta zona (ex: link temporario por queda do link principal). Deixe em branco para usar a rede padrao. Salvar grava direto na planilha do Google - qualquer tecnico com a ferramenta ja ve a mudanca."
    $lblAjuda.Location = New-Object System.Drawing.Point(180, 520)
    $lblAjuda.Size = New-Object System.Drawing.Size(410, 60)
    $lblAjuda.Anchor = "Bottom,Left"
    $lblAjuda.ForeColor = [System.Drawing.Color]::Gray
    $dlg.Controls.Add($lblAjuda)

    $btnSalvar = New-Object System.Windows.Forms.Button
    $btnSalvar.Text = "Salvar na Planilha"
    $btnSalvar.Location = New-Object System.Drawing.Point(15, 520)
    $btnSalvar.Width = 150
    $btnSalvar.Height = 30
    $btnSalvar.Anchor = "Bottom,Left"
    $btnSalvar.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
    $btnSalvar.ForeColor = [System.Drawing.Color]::White
    $dlg.Controls.Add($btnSalvar)

    $btnFecharGz = New-Object System.Windows.Forms.Button
    $btnFecharGz.Text = "Fechar"
    $btnFecharGz.Location = New-Object System.Drawing.Point(650, 520)
    $btnFecharGz.Width = 100
    $btnFecharGz.Height = 30
    $btnFecharGz.Anchor = "Bottom,Right"
    $dlg.Controls.Add($btnFecharGz)

    $btnSalvar.Add_Click({
        $cfgZonas = Get-ConfigZonasWebApp
        if (-not $cfgZonas) { $cfgZonas = Read-ConfigZonasWebAppInterativo }
        if (-not $cfgZonas) { return }

        $alterados = New-Object System.Collections.Generic.List[object]
        foreach ($row in $gridZonas.Rows) {
            $z = [int]$row.Cells["Zona"].Value
            $substitutaGrid = ConvertTo-CidrRede "$($row.Cells["Override"].Value)"
            $obsGrid = "$($row.Cells["Observacao"].Value)".Trim()

            $zonaInfo = $script:TabelaZonas[$z]
            $substitutaAtual = if ($zonaInfo -and $zonaInfo.Substituta) { $zonaInfo.Substituta.Trim() } else { "" }
            $obsAtual = if ($zonaInfo -and $zonaInfo.Observacao) { $zonaInfo.Observacao.Trim() } else { "" }

            if ($substitutaGrid -ne $substitutaAtual -or $obsGrid -ne $obsAtual) {
                $alterados.Add([PSCustomObject]@{ Zona = $z; Substituta = $substitutaGrid; Observacao = $obsGrid })
            }
        }

        if ($alterados.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Nenhuma alteracao para salvar.", "Aviso", "OK", "Information") | Out-Null
            return
        }

        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $sucesso = 0
        $falha = 0
        foreach ($alt in $alterados) {
            $ok = Send-AtualizacaoZonaViaAppsScript -Config $cfgZonas -Zona $alt.Zona -Substituta $alt.Substituta -Observacao $alt.Observacao
            if ($ok) {
                $sucesso++
                if ($script:TabelaZonas.ContainsKey($alt.Zona)) {
                    $script:TabelaZonas[$alt.Zona].Substituta = $alt.Substituta
                    $script:TabelaZonas[$alt.Zona].Observacao = $alt.Observacao
                }
            } else {
                $falha++
            }
        }
        $dlg.Cursor = [System.Windows.Forms.Cursors]::Default

        Add-Log "Planilha de zonas atualizada: $sucesso zona(s) salva(s)$(if ($falha -gt 0) { ", $falha falharam (ver log)" })." "Cyan"
        if ($sucesso -gt 0) {
            # Rebusca a planilha de verdade (mesmo mecanismo do botao
            # "Atualizar da Planilha") em vez de confiar so na atualizacao
            # em memoria - garante que a tela mostra exatamente o que esta
            # gravado, sem depender de nenhum passo intermediario.
            [void](Import-TabelaZonas)
            Atualizar-MaximoZona
        }
        Update-LabelSedeInfo
        & $populaGridZonas -GridZonas $gridZonas -LblContagem $lblContagem -Filtro $txtFiltro.Text

        $msg = "$sucesso zona(s) salva(s) na planilha."
        if ($falha -gt 0) { $msg += "`r`n$falha falharam - ver log da janela principal." }
        [System.Windows.Forms.MessageBox]::Show($msg, "Concluido", "OK", "Information") | Out-Null
    }.GetNewClosure())

    $btnFecharGz.Add_Click({ $dlg.Close() }.GetNewClosure())

    [void]$dlg.ShowDialog()
}

# ============================================================
# ACOES DAS LINHAS DO GRID (compartilhadas entre clique no botao
# e duplo-clique na linha)
# ============================================================
function Invoke-AcaoAbrirVnc {
    param($Resultado)
    if ($Resultado -and $Resultado.VncAtivo -and -not $Resultado.PossivelImpressora) {
        Open-VncViewer -IP $Resultado.IP
    }
}

function Invoke-AcaoAbrirRc {
    param($Resultado)
    if ($Resultado -and $Resultado.RcIvantiAtivo -and -not $Resultado.PossivelImpressora) {
        Open-RcViewer -IP $Resultado.IP
    }
}

function Invoke-AcaoPingContinuo {
    <#
        Abre um "ping -t" continuo pro IP numa janela de cmd separada -
        util pra acompanhar em tempo real quando uma maquina volta a
        responder (ex: religada via Wake-on-LAN, ou apos destravar algum
        problema de rede), sem precisar rodar a varredura da zona inteira
        de novo. Disponivel pra QUALQUER linha, inclusive as
        "Possivelmente Desligado" vindas do OCS.

        O titulo da janela usa so o IP (gerado internamente por este
        script a partir do prefixo da zona - sempre um IPv4 valido), NAO
        o Hostname - que pode vir de DNS reverso/NetBIOS/OCS Inventory,
        fora do nosso controle, e por isso nao deve ser interpolado cru
        numa linha de comando de cmd.exe.
    #>
    param($Resultado)
    if (-not $Resultado -or -not $Resultado.IP) { return }
    $ip = $Resultado.IP
    Start-ProcessoNaoElevado -Caminho "cmd.exe" -Argumentos "/k title Ping continuo - $ip & ping $ip -t"
}

function Invoke-AcaoAtualizarHost {
    <#
        Reconsulta so este 1 IP (mesmo probe da varredura completa -
        ping/porta de fallback, VNC, RC Ivanti, OCS Inventory) e atualiza
        a linha da grade no lugar, sem precisar rodar a varredura da zona
        inteira de novo. Util pra conferir na hora um status que acabou de
        mudar na maquina (ex: usuario habilitou o VNC agora ha pouco).

        So copia pro $Resultado existente as propriedades que o probe
        realmente calcula (Online, Hostname, VncAtivo, RcIvantiAtivo,
        VersaoSis, Modelo, etc.) - propriedades computadas so 1x na
        varredura original (EhGateway, EhNobreakCentral, PertenceZonaAtual
        etc.) ficam intocadas, ja que sao estruturais e nao mudam.

        Roda num unico runspace em segundo plano (sem pool, e so 1 IP),
        com a UI so bombeando DoEvents enquanto espera - mesmo padrao ja
        usado nas outras chamadas de rede desta ferramenta.
    #>
    param($Resultado)
    if (-not $Resultado -or -not $Resultado.IP) { return }

    Add-Log "Atualizando status de '$($Resultado.Hostname)' ($($Resultado.IP))..." "Cyan"
    $grid.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript($scriptBlock).AddArgument($Resultado.IP).AddArgument(400).AddArgument($script:PortasFallback).AddArgument($script:PortasImpressora).AddArgument($script:PortaVnc).AddArgument($script:PortaRcIvanti).AddArgument($script:UrlOcsApiBase).AddArgument($script:ZonaAtual).AddArgument($script:RedeCompartilhada).AddArgument($script:MapaModelos).AddArgument($script:SistemasEleitoraisExtra)
        $handle = $ps.BeginInvoke()
        while (-not $handle.IsCompleted) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 50
        }
        $novoResultado = @($ps.EndInvoke($handle))[0]
    } finally {
        $ps.Dispose()
        $grid.Cursor = [System.Windows.Forms.Cursors]::Default
    }

    if (-not $novoResultado) {
        Add-Log "[ERRO] Falha ao atualizar '$($Resultado.IP)'." "OrangeRed"
        return
    }

    foreach ($prop in $novoResultado.PSObject.Properties) {
        $Resultado.($prop.Name) = $prop.Value
    }
    Reconstruir-Grid
    Add-Log "Status de '$($Resultado.Hostname)' ($($Resultado.IP)) atualizado." "Green"
}

function Test-EhImpressoraPantum {
    <#
        A deteccao usada durante a varredura em massa (porta 9100/515/631
        aberta) e so uma heuristica rapida - nao confirma que o fabricante e
        Pantum de fato, so que "parece uma impressora de rede". Aqui, numa
        consulta individual (ja que o usuario clicou em "Info Impressora"),
        da pra confirmar de verdade: a pagina do console web da Pantum sempre
        traz a marca em texto puro (titulo da pagina, logo, rodape de
        copyright "Zhuhai Pantum Electronics"), entao uma busca simples por
        "pantum" no HTML bruto e um sinal confiavel.
    #>
    param([string]$IP, [int]$TimeoutSec = 3)
    foreach ($url in @("http://$IP/index.html", "http://$IP/")) {
        try {
            $resp = Invoke-WebRequest -Uri $url -TimeoutSec $TimeoutSec -UseBasicParsing
            if ($resp.Content -match '(?i)pantum') { return $true }
        } catch {}
    }
    return $false
}

function Invoke-AcaoInfoImpressora {
    param($Resultado, $Row = $null)
    if (-not $Resultado -or -not $Resultado.PossivelImpressora) { return }

    $grid.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    Add-Log "Consultando impressora $($Resultado.IP) via SNMP..." "Gray"
    $info = Get-InfoImpressoraSNMP -IP $Resultado.IP -Community $script:SnmpCommunity -TimeoutMs 1200

    if (-not $info) {
        Add-Log "SNMP nao respondeu em $($Resultado.IP), tentando console web..." "Gray"
        $info = Get-InfoImpressoraPantum -IP $Resultado.IP
    }

    if ($info) {
        Add-Log "Confirmando fabricante de $($Resultado.IP)..." "Gray"
        $confirmadoPantum = Test-EhImpressoraPantum -IP $Resultado.IP
        if ($confirmadoPantum) {
            if ($Row) { $Row.Cells["Tipo"].Value = "Impressora Pantum" }
            Add-Log "Confirmado: $($Resultado.IP) e uma impressora Pantum." "LightGreen"
        } elseif ($Row) {
            Add-Log "Nao foi possivel confirmar a marca Pantum em $($Resultado.IP) (mantendo rotulo com '?')." "Gray"
        }

        Add-Log "Buscando preferencias de impressao de $($Resultado.IP)..." "Gray"
        $prefs = Get-PreferenciasImpressaoPantum -IP $Resultado.IP
        if ($prefs -and $prefs.Campos.Count -gt 0) {
            $info | Add-Member -NotePropertyName Preferencias -NotePropertyValue $prefs -Force
            Add-Log "Preferencias obtidas de $($prefs.Url): $($prefs.Campos.Count) campo(s)." "Cyan"
        } else {
            Add-Log "Nao foi possivel buscar preferencias de impressao de $($Resultado.IP) (ver detalhes [DEBUG] acima)." "Gray"
        }
    }
    $grid.Cursor = [System.Windows.Forms.Cursors]::Default

    if ($info) {
        $fonte = if ($info.PSObject.Properties.Name -contains "Fonte") { $info.Fonte } else { "Console Web" }
        Add-Log "Info obtida de $($Resultado.IP) via ${fonte}: $($info.ProductName) - Status: $($info.PrinterStatus)" "Cyan"
        Show-InfoImpressora -IP $Resultado.IP -Info $info
    } else {
        Add-Log "[ERRO] Nao foi possivel ler informacoes de $($Resultado.IP) via SNMP nem console web." "OrangeRed"
        $resp = [System.Windows.Forms.MessageBox]::Show("Nao foi possivel ler as informacoes automaticamente (nem SNMP, nem console web).`r`nDeseja abrir o console web no navegador para conferir manualmente?", "Aviso", "YesNo", "Warning")
        if ($resp -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-ProcessoNaoElevado -Caminho "http://$($Resultado.IP)/"
        }
    }
}

# ============================================================
# ENVIO DE CVC (InstSeg) PARA O GOOGLE DRIVE
# ============================================================
# ============================================================
# CONFIGURACAO DO ENVIO AUTOMATICO AO GOOGLE DRIVE (Web App do Apps Script)
# ============================================================
function Get-ConfigEnvioDrive {
    if (-not (Test-Path $script:ArquivoConfigDrive)) { return $null }
    try {
        $cfg = Get-Content -Path $script:ArquivoConfigDrive -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.UrlWebApp -and $cfg.Token) { return $cfg }
    } catch {}
    return $null
}

function Set-ConfigEnvioDrive {
    param([string]$UrlWebApp, [string]$Token)
    [PSCustomObject]@{ UrlWebApp = $UrlWebApp; Token = $Token } |
        ConvertTo-Json | Set-Content -Path $script:ArquivoConfigDrive -Encoding UTF8
}

function Read-ConfigEnvioDriveInterativo {
    <#
        Pede a URL do Web App (Apps Script) e o token combinado, pre-
        preenchendo com o que ja estiver salvo (se houver) para facilitar
        reconfiguracao. Devolve $null se o usuario cancelar.
    #>
    $atual = Get-ConfigEnvioDrive

    $url = [Microsoft.VisualBasic.Interaction]::InputBox(
        "URL do Web App do Google Apps Script (Implantar > Nova implantacao > Aplicativo da web), termina em /exec:`r`n`r`nVer instrucoes em apps_script_receber_cvc.gs.",
        "Configurar Envio ao Google Drive - URL",
        $(if ($atual) { $atual.UrlWebApp } else { "" })
    )
    if (-not $url) { return $null }

    $token = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Token combinado com o script (mesmo valor da constante TOKEN no Apps Script):",
        "Configurar Envio ao Google Drive - Token",
        $(if ($atual) { $atual.Token } else { "" })
    )
    if (-not $token) { return $null }

    Set-ConfigEnvioDrive -UrlWebApp $url.Trim() -Token $token.Trim()
    Add-Log "Configuracao de envio automatico ao Google Drive salva." "Cyan"
    return (Get-ConfigEnvioDrive)
}

# ============================================================
# CONFIGURACAO DE ATUALIZACAO DA PLANILHA DE ZONAS (Web App do Apps Script)
# ============================================================
function Get-ConfigZonasWebApp {
    if (-not (Test-Path $script:ArquivoConfigZonasWebApp)) { return $null }
    try {
        $cfg = Get-Content -Path $script:ArquivoConfigZonasWebApp -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.UrlWebApp -and $cfg.Token) { return $cfg }
    } catch {}
    return $null
}

function Set-ConfigZonasWebApp {
    param([string]$UrlWebApp, [string]$Token)
    [PSCustomObject]@{ UrlWebApp = $UrlWebApp; Token = $Token } |
        ConvertTo-Json | Set-Content -Path $script:ArquivoConfigZonasWebApp -Encoding UTF8
}

function Read-ConfigZonasWebAppInterativo {
    <#
        Pede a URL do Web App (Apps Script) que atualiza a planilha de zonas
        e o token combinado, pre-preenchendo com o que ja estiver salvo (se
        houver). Devolve $null se o usuario cancelar.
    #>
    $atual = Get-ConfigZonasWebApp

    $url = [Microsoft.VisualBasic.Interaction]::InputBox(
        "URL do Web App do Google Apps Script para ATUALIZAR a planilha de zonas (Implantar > Nova implantacao > Aplicativo da web), termina em /exec:`r`n`r`nVer instrucoes em apps_script_atualizar_zonas.gs.",
        "Configurar Atualizacao da Planilha de Zonas - URL",
        $(if ($atual) { $atual.UrlWebApp } else { "" })
    )
    if (-not $url) { return $null }

    $token = [Microsoft.VisualBasic.Interaction]::InputBox(
        "Token combinado com o script (mesmo valor da constante TOKEN no Apps Script):",
        "Configurar Atualizacao da Planilha de Zonas - Token",
        $(if ($atual) { $atual.Token } else { "" })
    )
    if (-not $token) { return $null }

    Set-ConfigZonasWebApp -UrlWebApp $url.Trim() -Token $token.Trim()
    Add-Log "Configuracao de atualizacao da planilha de zonas salva." "Cyan"
    return (Get-ConfigZonasWebApp)
}

function Send-AtualizacaoZonaViaAppsScript {
    <#
        Manda a Substituta/Observacao de uma zona por HTTP POST ao Web App
        do Apps Script, que grava direto nas colunas D/E da linha
        correspondente na planilha "Zonas". Devolve $true/$false - quem
        chama decide o que fazer em caso de falha (a mudanca so fica
        aplicada na planilha se devolver $true).
    #>
    param($Config, [int]$Zona, [string]$Substituta, [string]$Observacao)

    $zonaPad = "{0:D3}" -f $Zona
    try {
        $corpo = @{ token = $Config.Token; zona = $zonaPad; rede = $Substituta; observacao = $Observacao } | ConvertTo-Json -Compress
        $resp = Invoke-RestMethod -Uri $Config.UrlWebApp -Method Post -Body $corpo -ContentType "application/json" -TimeoutSec 20
    } catch {
        # O Web App do Apps Script as vezes devolve erro HTTP (ex: 404) no
        # redirecionamento interno da resposta (script.google.com ->
        # script.googleusercontent.com) MESMO quando o doPost ja gravou
        # certinho - confirmado na pratica (planilha correta, POST reportou
        # erro). Por isso, antes de considerar falha de verdade, confere se
        # o valor foi mesmo gravado buscando a planilha de novo.
        Add-Log "[AVISO] Erro HTTP ao atualizar zona ${zonaPad}: $($_.Exception.Message) - conferindo se a gravacao aconteceu mesmo assim..." "Yellow"
        if (Import-TabelaZonas) {
            $zonaInfo = $script:TabelaZonas[$Zona]
            $substitutaGravada = if ($zonaInfo -and $zonaInfo.Substituta) { $zonaInfo.Substituta.Trim() } else { "" }
            $obsGravada = if ($zonaInfo -and $zonaInfo.Observacao) { $zonaInfo.Observacao.Trim() } else { "" }
            if ($substitutaGravada -eq $Substituta.Trim() -and $obsGravada -eq $Observacao.Trim()) {
                Add-Log "Confirmado: zona $zonaPad foi gravada na planilha apesar do erro HTTP (falso alarme conhecido do Apps Script)." "Cyan"
                return $true
            }
        }
        Add-Log "[ERRO] Falha ao atualizar zona $zonaPad na planilha: $($_.Exception.Message)" "OrangeRed"
        return $false
    }

    if (-not $resp.ok) {
        Add-Log "[ERRO] Planilha recusou atualizar a zona ${zonaPad}: $($resp.erro)" "OrangeRed"
        return $false
    }
    return $true
}

function Send-ArquivoParaGoogleDriveViaAppsScript {
    <#
        Manda o arquivo (nome + conteudo em base64) por HTTP POST ao Web App
        do Apps Script, que grava direto na pasta do Drive. Se ainda nao
        estiver configurado, pede a configuracao na hora (so a primeira
        vez). Devolve $null em qualquer falha (log ja registra o motivo) -
        quem chama decide o que fazer (ex: cair no fallback manual).
    #>
    param([System.IO.FileInfo]$Arquivo, [int]$TimeoutSec = 30)

    $cfg = Get-ConfigEnvioDrive
    if (-not $cfg) { $cfg = Read-ConfigEnvioDriveInterativo }
    if (-not $cfg) { return $null }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($Arquivo.FullName)
        $base64 = [System.Convert]::ToBase64String($bytes)
        $corpo = @{ token = $cfg.Token; nomeArquivo = $Arquivo.Name; conteudoBase64 = $base64 } | ConvertTo-Json -Compress

        $resp = Invoke-RestMethod -Uri $cfg.UrlWebApp -Method Post -Body $corpo -ContentType "application/json" -TimeoutSec $TimeoutSec
    } catch {
        Add-Log "[ERRO] Falha ao enviar '$($Arquivo.Name)' via Apps Script: $($_.Exception.Message)" "OrangeRed"
        return $null
    }

    if (-not $resp.ok) {
        Add-Log "[ERRO] Apps Script recusou o envio de '$($Arquivo.Name)': $($resp.erro)" "OrangeRed"
        return $null
    }
    return $resp
}

function Get-ArquivoCvcMaisRecente {
    <#
        Procura, no compartilhamento \\<IP>\InstSeg\CVC da propria estacao,
        o arquivo .cvc cujo nome (sem extensao) e identico ao nome curto da
        maquina. Se por algum motivo houver mais de um (nao deveria, ja que
        nomes de arquivo sao unicos na pasta), fica com o de data de
        modificacao mais recente.
    #>
    param([string]$IP, [string]$HostnameCurto)

    $pastaCvc = "\\$IP\InstSeg\CVC"
    if (-not (Test-Path $pastaCvc)) { return $null }

    $candidatos = Get-ChildItem -Path $pastaCvc -Filter "*.cvc" -File -ErrorAction SilentlyContinue |
        Where-Object { $_.BaseName -eq $HostnameCurto }
    if (-not $candidatos) { return $null }

    return (@($candidatos) | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
}

function Show-JanelaSistemasEleitorais {
    <#
        Janela "Sistemas Eleitorais" - consolida o que antes eram DUAS
        janelas separadas (Show-JanelaPacotes + a antiga "Verificar
        Sistemas Eleitorais") numa so: pra cada sistema conhecido (SIS +
        $script:SistemasEleitoraisExtra), mostra a versao instalada JA
        LIDA na varredura, a versao "Atual" da planilha, se esta
        atualizado, o status de copia do pacote no InstSeg, E os botoes
        de acao (Baixar e Copiar / Verificar Hash / Abrir Pasta) - tudo
        numa unica grade, em vez do usuario ter que abrir duas janelas
        diferentes pra ver o mesmo conjunto de sistemas.

        Comparacao de versao instalada x atual e uma igualdade de STRING
        direta contra $script:VersaoAtualPorSistema (nao usa
        Resolve-NomeAmigavelVersao pra decidir "desatualizado" porque
        aquela funcao devolve $null se a versao instalada nem estiver
        catalogada na planilha - o que esconderia justamente o caso mais
        claro de desatualizado, uma versao tao antiga que nem consta mais
        la). Resolve-NomeAmigavelVersao/$script:TabelaVersoes ainda sao
        usados, a parte, so pra exibir o nome de praia quando disponivel.
    #>
    param($Resultado)

    # "Versao (Nome Amigavel)" - direto em $script:TabelaVersoes (nao
    # Resolve-NomeAmigavelVersao) porque precisamos do nome amigavel
    # tanto da versao INSTALADA quanto da versao ATUAL.
    function Format-VersaoComNomeAmigavel {
        param($Sistema, $Versao)
        if (-not $Versao -or $Versao -eq "-") { return "-" }
        $chave = "$($Sistema.ToUpper())|$($Versao.Trim())"
        if ($script:TabelaVersoes.ContainsKey($chave) -and $script:TabelaVersoes[$chave].NomeAmigavel) {
            return "$Versao ($($script:TabelaVersoes[$chave].NomeAmigavel))"
        }
        return $Versao
    }

    # Cada item junta os dados de "sistema eleitoral" (versao instalada,
    # versao atual) com o pacote de instalacao correspondente (achado por
    # NomeVersaoAtual, que e o texto exato da coluna "Sistema" da
    # planilha) - se nao houver LinkDrive/PastaDestino configurado pra
    # esse sistema, $Pacote fica $null e as acoes de copia/hash/pasta nao
    # aparecem pra essa linha.
    $itens = New-Object System.Collections.Generic.List[object]
    $itens.Add([PSCustomObject]@{ Titulo = "SIS"; Versao = $Resultado.VersaoSis; NomeVersaoAtual = "SIS" })
    foreach ($sis in $script:SistemasEleitoraisExtra) {
        $itens.Add([PSCustomObject]@{ Titulo = $sis.Titulo; Versao = $Resultado.($sis.Propriedade); NomeVersaoAtual = $sis.NomeVersaoAtual })
    }
    foreach ($item in $itens) {
        $pacote = $script:TabelaPacotes | Where-Object { $_.Sistema -eq $item.NomeVersaoAtual } | Select-Object -First 1
        $item | Add-Member -NotePropertyName Pacote -NotePropertyValue $pacote
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Sistemas Eleitorais - $($Resultado.Hostname) ($($Resultado.IP))"
    $dlg.Size = New-Object System.Drawing.Size(1280, 490)
    $dlg.MinimumSize = New-Object System.Drawing.Size(750, 320)
    $dlg.StartPosition = "CenterParent"

    $painelLegenda = New-Object System.Windows.Forms.FlowLayoutPanel
    $painelLegenda.Dock = [System.Windows.Forms.DockStyle]::Top
    $painelLegenda.Height = 30
    $painelLegenda.Padding = New-Object System.Windows.Forms.Padding(10, 6, 10, 0)
    $dlg.Controls.Add($painelLegenda)
    function Add-ItemLegendaSis {
        param($Painel, $Texto, $Cor)
        $lblItem = New-Object System.Windows.Forms.Label
        $lblItem.Text = "● $Texto"
        $lblItem.ForeColor = $Cor
        $lblItem.AutoSize = $true
        $lblItem.Margin = New-Object System.Windows.Forms.Padding(0, 3, 20, 0)
        [void]$Painel.Controls.Add($lblItem)
    }
    Add-ItemLegendaSis $painelLegenda "Atualizado" ([System.Drawing.Color]::FromArgb(0, 128, 0))
    Add-ItemLegendaSis $painelLegenda "Desatualizado" ([System.Drawing.Color]::FromArgb(200, 100, 0))
    Add-ItemLegendaSis $painelLegenda "Nao instalado" ([System.Drawing.Color]::FromArgb(110, 110, 110))
    Add-ItemLegendaSis $painelLegenda "Pacote copiado" ([System.Drawing.Color]::FromArgb(0, 128, 0))
    Add-ItemLegendaSis $painelLegenda "Pacote fora do padrao" ([System.Drawing.Color]::FromArgb(200, 100, 0))
    Add-ItemLegendaSis $painelLegenda "Tamanho nao confere" ([System.Drawing.Color]::Firebrick)

    $lblCarregandoSis = New-Object System.Windows.Forms.Label
    $lblCarregandoSis.Text = ""
    $lblCarregandoSis.Dock = [System.Windows.Forms.DockStyle]::Top
    $lblCarregandoSis.Height = 22
    $lblCarregandoSis.Padding = New-Object System.Windows.Forms.Padding(12, 0, 12, 0)
    $lblCarregandoSis.ForeColor = [System.Drawing.Color]::Gray
    $lblCarregandoSis.Visible = $false
    $dlg.Controls.Add($lblCarregandoSis)

    # --- Rodape (Dock=Bottom) com barra de progresso + botoes ---
    $painelRodape = New-Object System.Windows.Forms.Panel
    $painelRodape.Dock = [System.Windows.Forms.DockStyle]::Bottom
    $painelRodape.Height = 104
    $dlg.Controls.Add($painelRodape)

    # Escopo $script: de proposito na criacao (ver nota do alias local
    # logo abaixo, antes do click handler) - mesmo padrao ja usado/testado
    # em Show-JanelaPacotes.
    $script:lblProgressoPacoteAtual = New-Object System.Windows.Forms.Label
    $script:lblProgressoPacoteAtual.Text = ""
    $script:lblProgressoPacoteAtual.Location = New-Object System.Drawing.Point(12, 6)
    $script:lblProgressoPacoteAtual.Size = New-Object System.Drawing.Size(400, 18)
    $script:lblProgressoPacoteAtual.Anchor = "Top,Left,Right"
    $script:lblProgressoPacoteAtual.ForeColor = [System.Drawing.Color]::FromArgb(0, 90, 158)
    $painelRodape.Controls.Add($script:lblProgressoPacoteAtual)

    $script:barraProgressoPacoteAtual = New-Object System.Windows.Forms.ProgressBar
    $script:barraProgressoPacoteAtual.Location = New-Object System.Drawing.Point(12, 26)
    $script:barraProgressoPacoteAtual.Size = New-Object System.Drawing.Size(400, 20)
    $script:barraProgressoPacoteAtual.Anchor = "Top,Left,Right"
    $script:barraProgressoPacoteAtual.Minimum = 0
    $script:barraProgressoPacoteAtual.Maximum = 100
    $script:barraProgressoPacoteAtual.Value = 0
    $script:barraProgressoPacoteAtual.Visible = $false
    $painelRodape.Controls.Add($script:barraProgressoPacoteAtual)

    $btnAtualizarSis = New-Object System.Windows.Forms.Button
    $btnAtualizarSis.Text = "Atualizar Status"
    $btnAtualizarSis.Location = New-Object System.Drawing.Point(12, 60)
    $btnAtualizarSis.Width = 140
    $btnAtualizarSis.Height = 28
    $btnAtualizarSis.Anchor = "Top,Left"
    $painelRodape.Controls.Add($btnAtualizarSis)

    $btnFecharSis = New-Object System.Windows.Forms.Button
    $btnFecharSis.Text = "Fechar"
    $btnFecharSis.Location = New-Object System.Drawing.Point(1170, 60)
    $btnFecharSis.Width = 90
    $btnFecharSis.Height = 28
    $btnFecharSis.Anchor = "Top,Right"
    $painelRodape.Controls.Add($btnFecharSis)
    $btnFecharSis.Add_Click({ $dlg.Close() }.GetNewClosure())

    $gridSis = New-Object System.Windows.Forms.DataGridView
    # Location/Size/Anchor (NAO Dock=Fill) de proposito - confirmado na
    # pratica, com varias tentativas (incluindo redimensionar a janela na
    # mao), que o cabecalho de coluna simplesmente NAO renderiza nesta
    # janela com Dock=Fill (linhas de dado aparecem normal, cabecalho
    # fica em branco/achatado, mesmo testando com e sem
    # ColumnHeadersHeightSizeMode/EnableHeadersVisualStyles). A grade
    # principal ($grid, no formulario de fora) usa exatamente esse
    # padrao (Location+Size+Anchor "Top,Bottom,Left,Right") e sempre
    # mostrou cabecalho normal - reaproveitado aqui.
    $gridSis.Location = New-Object System.Drawing.Point(0, 52)
    $gridSis.Size = New-Object System.Drawing.Size(1264, 300)
    $gridSis.Anchor = "Top,Bottom,Left,Right"
    $gridSis.AllowUserToAddRows = $false
    $gridSis.AllowUserToDeleteRows = $false
    $gridSis.RowHeadersVisible = $false
    $gridSis.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $gridSis.MultiSelect = $false
    $gridSis.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None
    $gridSis.RowTemplate.Height = 24
    $dlg.Controls.Add($gridSis)

    function Add-ColunaGridSis {
        param($Nome, $Titulo, $Largura, $SoLeitura = $true)
        $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $c.Name = $Nome; $c.HeaderText = $Titulo; $c.Width = $Largura; $c.ReadOnly = $SoLeitura
        [void]$gridSis.Columns.Add($c)
    }
    Add-ColunaGridSis "Sistema" "Sistema" 170
    Add-ColunaGridSis "VersaoInstalada" "Versão Instalada" 190
    Add-ColunaGridSis "VersaoAtual" "Versão mais atual" 190
    Add-ColunaGridSis "StatusAtualizacao" "Status" 140
    Add-ColunaGridSis "StatusPacote" "Pacote de Instalação" 260

    $colCopiarSis = New-Object System.Windows.Forms.DataGridViewButtonColumn
    $colCopiarSis.Name = "Copiar"; $colCopiarSis.HeaderText = ""; $colCopiarSis.UseColumnTextForButtonValue = $false; $colCopiarSis.Width = 120
    [void]$gridSis.Columns.Add($colCopiarSis)

    $colVerificarSis = New-Object System.Windows.Forms.DataGridViewButtonColumn
    $colVerificarSis.Name = "Verificar"; $colVerificarSis.HeaderText = ""; $colVerificarSis.Text = "Verificar Hash"; $colVerificarSis.UseColumnTextForButtonValue = $true; $colVerificarSis.Width = 110
    [void]$gridSis.Columns.Add($colVerificarSis)

    $colAbrirPastaSis = New-Object System.Windows.Forms.DataGridViewButtonColumn
    $colAbrirPastaSis.Name = "AbrirPasta"; $colAbrirPastaSis.HeaderText = ""; $colAbrirPastaSis.Text = "Abrir Pasta"; $colAbrirPastaSis.UseColumnTextForButtonValue = $true; $colAbrirPastaSis.Width = 100
    [void]$gridSis.Columns.Add($colAbrirPastaSis)

    # NAO mexe em ColumnHeadersHeightSizeMode/ColumnHeadersHeight/
    # EnableHeadersVisualStyles aqui - varias tentativas confirmaram na
    # pratica que essas propriedades fazem o cabecalho inteiro SUMIR
    # nesta janela especifica (so as linhas de dado apareciam, sem texto
    # de coluna nenhum), reordenar/reaplicar no evento Shown tambem nao
    # resolveu. A grade principal ($grid, no formulario de fora) nunca
    # mexeu nessas propriedades e sempre mostrou cabecalho normal -
    # entao aqui deixa tudo no padrao tambem. RowTemplate.Height (acima)
    # ja resolve sozinho o achatamento da 1a linha.

    # Preenche Sistema/Versao Instalada/Versao Atual/Atualizado? NA HORA
    # (nao depende de rede - so dados ja lidos na varredura + a planilha
    # ja carregada em memoria). So a coluna de Pacote e os botoes de acao
    # dependem do InstSeg (rede) - ficam "Verificando..."/desabilitados
    # ate a janela aparecer e o levantamento (evento Shown) terminar,
    # mesmo padrao ja usado em Show-JanelaPacotes.
    $popularLinhaBaseSis = {
        param([System.Windows.Forms.DataGridView]$Grid, [int]$Indice, $Item)
        $row = $Grid.Rows[$Indice]
        $instalado = $Item.Versao -and $Item.Versao -ne "-"
        $versaoAtual = if ($Item.NomeVersaoAtual) { $script:VersaoAtualPorSistema[$Item.NomeVersaoAtual] } else { $null }

        $row.Cells["Sistema"].Value = $Item.Titulo
        $row.Cells["VersaoInstalada"].Value = if ($instalado) { Format-VersaoComNomeAmigavel -Sistema $Item.NomeVersaoAtual -Versao $Item.Versao } else { "-" }
        $row.Cells["VersaoAtual"].Value = if ($versaoAtual) { Format-VersaoComNomeAmigavel -Sistema $Item.NomeVersaoAtual -Versao $versaoAtual } else { "-" }
        $row.Cells["StatusAtualizacao"].Style.Font = $Grid.Font

        if (-not $instalado) {
            $row.Cells["StatusAtualizacao"].Value = "Nao instalado"
            $row.Cells["StatusAtualizacao"].Style.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
        } elseif ($versaoAtual) {
            if ($Item.Versao.Trim() -eq $versaoAtual.Trim()) {
                $row.Cells["StatusAtualizacao"].Value = "Atualizado"
                $row.Cells["StatusAtualizacao"].Style.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
            } else {
                $row.Cells["StatusAtualizacao"].Value = "Desatualizado"
                $row.Cells["StatusAtualizacao"].Style.ForeColor = [System.Drawing.Color]::FromArgb(200, 100, 0)
                $row.Cells["StatusAtualizacao"].Style.Font = New-Object System.Drawing.Font($Grid.Font, [System.Drawing.FontStyle]::Bold)
            }
        } else {
            $row.Cells["StatusAtualizacao"].Value = "Instalado (versao atual desconhecida)"
            $row.Cells["StatusAtualizacao"].Style.ForeColor = $Grid.DefaultCellStyle.ForeColor
        }

        if (-not $Item.Pacote) {
            $row.Cells["StatusPacote"].Value = "-"
            foreach ($nomeColunaBotao in @("Copiar", "Verificar", "AbrirPasta")) {
                $celulaSemBotao = New-Object System.Windows.Forms.DataGridViewTextBoxCell
                $celulaSemBotao.Value = ""
                $row.Cells[$nomeColunaBotao] = $celulaSemBotao
            }
        }
    }

    # Preenche Pacote de Instalacao + botoes de acao - PRECISA do
    # levantamento do InstSeg (rede), por isso roda so depois da janela
    # ja estar visivel (ver Add_Shown mais abaixo) ou apos uma acao de
    # copiar/verificar mudar o status de uma linha especifica.
    $popularLinhaPacoteSis = {
        param([System.Windows.Forms.DataGridView]$Grid, [int]$Indice, $Item, $Resultado, $ArquivosInstSeg = $null)
        $row = $Grid.Rows[$Indice]
        if (-not $Item.Pacote) { return }

        $statusInfo = Get-StatusPacoteNoDestino -Resultado $Resultado -Pacote $Item.Pacote -ArquivosInstSeg $ArquivosInstSeg
        $row.Tag = [PSCustomObject]@{ Pacote = $Item.Pacote; StatusInfo = $statusInfo }
        $row.Cells["StatusPacote"].ToolTipText = ""
        $row.Cells["StatusPacote"].Style.Font = $Grid.Font

        if ($statusInfo.Existe) {
            $raizInstSeg = "\\$($Resultado.IP)\InstSeg\"
            $pastaArquivo = Split-Path $statusInfo.ArquivoDestino -Parent
            $pastaRelativa = if ($pastaArquivo -and $pastaArquivo.ToUpper().StartsWith($raizInstSeg.ToUpper())) { $pastaArquivo.Substring($raizInstSeg.Length) } else { $pastaArquivo }
            $pastaExibida = "\\InstSeg\$pastaRelativa"
            $tamanhoTxt = "$([Math]::Round($statusInfo.Tamanho / 1MB, 1)) MB"
            $dataTxt = $statusInfo.Data.ToString("dd/MM/yy HH:mm")

            if ($statusInfo.ForaDoPadrao) {
                $row.Cells["StatusPacote"].Value = "Copiado Fora do Padrao ($pastaExibida) - $tamanhoTxt - $dataTxt"
                $row.Cells["StatusPacote"].Style.ForeColor = [System.Drawing.Color]::FromArgb(200, 100, 0)
            } else {
                $row.Cells["StatusPacote"].Value = "Copiado ($pastaExibida) - $tamanhoTxt - $dataTxt"
                $row.Cells["StatusPacote"].Style.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
            }
            $row.Cells["StatusPacote"].ToolTipText = $statusInfo.ArquivoDestino
            if ($statusInfo.TamanhoConfere -eq $false) {
                $row.Cells["StatusPacote"].Value = "TAMANHO NAO CONFERE! " + $row.Cells["StatusPacote"].Value
                $row.Cells["StatusPacote"].Style.ForeColor = [System.Drawing.Color]::Firebrick
                $row.Cells["StatusPacote"].Style.Font = New-Object System.Drawing.Font($Grid.Font, [System.Drawing.FontStyle]::Bold)
                $row.Cells["StatusPacote"].ToolTipText = "Tamanho no destino ($($statusInfo.Tamanho) bytes) diferente do oficial da planilha ($($Item.Pacote.TamanhoEsperado) bytes) - copia pode estar corrompida/incompleta. Copie de novo.`r`n$($statusInfo.ArquivoDestino)"
            }
            $row.Cells["Copiar"].Value = "Copiar Novamente"
        } else {
            $tamanhoEsperadoTxt = if ($Item.Pacote.TamanhoEsperado) { " ($([Math]::Round($Item.Pacote.TamanhoEsperado / 1MB, 1)) MB)" } else { "" }
            $row.Cells["StatusPacote"].Value = "Nao copiado ainda$tamanhoEsperadoTxt"
            $row.Cells["StatusPacote"].Style.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
            $row.Cells["Copiar"].Value = "Baixar e Copiar"
        }

        if ($statusInfo.Existe) {
            if ($row.Cells["Verificar"] -isnot [System.Windows.Forms.DataGridViewButtonCell]) {
                $celulaBotao = New-Object System.Windows.Forms.DataGridViewButtonCell
                $celulaBotao.Value = "Verificar Hash"
                $row.Cells["Verificar"] = $celulaBotao
            }
        } else {
            $celulaSemBotao = New-Object System.Windows.Forms.DataGridViewTextBoxCell
            $celulaSemBotao.Value = ""
            $row.Cells["Verificar"] = $celulaSemBotao
        }
    }

    for ($i = 0; $i -lt $itens.Count; $i++) {
        [void]$gridSis.Rows.Add()
        & $popularLinhaBaseSis -Grid $gridSis -Indice $i -Item $itens[$i]
        if ($itens[$i].Pacote) { $gridSis.Rows[$i].Cells["StatusPacote"].Value = "Verificando..." }
    }

    $recarregarPacotesSis = {
        param([System.Windows.Forms.DataGridView]$Grid, $Itens, $Resultado, $LblCarregando)

        foreach ($item2 in $Itens) {
            if ($item2.Pacote) {
                $idxLinha = $Itens.IndexOf($item2)
                $Grid.Rows[$idxLinha].Cells["StatusPacote"].Value = "Verificando..."
                $Grid.Rows[$idxLinha].Cells["StatusPacote"].Style.ForeColor = [System.Drawing.Color]::Gray
            }
        }
        if ($LblCarregando) {
            $LblCarregando.Text = "Verificando pacotes em \\$($Resultado.IP)\InstSeg (pode demorar em links de zona lentos)..."
            $LblCarregando.Visible = $true
        }
        [System.Windows.Forms.Application]::DoEvents()

        $scriptBlockListarInstSeg = {
            param($Ip)
            $raiz = "\\$Ip\InstSeg"
            if (-not (Test-Path $raiz)) { return $null }
            try { return @(Get-ChildItem -Path $raiz -File -Recurse -Depth 6 -ErrorAction SilentlyContinue) } catch { return $null }
        }
        $ps = [powershell]::Create()
        try {
            [void]$ps.AddScript($scriptBlockListarInstSeg).AddArgument($Resultado.IP)
            $handle = $ps.BeginInvoke()
            while (-not $handle.IsCompleted) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 50
            }
            $arquivosInstSeg = $ps.EndInvoke($handle)
        } finally {
            $ps.Dispose()
        }

        if ($LblCarregando) { $LblCarregando.Visible = $false }

        for ($i = 0; $i -lt $Itens.Count; $i++) {
            & $popularLinhaPacoteSis -Grid $Grid -Indice $i -Item $Itens[$i] -Resultado $Resultado -ArquivosInstSeg $arquivosInstSeg
        }
    }

    # So comeca a buscar o InstSeg DEPOIS da janela ja estar visivel -
    # senao a janela nao aparece na tela ate a busca de rede terminar.
    $dlg.Add_Shown({ & $recarregarPacotesSis -Grid $gridSis -Itens $itens -Resultado $Resultado -LblCarregando $lblCarregandoSis }.GetNewClosure())
    $btnAtualizarSis.Add_Click({ & $recarregarPacotesSis -Grid $gridSis -Itens $itens -Resultado $Resultado -LblCarregando $lblCarregandoSis }.GetNewClosure())

    # Aliases LOCAIS (sem prefixo $script:) das variaveis de progresso -
    # necessario porque o handler abaixo usa .GetNewClosure(), e um
    # .GetNewClosure() cria um escopo "$script:" PROPRIO/ISOLADO pro
    # scriptblock resultante, desconectado do $script: real do arquivo
    # (confirmado na pratica em Show-JanelaPacotes). Variaveis locais SEM
    # prefixo de escopo sao capturadas corretamente pelo GetNewClosure.
    $barraProgressoLocal = $script:barraProgressoPacoteAtual
    $lblProgressoLocal = $script:lblProgressoPacoteAtual
    $callbackProgressoLocal = $script:AoAtualizarProgressoPacoteCallback

    $gridSis.Add_CellContentClick({
        param($sender, $e)
        if ($e.RowIndex -lt 0) { return }
        $nomeColuna = $gridSis.Columns[$e.ColumnIndex].Name
        $row = $gridSis.Rows[$e.RowIndex]
        $tagLinha = $row.Tag
        if (-not $tagLinha) { return }
        $item = $itens[$e.RowIndex]

        if ($nomeColuna -eq "Copiar") {
            $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            if ($barraProgressoLocal -and $lblProgressoLocal) {
                $barraProgressoLocal.Value = 0
                $barraProgressoLocal.Visible = $true
                $barraProgressoLocal.Refresh()
                $lblProgressoLocal.Text = "Iniciando..."
                $lblProgressoLocal.Refresh()
                [System.Windows.Forms.Application]::DoEvents()
            }
            try {
                Invoke-AcaoBaixarPacote -Resultado $Resultado -Pacote $tagLinha.Pacote -AoAtualizarProgresso $callbackProgressoLocal -GridStatus $gridSis -LinhaIndice $e.RowIndex | Out-Null
            } finally {
                if ($barraProgressoLocal) { $barraProgressoLocal.Visible = $false }
                if ($lblProgressoLocal) { $lblProgressoLocal.Text = "" }
                $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
            }
            & $popularLinhaPacoteSis -Grid $gridSis -Indice $e.RowIndex -Item $item -Resultado $Resultado
        } elseif ($nomeColuna -eq "Verificar") {
            $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            try {
                Invoke-AcaoVerificarHashPacote -Resultado $Resultado -Pacote $tagLinha.Pacote -StatusInfo $tagLinha.StatusInfo -GridStatus $gridSis -LinhaIndice $e.RowIndex
            } finally {
                $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
            }
        } elseif ($nomeColuna -eq "AbrirPasta") {
            Invoke-AcaoAbrirPastaPacote -Resultado $Resultado -Pacote $tagLinha.Pacote -StatusInfo $tagLinha.StatusInfo
        }
    }.GetNewClosure())

    [void]$dlg.ShowDialog()
}

function Invoke-AcaoEnviarCvcDrive {
    <#
        Localiza o CVC da maquina e tenta enviar automaticamente ao Google
        Drive via Web App do Apps Script (Send-ArquivoParaGoogleDriveViaAppsScript).
        Se o envio automatico falhar por qualquer motivo (Web App nao
        configurado/cancelado, fora do ar, erro de rede), cai no fallback
        manual: copia o arquivo para uma pasta local e abre a pasta do
        Drive no navegador, para o tecnico arrastar o arquivo ate ela.
    #>
    param($Resultado)
    if (-not $Resultado) { return }

    $temNomeResolvido = $Resultado.Hostname -and $Resultado.Hostname -ne "(sem resolucao de nome)"
    if (-not $temNomeResolvido) {
        [System.Windows.Forms.MessageBox]::Show("Este host nao tem nome resolvido - nao e possivel localizar o arquivo CVC pelo nome da maquina.", "Aviso", "OK", "Warning") | Out-Null
        return
    }

    $hostnameCurto = ($Resultado.Hostname -split '\.')[0]
    $pastaCvc = "\\$($Resultado.IP)\InstSeg\CVC"
    Add-Log "Procurando arquivo CVC de '$hostnameCurto' em $pastaCvc..." "Gray"

    $arquivo = $null
    try {
        $arquivo = Get-ArquivoCvcMaisRecente -IP $Resultado.IP -HostnameCurto $hostnameCurto
    } catch {
        Add-Log "[ERRO] Falha ao acessar ${pastaCvc}: $($_.Exception.Message)" "OrangeRed"
        [System.Windows.Forms.MessageBox]::Show("Falha ao acessar ${pastaCvc}:`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
        return
    }

    if (-not $arquivo) {
        Add-Log "[AVISO] Nenhum arquivo '$hostnameCurto.cvc' encontrado em $pastaCvc." "Yellow"
        [System.Windows.Forms.MessageBox]::Show("Nenhum arquivo '$hostnameCurto.cvc' encontrado em:`r`n$pastaCvc", "Nao encontrado", "OK", "Warning") | Out-Null
        return
    }

    Add-Log "CVC encontrado: $($arquivo.FullName) (modificado em $($arquivo.LastWriteTime)). Enviando automaticamente ao Google Drive..." "Gray"
    $grid.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    $respEnvio = Send-ArquivoParaGoogleDriveViaAppsScript -Arquivo $arquivo
    $grid.Cursor = [System.Windows.Forms.Cursors]::Default

    if ($respEnvio) {
        Add-Log "CVC enviado automaticamente ao Google Drive: $($respEnvio.url)" "LightGreen"
        [System.Windows.Forms.MessageBox]::Show("CVC de '$hostnameCurto' enviado automaticamente para o Google Drive.", "Envio concluido", "OK", "Information") | Out-Null
        return
    }

    Add-Log "Envio automatico falhou - copiando localmente e abrindo a pasta do Drive para envio manual (fallback)." "Yellow"

    try {
        if (-not (Test-Path $script:PastaLocalEnvioCvc)) {
            New-Item -ItemType Directory -Path $script:PastaLocalEnvioCvc -Force | Out-Null
        }
        $destino = Join-Path $script:PastaLocalEnvioCvc $arquivo.Name
        Copy-Item -Path $arquivo.FullName -Destination $destino -Force
    } catch {
        Add-Log "[ERRO] Falha ao copiar '$($arquivo.FullName)' para '$($script:PastaLocalEnvioCvc)': $($_.Exception.Message)" "OrangeRed"
        [System.Windows.Forms.MessageBox]::Show("Falha ao copiar o arquivo CVC:`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
        return
    }

    Add-Log "CVC copiado para $destino. Abrindo a pasta local e a pasta do Google Drive - arraste o arquivo ate a janela do navegador para concluir o envio." "Cyan"

    Start-ProcessoNaoElevado -Caminho "explorer.exe" -Argumentos "/select,`"$destino`""
    Start-ProcessoNaoElevado -Caminho $script:UrlDrivePastaCvc
}

function Invoke-AcaoAbrirExclusaoOcs {
    <#
        A API REST do OCS so suporta GET (confirmado na doc oficial) - nao
        da pra excluir por ali. Em vez disso, abre direto no navegador a
        tela "Remocao de Computadores" do console web do OCS, ja com esta
        maquina marcada (mesma URL que o proprio OCS usa quando voce
        seleciona um computador e clica em "Apagar" na listagem:
        index.php?function=sup_search&head=1&idchecked=<ID>&comp=1) - falta
        so um clique manual no botao "Apagar" daquela tela pra confirmar.
    #>
    param($Resultado)
    if (-not $Resultado -or -not $Resultado.HardwareId) {
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel identificar o ID desta maquina no OCS Inventory.", "Aviso", "OK", "Warning") | Out-Null
        return
    }

    $url = "$($script:UrlOcsWebConsole)/index.php?function=sup_search&head=1&idchecked=$($Resultado.HardwareId)&comp=1"
    Add-Log "Abrindo tela de remocao do OCS Inventory para '$($Resultado.Hostname)' (ID $($Resultado.HardwareId)) - clique em 'Apagar' na pagina que abrir para confirmar." "Cyan"
    Start-ProcessoNaoElevado -Caminho $url
}

# ============================================================
# WAKE-ON-LAN (ligar computador remotamente pra maquinas "Possivelmente
# Desligado" do OCS Inventory)
# ============================================================
function Get-MacAddressOcs {
    <#
        Busca o endereco MAC de uma maquina no OCS Inventory (secao
        "networks" do /computer/:id, ainda nao usada em nenhum outro lugar
        do script ate agora - hardware/bios/registry ja eram usados, mas o
        nome exato dos campos aqui (MACADDR, IPADDRESS etc.) nao foi
        confirmado na pratica ainda). Se a maquina tiver mais de uma
        interface de rede, prioriza a que bate com o ultimo IP conhecido
        ($IpConhecido); senao usa a primeira interface com MAC preenchido.
        Devolve $null (com aviso no log) se nao achar - quem chama decide o
        que fazer.
    #>
    param([int]$HardwareId, [string]$IpConhecido = $null)
    if (-not $HardwareId) { return $null }

    try {
        $url = "$($script:UrlOcsApiBase)/computer/$HardwareId/networks"
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 8
        $secaoRedes = $null
        try { $secaoRedes = $resp."$HardwareId".networks } catch {}
        $redes = @($secaoRedes)

        if ($redes.Count -eq 0) {
            Add-Log "[AVISO] OCS Inventory nao devolveu nenhuma interface de rede pro ID $HardwareId (secao 'networks' vazia, ou o servidor usa outro nome de secao)." "Yellow"
            return $null
        }

        $candidatosMac = @("MACADDR", "MACADDRESS", "MAC")
        $candidatosIp  = @("IPADDRESS", "IPADDR", "IP")

        $redeEscolhida = $null
        if ($IpConhecido) {
            foreach ($campoIp in $candidatosIp) {
                $redeEscolhida = $redes | Where-Object { $_.$campoIp -eq $IpConhecido } | Select-Object -First 1
                if ($redeEscolhida) { break }
            }
        }
        if (-not $redeEscolhida) { $redeEscolhida = $redes | Select-Object -First 1 }

        foreach ($campoMac in $candidatosMac) {
            if ($redeEscolhida.$campoMac) { return $redeEscolhida.$campoMac }
        }

        $propsDisponiveis = ($redeEscolhida.PSObject.Properties | ForEach-Object { $_.Name }) -join ", "
        Add-Log "[AVISO] Nao achei um campo de MAC reconhecido na resposta do OCS pro ID ${HardwareId}. Campos disponiveis na interface: $propsDisponiveis" "Yellow"
        return $null
    } catch {
        Add-Log "[AVISO] Falha ao buscar MAC no OCS Inventory (ID $HardwareId): $($_.Exception.Message)" "Yellow"
        return $null
    }
}

function Send-MagicPacketWol {
    <#
        Monta e manda o "magic packet" padrao de Wake-on-LAN (6 bytes 0xFF
        seguidos do MAC repetido 16x) por UDP broadcast, nas portas 7 e 9
        (as duas convencoes mais comuns - manda nas duas pra cobrir tanto
        placas de rede/BIOS que escutam uma quanto a outra).
    #>
    param([string]$MacAddress, [string]$IpBroadcast)

    $macLimpo = ($MacAddress -replace "[^0-9A-Fa-f]", "")
    if ($macLimpo.Length -ne 12) { throw "Endereco MAC invalido: '$MacAddress'" }

    $bytesMac = New-Object byte[] 6
    for ($i = 0; $i -lt 6; $i++) {
        $bytesMac[$i] = [Convert]::ToByte($macLimpo.Substring($i * 2, 2), 16)
    }

    $pacote = New-Object byte[] 102
    for ($i = 0; $i -lt 6; $i++) { $pacote[$i] = 0xFF }
    for ($rep = 0; $rep -lt 16; $rep++) {
        [Array]::Copy($bytesMac, 0, $pacote, 6 + ($rep * 6), 6)
    }

    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.EnableBroadcast = $true
        foreach ($porta in @(9, 7)) {
            [void]$udp.Send($pacote, $pacote.Length, $IpBroadcast, $porta)
        }
    } finally {
        $udp.Close()
    }
}

function Invoke-AcaoLigarWol {
    <#
        Wake-on-LAN pra maquinas "Possivelmente Desligado": busca o MAC no
        OCS Inventory (Get-MacAddressOcs) e manda o magic packet pro
        broadcast direcionado da rede da zona (assume /24, mesmo padrao
        usado no resto da ferramenta - ex: IP 10.198.72.145 -> broadcast
        10.198.72.255).

        AVISO IMPORTANTE: isso SO funciona se os roteadores entre esta
        maquina (onde a ferramenta esta rodando) e a rede da zona
        permitirem encaminhar broadcast direcionado ate aquele segmento -
        por padrao de seguranca (mitigar ataque smurf), a maioria dos
        roteadores bloqueia isso, e nao ha como confirmar por aqui se vai
        funcionar ou nao. O botao "WOL" do proprio console do OCS Inventory
        aparentemente ja funciona - se o envio direto daqui nao acordar a
        maquina, o OCS provavelmente usa algum mecanismo de rele local
        (agente IPDiscover na propria rede da zona) que este script, rodando
        de fora dessa rede, nao tem como reproduzir.
    #>
    param($Resultado)

    if (-not $Resultado -or -not $Resultado.HardwareId) {
        [System.Windows.Forms.MessageBox]::Show("Essa maquina nao tem ID do OCS Inventory associado.", "Aviso", "OK", "Warning") | Out-Null
        return
    }

    Add-Log "Buscando endereco MAC de '$($Resultado.Hostname)' no OCS Inventory (ID $($Resultado.HardwareId))..." "Gray"
    $mac = Get-MacAddressOcs -HardwareId $Resultado.HardwareId -IpConhecido $Resultado.IP
    if (-not $mac) {
        Add-Log "[ERRO] Nao foi possivel obter o MAC de '$($Resultado.Hostname)' no OCS Inventory - Wake-on-LAN cancelado." "OrangeRed"
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel obter o endereco MAC dessa maquina no OCS Inventory.", "Erro", "OK", "Error") | Out-Null
        return
    }

    if (-not $Resultado.IP -or $Resultado.IP -eq "-") {
        Add-Log "[ERRO] Sem IP conhecido para '$($Resultado.Hostname)' - nao da pra calcular o broadcast da rede. Wake-on-LAN cancelado." "OrangeRed"
        return
    }
    $partesIp = $Resultado.IP -split "\."
    $ipBroadcast = "$($partesIp[0]).$($partesIp[1]).$($partesIp[2]).255"

    try {
        Send-MagicPacketWol -MacAddress $mac -IpBroadcast $ipBroadcast
        Add-Log "Pacote Wake-on-LAN enviado para '$($Resultado.Hostname)' (MAC $mac) via broadcast $ipBroadcast, portas 7 e 9. So funciona se a rede permitir broadcast ate essa zona - sem garantia. Aguarde uns 30-60s e rode a varredura de novo pra conferir se respondeu." "Cyan"
        [System.Windows.Forms.MessageBox]::Show("Pacote Wake-on-LAN enviado para MAC $mac.`r`n`r`nIsso so funciona se a rede permitir broadcast ate a zona - nao ha garantia de que a maquina vai ligar. Aguarde um pouco e rode a varredura novamente pra conferir.", "Wake-on-LAN enviado", "OK", "Information") | Out-Null
    } catch {
        Add-Log "[ERRO] Falha ao enviar o pacote Wake-on-LAN: $($_.Exception.Message)" "OrangeRed"
        [System.Windows.Forms.MessageBox]::Show("Falha ao enviar o pacote Wake-on-LAN:`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
    }
}

# --- Botoes inferiores ---
$btnExportar = New-Object System.Windows.Forms.Button
$btnExportar.Text = "Exportar CSV"
$btnExportar.Location = New-Object System.Drawing.Point(15, 611)
$btnExportar.Width = 120
$btnExportar.Height = 28
$btnExportar.Anchor = "Bottom,Left"
$btnExportar.Enabled = $false
$form.Controls.Add($btnExportar)

$btnConfiguracoes = New-Object System.Windows.Forms.Button
$btnConfiguracoes.Text = "Configuracoes..."
$btnConfiguracoes.Location = New-Object System.Drawing.Point(145, 611)
$btnConfiguracoes.Width = 150
$btnConfiguracoes.Height = 28
$btnConfiguracoes.Anchor = "Bottom,Left"
$form.Controls.Add($btnConfiguracoes)

$btnFechar = New-Object System.Windows.Forms.Button
$btnFechar.Text = "Fechar"
$btnFechar.Location = New-Object System.Drawing.Point(1285, 611)
$btnFechar.Width = 80
$btnFechar.Height = 28
$btnFechar.Anchor = "Bottom,Right"
$form.Controls.Add($btnFechar)

# ============================================================
# CONSTRUCAO DE LINHAS DO GRID (reutilizada tanto na varredura ao vivo
# quanto ao reconstruir a grade quando o filtro de zona muda)
# ============================================================
function Add-LinhaGrid {
    param($Resultado)

    $temNomeResolvido = $Resultado.Hostname -and $Resultado.Hostname -ne "(sem resolucao de nome)"
    $tipo =
        if ($Resultado.SemLinkComunicacao) { "Sem Link de Comunicacao" }
        elseif ($Resultado.PossivelmenteDesligado -and $Resultado.CandidatoExclusaoOcs) { "Desligado - candidata a exclusao" }
        elseif ($Resultado.PossivelmenteDesligado) { "Possivelmente Desligado" }
        elseif ($Resultado.EhGateway) { "Gateway / Roteador" }
        elseif ($Resultado.PossivelImpressora) { "Impressora Pantum?" }
        elseif ($Resultado.EhNobreakCentral) { "Nobreak Central" }
        elseif ($Resultado.EhTelefoneVoip) { "Telefone VOIP" }
        elseif ($temNomeResolvido) { "Host / PC" }
        else { "Tipo Desconhecido" }
    $tempoTxt = if ($Resultado.TempoMs) { "$($Resultado.TempoMs)" } else { "-" }
    $vncTxt = if ($Resultado.VncAtivo) { "Ativo (5900)" } else { "-" }
    $rcTxt = if ($Resultado.RcIvantiAtivo) { "Ativo (9535)" } else { "-" }
    $modeloTxt = if ($Resultado.Modelo) { $Resultado.Modelo } else { "-" }

    # Se a planilha de Versoes de Sistemas estiver configurada e tiver
    # mapeamento pra essa versao "crua", mostra "Nome Amigavel (versao)"
    # (ex: "Praia de Genipabu (6.27)") no lugar do numero sozinho - senao
    # mostra so a versao crua como sempre mostrou. So se aplica a colunas
    # com ComNomeAmigavel = $true (GEDAI, HOLOCRON, PADA-UE, FBR) - SIS e
    # BitLocker nao tem nome de praia, entao sempre mostram a versao crua.
    #
    # $colunasAtualizadas/$colunasDesatualizadas guardam quais celulas
    # precisam ser destacadas (verde = versao instalada bate com a marcada
    # "Atual" na planilha pra aquele sistema; vermelho = nao bate). Usa
    # $script:VersaoAtualPorSistema DIRETO (mesma fonte da janela "Verificar
    # Sistemas Eleitorais") em vez de Resolve-NomeAmigavelVersao/EhAtual -
    # assim vale pra QUALQUER sistema com "Atual" marcado na planilha,
    # independente de ComNomeAmigavel (cobre SIS/Bitlocker/Transportador,
    # que antes nunca ganhavam destaque nenhum).
    $colunasAtualizadas = @()
    $colunasDesatualizadas = @()
    $sisTxt = if ($Resultado.VersaoSis) { $Resultado.VersaoSis } else { "-" }
    if ($sisTxt -ne "-") {
        $versaoAtualSis = $script:VersaoAtualPorSistema["SIS"]
        if ($versaoAtualSis) {
            if ($sisTxt.Trim() -eq $versaoAtualSis.Trim()) { $colunasAtualizadas += "Sis" } else { $colunasDesatualizadas += "Sis" }
        }
    }

    # Status Instalador: compara o hostname (sem sufixo de dominio, ex.
    # "ZMA053WKS71099.tre-ma.gov.br" -> "ZMA053WKS71099") contra a lista de
    # maquinas liberadas pro usuario "instalador" no AD (consultada uma vez
    # por varredura). So faz sentido pra maquina com SIS instalado (estacao
    # eleitoral de verdade) - "-" pra tudo mais (impressora, sem SIS, sem
    # hostname resolvido, ou se a consulta ao AD falhou).
    $instaladorTxt = "-"
    if ($sisTxt -ne "-" -and $temNomeResolvido -and -not $Resultado.PossivelImpressora -and $null -ne $script:MaquinasLiberadasInstalador) {
        $hostnameCurto = ($Resultado.Hostname -split '\.')[0]
        if ($script:MaquinasLiberadasInstalador.Count -eq 0 -or $script:MaquinasLiberadasInstalador -contains $hostnameCurto) {
            $instaladorTxt = "Liberado"
        } else {
            $instaladorTxt = "Bloqueado"
        }
    }

    # Impressora com IP reaproveitado costuma herdar no DNS reverso o nome
    # da maquina antiga que usava aquele IP antes (PTR desatualizado no
    # servidor de DNS - confirmado na pratica: console web da impressora
    # mostra um IP, mas "ping -a" no mesmo IP resolve pra hostname de PC).
    # Como esse hostname nao tem nenhuma relacao com a impressora de
    # verdade, so confunde - a coluna Hostname fica em branco pra impressora.
    $hostnameExibido = if ($Resultado.PossivelImpressora) { "-" } else { $Resultado.Hostname }

    $valoresLinha = @($Resultado.IP, $tipo, $hostnameExibido, $modeloTxt, $tempoTxt, $Resultado.DetectadoPor, $vncTxt, $rcTxt, $sisTxt, $instaladorTxt)
    foreach ($sis in $script:SistemasEleitoraisExtra) {
        if (-not $sis.NaGradePrincipal) { continue }
        $valorExtra = $Resultado.($sis.Propriedade)
        $infoExtra = if ($sis.ComNomeAmigavel) { Resolve-NomeAmigavelVersao -Sistema $sis.NomeVersaoAtual -Versao $valorExtra } else { $null }
        $valoresLinha += $(if ($infoExtra) { "$($infoExtra.NomeAmigavel) ($valorExtra)" } elseif ($valorExtra) { $valorExtra } else { "-" })

        if ($valorExtra -and $valorExtra -ne "-") {
            $versaoAtualSistema = $script:VersaoAtualPorSistema[$sis.NomeVersaoAtual]
            if ($versaoAtualSistema) {
                if ($valorExtra.Trim() -eq $versaoAtualSistema.Trim()) { $colunasAtualizadas += $sis.Coluna } else { $colunasDesatualizadas += $sis.Coluna }
            }
        }
    }
    $valoresLinha += @("", "", "")

    $rowIndex = $grid.Rows.Add($valoresLinha)
    $row = $grid.Rows[$rowIndex]
    $row.Tag = $Resultado

    foreach ($nomeColuna in $colunasAtualizadas) {
        $row.Cells[$nomeColuna].Style.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
        $row.Cells[$nomeColuna].Style.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
        $row.Cells[$nomeColuna].ToolTipText = "Versao atualizada"
    }
    foreach ($nomeColuna in $colunasDesatualizadas) {
        $row.Cells[$nomeColuna].Style.ForeColor = [System.Drawing.Color]::FromArgb(220, 53, 69)
        $row.Cells[$nomeColuna].Style.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
        $row.Cells[$nomeColuna].ToolTipText = "Versao desatualizada"
    }

    if ($Resultado.SemLinkComunicacao) {
        # Gateway da zona nao respondeu - sinal forte de que a ZONA
        # INTEIRA esta sem link de comunicacao (nao que cada maquina
        # individual esta desligada) - vermelho bem visivel, prioridade
        # maxima de destaque, ate acima do "candidata a exclusao".
        $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(220, 53, 69)
        $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::White
        $row.DefaultCellStyle.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
    } elseif ($Resultado.PossivelmenteDesligado -and $Resultado.CandidatoExclusaoOcs) {
        $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 220, 200)
        $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(150, 60, 0)
        $row.DefaultCellStyle.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
    } elseif ($Resultado.PossivelmenteDesligado) {
        $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(230, 230, 230)
        $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(110, 110, 110)
    } elseif ($Resultado.PossivelImpressora) {
        $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 235, 245)
    } elseif ($Resultado.EhGateway) {
        $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(225, 240, 255)
    } elseif ($Resultado.EhNobreakCentral) {
        $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 245, 210)
    } elseif ($Resultado.EhTelefoneVoip) {
        $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(220, 245, 235)
    } elseif (-not $temNomeResolvido) {
        $row.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(240, 240, 240)
    }

    # VNC/RC Ivanti ativos ficam em negrito/verde na propria coluna de
    # status - as acoes (Abrir VNC/RCViewer/Info Impressora) nao tem mais
    # botao na grade, so no menu de contexto (botao direito) e duplo-clique.
    $vncDisponivel = $Resultado.VncAtivo -and -not $Resultado.PossivelImpressora
    if ($vncDisponivel) {
        $row.Cells["Vnc"].Style.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
        $row.Cells["Vnc"].Style.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
    }

    $rcDisponivel = $Resultado.RcIvantiAtivo -and -not $Resultado.PossivelImpressora
    if ($rcDisponivel) {
        $row.Cells["Rc"].Style.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
        $row.Cells["Rc"].Style.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
    }

    if ($instaladorTxt -eq "Liberado") {
        $row.Cells["Instalador"].Style.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
        $row.Cells["Instalador"].Style.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
    } elseif ($instaladorTxt -eq "Bloqueado") {
        $row.Cells["Instalador"].Style.ForeColor = [System.Drawing.Color]::FromArgb(220, 53, 69)
        $row.Cells["Instalador"].Style.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
    }
}

function Atualizar-ResumoStatus {
    $ativos = $script:Resultados | Where-Object { $_.Online }
    $exibidos = $grid.Rows.Count
    $impressorasExibidas = @($grid.Rows | Where-Object { $_.Tag.PossivelImpressora }).Count
    $vncsExibidos = @($grid.Rows | Where-Object { $_.Tag.VncAtivo }).Count
    $desligados = $script:MaquinasDesligadasOcs.Count

    if ($script:RedeCompartilhada -and $chkFiltrarZona.Checked) {
        $lblStatus.Text = "Concluido: $exibidos de $($ativos.Count) ativo(s) na rede pertencem a esta zona. $impressorasExibidas impressora(s), $vncsExibidos com VNC."
    } else {
        $lblStatus.Text = "Concluido: $($ativos.Count) ativo(s), $impressorasExibidas impressora(s), $vncsExibidos com VNC ativo."
    }
    if ($desligados -gt 0) {
        $lblStatus.Text += " $desligados possivelmente desligada(s)/desconectada(s) (OCS)."
    }
    $btnExportar.Enabled = ($ativos.Count -gt 0 -or $desligados -gt 0)
}

function Reconstruir-Grid {
    <#
        Limpa e reconstroi a grade a partir de $script:Resultados (dispositivos
        vistos na varredura) e $script:MaquinasDesligadasOcs (cadastrados no
        OCS Inventory para esta zona, mas que nao responderam), aplicando o
        estado atual da checkbox "Mostrar so hosts desta zona". Usada quando o
        usuario alterna essa checkbox, ou apos a busca de maquinas desligadas.
    #>
    $grid.Rows.Clear()
    foreach ($r in $script:Resultados) {
        if (-not $r.Online) { continue }
        # Impressora/gateway/nobreak central sao infraestrutura compartilhada
        # do predio (nao "pertencem" a nenhuma zona especifica por hostname)
        # - sempre aparecem, mesmo com o filtro "so hosts desta zona" marcado.
        if (-not $script:RedeCompartilhada -or -not $chkFiltrarZona.Checked -or $r.PertenceZonaAtual -or $r.PossivelImpressora -or $r.EhGateway -or $r.EhNobreakCentral) {
            Add-LinhaGrid -Resultado $r
        }
    }
    foreach ($r in $script:MaquinasDesligadasOcs) {
        Add-LinhaGrid -Resultado $r
    }
    Atualizar-ResumoStatus
}

$chkFiltrarZona.Add_CheckedChanged({ Reconstruir-Grid })

# ============================================================
# TIMER DE POLLING
# ============================================================
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 150

$timer.Add_Tick({
    if ($script:Jobs.Count -eq 0) { return }

    $aindaPendentes = New-Object System.Collections.Generic.List[object]

    foreach ($job in $script:Jobs) {
        if ($job.Handle.IsCompleted) {
            try {
                $resultado = $job.Pipe.EndInvoke($job.Handle)
                $job.Pipe.Dispose()
                $script:Resultados.Add($resultado)

                if ($resultado.Online) {
                    # A convencao ".70 = gateway" e um padrao POR ZONA (rede
                    # 10.198.zona.X, uma rede/roteador por zona no interior) -
                    # confirmado NA PRATICA que nao vale em rede COMPARTILHADA
                    # entre varias zonas (ex: 10.11.81.X, predio do Forum de
                    # Sao Luis): la nao existe um roteador fixo em .70 pra
                    # "zona", e um IP qualquer como outro qualquer, entao essa
                    # classificacao fica desativada quando RedeCompartilhada.
                    # ".10/.11 = nobreak central" continua valendo mesmo em
                    # rede compartilhada (1 nobreak fisico pro predio inteiro).
                    # Ja ".190-.195 = telefone VOIP" e por zona (cada zona tem
                    # seus proprios ramais), tambem desativado em compartilhada.
                    $ultimoOcteto = [int]($resultado.IP -split '\.')[3]
                    $ehGateway = (-not $script:RedeCompartilhada) -and $resultado.IP.EndsWith(".70")
                    $ehNobreakCentral = ($ultimoOcteto -eq 10 -or $ultimoOcteto -eq 11)
                    $ehTelefoneVoip = (-not $script:RedeCompartilhada) -and ($ultimoOcteto -ge 190 -and $ultimoOcteto -le 195)

                    $resultado | Add-Member -NotePropertyName EhGateway -NotePropertyValue $ehGateway -Force
                    $resultado | Add-Member -NotePropertyName EhNobreakCentral -NotePropertyValue $ehNobreakCentral -Force
                    $resultado | Add-Member -NotePropertyName EhTelefoneVoip -NotePropertyValue $ehTelefoneVoip -Force

                    if ($script:RedeCompartilhada) {
                        $pertence = Test-HostnamePertenceZona -Hostname $resultado.Hostname -Zona $script:ZonaAtual
                        $resultado | Add-Member -NotePropertyName PertenceZonaAtual -NotePropertyValue $pertence -Force
                    } else {
                        $resultado | Add-Member -NotePropertyName PertenceZonaAtual -NotePropertyValue $true -Force
                    }

                    if ($resultado.PossivelImpressora) {
                        Add-Log "[IMPRESSORA] $($resultado.IP)  $($resultado.Hostname)  portas: $($resultado.PortasAbertas)" "DeepPink"
                    } elseif ($ehGateway) {
                        Add-Log "[GATEWAY]    $($resultado.IP)  $($resultado.Hostname)" "Cyan"
                    } elseif ($ehNobreakCentral) {
                        Add-Log "[NOBREAK]    $($resultado.IP)  $($resultado.Hostname)" "Yellow"
                    } elseif ($ehTelefoneVoip) {
                        Add-Log "[VOIP]       $($resultado.IP)  $($resultado.Hostname)" "Yellow"
                    } else {
                        Add-Log "[HOST]       $($resultado.IP)  $($resultado.Hostname)" "LightGreen"
                    }
                    if ($resultado.VncAtivo -and -not $resultado.PossivelImpressora) {
                        Add-Log "  -> VNC ativo em $($resultado.IP)" "SkyBlue"
                    }
                    if ($resultado.RcIvantiAtivo -and -not $resultado.PossivelImpressora) {
                        Add-Log "  -> RC Ivanti ativo em $($resultado.IP)" "SkyBlue"
                    }

                    # Impressora/gateway/nobreak central sao infraestrutura
                    # compartilhada do predio (nao "pertencem" a nenhuma zona
                    # especifica por hostname) - sempre aparecem, mesmo com o
                    # filtro "so hosts desta zona" marcado numa rede
                    # compartilhada, senao ficam escondidos pra sempre (nunca
                    # teriam PertenceZonaAtual = true).
                    if (-not $script:RedeCompartilhada -or -not $chkFiltrarZona.Checked -or $resultado.PertenceZonaAtual -or $resultado.PossivelImpressora -or $ehGateway -or $ehNobreakCentral) {
                        Add-LinhaGrid -Resultado $resultado
                    }
                }
            } catch {
                Add-Log "[ERRO] Falha ao processar $($job.IP): $_" "OrangeRed"
            }
            $script:Concluidos++
        } else {
            $aindaPendentes.Add($job)
        }
    }

    $script:Jobs = $aindaPendentes
    $progressBar.Value = [Math]::Min($script:Concluidos, $progressBar.Maximum)
    $lblStatus.Text = "Verificando... $($script:Concluidos) de $($script:Total) enderecos analisados."

    if ($script:Jobs.Count -eq 0) {
        $timer.Stop()
        if ($script:Pool) { $script:Pool.Close(); $script:Pool.Dispose(); $script:Pool = $null }
        $script:Escaneando = $false

        Atualizar-ResumoStatus
        $ativos = $script:Resultados | Where-Object { $_.Online }
        $impressoras = $ativos | Where-Object { $_.PossivelImpressora }
        $vncs = $ativos | Where-Object { $_.VncAtivo }
        Add-Log "=== Varredura concluida: $($ativos.Count) ativo(s) / $($impressoras.Count) impressora(s) / $($vncs.Count) com VNC ===" "Cyan"

        Invoke-BuscarDesligadosOcs

        # Se o GATEWAY da zona (convencao ".70") nao respondeu na
        # varredura, e sinal forte de falta de LINK DE COMUNICACAO com a
        # zona inteira - nao que cada maquina individual esta desligada
        # (o que costuma ser a explicacao errada quando TODAS aparecem
        # como "Possivelmente Desligado" de uma vez). Roda depois de
        # Invoke-BuscarDesligadosOcs (que limpa $script:MaquinasDesligadasOcs)
        # e insere na frente pra ficar bem visivel.
        # So faz sentido numa rede POR ZONA (10.198.zona.0/24, um roteador
        # fixo por zona) - numa rede COMPARTILHADA entre varias zonas (ex:
        # predio do Forum de Sao Luis, 10.11.81.0/24) nao existe essa
        # convencao de gateway fixo em .70 pra "a zona", entao a deteccao
        # fica desativada (senao gera falso positivo reclassificando o
        # predio inteiro como sem link so por causa de um IP qualquer).
        $resolucaoZonaAtual = Resolve-RedeDaZona -Zona $script:ZonaAtual
        $ipGateway = "$($resolucaoZonaAtual.Prefixo)70"
        $gatewayRespondeu = $script:Resultados | Where-Object { $_.IP -eq $ipGateway -and $_.Online } | Select-Object -First 1
        if ($script:RedeCompartilhada) {
            # nada a fazer - convencao de gateway por zona nao se aplica aqui
        } elseif (-not $gatewayRespondeu) {
            Add-Log "[AVISO] Gateway ($ipGateway) nao respondeu na varredura - possivel falta de link de comunicacao com a zona inteira (as maquinas podem aparecer como desligadas so por causa disso, nao por estarem realmente desligadas)." "OrangeRed"
            $pseudoSemLink = [PSCustomObject]@{
                IP                     = $ipGateway
                Online                 = $false
                Hostname               = "(sem resolucao de nome)"
                TempoMs                = $null
                PossivelImpressora     = $false
                PortasAbertas          = ""
                DetectadoPor           = "Gateway nao respondeu - possivel falta de link de comunicacao"
                VncAtivo               = $false
                RcIvantiAtivo          = $false
                VersaoSis              = "-"
                Modelo                 = "-"
                EhGateway              = $true
                EhNobreakCentral       = $false
                EhTelefoneVoip         = $false
                PertenceZonaAtual      = $true
                PossivelmenteDesligado = $false
                CandidatoExclusaoOcs   = $false
                SemLinkComunicacao     = $true
            }
            foreach ($sis in $script:SistemasEleitoraisExtra) {
                $pseudoSemLink | Add-Member -NotePropertyName $sis.Propriedade -NotePropertyValue "-"
            }

            # Reclassifica TODAS as maquinas "Possivelmente Desligado" ja
            # levantadas (via OCS) como "Sem Link de Comunicacao" tambem -
            # sem o gateway responder, nao da pra afirmar que cada uma
            # individualmente esta desligada, o mais provavel e que a
            # zona inteira esta sem link com o predio/servidor.
            foreach ($maquina in $script:MaquinasDesligadasOcs) {
                $maquina.SemLinkComunicacao = $true
                $maquina.DetectadoPor = "$($maquina.DetectadoPor) (gateway da zona tambem nao respondeu)"
            }

            $script:MaquinasDesligadasOcs.Insert(0, $pseudoSemLink)
            Reconstruir-Grid
        }

        $btnIniciar.Enabled = $true
        $btnCancelar.Enabled = $false
        $numZona.Enabled = $true
    }
})

# ============================================================
# CONSULTA AD: maquinas liberadas para o usuario "instalador"
# ============================================================
function Get-RaizBuscaAd {
    <#
        Amarra a raiz de busca do AD explicitamente na RAIZ DO DOMINIO
        (LDAP://DC=tre-ma,DC=gov,DC=br) em vez de deixar o
        DirectoryEntry() vazio decidir sozinho onde "comeca" a busca -
        confirmado na pratica que o bind vazio pode nao alcancar certas
        OUs (ex: OU=ZONAS_CAPITAL, usada pelos usuarios das zonas de Sao
        Luis, estrutura diferente do resto do interior), causando "Falha
        ao consultar o AD" so pra esses usuarios especificos. Cai pro
        bind vazio (comportamento antigo) se nao conseguir detectar o
        dominio atual por algum motivo.
    #>
    try {
        $dominioAtual = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        $dnDominio = "DC=" + ($dominioAtual.Name -split '\.' -join ',DC=')
        return New-Object System.DirectoryServices.DirectoryEntry("LDAP://$dnDominio")
    } catch {
        return New-Object System.DirectoryServices.DirectoryEntry
    }
}

function Get-MaquinasLiberadasInstalador {
    <#
        Consulta o atributo LDAP userWorkstations do usuario
        $script:NomeUsuarioInstalador (lista de hostnames NetBIOS separados
        por virgula onde ele esta liberado pra logar agora) via ADSI puro,
        sem depender do modulo ActiveDirectory/RSAT. Retorna um array de
        hostnames (vazio = sem restricao, liberado em qualquer maquina) ou
        $null se a consulta falhou (dominio inacessivel, usuario nao
        encontrado etc) - nesse caso a coluna "Status Instalador" fica "-"
        pra todo mundo, ja que nao da pra saber o status real.
    #>
    try {
        $raizBusca = Get-RaizBuscaAd
        $busca = New-Object System.DirectoryServices.DirectorySearcher($raizBusca)
        $busca.ReferralChasing = [System.DirectoryServices.ReferralChasingOption]::None
        $busca.Filter = "(&(objectClass=user)(objectCategory=person)(samAccountName=$script:NomeUsuarioInstalador))"
        [void]$busca.PropertiesToLoad.Add("userWorkstations")
        $resultado = $busca.FindOne()
        if (-not $resultado) {
            Add-Log "[AVISO] Usuario '$script:NomeUsuarioInstalador' nao encontrado no AD - coluna Status Instalador ficara em branco." "OrangeRed"
            return $null
        }
        if ($resultado.Properties["userworkstations"].Count -eq 0) {
            return @()
        }
        $valorCru = $resultado.Properties["userworkstations"][0]
        return @($valorCru -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } catch {
        Add-Log "[AVISO] Falha ao consultar AD para status do instalador: $_" "OrangeRed"
        return $null
    }
}

# ============================================================
# JANELA: Usuarios da ZE (lista de usuarios do AD lotados numa zona,
# com os grupos de cada um)
# ============================================================
function ConvertTo-InfoObjetoAd {
    <#
        Quebra um DN de objeto do AD (ex: "CN=GEDAI2K1GAdmin,OU=Grupos,
        OU=TRIBUNAL,DC=tre-ma,DC=gov,DC=br") em Nome (primeiro CN/OU, o
        proprio objeto) e Caminho (dominio + containers, na mesma ordem
        "de cima pra baixo" que a tela nativa de propriedades do AD
        mostra em "Pastas de Active Directory Domain..." - ex:
        "tre-ma.gov.br/TRIBUNAL/Grupos"). Nao trata CN com virgula
        escapada (raro nos nomes de grupo/usuario deste dominio).
    #>
    param([string]$Dn)
    if (-not $Dn) { return $null }
    $partes = $Dn -split ','
    if ($partes.Count -eq 0) { return $null }
    $nome = $partes[0] -replace '^(CN|OU)=', ''
    $dcs = @()
    $containers = @()
    for ($i = 1; $i -lt $partes.Count; $i++) {
        $p = $partes[$i].Trim()
        if ($p -match '^DC=(.+)$') { $dcs += $Matches[1] }
        elseif ($p -match '^(CN|OU)=(.+)$') { $containers += $Matches[2] }
    }
    [array]::Reverse($containers)
    $caminho = $dcs -join '.'
    if ($containers.Count -gt 0) { $caminho += "/" + ($containers -join '/') }
    return [PSCustomObject]@{ Nome = $nome; Caminho = $caminho }
}

function Get-UsuariosDaZona {
    <#
        Busca no AD os usuarios lotados numa zona eleitoral - o cadastro
        NAO e padronizado (as vezes fica no atributo "Escritorio"
        (physicalDeliveryOfficeName), as vezes em "Departamento"
        (department), confirmado na pratica olhando varios usuarios), e
        quando esta em Departamento segue o padrao "ZE-<zona> - <zona>a
        ZONA ELEITORAL - <SEDE>". Por isso a busca cobre as duas
        possibilidades por OR. Retorna array de PSCustomObject (Nome,
        Login, Descricao, Lotacao, Email, Telefone, ContaDesabilitada,
        ContaBloqueada, Grupos). NAO trata falha internamente - se a
        consulta ao AD der erro, a excecao propaga pra quem chamou
        (Show-JanelaUsuariosZona mostra a mensagem completa na janela).
    #>
    param([int]$Zona)

    $busca = $null
    $resultados = $null
    try {
        $raizBusca = Get-RaizBuscaAd
        $busca = New-Object System.DirectoryServices.DirectorySearcher($raizBusca)
        $busca.ReferralChasing = [System.DirectoryServices.ReferralChasingOption]::None
        $busca.PageSize = 1000
        # O AD usa a zona SEMPRE com 2 digitos no minimo (ex: zona 1 vira
        # "ZE-01", confirmado na pratica - "ZE-1" sozinho nao existe) - zonas
        # de 2+ digitos (10, 72, 105...) ja tem naturalmente 2+ digitos,
        # entao a formatacao nao muda nada pra elas. Ainda assim inclui a
        # forma SEM padding tambem no OR, por seguranca contra cadastro
        # manual inconsistente (o proprio motivo de ter essa tela).
        $zonaPad = "{0:D2}" -f $Zona
        $busca.Filter = "(&(objectClass=user)(objectCategory=person)(|(physicalDeliveryOfficeName=ZE-$Zona)(physicalDeliveryOfficeName=ZE-$zonaPad)(department=ZE-$Zona)(department=ZE-$Zona *)(department=ZE-$zonaPad)(department=ZE-$zonaPad *)))"
        foreach ($p in @("samAccountName", "displayName", "description", "department", "physicalDeliveryOfficeName", "mail", "telephoneNumber", "userAccountControl", "lockoutTime", "memberOf")) {
            [void]$busca.PropertiesToLoad.Add($p)
        }
        $resultados = $busca.FindAll()

        $usuarios = New-Object System.Collections.Generic.List[object]
        foreach ($r in $resultados) {
            $props = $r.Properties
            $uac = if ($props["useraccountcontrol"].Count -gt 0) { [int]$props["useraccountcontrol"][0] } else { 0 }
            # "Bloqueado" (lockout por tentativas de senha erradas) e um
            # status DIFERENTE de "Desabilitado" (uac bit ACCOUNTDISABLE) -
            # nao tem bit proprio no userAccountControl, fica no atributo
            # lockoutTime: 0 (ou ausente) = nunca bloqueado/desbloqueado,
            # qualquer valor diferente de 0 = bloqueado desde aquele
            # instante (FILETIME do Windows).
            $lockoutTime = if ($props["lockouttime"].Count -gt 0) { [long]$props["lockouttime"][0] } else { 0 }
            $grupos = New-Object System.Collections.Generic.List[object]
            foreach ($g in $props["memberof"]) {
                $info = ConvertTo-InfoObjetoAd -Dn $g
                if ($info) { $grupos.Add($info) }
            }
            $usuarios.Add([PSCustomObject]@{
                Nome              = if ($props["displayname"].Count -gt 0) { $props["displayname"][0] } elseif ($props["samaccountname"].Count -gt 0) { $props["samaccountname"][0] } else { "(sem nome)" }
                Login             = if ($props["samaccountname"].Count -gt 0) { $props["samaccountname"][0] } else { "" }
                Descricao         = if ($props["description"].Count -gt 0) { $props["description"][0] } else { "" }
                Lotacao           = if ($props["department"].Count -gt 0) { $props["department"][0] } elseif ($props["physicaldeliveryofficename"].Count -gt 0) { $props["physicaldeliveryofficename"][0] } else { "" }
                Email             = if ($props["mail"].Count -gt 0) { $props["mail"][0] } else { "" }
                Telefone          = if ($props["telephonenumber"].Count -gt 0) { $props["telephonenumber"][0] } else { "" }
                ContaDesabilitada = (($uac -band 2) -ne 0)
                ContaBloqueada    = ($lockoutTime -ne 0)
                Grupos            = ($grupos | Sort-Object Nome)
            })
        }
        return ($usuarios | Sort-Object Nome)
    } finally {
        # SEM catch aqui de proposito - deixa a excecao propagar pra quem
        # chamou tratar (Show-JanelaUsuariosZona mostra o erro completo
        # direto na janela, mais confiavel do que so logar e a pessoa ter
        # que catar a linha certa no log da janela principal).
        if ($resultados) { $resultados.Dispose() }
        if ($busca) { $busca.Dispose() }
    }
}

function Show-JanelaUsuariosZona {
    param([int]$Zona)

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Usuarios da ZE $Zona"
    $dlg.Size = New-Object System.Drawing.Size(1400, 600)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $lblStatusUsuarios = New-Object System.Windows.Forms.Label
    $lblStatusUsuarios.Text = "Consultando AD..."
    $lblStatusUsuarios.Location = New-Object System.Drawing.Point(12, 12)
    $lblStatusUsuarios.Size = New-Object System.Drawing.Size(1370, 36)
    $lblStatusUsuarios.AutoSize = $false
    $lblStatusUsuarios.ForeColor = [System.Drawing.Color]::Gray
    $dlg.Controls.Add($lblStatusUsuarios)

    $lblGrupos = New-Object System.Windows.Forms.Label
    $lblGrupos.Text = "Acessos a Sistemas Eleitorais (grupos mapeados na planilha):"
    $lblGrupos.Location = New-Object System.Drawing.Point(1007, 52)
    $lblGrupos.AutoSize = $true
    $dlg.Controls.Add($lblGrupos)

    $gridUsuarios = New-Object System.Windows.Forms.DataGridView
    # Location/Size/Anchor (NAO Dock=Fill) de proposito - confirmado em
    # outra janela desta ferramenta (Sistemas Eleitorais) que Dock=Fill
    # pode deixar o cabecalho de coluna sumido/em branco nesse ambiente.
    $gridUsuarios.Location = New-Object System.Drawing.Point(12, 52)
    $gridUsuarios.Size = New-Object System.Drawing.Size(980, 400)
    $gridUsuarios.Anchor = "Top,Bottom,Left"
    $gridUsuarios.AllowUserToAddRows = $false
    $gridUsuarios.AllowUserToDeleteRows = $false
    $gridUsuarios.ReadOnly = $true
    $gridUsuarios.RowHeadersVisible = $false
    $gridUsuarios.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $gridUsuarios.MultiSelect = $false
    $gridUsuarios.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None
    $dlg.Controls.Add($gridUsuarios)

    function Add-ColunaGridUsuarios {
        param($Nome, $Titulo, $Largura)
        $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $c.Name = $Nome; $c.HeaderText = $Titulo; $c.Width = $Largura
        [void]$gridUsuarios.Columns.Add($c)
    }
    Add-ColunaGridUsuarios "Nome" "Nome" 180
    Add-ColunaGridUsuarios "Login" "Login" 95
    Add-ColunaGridUsuarios "Descricao" "Descricao/Cargo" 210
    Add-ColunaGridUsuarios "Lotacao" "Lotacao (AD)" 250
    Add-ColunaGridUsuarios "Email" "Email" 220

    $gridGrupos = New-Object System.Windows.Forms.DataGridView
    $gridGrupos.Location = New-Object System.Drawing.Point(1007, 72)
    $gridGrupos.Size = New-Object System.Drawing.Size(375, 380)
    $gridGrupos.Anchor = "Top,Bottom,Right"
    $gridGrupos.AllowUserToAddRows = $false
    $gridGrupos.AllowUserToDeleteRows = $false
    $gridGrupos.ReadOnly = $true
    $gridGrupos.RowHeadersVisible = $false
    $gridGrupos.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $gridGrupos.MultiSelect = $false
    $gridGrupos.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None
    $dlg.Controls.Add($gridGrupos)

    function Add-ColunaGridGrupos {
        param($Nome, $Titulo, $Largura)
        $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $c.Name = $Nome; $c.HeaderText = $Titulo; $c.Width = $Largura
        [void]$gridGrupos.Columns.Add($c)
    }
    Add-ColunaGridGrupos "Nome" "Grupo" 155
    Add-ColunaGridGrupos "Sistema" "Sistema" 115
    Add-ColunaGridGrupos "Perfil" "Perfil" 95

    $painelLegendaUsuarios = New-Object System.Windows.Forms.FlowLayoutPanel
    $painelLegendaUsuarios.Location = New-Object System.Drawing.Point(12, 460)
    $painelLegendaUsuarios.Size = New-Object System.Drawing.Size(660, 26)
    $painelLegendaUsuarios.Anchor = "Bottom,Left"
    $dlg.Controls.Add($painelLegendaUsuarios)
    function Add-ItemLegendaUsuarios {
        param($Painel, $Texto, $Cor)
        $lblItem = New-Object System.Windows.Forms.Label
        $lblItem.Text = "● $Texto"
        $lblItem.ForeColor = $Cor
        $lblItem.AutoSize = $true
        $lblItem.Margin = New-Object System.Windows.Forms.Padding(0, 4, 20, 0)
        [void]$Painel.Controls.Add($lblItem)
    }
    Add-ItemLegendaUsuarios $painelLegendaUsuarios "Desabilitada" ([System.Drawing.Color]::FromArgb(150, 150, 150))
    Add-ItemLegendaUsuarios $painelLegendaUsuarios "Bloqueada" ([System.Drawing.Color]::FromArgb(220, 53, 69))

    $btnFecharUsuarios = New-Object System.Windows.Forms.Button
    $btnFecharUsuarios.Text = "Fechar"
    $btnFecharUsuarios.Location = New-Object System.Drawing.Point(1297, 498)
    $btnFecharUsuarios.Width = 90
    $btnFecharUsuarios.Height = 28
    $btnFecharUsuarios.Anchor = "Bottom,Right"
    $dlg.Controls.Add($btnFecharUsuarios)
    $btnFecharUsuarios.Add_Click({ $dlg.Close() }.GetNewClosure())

    $gridUsuarios.Add_SelectionChanged({
        $gridGrupos.Rows.Clear()
        if ($gridUsuarios.SelectedRows.Count -eq 0) { return }
        $usuario = $gridUsuarios.SelectedRows[0].Tag
        if (-not $usuario) { return }
        foreach ($grupo in $usuario.Grupos) {
            $mapeamento = Get-InfoGrupoSistema -NomeGrupo $grupo.Nome
            if (-not $mapeamento) { continue }
            $idxGrupo = $gridGrupos.Rows.Add(@($grupo.Nome, $mapeamento.Sistema, $mapeamento.Perfil))
            $gridGrupos.Rows[$idxGrupo].Cells["Nome"].ToolTipText = $grupo.Caminho
        }
    }.GetNewClosure())

    $dlg.Add_Shown({
        [System.Windows.Forms.Application]::DoEvents()
        Import-TabelaGruposSistemas | Out-Null
        $usuarios = $null
        try {
            $usuarios = Get-UsuariosDaZona -Zona $Zona
        } catch {
            # Mostra a mensagem de erro completa DIRETO na janela (mais
            # confiavel do que so mandar pro log da janela principal e a
            # pessoa ter que catar a linha certa la).
            $lblStatusUsuarios.Text = "Falha ao consultar o AD: $($_.Exception.Message)"
            $lblStatusUsuarios.ForeColor = [System.Drawing.Color]::Firebrick
            Add-Log "[ERRO] Falha ao consultar usuarios da zona $Zona no AD: $_" "OrangeRed"
            return
        }
        if ($usuarios.Count -eq 0) {
            $lblStatusUsuarios.Text = "Nenhum usuario encontrado no AD para a ZE $Zona (campo Departamento/Escritorio pode estar vazio ou fora do padrao)."
            $lblStatusUsuarios.ForeColor = [System.Drawing.Color]::OrangeRed
            return
        }
        $lblStatusUsuarios.Text = "$($usuarios.Count) usuario(s) encontrado(s) para a ZE ${Zona}:"
        $lblStatusUsuarios.ForeColor = [System.Drawing.Color]::Gray
        foreach ($usuario in $usuarios) {
            $idx = $gridUsuarios.Rows.Add(@($usuario.Nome, $usuario.Login, $usuario.Descricao, $usuario.Lotacao, $usuario.Email))
            $row = $gridUsuarios.Rows[$idx]
            $row.Tag = $usuario
            $situacoes = @()
            if ($usuario.ContaDesabilitada) { $situacoes += "desabilitada" }
            if ($usuario.ContaBloqueada) { $situacoes += "bloqueada" }
            if ($usuario.ContaDesabilitada) {
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(150, 150, 150)
            } elseif ($usuario.ContaBloqueada) {
                $row.DefaultCellStyle.ForeColor = [System.Drawing.Color]::FromArgb(220, 53, 69)
                $row.DefaultCellStyle.Font = New-Object System.Drawing.Font($gridUsuarios.Font, [System.Drawing.FontStyle]::Bold)
            }
            if ($situacoes.Count -gt 0) {
                $row.Cells["Nome"].ToolTipText = "Conta " + ($situacoes -join " e ") + " no AD"
            }
        }
    }.GetNewClosure())

    [void]$dlg.ShowDialog($form)
}

# ============================================================
# EVENTO: Iniciar Varredura
# ============================================================
$btnIniciar.Add_Click({
    $zona = [int]$numZona.Value
    $resolucao = Resolve-RedeDaZona -Zona $zona
    $baseIP = $resolucao.Prefixo

    $script:ZonaAtual = $zona
    $script:MaquinasLiberadasInstalador = Get-MaquinasLiberadasInstalador
    if ($null -eq $script:MaquinasLiberadasInstalador) {
        Add-Log "Nao foi possivel consultar o AD para o status do instalador nesta varredura." "Gray"
    } elseif ($script:MaquinasLiberadasInstalador.Count -eq 0) {
        Add-Log "Usuario '$script:NomeUsuarioInstalador' sem restricao de maquina no AD (liberado em qualquer uma)." "Gray"
    } else {
        Add-Log "Usuario '$script:NomeUsuarioInstalador' liberado em $($script:MaquinasLiberadasInstalador.Count) maquina(s) no AD." "Gray"
    }
    # "Rede compartilhada" = a mesma rede /24 atende mais de uma zona ao
    # mesmo tempo (varias zonas no mesmo predio, ex: 004/005/006 ou as
    # zonas de Sao Luis) - detectado dinamicamente a partir da planilha,
    # nao mais fixo so para Sao Luis.
    $script:RedeCompartilhada = Test-RedeEhCompartilhada -Prefixo $resolucao.Prefixo

    $grid.Rows.Clear()
    $rtbLog.Clear()
    $script:Resultados.Clear()
    $script:MaquinasDesligadasOcs.Clear()
    $script:Jobs.Clear()
    $script:Concluidos = 0
    $btnExportar.Enabled = $false
    $numZona.Enabled = $false

    $sedeTxt = if ($resolucao.Sede) { $resolucao.Sede } else { "(sede desconhecida)" }
    Add-Log "=== Iniciando varredura da Zona $zona - $sedeTxt ($($baseIP)0/24) ===" "Yellow"
    Add-Log "Rede determinada por: $($resolucao.Origem)" "Gray"
    if ($script:RedeCompartilhada) {
        $filtroTxt = if ($chkFiltrarZona.Checked) { "ativo (so mostra hosts desta zona)" } else { "desativado (mostra todos os hosts da rede)" }
        Add-Log "Rede compartilhada entre varias zonas - filtro por hostname $filtroTxt." "Gray"
    }

    $ips = 1..254 | ForEach-Object { "$baseIP$_" }
    $script:Total = $ips.Count
    $progressBar.Maximum = $script:Total
    $progressBar.Value = 0

    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $script:Pool = [runspacefactory]::CreateRunspacePool(1, 60, $sessionState, $Host)
    $script:Pool.Open()

    foreach ($ip in $ips) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $script:Pool
        [void]$ps.AddScript($scriptBlock).AddArgument($ip).AddArgument(400).AddArgument($script:PortasFallback).AddArgument($script:PortasImpressora).AddArgument($script:PortaVnc).AddArgument($script:PortaRcIvanti).AddArgument($script:UrlOcsApiBase).AddArgument($script:ZonaAtual).AddArgument($script:RedeCompartilhada).AddArgument($script:MapaModelos).AddArgument($script:SistemasEleitoraisExtra)
        $handle = $ps.BeginInvoke()
        $script:Jobs.Add([PSCustomObject]@{ Pipe = $ps; Handle = $handle; IP = $ip })
    }

    $script:Escaneando = $true
    $btnIniciar.Enabled = $false
    $btnCancelar.Enabled = $true
    $timer.Start()
})

# ============================================================
# EVENTO: Cancelar
# ============================================================
$btnCancelar.Add_Click({
    $timer.Stop()
    foreach ($job in $script:Jobs) {
        try { $job.Pipe.Stop(); $job.Pipe.Dispose() } catch {}
    }
    $script:Jobs.Clear()
    if ($script:Pool) { $script:Pool.Close(); $script:Pool.Dispose(); $script:Pool = $null }
    $script:Escaneando = $false

    Add-Log "=== Varredura cancelada pelo usuario ===" "OrangeRed"
    $lblStatus.Text = "Cancelado."
    $btnIniciar.Enabled = $true
    $btnCancelar.Enabled = $false
    $numZona.Enabled = $true
    $ativos = $script:Resultados | Where-Object { $_.Online }
    $btnExportar.Enabled = ($ativos.Count -gt 0 -or $script:MaquinasDesligadasOcs.Count -gt 0)
})

# ============================================================
# EVENTO: Exportar CSV
# ============================================================
$btnExportar.Add_Click({
    $exportarFiltrado = $script:RedeCompartilhada -and $chkFiltrarZona.Checked
    $ativos = if ($exportarFiltrado) {
        $script:Resultados | Where-Object { $_.Online -and $_.PertenceZonaAtual } | Sort-Object { [int]($_.IP -split '\.')[3] }
    } else {
        $script:Resultados | Where-Object { $_.Online } | Sort-Object { [int]($_.IP -split '\.')[3] }
    }
    $desligados = $script:MaquinasDesligadasOcs
    if ($ativos.Count -eq 0 -and $desligados.Count -eq 0) { return }

    $zona = [int]$numZona.Value
    $timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
    $sfd = New-Object System.Windows.Forms.SaveFileDialog
    $sfd.Filter = "Arquivo CSV (*.csv)|*.csv"
    $sfd.FileName = "Zona${zona}_Dispositivos_$timestamp.csv"

    if ($sfd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        (@($ativos) + @($desligados)) |
            Select-Object IP, Hostname, PossivelImpressora, PortasAbertas, VncAtivo, RcIvantiAtivo, TempoMs, DetectadoPor, @{Name = "PossivelmenteDesligado"; Expression = { [bool]$_.PossivelmenteDesligado } } |
            Export-Csv -Path $sfd.FileName -NoTypeInformation -Encoding UTF8
        $obsFiltro = if ($exportarFiltrado) { " (filtrado - so desta zona)" } else { "" }
        Add-Log "CSV exportado para: $($sfd.FileName) - $($ativos.Count) ativo(s) + $($desligados.Count) possivelmente desligada(s)$obsFiltro." "Cyan"
        [System.Windows.Forms.MessageBox]::Show("CSV exportado com sucesso.", "Concluido", "OK", "Information") | Out-Null
    }
})

# ============================================================
# JANELA UNICA DE CONFIGURACOES (VNC Viewer, RCViewer, SNMP, Envio Drive)
# ============================================================
function Show-Configuracoes {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Configuracoes da Ferramenta"
    $dlg.Size = New-Object System.Drawing.Size(530, 520)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(12, 12)
    $tabs.Size = New-Object System.Drawing.Size(495, 415)
    $dlg.Controls.Add($tabs)

    # --- Aba VNC Viewer ---
    $tabVnc = New-Object System.Windows.Forms.TabPage
    $tabVnc.Text = "VNC Viewer"
    $tabs.TabPages.Add($tabVnc)

    $lblVnc = New-Object System.Windows.Forms.Label
    $lblVnc.Text = "Caminho do vncviewer.exe (usado no botao 'Abrir VNC' de cada linha):"
    $lblVnc.Location = New-Object System.Drawing.Point(15, 20)
    $lblVnc.Size = New-Object System.Drawing.Size(455, 20)
    $tabVnc.Controls.Add($lblVnc)

    $txtVnc = New-Object System.Windows.Forms.TextBox
    $txtVnc.Location = New-Object System.Drawing.Point(15, 45)
    $txtVnc.Width = 355
    $txtVnc.Text = $script:VncViewerPath
    $tabVnc.Controls.Add($txtVnc)

    $btnProcurarVnc = New-Object System.Windows.Forms.Button
    $btnProcurarVnc.Text = "Procurar..."
    $btnProcurarVnc.Location = New-Object System.Drawing.Point(378, 43)
    $btnProcurarVnc.Width = 95
    $btnProcurarVnc.Height = 25
    $tabVnc.Controls.Add($btnProcurarVnc)
    $btnProcurarVnc.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title = "Localizar vncviewer.exe"
        $ofd.Filter = "Executavel (*.exe)|*.exe"
        if ($txtVnc.Text -and (Test-Path $txtVnc.Text -ErrorAction SilentlyContinue)) {
            $ofd.InitialDirectory = Split-Path $txtVnc.Text
        }
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtVnc.Text = $ofd.FileName }
    }.GetNewClosure())

    # --- Aba RCViewer ---
    $tabRc = New-Object System.Windows.Forms.TabPage
    $tabRc.Text = "RCViewer"
    $tabs.TabPages.Add($tabRc)

    $lblRc = New-Object System.Windows.Forms.Label
    $lblRc.Text = "Caminho do RCViewer.exe (Ivanti/LANDesk - botao 'Abrir RCViewer' de cada linha):"
    $lblRc.Location = New-Object System.Drawing.Point(15, 20)
    $lblRc.Size = New-Object System.Drawing.Size(455, 20)
    $tabRc.Controls.Add($lblRc)

    $txtRc = New-Object System.Windows.Forms.TextBox
    $txtRc.Location = New-Object System.Drawing.Point(15, 45)
    $txtRc.Width = 355
    $txtRc.Text = $script:RcViewerPath
    $tabRc.Controls.Add($txtRc)

    $btnProcurarRc = New-Object System.Windows.Forms.Button
    $btnProcurarRc.Text = "Procurar..."
    $btnProcurarRc.Location = New-Object System.Drawing.Point(378, 43)
    $btnProcurarRc.Width = 95
    $btnProcurarRc.Height = 25
    $tabRc.Controls.Add($btnProcurarRc)
    $btnProcurarRc.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title = "Localizar RCViewer.exe"
        $ofd.Filter = "Executavel (*.exe)|*.exe"
        if ($txtRc.Text -and (Test-Path $txtRc.Text -ErrorAction SilentlyContinue)) {
            $ofd.InitialDirectory = Split-Path $txtRc.Text
        }
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { $txtRc.Text = $ofd.FileName }
    }.GetNewClosure())

    # --- Aba SNMP ---
    $tabSnmp = New-Object System.Windows.Forms.TabPage
    $tabSnmp.Text = "SNMP"
    $tabs.TabPages.Add($tabSnmp)

    $lblSnmp = New-Object System.Windows.Forms.Label
    $lblSnmp.Text = "Comunidade SNMP v1/v2c usada pelas impressoras (padrao das Pantum do TRE-MA: public):"
    $lblSnmp.Location = New-Object System.Drawing.Point(15, 20)
    $lblSnmp.Size = New-Object System.Drawing.Size(455, 35)
    $tabSnmp.Controls.Add($lblSnmp)

    $txtSnmp = New-Object System.Windows.Forms.TextBox
    $txtSnmp.Location = New-Object System.Drawing.Point(15, 60)
    $txtSnmp.Width = 200
    $txtSnmp.Text = $script:SnmpCommunity
    $tabSnmp.Controls.Add($txtSnmp)

    # --- Aba Envio ao Google Drive ---
    $tabDrive = New-Object System.Windows.Forms.TabPage
    $tabDrive.Text = "Envio ao Drive"
    $tabs.TabPages.Add($tabDrive)

    $cfgDriveAtual = Get-ConfigEnvioDrive

    $lblDriveUrl = New-Object System.Windows.Forms.Label
    $lblDriveUrl.Text = "URL do Web App do Apps Script (Implantar > Nova implantacao), termina em /exec:"
    $lblDriveUrl.Location = New-Object System.Drawing.Point(15, 20)
    $lblDriveUrl.Size = New-Object System.Drawing.Size(455, 20)
    $tabDrive.Controls.Add($lblDriveUrl)

    $txtDriveUrl = New-Object System.Windows.Forms.TextBox
    $txtDriveUrl.Location = New-Object System.Drawing.Point(15, 45)
    $txtDriveUrl.Width = 455
    $txtDriveUrl.Text = if ($cfgDriveAtual) { $cfgDriveAtual.UrlWebApp } else { "" }
    $tabDrive.Controls.Add($txtDriveUrl)

    $lblDriveToken = New-Object System.Windows.Forms.Label
    $lblDriveToken.Text = "Token combinado com o script (mesmo valor da constante TOKEN no Apps Script):"
    $lblDriveToken.Location = New-Object System.Drawing.Point(15, 80)
    $lblDriveToken.Size = New-Object System.Drawing.Size(455, 20)
    $tabDrive.Controls.Add($lblDriveToken)

    $txtDriveToken = New-Object System.Windows.Forms.TextBox
    $txtDriveToken.Location = New-Object System.Drawing.Point(15, 105)
    $txtDriveToken.Width = 455
    $txtDriveToken.Text = if ($cfgDriveAtual) { $cfgDriveAtual.Token } else { "" }
    $tabDrive.Controls.Add($txtDriveToken)

    # --- Aba Versoes de Sistemas ---
    $tabVersoes = New-Object System.Windows.Forms.TabPage
    $tabVersoes.Text = "Versoes de Sistemas"
    $tabs.TabPages.Add($tabVersoes)

    $cfgVersoesAtual = Get-ConfigVersoes

    $lblVersoes = New-Object System.Windows.Forms.Label
    $lblVersoes.Text = "URL da ABA (nao da planilha inteira) com os Sistemas Eleitorais - usada pro nome amigavel na grade e pelos pacotes de instalacao. Compartilhe como 'Qualquer pessoa com o link - Leitor'.`r`n`r`nColunas esperadas:`r`nSistema | Versao | NomeAmigavel | LinkDrive | PastaDestino | Atual | NomeArquivo | Hash | Tamanho`r`n`r`nLinkDrive/PastaDestino (opcionais) viram pacote baixavel. Atual=SIM na versao mais recente de cada sistema. Hash/Tamanho (opcionais) conferem a integridade do pacote copiado. Todo o recurso e opcional - sem planilha, a grade so mostra a versao crua."
    $lblVersoes.Location = New-Object System.Drawing.Point(15, 15)
    $lblVersoes.Size = New-Object System.Drawing.Size(455, 180)
    $tabVersoes.Controls.Add($lblVersoes)

    $txtVersoes = New-Object System.Windows.Forms.TextBox
    $txtVersoes.Location = New-Object System.Drawing.Point(15, 200)
    $txtVersoes.Width = 455
    $txtVersoes.Text = if ($cfgVersoesAtual) { $cfgVersoesAtual.SpreadsheetId } else { "" }
    $tabVersoes.Controls.Add($txtVersoes)

    # --- Botoes ---
    $btnSalvarConfig = New-Object System.Windows.Forms.Button
    $btnSalvarConfig.Text = "Salvar"
    $btnSalvarConfig.Location = New-Object System.Drawing.Point(320, 438)
    $btnSalvarConfig.Width = 90
    $btnSalvarConfig.Height = 30
    $btnSalvarConfig.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
    $btnSalvarConfig.ForeColor = [System.Drawing.Color]::White
    $dlg.Controls.Add($btnSalvarConfig)

    $btnFecharConfig = New-Object System.Windows.Forms.Button
    $btnFecharConfig.Text = "Fechar"
    $btnFecharConfig.Location = New-Object System.Drawing.Point(415, 438)
    $btnFecharConfig.Width = 90
    $btnFecharConfig.Height = 30
    $dlg.Controls.Add($btnFecharConfig)

    $btnSalvarConfig.Add_Click({
        $itensSalvos = New-Object System.Collections.Generic.List[string]

        if ($txtVnc.Text -and $txtVnc.Text.Trim()) {
            $script:VncViewerPath = $txtVnc.Text.Trim()
            Set-Content -Path $script:ArquivoConfigVnc -Value $script:VncViewerPath -Encoding UTF8
            $itensSalvos.Add("VNC Viewer")
        }
        if ($txtRc.Text -and $txtRc.Text.Trim()) {
            $script:RcViewerPath = $txtRc.Text.Trim()
            Set-Content -Path $script:ArquivoConfigRc -Value $script:RcViewerPath -Encoding UTF8
            $itensSalvos.Add("RCViewer")
        }
        if ($txtSnmp.Text -and $txtSnmp.Text.Trim()) {
            $script:SnmpCommunity = $txtSnmp.Text.Trim()
            $itensSalvos.Add("SNMP")
        }
        if ($txtDriveUrl.Text.Trim() -and $txtDriveToken.Text.Trim()) {
            Set-ConfigEnvioDrive -UrlWebApp $txtDriveUrl.Text.Trim() -Token $txtDriveToken.Text.Trim()
            $itensSalvos.Add("Envio ao Drive")
        }
        if ($txtVersoes.Text -and $txtVersoes.Text.Trim()) {
            $refPlanilhaVersoes = Resolve-IdEGidPlanilha $txtVersoes.Text
            Set-ConfigVersoes -SpreadsheetId $refPlanilhaVersoes.Id -Gid $refPlanilhaVersoes.Gid
            if (Import-TabelaVersoes) {
                Add-Log "Planilha de sistemas eleitorais carregada ($($script:TabelaVersoes.Count) mapeamento(s) de versao, $($script:TabelaPacotes.Count) pacote(s))." "Cyan"
                Reconstruir-Grid
            }
            $itensSalvos.Add("Versoes de Sistemas")
        }

        Add-Log "Configuracoes salvas: $($itensSalvos -join ', ')." "Cyan"
        [System.Windows.Forms.MessageBox]::Show("Configuracoes salvas.", "Concluido", "OK", "Information") | Out-Null
    }.GetNewClosure())

    $btnFecharConfig.Add_Click({ $dlg.Close() }.GetNewClosure())

    [void]$dlg.ShowDialog()
}

$btnConfiguracoes.Add_Click({ Show-Configuracoes })

# ============================================================
# BUSCA DE MAQUINAS POSSIVELMENTE DESLIGADAS (cadastradas no OCS Inventory
# para esta zona, mas que nao responderam na varredura). Chamada
# automaticamente ao final de "Iniciar Varredura" - SIS/Modelo/sistemas
# eleitorais das maquinas ONLINE ja sao resolvidos durante a propria
# varredura (dentro do $scriptBlock por IP), entao nao precisa de um botao
# separado de reconsulta.
# ============================================================
function Invoke-BuscarDesligadosOcs {
    if ($script:Resultados.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Rode uma varredura primeiro - a busca de desligados compara com o que foi visto na rede.", "Aviso", "OK", "Warning") | Out-Null
        return
    }

    $zona = [int]$numZona.Value
    $zonaPad = "{0:D3}" -f $zona
    $padroes = @("ZMA$zonaPad", "CMA$zonaPad", "ZE-$zonaPad", "ZE$zonaPad")
    $resolucaoAtual = Resolve-RedeDaZona -Zona $zona

    Add-Log "=== Buscando no OCS Inventory maquinas da Zona $zonaPad (busca exata por IP em $($resolucaoAtual.Prefixo)0/24) ===" "Yellow"
    $grid.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    # Busca por IP (nao por padrao de nome) - o ultimo IP conhecido de uma
    # maquina ja fica dentro da rede fisica da propria zona/predio, mesmo
    # em rede compartilhada entre varias zonas, entao nao precisa mais
    # distinguir rede compartilhada aqui.
    $comps = Get-OcsComputadoresPorIp -PrefixoRede $resolucaoAtual.Prefixo
    Add-Log "$($comps.Count) maquina(s) da zona encontrada(s) no cadastro do OCS Inventory (por IP)." "Gray"

    # Preenche o Hostname de quem respondeu a varredura mas ficou "(sem
    # resolucao de nome)" (DNS reverso/NetBIOS falharam) - cruza pelo ULTIMO
    # IP CONHECIDO no OCS. Precisa rodar ANTES de montar $nomesOnline
    # abaixo, senao essas maquinas (agora online, mas ainda sem nome
    # conhecido no momento do calculo) seriam contadas de novo como
    # "possivelmente desligadas" por engano.
    $corrigidos = 0
    for ($indiceResultado = 0; $indiceResultado -lt $script:Resultados.Count; $indiceResultado++) {
        $cand = $script:Resultados[$indiceResultado]
        if (-not $cand.Online -or ($cand.Hostname -and $cand.Hostname -ne "(sem resolucao de nome)")) { continue }

        $compAchado = $null
        foreach ($comp in $comps) {
            if ($comp.hardware.IPADDR -eq $cand.IP -and $comp.hardware.NAME) { $compAchado = $comp; break }
        }
        if (-not $compAchado) { continue }
        $hwComp = $compAchado.hardware

        # Nem mutar o objeto original nem ".Copy()" + reatribuir depois
        # funcionaram (o GetHashCode "igual" que parecia confirmar isso era
        # um alarme falso - PSCustomObject nao tem GetHashCode confiavel
        # para identidade). O padrao que ja e comprovadamente confiavel no
        # resto do script e construir o objeto novo com o VALOR CERTO JA NA
        # CRIACAO (igual aos pseudo-resultados de "Possivelmente
        # Desligado"), entao calculamos tudo primeiro e so then construimos
        # o literal [PSCustomObject]@{} uma unica vez.
        $modeloNovo = $cand.Modelo
        $biosComp = @($compAchado.bios) | Select-Object -First 1
        if ($biosComp -and $biosComp.SMODEL -and $modeloNovo -eq "-") {
            $modeloNovo = Resolve-ModeloAmigavel -ModeloOriginal $biosComp.SMODEL
        }
        $versaoSisNovo = $cand.VersaoSis
        $registryComp = @($compAchado.registry)
        $entradaSisComp = @($registryComp) | Where-Object { $_.NAME -eq "VERSAO_SIS" } | Select-Object -First 1
        if ($entradaSisComp -and $entradaSisComp.REGVALUE -and $versaoSisNovo -eq "-") {
            $versaoSisNovo = $entradaSisComp.REGVALUE
        }
        $pertenceZonaNovo = $cand.PertenceZonaAtual
        if ($script:RedeCompartilhada) {
            $pertenceZonaNovo = Test-HostnamePertenceZona -Hostname $hwComp.NAME -Zona $script:ZonaAtual
        }

        $copia = [PSCustomObject]@{
            IP                 = $cand.IP
            Online             = $cand.Online
            Hostname           = $hwComp.NAME
            TempoMs            = $cand.TempoMs
            PossivelImpressora = $cand.PossivelImpressora
            PortasAbertas      = $cand.PortasAbertas
            DetectadoPor       = "$($cand.DetectadoPor) (nome via OCS Inventory)"
            VncAtivo           = $cand.VncAtivo
            RcIvantiAtivo      = $cand.RcIvantiAtivo
            VersaoSis          = $versaoSisNovo
            Modelo             = $modeloNovo
            EhGateway          = $cand.EhGateway
            EhNobreakCentral   = $cand.EhNobreakCentral
            EhTelefoneVoip     = $cand.EhTelefoneVoip
            PertenceZonaAtual  = $pertenceZonaNovo
        }
        foreach ($sisExtra in $script:SistemasEleitoraisExtra) {
            $valorExtraNovo = $cand.($sisExtra.Propriedade)
            $entradaExtraComp = @($registryComp) | Where-Object { $_.NAME -eq $sisExtra.Chave } | Select-Object -First 1
            if ($entradaExtraComp -and $entradaExtraComp.REGVALUE -and $valorExtraNovo -eq "-") {
                $valorExtraNovo = $entradaExtraComp.REGVALUE
            }
            $copia | Add-Member -NotePropertyName $sisExtra.Propriedade -NotePropertyValue $valorExtraNovo
        }

        $script:Resultados[$indiceResultado] = $copia
        $corrigidos++
    }
    if ($corrigidos -gt 0) {
        Add-Log "$corrigidos hostname(s) resolvido(s) via OCS Inventory (por ultimo IP conhecido) - DNS reverso/NetBIOS nao encontraram esses." "Cyan"
    }

    # Nomes curtos (maiusculo) ja vistos online nesta varredura (agora
    # incluindo os que acabaram de ser resolvidos acima)
    $nomesOnline = @{}
    foreach ($r in $script:Resultados) {
        if ($r.Online -and $r.Hostname -and $r.Hostname -ne "(sem resolucao de nome)") {
            $nomesOnline[(($r.Hostname -split '\.')[0]).ToUpper()] = $true
        }
    }

    $script:MaquinasDesligadasOcs.Clear()
    $nomesJaAdicionados = @{}
    foreach ($comp in $comps) {
        $hw = $comp.hardware
        # Registro incompleto/orfao no proprio OCS (sem nome, sem IP) - as
        # vezes sobra quando uma maquina e reinstalada e o OCS cria um
        # cadastro novo sem mesclar o antigo. Nao da pra mostrar como
        # "possivelmente desligado" util (nada pra identificar a maquina),
        # entao pula.
        if (-not $hw -or -not $hw.NAME) { continue }
        $nomeOcs = $hw.NAME
        $nomeCurto = ($nomeOcs -split '\.')[0]

        # A busca por IP acha TODA maquina fisicamente naquela rede /24 -
        # numa rede COMPARTILHADA entre varias zonas (varios prédios tem
        # mais de uma zona no mesmo /24), isso inclui maquinas de OUTRAS
        # zonas do mesmo predio. So o padrao de nome (ZMA075 etc.) separa
        # qual maquina e desta zona especifica nesse caso - em rede NAO
        # compartilhada, o IP sozinho ja e exclusivo da zona, entao nao
        # precisa filtrar por nome.
        if ($script:RedeCompartilhada) {
            $nomeUpper = if ($nomeOcs) { $nomeOcs.ToUpper() } else { "" }
            $bateNome = $false
            foreach ($padrao in $padroes) {
                if ($nomeUpper.Contains($padrao)) { $bateNome = $true; break }
            }
            if (-not $bateNome) { continue }
        }

        if ($nomesOnline.ContainsKey($nomeCurto.ToUpper())) { continue }
        if ($nomesJaAdicionados.ContainsKey($nomeCurto.ToUpper())) { continue }   # inventario pode listar a mesma maquina mais de uma vez
        $nomesJaAdicionados[$nomeCurto.ToUpper()] = $true

        $bios = @($comp.bios) | Select-Object -First 1
        $modeloOriginal = if ($bios) { $bios.SMODEL } else { $null }

        $registry = @($comp.registry)
        $versaoSis = (@($registry) | Where-Object { $_.NAME -eq "VERSAO_SIS" } | Select-Object -First 1).REGVALUE

        $ultimoContatoBruto = if ($hw.LASTDATE) { $hw.LASTDATE } elseif ($hw.LASTCOME) { $hw.LASTCOME } else { $null }
        $ultimoContato = $null
        $candidatoExclusaoOcs = $false   # ultimo contato ha mais de X meses - possivel "lixo" pra revisar no OCS
        if ($ultimoContatoBruto) {
            $dataParseada = [DateTime]::MinValue
            if ([DateTime]::TryParseExact($ultimoContatoBruto, "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dataParseada)) {
                $ultimoContato = $dataParseada.ToString("dd/MM/yy HH:mm:ss")
                $candidatoExclusaoOcs = $dataParseada -lt (Get-Date).AddMonths(-$script:MesesParaCandidatoExclusaoOcs)
            } else {
                $ultimoContato = $ultimoContatoBruto   # formato inesperado - mostra cru em vez de esconder a informacao
            }
        }
        $detectadoPor = if ($ultimoContato) { "OCS Inventory - ultimo contato $ultimoContato" } else { "OCS Inventory (sem resposta na varredura)" }
        if ($candidatoExclusaoOcs) { $detectadoPor += " (candidata a exclusao - +$($script:MesesParaCandidatoExclusaoOcs)m sem contato)" }

        $pseudo = [PSCustomObject]@{
            IP                     = if ($hw.IPADDR) { $hw.IPADDR } else { "-" }
            Online                 = $false
            Hostname               = $nomeOcs
            TempoMs                = $null
            PossivelImpressora     = $false
            PortasAbertas          = ""
            DetectadoPor           = $detectadoPor
            VncAtivo               = $false
            RcIvantiAtivo          = $false
            VersaoSis              = if ($versaoSis) { $versaoSis } else { "-" }
            Modelo                 = if ($modeloOriginal) { Resolve-ModeloAmigavel -ModeloOriginal $modeloOriginal } else { "-" }
            EhGateway              = $false
            EhNobreakCentral       = $false
            EhTelefoneVoip         = $false
            PertenceZonaAtual      = if ($script:RedeCompartilhada) { Test-HostnamePertenceZona -Hostname $nomeOcs -Zona $zona } else { $true }
            PossivelmenteDesligado = $true
            HardwareId             = $hw.ID
            CandidatoExclusaoOcs   = $candidatoExclusaoOcs
            SemLinkComunicacao     = $false
        }
        foreach ($sis in $script:SistemasEleitoraisExtra) {
            $entradaExtra = @($registry) | Where-Object { $_.NAME -eq $sis.Chave } | Select-Object -First 1
            $valorExtra = if ($entradaExtra -and $entradaExtra.REGVALUE) { $entradaExtra.REGVALUE } else { "-" }
            $pseudo | Add-Member -NotePropertyName $sis.Propriedade -NotePropertyValue $valorExtra
        }

        $script:MaquinasDesligadasOcs.Add($pseudo)
    }

    Reconstruir-Grid
    $grid.Cursor = [System.Windows.Forms.Cursors]::Default
    $qtdCandidatas = @($script:MaquinasDesligadasOcs | Where-Object { $_.CandidatoExclusaoOcs }).Count
    Add-Log "=== $($script:MaquinasDesligadasOcs.Count) maquina(s) da Zona $zonaPad parecem desligadas/desconectadas (cadastradas no OCS, sem resposta na varredura) - $qtdCandidatas com mais de $($script:MesesParaCandidatoExclusaoOcs) meses sem contato ===" "OrangeRed"
}

# ============================================================
# EVENTOS: acoes de linha - VNC, RCViewer e Info Impressora por
# duplo-clique na linha (o botao dedicado na grade foi removido - essas
# acoes ficam so no menu de contexto e no duplo-clique).
# ============================================================
$grid.Add_CellDoubleClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0) { return }
    $linhaAtual = $grid.Rows[$e.RowIndex]
    $r = $linhaAtual.Tag
    if (-not $r) { return }

    if ($r.PossivelImpressora) {
        Invoke-AcaoInfoImpressora -Resultado $r -Row $linhaAtual
    } elseif ($r.VncAtivo) {
        Invoke-AcaoAbrirVnc -Resultado $r
    } elseif ($r.RcIvantiAtivo) {
        Invoke-AcaoAbrirRc -Resultado $r
    }
})

# ============================================================
# MENU DE CONTEXTO (clique direito): opcoes variam conforme o tipo do
# dispositivo na linha (Host/PC, Impressora, etc). Cada tipo novo de acao
# entra aqui, sem precisar de outro botao fixo na tela.
# ============================================================
$script:LinhaContextoAtual = $null

$grid.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Right) { return }
    $hit = $grid.HitTest($e.X, $e.Y)
    if ($hit.RowIndex -ge 0) {
        $grid.ClearSelection()
        $grid.Rows[$hit.RowIndex].Selected = $true
        $script:LinhaContextoAtual = $grid.Rows[$hit.RowIndex]
    } else {
        $script:LinhaContextoAtual = $null
    }
})

$menuContextoGrid = New-Object System.Windows.Forms.ContextMenuStrip
$menuContextoGrid.Add_Opening({
    param($sender, $e)
    $menuContextoGrid.Items.Clear()

    $linha = $script:LinhaContextoAtual
    $r = if ($linha) { $linha.Tag } else { $null }
    if (-not $r) { $e.Cancel = $true; return }

    $temNomeResolvido = $r.Hostname -and $r.Hostname -ne "(sem resolucao de nome)"
    $ehHostPc = $temNomeResolvido -and -not $r.PossivelImpressora -and -not $r.EhGateway -and -not $r.EhNobreakCentral -and -not $r.EhTelefoneVoip -and -not $r.PossivelmenteDesligado

    # Disponivel pra QUALQUER linha (inclusive "Possivelmente Desligado"
    # vindas do OCS) - util pra acompanhar em tempo real se um dispositivo
    # volta a responder, sem depender do tipo detectado.
    $itemPing = $menuContextoGrid.Items.Add("Ping")
    $itemPing.Add_Click({ Invoke-AcaoPingContinuo -Resultado $r }.GetNewClosure())
    $temOutrosItens = $r.PossivelImpressora -or $ehHostPc -or ($r.PossivelmenteDesligado -and $r.HardwareId)
    if ($temOutrosItens) { [void]$menuContextoGrid.Items.Add("-") }

    if ($r.PossivelImpressora) {
        $itemInfo = $menuContextoGrid.Items.Add("Info Impressora")
        $itemInfo.Add_Click({ Invoke-AcaoInfoImpressora -Resultado $r -Row $linha }.GetNewClosure())
    } elseif ($ehHostPc) {
        if ($r.VncAtivo) {
            $itemVnc = $menuContextoGrid.Items.Add("Abrir VNC")
            $itemVnc.Add_Click({ Invoke-AcaoAbrirVnc -Resultado $r }.GetNewClosure())
        }
        if ($r.RcIvantiAtivo) {
            $itemRc = $menuContextoGrid.Items.Add("Abrir RCViewer")
            $itemRc.Add_Click({ Invoke-AcaoAbrirRc -Resultado $r }.GetNewClosure())
        }
        # So faz sentido oferecer o envio do CVC se a maquina tem SIS
        # instalado - sem SIS, nao ha CVC gerado no InstSeg\CVC pra achar.
        $temSis = $r.VersaoSis -and $r.VersaoSis -ne "-"
        if ($temSis) {
            $itemCvc = $menuContextoGrid.Items.Add("Enviar CVC para o Google Drive...")
            $itemCvc.Add_Click({ Invoke-AcaoEnviarCvcDrive -Resultado $r }.GetNewClosure())
        }
        # Janela consolidada (status de versao + pacotes de instalacao) -
        # so aparece se a planilha de Pacotes de Sistemas estiver
        # configurada e tiver pelo menos 1 linha valida (ver
        # Configuracoes > Pacotes de Sistemas) OU a maquina tiver SIS
        # instalado (mesmo sem pacote configurado ainda, da pra ver o
        # status de versao dos sistemas eleitorais).
        if ($script:TabelaPacotes.Count -gt 0 -or $temSis) {
            $itemSistemas = $menuContextoGrid.Items.Add("Sistemas Eleitorais...")
            $itemSistemas.Add_Click({ Show-JanelaSistemasEleitorais -Resultado $r }.GetNewClosure())
        }
        [void]$menuContextoGrid.Items.Add("-")
        # Reconsulta so esta maquina (VNC/RC/SIS/etc.) e atualiza a linha
        # no lugar - util quando algo mudou no computador (ex: usuario
        # acabou de habilitar o VNC) e nao vale a pena rodar a varredura
        # da zona inteira de novo so pra ver isso refletido.
        $itemAtualizarHost = $menuContextoGrid.Items.Add("Atualizar Status desta Maquina")
        $itemAtualizarHost.Add_Click({ Invoke-AcaoAtualizarHost -Resultado $r }.GetNewClosure())
    } elseif ($r.PossivelmenteDesligado -and $r.HardwareId) {
        $itemWol = $menuContextoGrid.Items.Add("Ligar Computador (Wake-on-LAN)")
        $itemWol.Add_Click({ Invoke-AcaoLigarWol -Resultado $r }.GetNewClosure())

        $itemAbrirExclusao = $menuContextoGrid.Items.Add("Abrir para Excluir no OCS Inventory...")
        $itemAbrirExclusao.Add_Click({ Invoke-AcaoAbrirExclusaoOcs -Resultado $r }.GetNewClosure())
    }

    if ($menuContextoGrid.Items.Count -eq 0) { $e.Cancel = $true }
})
$grid.ContextMenuStrip = $menuContextoGrid

$btnFechar.Add_Click({ $form.Close() })

$form.Add_FormClosing({
    if ($script:Escaneando) {
        $timer.Stop()
        foreach ($job in $script:Jobs) { try { $job.Pipe.Stop(); $job.Pipe.Dispose() } catch {} }
        if ($script:Pool) { try { $script:Pool.Close(); $script:Pool.Dispose() } catch {} }
    }
})

# ============================================================
# INICIALIZACAO: carrega a planilha de zonas (Sede, Rede Padrao,
# Substituta, Observacao) antes de exibir a janela
# ============================================================
Add-Log "Carregando planilha de zonas eleitorais..." "Gray"
$okZonasInicial = Import-TabelaZonas
if ($okZonasInicial) {
    $qtdSubstitutas = @($script:TabelaZonas.Values | Where-Object { $_.Substituta }).Count
    Add-Log "$($script:TabelaZonas.Count) zona(s) carregada(s). $qtdSubstitutas com rede substituta ativa." "Cyan"
    Atualizar-MaximoZona
}
Update-LabelSedeInfo

# Planilha de sistemas eleitorais (versoes + pacotes) e opcional - so tenta
# carregar (e so loga) se ja tiver sido configurada alguma vez (ver
# "Configuracoes > Versoes de Sistemas"); sem isso a ferramenta segue
# mostrando a versao crua e sem menu de pacotes, normal.
if (Get-ConfigVersoes) {
    if (Import-TabelaVersoes) {
        Add-Log "Planilha de sistemas eleitorais carregada ($($script:TabelaVersoes.Count) mapeamento(s) de versao, $($script:TabelaPacotes.Count) pacote(s))." "Gray"
    }
}

[void]$form.ShowDialog()
