<#
    VisaoAcoesLocais.psm1

    Acoes disparadas do menu de contexto da grade principal que rodam
    DIRETO NA ESTACAO DO TECNICO: lancar visualizador VNC/RC Ivanti
    apontado pro IP, e abrir um "ping -t" continuo numa janela separada.
    Nenhuma delas passa pelo POLICY-SERVER - sao processos LOCAIS (o
    visualizador roda na propria maquina do tecnico, conectando direto
    na maquina de zona) ou nem tocam rede nenhuma (o ping continuo e so
    uma janela de cmd.exe local).

    Relocado do ScannerRedeZona.ps1 original com uma simplificacao real:
    o original rodava auto-elevado (UAC RunAs no topo do script) e por
    isso precisava de Start-ProcessoNaoElevado (via Shell.Application
    COM, ver comentario historico no original) pra o VNC/RC nao herdar
    elevacao e falhar silenciosamente. O VisaoCliente.ps1 novo NAO se
    autoeleva (nao faz mais sentido - varredura/robocopy/etc rodam no
    servidor ou usam permissao normal de usuario dominio) - Start-Process
    comum ja lanca sem elevacao nenhuma, entao essa complicacao nao e
    mais necessaria aqui.
#>

$script:VncViewerPath = $null
$script:RcViewerPath  = $null
$script:ArquivoConfigVnc = Join-Path $PSScriptRoot "vnc_config.txt"
$script:ArquivoConfigRc  = Join-Path $PSScriptRoot "rcviewer_config.txt"

function Get-CaminhoVncViewer {
    <#
        Devolve o caminho do vncviewer.exe: cache em memoria, senao
        arquivo de config local, senao tenta os caminhos padrao de
        instalacao mais comuns (UltraVNC/TightVNC/RealVNC/TigerVNC),
        senao pede pro usuario localizar via OpenFileDialog (e salva pra
        nao perguntar de novo). Devolve $null se o usuario cancelar.
    #>
    if ($script:VncViewerPath -and (Test-Path $script:VncViewerPath)) { return $script:VncViewerPath }

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
            return $script:VncViewerPath
        }
    }

    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title = "Localizar vncviewer.exe"
    $ofd.Filter = "Executavel (*.exe)|*.exe"
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:VncViewerPath = $ofd.FileName
        Set-Content -Path $script:ArquivoConfigVnc -Value $ofd.FileName -Encoding UTF8
        return $script:VncViewerPath
    }
    return $null
}

function Get-CaminhoRcViewer {
    if ($script:RcViewerPath -and (Test-Path $script:RcViewerPath)) { return $script:RcViewerPath }

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
            return $script:RcViewerPath
        }
    }

    $ofd = New-Object System.Windows.Forms.OpenFileDialog
    $ofd.Title = "Localizar RCViewer.exe"
    $ofd.Filter = "Executavel (*.exe)|*.exe"
    if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:RcViewerPath = $ofd.FileName
        Set-Content -Path $script:ArquivoConfigRc -Value $ofd.FileName -Encoding UTF8
        return $script:RcViewerPath
    }
    return $null
}

function Open-VncViewer {
    <#
        Abre o vncviewer.exe local ja apontado pro IP - conecta direto
        (o vncviewer aceita o IP como argumento de linha de comando).
        Devolve [PSCustomObject]@{ Sucesso; Mensagem }.
    #>
    param([Parameter(Mandatory)][string]$IP)

    $caminho = Get-CaminhoVncViewer
    if (-not $caminho) {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = "VNC Viewer nao configurado." }
    }
    try {
        Start-Process -FilePath $caminho -ArgumentList $IP
        return [PSCustomObject]@{ Sucesso = $true; Mensagem = "Abrindo VNC Viewer para $IP..." }
    } catch {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = "Falha ao abrir o VNC Viewer para ${IP}: $($_.Exception.Message)" }
    }
}

