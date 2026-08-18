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
# entrada aqui vira automaticamente uma coluna na grade e e resolvida durante
# a propria varredura (dentro do $scriptBlock por IP).
$script:SistemasEleitoraisExtra = @(
    [PSCustomObject]@{ Chave = "BITLOCKER"; Propriedade = "VersaoBitlocker"; Coluna = "Bitlocker"; Titulo = "BitLocker"; Largura = 90 }
    [PSCustomObject]@{ Chave = "GEDAI";     Propriedade = "VersaoGedai";     Coluna = "Gedai";     Titulo = "GEDAI";     Largura = 80 }
    [PSCustomObject]@{ Chave = "HOLOCRON";  Propriedade = "VersaoHolocron";  Coluna = "Holocron";  Titulo = "Holocron";  Largura = 90 }
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
                $nomeCurto = ($resultado.Hostname -split '\.')[0]
                foreach ($chaveParam in @("NAME", "name")) {
                    try {
                        $urlBusca = "$urlOcsApiBase/computers/search?start=0&limit=5&$chaveParam=$nomeCurto"
                        $respBusca = Invoke-RestMethod -Uri $urlBusca -TimeoutSec 5
                        if (@($respBusca).Count -gt 0) {
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
$btnGerenciarZonas.Text = "Gerenciar Zonas..."
$btnGerenciarZonas.Location = New-Object System.Drawing.Point(825, 43)
$btnGerenciarZonas.Width = 105
$btnGerenciarZonas.Height = 24
$form.Controls.Add($btnGerenciarZonas)

$numZona.Add_ValueChanged({ Update-LabelSedeInfo })
$btnGerenciarZonas.Add_Click({ Show-GerenciarZonas })

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
foreach ($sis in $script:SistemasEleitoraisExtra) {
    Add-ColunaGrid $sis.Coluna $sis.Titulo $sis.Largura
}

$colBotao = New-Object System.Windows.Forms.DataGridViewButtonColumn
$colBotao.Name = "AbrirVnc"
$colBotao.HeaderText = ""
$colBotao.Text = "Abrir VNC"
$colBotao.UseColumnTextForButtonValue = $true
$colBotao.Width = 95
[void]$grid.Columns.Add($colBotao)

$colBotaoRc = New-Object System.Windows.Forms.DataGridViewButtonColumn
$colBotaoRc.Name = "AbrirRc"
$colBotaoRc.HeaderText = ""
$colBotaoRc.Text = "Abrir RCViewer"
$colBotaoRc.UseColumnTextForButtonValue = $true
$colBotaoRc.Width = 110
[void]$grid.Columns.Add($colBotaoRc)

$colBotaoInfo = New-Object System.Windows.Forms.DataGridViewButtonColumn
$colBotaoInfo.Name = "InfoImpressora"
$colBotaoInfo.HeaderText = ""
$colBotaoInfo.Text = "Info Impressora"
$colBotaoInfo.UseColumnTextForButtonValue = $true
$colBotaoInfo.Width = 110
[void]$grid.Columns.Add($colBotaoInfo)

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

function Get-OcsComputadoresDaZona {
    <#
        Enumera as maquinas de uma zona percorrendo TODO o inventario do
        OCS, ja que /computers/search?NAME=... so aceita nome EXATO
        (confirmado na pratica: nem prefixo nem coringa "%" embutido
        funcionam - devolve 0 pra qualquer coisa que nao seja o nome
        completo certinho).

        /computers (sem "/search") se comportou diferente: SEM nenhum
        filtro de nome, ele pagina o inventario INTEIRO via start/limit e
        devolve o registro COMPLETO de cada maquina (hardware + bios +
        registry, igual ao que /computer/:id/bios e /computer/:id/registry
        dariam separados). Entao aqui a gente pagina esse endpoint e filtra
        pelo nome (hardware.NAME) no proprio script, com o mesmo padrao de
        prefixo de zona usado no resto da ferramenta (Test-HostnamePertenceZona).

        Cada pagina e "pesada" (registro completo, com impressoras/discos/
        placas de rede etc. de cada maquina) e o servidor tem uns 2000+
        maquinas cadastradas no total - buscando pagina por pagina, uma de
        cada vez, isso demorava bastante (14 idas-e-voltas sequenciais na
        pratica). Como o gargalo e rede/round-trip (nao processamento local),
        buscamos varias paginas em paralelo usando o mesmo RunspacePool do
        scan de IP - um lote de $Paralelismo paginas por vez. Ao final de
        cada lote, se alguma pagina do lote veio incompleta (menos que
        $TamanhoPagina itens) ou deu erro, paramos de disparar novos lotes -
        pode sobrar 1-2 chamadas "a mais" perto do fim (paginas que ja
        passaram do total), o que e barato comparado ao ganho de tempo.

        $PrefixoRede (opcional, ex: "10.198.54.") tambem inclui no resultado
        qualquer maquina cujo ULTIMO IP CONHECIDO (hardware.IPADDR) comece
        com esse prefixo, mesmo que o nome nao bata com nenhum padrao -
        usado para resolver hostname pelo IP de hosts que responderam a
        varredura mas nao tem DNS reverso/NetBIOS funcionando.
    #>
    param([string[]]$Padroes, [string]$PrefixoRede = $null, [int]$TamanhoPagina = 150, [int]$TimeoutSec = 30, [int]$MaxPaginas = 40, [int]$Paralelismo = 5)

    $scriptBlockPagina = {
        param($UrlBase, $Start, $Limite, $TimeoutSec)
        try {
            $resp = Invoke-RestMethod -Uri "$UrlBase/computers?start=$Start&limit=$Limite" -TimeoutSec $TimeoutSec
            $itens = @($resp.PSObject.Properties) | ForEach-Object { $_.Value }
            return [PSCustomObject]@{ Start = $Start; Itens = $itens; Erro = $null }
        } catch {
            return [PSCustomObject]@{ Start = $Start; Itens = @(); Erro = $_.Exception.Message }
        }
    }

    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $poolPaginas = [runspacefactory]::CreateRunspacePool(1, $Paralelismo, $sessionState, $Host)
    $poolPaginas.Open()

    $encontrados = New-Object System.Collections.Generic.List[object]
    try {
        $proximoStart = 0
        $paginasDisparadas = 0
        $terminou = $false

        while (-not $terminou -and $paginasDisparadas -lt $MaxPaginas) {
            $lote = New-Object System.Collections.Generic.List[object]
            for ($i = 0; $i -lt $Paralelismo -and $paginasDisparadas -lt $MaxPaginas; $i++) {
                $ps = [powershell]::Create()
                $ps.RunspacePool = $poolPaginas
                [void]$ps.AddScript($scriptBlockPagina).AddArgument($script:UrlOcsApiBase).AddArgument($proximoStart).AddArgument($TamanhoPagina).AddArgument($TimeoutSec)
                $lote.Add([PSCustomObject]@{ Pipe = $ps; Handle = $ps.BeginInvoke(); Start = $proximoStart })
                $proximoStart += $TamanhoPagina
                $paginasDisparadas++
            }

            Add-Log "[DEBUG OCS] Buscando lote de $($lote.Count) pagina(s) em paralelo (registros a partir de $($lote[0].Start))..." "Gray"

            # Espera o lote terminar SEM travar a interface: esta funcao roda
            # sincrona, direto no evento de conclusao da varredura (thread da
            # UI) - um EndInvoke() direto bloqueia ali parado, sem bombear as
            # mensagens do Windows Forms, entao a janela fica sem repintar (e
            # o log parece "pular" tudo de uma vez so quando volta a
            # responder). O DoEvents() aqui mantem a tela viva enquanto
            # espera, igual o timer da varredura de IP ja faz via polling.
            while ($lote | Where-Object { -not $_.Handle.IsCompleted }) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 30
            }

            $resultadosLote = foreach ($job in $lote) {
                $r = $job.Pipe.EndInvoke($job.Handle)
                $job.Pipe.Dispose()
                $r
            }

            foreach ($r in ($resultadosLote | Sort-Object Start)) {
                if ($r.Erro) {
                    Add-Log "[DEBUG OCS] Erro ao paginar inventario (start=$($r.Start)): $($r.Erro)" "OrangeRed"
                    $terminou = $true
                    continue
                }

                foreach ($comp in $r.Itens) {
                    $hw = $comp.hardware
                    if (-not $hw -or -not $hw.NAME) { continue }
                    $nomeUpper = $hw.NAME.ToUpper()
                    $bateNome = $false
                    foreach ($padrao in $Padroes) {
                        if ($nomeUpper.Contains($padrao)) { $bateNome = $true; break }
                    }
                    $bateIp = $PrefixoRede -and $hw.IPADDR -and $hw.IPADDR.StartsWith($PrefixoRede)
                    if ($bateNome -or $bateIp) { $encontrados.Add($comp) }
                }

                if ($r.Itens.Count -lt $TamanhoPagina) { $terminou = $true }
            }
        }
    } finally {
        $poolPaginas.Close()
        $poolPaginas.Dispose()
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
        if ($Resultado.PossivelmenteDesligado -and $Resultado.CandidatoExclusaoOcs) { "Desligado - candidata a exclusao" }
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
    $sisTxt = if ($Resultado.VersaoSis) { $Resultado.VersaoSis } else { "-" }
    $modeloTxt = if ($Resultado.Modelo) { $Resultado.Modelo } else { "-" }

    $valoresLinha = @($Resultado.IP, $tipo, $Resultado.Hostname, $modeloTxt, $tempoTxt, $Resultado.DetectadoPor, $vncTxt, $rcTxt, $sisTxt)
    foreach ($sis in $script:SistemasEleitoraisExtra) {
        $valorExtra = $Resultado.($sis.Propriedade)
        $valoresLinha += $(if ($valorExtra) { $valorExtra } else { "-" })
    }
    $valoresLinha += @("", "", "")

    $rowIndex = $grid.Rows.Add($valoresLinha)
    $row = $grid.Rows[$rowIndex]
    $row.Tag = $Resultado

    if ($Resultado.PossivelmenteDesligado -and $Resultado.CandidatoExclusaoOcs) {
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

    # Os botoes "Abrir VNC" / "Abrir RCViewer" / "Info Impressora" so fazem
    # sentido nas linhas correspondentes. Nos demais casos, trocamos a
    # celula (que por padrao e um botao, pois a coluna inteira e
    # DataGridViewButtonColumn) por uma celula de texto vazia, entao a
    # linha nao mostra botao nenhum ali.
    $vncDisponivel = $Resultado.VncAtivo -and -not $Resultado.PossivelImpressora
    if ($vncDisponivel) {
        $row.Cells["AbrirVnc"].Value = "Abrir VNC"
        $row.Cells["Vnc"].Style.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
        $row.Cells["Vnc"].Style.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
    } else {
        $celulaSemBotao = New-Object System.Windows.Forms.DataGridViewTextBoxCell
        $celulaSemBotao.Value = ""
        $row.Cells["AbrirVnc"] = $celulaSemBotao
    }

    $rcDisponivel = $Resultado.RcIvantiAtivo -and -not $Resultado.PossivelImpressora
    if ($rcDisponivel) {
        $row.Cells["AbrirRc"].Value = "Abrir RCViewer"
        $row.Cells["Rc"].Style.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
        $row.Cells["Rc"].Style.Font = New-Object System.Drawing.Font($grid.Font, [System.Drawing.FontStyle]::Bold)
    } else {
        $celulaSemBotaoRc = New-Object System.Windows.Forms.DataGridViewTextBoxCell
        $celulaSemBotaoRc.Value = ""
        $row.Cells["AbrirRc"] = $celulaSemBotaoRc
    }

    if ($Resultado.PossivelImpressora) {
        $row.Cells["InfoImpressora"].Value = "Info Impressora"
    } else {
        $celulaSemBotaoInfo = New-Object System.Windows.Forms.DataGridViewTextBoxCell
        $celulaSemBotaoInfo.Value = ""
        $row.Cells["InfoImpressora"] = $celulaSemBotaoInfo
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
        if (-not $script:RedeCompartilhada -or -not $chkFiltrarZona.Checked -or $r.PertenceZonaAtual) {
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
                    # As convencoes ".70 = gateway", ".10/.11 = nobreak central" e
                    # ".190-.195 = telefone VOIP" valem so para o padrao de rede do
                    # interior (10.198.zona.X), onde cada zona segue um layout
                    # padronizado. Na rede compartilhada de Sao Luis (10.11.81.X),
                    # esses mesmos finais de IP podem ser qualquer coisa de
                    # qualquer zona, entao essas regras nao se aplicam la.
                    $ultimoOcteto = [int]($resultado.IP -split '\.')[3]
                    $ehGateway = (-not $script:RedeCompartilhada) -and $resultado.IP.EndsWith(".70")
                    $ehNobreakCentral = (-not $script:RedeCompartilhada) -and ($ultimoOcteto -eq 10 -or $ultimoOcteto -eq 11)
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

                    if (-not $script:RedeCompartilhada -or -not $chkFiltrarZona.Checked -or $resultado.PertenceZonaAtual) {
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

        $btnIniciar.Enabled = $true
        $btnCancelar.Enabled = $false
        $numZona.Enabled = $true
    }
})

# ============================================================
# EVENTO: Iniciar Varredura
# ============================================================
$btnIniciar.Add_Click({
    $zona = [int]$numZona.Value
    $resolucao = Resolve-RedeDaZona -Zona $zona
    $baseIP = $resolucao.Prefixo

    $script:ZonaAtual = $zona
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
    $dlg.Size = New-Object System.Drawing.Size(530, 440)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(12, 12)
    $tabs.Size = New-Object System.Drawing.Size(495, 335)
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

    # --- Botoes ---
    $btnSalvarConfig = New-Object System.Windows.Forms.Button
    $btnSalvarConfig.Text = "Salvar"
    $btnSalvarConfig.Location = New-Object System.Drawing.Point(320, 358)
    $btnSalvarConfig.Width = 90
    $btnSalvarConfig.Height = 30
    $btnSalvarConfig.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
    $btnSalvarConfig.ForeColor = [System.Drawing.Color]::White
    $dlg.Controls.Add($btnSalvarConfig)

    $btnFecharConfig = New-Object System.Windows.Forms.Button
    $btnFecharConfig.Text = "Fechar"
    $btnFecharConfig.Location = New-Object System.Drawing.Point(415, 358)
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

    Add-Log "=== Buscando no OCS Inventory maquinas da Zona $zonaPad que nao apareceram na varredura (paginando o inventario completo) ===" "Yellow"
    $grid.Cursor = [System.Windows.Forms.Cursors]::WaitCursor

    $comps = Get-OcsComputadoresDaZona -Padroes $padroes -PrefixoRede $resolucaoAtual.Prefixo
    Add-Log "$($comps.Count) maquina(s) da zona encontrada(s) no cadastro do OCS Inventory (por nome ou IP)." "Gray"

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
        $nomeOcs = $hw.NAME
        $nomeCurto = ($nomeOcs -split '\.')[0]
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
            PertenceZonaAtual      = $true
            PossivelmenteDesligado = $true
            HardwareId             = $hw.ID
            CandidatoExclusaoOcs   = $candidatoExclusaoOcs
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
# EVENTOS: acoes de linha - VNC e Info Impressora
# (clique no botao da coluna correspondente, ou duplo-clique na linha)
# ============================================================
$grid.Add_CellContentClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0) { return }
    $nomeColuna = $grid.Columns[$e.ColumnIndex].Name
    $linhaAtual = $grid.Rows[$e.RowIndex]
    $r = $linhaAtual.Tag

    if ($nomeColuna -eq "AbrirVnc") {
        Invoke-AcaoAbrirVnc -Resultado $r
    } elseif ($nomeColuna -eq "AbrirRc") {
        Invoke-AcaoAbrirRc -Resultado $r
    } elseif ($nomeColuna -eq "InfoImpressora") {
        Invoke-AcaoInfoImpressora -Resultado $r -Row $linhaAtual
    }
})

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
    } elseif ($r.PossivelmenteDesligado -and $r.HardwareId) {
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

[void]$form.ShowDialog()