function Open-RcViewer {
    <#
        O RCViewer.exe moderno da Ivanti exige login interativo no
        Nucleo (nao ha switch de linha de comando confiavel pra conectar
        direto num IP, diferente do vncviewer.exe) - abre o RCViewer e
        copia o IP pra area de transferencia, pra colar na busca de
        dispositivo depois de logar.
    #>
    param([Parameter(Mandatory)][string]$IP)

    $caminho = Get-CaminhoRcViewer
    if (-not $caminho) {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = "RCViewer nao configurado." }
    }
    try {
        Start-Process -FilePath $caminho
        [System.Windows.Forms.Clipboard]::SetText($IP)
        return [PSCustomObject]@{ Sucesso = $true; Mensagem = "Abrindo RCViewer. IP $IP copiado pra area de transferencia - cole na busca de dispositivo apos logar." }
    } catch {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = "Falha ao abrir o RCViewer: $($_.Exception.Message)" }
    }
}

function Start-PingContinuo {
    <#
        Abre um "ping -t" continuo pro IP numa janela de cmd separada -
        util pra acompanhar em tempo real quando uma maquina volta a
        responder, sem precisar rodar a varredura da zona inteira de
        novo.
    #>
    param([Parameter(Mandatory)][string]$IP)
    Start-Process -FilePath "cmd.exe" -ArgumentList "/k title Ping continuo - $IP & ping $IP -t"
}

# ============================================================
# INFO DE IMPRESSORA (console web Pantum + SNMP)
# ============================================================
# Relocado do ScannerRedeZona.ps1 original. Acao disparada da grade
# principal (duplo-clique / menu de contexto) sobre uma linha detectada
# como possivel impressora durante a varredura. As consultas (HTTP ao
# console web embutido, UDP/SNMP na porta 161) vao direto da estacao do
# tecnico para o IP de zona - nao ha autenticacao Windows nem duplo-salto
# Kerberos envolvido aqui (SNMP community string e HTTP anonimo), mas o
# padrao de arquitetura e o mesmo das outras acoes deste modulo: e uma
# acao "aponta pro IP e conecta direto", que faz mais sentido rodar local
# do que ser mais uma chamada ao POLICY-SERVER.
#
# Diferenca em relacao ao original: nenhuma funcao aqui chama Add-Log (so
# existe na janela principal). Onde o Add-Log carregava diagnostico util
# (ex: motivo de uma falha HTTP), o texto foi movido para um campo
# "Avisos" (array de string) no objeto de retorno da funcao mais proxima -
# quem chamar decide se/como exibir. O parametro $Row (referencia direta
# de celula do DataGridView da janela principal) tambem foi removido de
# Invoke-AcaoInfoImpressora: em vez de atualizar a grade in-place, a
# funcao devolve um resultado estruturado (Sucesso/EhPantum/Info/Avisos) e
# quem chamar decide se atualiza a coluna "Tipo".

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
        (X-Requested-With, Referer). Os detalhes de diagnostico (status HTTP,
        mensagem de erro, inicio da resposta) vao no campo Avisos do retorno,
        caso ainda falhe.

        Devolve sempre um objeto (nunca $null): { Sucesso; Url; Campos;
        Bruto; Avisos }. Campos e um [ordered]@{} - pode vir vazio quando
        Sucesso = $false.
    #>
    param([string]$IP, [int]$TimeoutSec = 5)

    $urlIndex = "http://$IP/index.html"
    $urlPrefs = "http://$IP/omDB.shtml?PRINT"
    $avisos = New-Object System.Collections.Generic.List[string]

    try {
        Invoke-WebRequest -Uri $urlIndex -TimeoutSec $TimeoutSec -UseBasicParsing -SessionVariable sessaoWeb | Out-Null
    } catch {
        $avisos.Add("Falha ao carregar $urlIndex (para estabelecer sessao): $($_.Exception.Message)")
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
        $avisos.Add("Falha ao buscar ${urlPrefs}: $($_.Exception.Message) (HTTP status: $statusCode)")
        return [PSCustomObject]@{ Sucesso = $false; Url = $urlPrefs; Campos = [ordered]@{}; Bruto = $null; Avisos = $avisos.ToArray() }
    }

    if (-not $resp.Content -or -not $resp.Content.Trim()) {
        $avisos.Add("$urlPrefs respondeu vazio (StatusCode: $($resp.StatusCode)).")
        return [PSCustomObject]@{ Sucesso = $false; Url = $urlPrefs; Campos = [ordered]@{}; Bruto = $resp.Content; Avisos = $avisos.ToArray() }
    }

    $avisos.Add("$urlPrefs respondeu StatusCode $($resp.StatusCode), $($resp.Content.Length) caractere(s).")

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
        $avisos.Add("Resposta sem padrao 'new OM(...)' reconhecido. Inicio da resposta: $trecho")
        return [PSCustomObject]@{ Sucesso = $false; Url = $urlPrefs; Campos = $campos; Bruto = $resp.Content; Avisos = $avisos.ToArray() }
    }

    return [PSCustomObject]@{ Sucesso = $true; Url = $urlPrefs; Campos = $campos; Bruto = $resp.Content; Avisos = $avisos.ToArray() }
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
#
# Funcoes puramente internas deste bloco (montagem/leitura BER, envio UDP) -
# nao sao exportadas do modulo, so Get-InfoImpressoraSNMP usa diretamente.

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

function Show-InfoImpressora {
    <#
        Janela de dialogo (WinForms) que exibe as informacoes coletadas por
        Get-InfoImpressoraSNMP ou Get-InfoImpressoraPantum (com fallback de
        console web). Nao depende de nenhuma variavel $script: compartilhada
        com a janela principal - $Info chega inteiro via parametro.

        So tem dois controles interativos (botao "Abrir Console Web" e botao
        "Fechar"), e nenhum dos dois reatribui uma variavel que o outro
        precise ler - so capturam $IP/$dlg (leitura) via .GetNewClosure().
        Por isso NAO se aplica aqui o cuidado documentado no VisaoCliente.ps1
        sobre GetNewClosure() + variaveis $script: escalares nao se
        propagando entre closures: esse bug e sobre REATRIBUICAO de estado
        compartilhado, que nao acontece nesta tela.
    #>
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
    $dlg.Text = "Visao - Informacoes da Impressora - $IP  (via $fonte)"
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
    $btnAbrirWeb.Add_Click({ Start-Process -FilePath "http://$IP/" }.GetNewClosure())
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

function Invoke-AcaoInfoImpressora {
    <#
        Orquestra a coleta de informacoes de uma impressora (tenta SNMP,
        cai para console web se SNMP nao responder, confirma o fabricante
        Pantum, busca preferencias de impressao) e abre a janela
        Show-InfoImpressora com o resultado.

        No original, esta funcao rodava dentro da janela principal, recebia
        $Row (referencia direta de celula do DataGridView) para atualizar a
        coluna "Tipo" da grade in-place quando confirmava Pantum, e logava
        cada etapa com Add-Log. Aqui isso nao existe: a funcao devolve um
        objeto estruturado (Sucesso/EhPantum/Info/Avisos) e quem chamar (a
        janela principal, numa fase futura ainda nao escrita) decide se
        atualiza a celula "Tipo" a partir de EhPantum, e se/como exibe os
        Avisos.

        $Community: comunidade SNMP (o original usava $script:SnmpCommunity,
        configuravel numa tela de configuracoes da janela principal - aqui
        vira parametro, com o mesmo padrao "public" usado nas impressoras
        Pantum do TRE-MA).
    #>
    param(
        [Parameter(Mandatory)]$Resultado,
        [string]$Community = "public"
    )

    $avisos = New-Object System.Collections.Generic.List[string]

    if (-not $Resultado -or -not $Resultado.PossivelImpressora) {
        return [PSCustomObject]@{ Sucesso = $false; EhPantum = $false; Info = $null; Avisos = $avisos.ToArray() }
    }

    $avisos.Add("Consultando impressora $($Resultado.IP) via SNMP...")
    $info = Get-InfoImpressoraSNMP -IP $Resultado.IP -Community $Community -TimeoutMs 1200

    if (-not $info) {
        $avisos.Add("SNMP nao respondeu em $($Resultado.IP), tentando console web...")
        $info = Get-InfoImpressoraPantum -IP $Resultado.IP
    }

    $ehPantum = $false
    if ($info) {
        $avisos.Add("Confirmando fabricante de $($Resultado.IP)...")
        $ehPantum = Test-EhImpressoraPantum -IP $Resultado.IP
        if ($ehPantum) {
            $avisos.Add("Confirmado: $($Resultado.IP) e uma impressora Pantum.")
        } else {
            $avisos.Add("Nao foi possivel confirmar a marca Pantum em $($Resultado.IP).")
        }

        $avisos.Add("Buscando preferencias de impressao de $($Resultado.IP)...")
        $prefs = Get-PreferenciasImpressaoPantum -IP $Resultado.IP
        if ($prefs.Sucesso -and $prefs.Campos.Count -gt 0) {
            $info | Add-Member -NotePropertyName Preferencias -NotePropertyValue $prefs -Force
            $avisos.Add("Preferencias obtidas de $($prefs.Url): $($prefs.Campos.Count) campo(s).")
        } else {
            $avisos.Add("Nao foi possivel buscar preferencias de impressao de $($Resultado.IP).")
        }
        foreach ($a in $prefs.Avisos) { $avisos.Add("[Preferencias] $a") }
    }

    if ($info) {
        $fonte = if ($info.PSObject.Properties.Name -contains "Fonte") { $info.Fonte } else { "Console Web" }
        $avisos.Add("Info obtida de $($Resultado.IP) via ${fonte}: $($info.ProductName) - Status: $($info.PrinterStatus)")
        Show-InfoImpressora -IP $Resultado.IP -Info $info
        return [PSCustomObject]@{ Sucesso = $true; EhPantum = $ehPantum; Info = $info; Avisos = $avisos.ToArray() }
    } else {
        $avisos.Add("[ERRO] Nao foi possivel ler informacoes de $($Resultado.IP) via SNMP nem console web.")
        $resp = [System.Windows.Forms.MessageBox]::Show("Nao foi possivel ler as informacoes automaticamente (nem SNMP, nem console web).`r`nDeseja abrir o console web no navegador para conferir manualmente?", "Aviso", "YesNo", "Warning")
        if ($resp -eq [System.Windows.Forms.DialogResult]::Yes) {
            Start-Process -FilePath "http://$($Resultado.IP)/"
        }
        return [PSCustomObject]@{ Sucesso = $false; EhPantum = $false; Info = $null; Avisos = $avisos.ToArray() }
    }
}

# ============================================================
# OCS INVENTORY: abrir tela de remocao no navegador
# ============================================================
$script:UrlOcsWebConsole = "https://inventario.tre-ma.jus.br/ocsreports"

function Open-ExclusaoOcs {
    <#
        A API REST do OCS so suporta GET (nao ha como excluir por ali) -
        em vez disso, abre direto no navegador a tela "Remocao de
        Computadores" do console web do OCS, ja com esta maquina marcada
        (mesma URL que o proprio OCS usa quando voce seleciona um
        computador e clica em "Apagar" na listagem). Falta so um clique
        manual no botao "Apagar" daquela tela pra confirmar.
    #>
    param([Parameter(Mandatory)][int]$HardwareId)

    $url = "$($script:UrlOcsWebConsole)/index.php?function=sup_search&head=1&idchecked=$HardwareId&comp=1"
    try {
        Start-Process -FilePath $url
        return [PSCustomObject]@{ Sucesso = $true; Mensagem = "Abrindo tela de remocao do OCS Inventory - clique em 'Apagar' na pagina que abrir para confirmar." }
    } catch {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = "Falha ao abrir o navegador: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function Get-CaminhoVncViewer, Get-CaminhoRcViewer, Open-VncViewer, Open-RcViewer, Start-PingContinuo, `
    Get-InfoImpressoraPantum, Get-PreferenciasImpressaoPantum, Get-InfoImpressoraSNMP, Test-EhImpressoraPantum, `
    Show-InfoImpressora, Invoke-AcaoInfoImpressora, Open-ExclusaoOcs
