Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
#  ConectarVNC-GUI.ps1
#  TRE-MA | SEASU/COINF/STIC
#
#  Verifica se uma maquina remota esta ligada e com o servico
#  VNC habilitado (porta TCP aberta), e permite abrir o
#  UltraVNC Viewer ja apontado para o IP informado.
#
#  Nao requer elevacao (checagem de rede + lancar um app de
#  usuario, nada disso precisa de admin).
# ============================================================

$scriptVersion = "1.0"
$ipPattern = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'

$configDir  = Join-Path $env:LOCALAPPDATA "TRE-MA-Manutencao"
$configFile = Join-Path $configDir "vncviewer_path.txt"

# ---------------------------------------------------------------
# Localiza / persiste o caminho do UltraVNC Viewer
# ---------------------------------------------------------------
function Salvar-CaminhoVNC {
    param([string]$Caminho)
    if (-not (Test-Path $configDir)) {
        New-Item -ItemType Directory -Path $configDir -Force | Out-Null
    }
    Set-Content -Path $configFile -Value $Caminho -Encoding UTF8
}

function Localizar-CaminhoVNC {
    $caminhosPadrao = @(
        "$env:ProgramFiles\UltraVNC\vncviewer.exe",
        "${env:ProgramFiles(x86)}\UltraVNC\vncviewer.exe",
        "$env:ProgramFiles\uvnc bvba\UltraVNC\vncviewer.exe",
        "${env:ProgramFiles(x86)}\uvnc bvba\UltraVNC\vncviewer.exe"
    )

    if (Test-Path $configFile) {
        $caminhoSalvo = Get-Content $configFile -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($caminhoSalvo -and (Test-Path $caminhoSalvo)) {
            return $caminhoSalvo
        }
    }

    foreach ($c in $caminhosPadrao) {
        if (Test-Path $c) {
            Salvar-CaminhoVNC -Caminho $c
            return $c
        }
    }

    return $null
}

$script:vncViewerPath = Localizar-CaminhoVNC

# ---------------------------------------------------------------
# Form principal
# ---------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Conectar VNC - TRE-MA (v$scriptVersion)"
$form.Size = New-Object System.Drawing.Size(710, 580)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::White

$lblIP = New-Object System.Windows.Forms.Label
$lblIP.Text = "IP da maquina remota:"
$lblIP.Location = New-Object System.Drawing.Point(20, 20)
$lblIP.Size = New-Object System.Drawing.Size(160, 20)
$lblIP.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.Controls.Add($lblIP)

$txtIP = New-Object System.Windows.Forms.TextBox
$txtIP.Location = New-Object System.Drawing.Point(180, 18)
$txtIP.Size = New-Object System.Drawing.Size(150, 25)
$txtIP.Font = New-Object System.Drawing.Font("Segoe UI", 11)
$txtIP.MaxLength = 15
$form.Controls.Add($txtIP)

$txtIP.Add_KeyPress({
    if (-not [char]::IsDigit($_.KeyChar) -and $_.KeyChar -ne '.' -and $_.KeyChar -ne [char]8) {
        $_.Handled = $true
    }
})

$lblPorta = New-Object System.Windows.Forms.Label
$lblPorta.Text = "Porta:"
$lblPorta.Location = New-Object System.Drawing.Point(345, 20)
$lblPorta.Size = New-Object System.Drawing.Size(45, 20)
$lblPorta.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.Controls.Add($lblPorta)

$txtPorta = New-Object System.Windows.Forms.TextBox
$txtPorta.Location = New-Object System.Drawing.Point(390, 18)
$txtPorta.Size = New-Object System.Drawing.Size(60, 25)
$txtPorta.Font = New-Object System.Drawing.Font("Segoe UI", 11)
$txtPorta.MaxLength = 5
$txtPorta.Text = "5900"
$form.Controls.Add($txtPorta)

$txtPorta.Add_KeyPress({
    if (-not [char]::IsDigit($_.KeyChar) -and $_.KeyChar -ne [char]8) {
        $_.Handled = $true
    }
})

$btnVerificar = New-Object System.Windows.Forms.Button
$btnVerificar.Text = "Verificar"
$btnVerificar.Location = New-Object System.Drawing.Point(465, 16)
$btnVerificar.Size = New-Object System.Drawing.Size(100, 28)
$btnVerificar.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnVerificar.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnVerificar.ForeColor = [System.Drawing.Color]::White
$btnVerificar.FlatStyle = "Flat"
$form.Controls.Add($btnVerificar)

$btnConectar = New-Object System.Windows.Forms.Button
$btnConectar.Text = "Conectar (UltraVNC)"
$btnConectar.Location = New-Object System.Drawing.Point(20, 55)
$btnConectar.Size = New-Object System.Drawing.Size(160, 28)
$btnConectar.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnConectar.BackColor = [System.Drawing.Color]::FromArgb(16, 124, 16)
$btnConectar.ForeColor = [System.Drawing.Color]::White
$btnConectar.FlatStyle = "Flat"
$form.Controls.Add($btnConectar)

$btnLocalizarVnc = New-Object System.Windows.Forms.Button
$btnLocalizarVnc.Text = "Localizar VNC..."
$btnLocalizarVnc.Location = New-Object System.Drawing.Point(190, 55)
$btnLocalizarVnc.Size = New-Object System.Drawing.Size(130, 28)
$btnLocalizarVnc.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($btnLocalizarVnc)

$btnCopiar = New-Object System.Windows.Forms.Button
$btnCopiar.Text = "Copiar Resultado"
$btnCopiar.Location = New-Object System.Drawing.Point(330, 55)
$btnCopiar.Size = New-Object System.Drawing.Size(120, 28)
$btnCopiar.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($btnCopiar)

$btnLimpar = New-Object System.Windows.Forms.Button
$btnLimpar.Text = "Limpar"
$btnLimpar.Location = New-Object System.Drawing.Point(460, 55)
$btnLimpar.Size = New-Object System.Drawing.Size(90, 28)
$btnLimpar.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($btnLimpar)

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Location = New-Object System.Drawing.Point(20, 95)
$rtbLog.Size = New-Object System.Drawing.Size(655, 440)
$rtbLog.Font = New-Object System.Drawing.Font("Consolas", 10)
$rtbLog.BackColor = [System.Drawing.Color]::Black
$rtbLog.ForeColor = [System.Drawing.Color]::White
$rtbLog.ReadOnly = $true
$rtbLog.Anchor = "Top, Bottom, Left, Right"
$form.Controls.Add($rtbLog)

# ---------------------------------------------------------------
# Log colorido no RichTextBox
# ---------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message = "",
        [string]$Color = "White"
    )
    $rtbLog.SelectionStart = $rtbLog.TextLength
    $rtbLog.SelectionLength = 0
    $rtbLog.SelectionColor = [System.Drawing.Color]::$Color
    $rtbLog.AppendText("$Message`r`n")
    $rtbLog.SelectionColor = $rtbLog.ForeColor
    $rtbLog.ScrollToCaret()
}

# ---------------------------------------------------------------
# Teste de porta TCP direto (sem depender de Test-NetConnection)
# ---------------------------------------------------------------
function Test-TcpPort {
    param(
        [string]$ComputerName,
        [int]$Port,
        [int]$TimeoutMs = 1500
    )
    $client = New-Object System.Net.Sockets.TcpClient
    try {
        $asyncResult = $client.BeginConnect($ComputerName, $Port, $null, $null)
        $sucesso = $asyncResult.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($sucesso -and $client.Connected) {
            $client.EndConnect($asyncResult)
            return $true
        }
        return $false
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

# ---------------------------------------------------------------
# Lanca um processo no contexto normal (nao-elevado) do usuario,
# mesmo que este script esteja rodando como Administrador.
# Usa o Shell.Application (mesmo mecanismo do Explorer), que roda
# em integridade media - o processo filho nao herda a elevacao.
# Resolve o caso em que uma ferramenta lancada de um terminal
# elevado nao consegue completar a conexao VNC, enquanto a mesma
# execucao feita manualmente (sessao normal) funciona.
# ---------------------------------------------------------------
function Start-ProcessoNaoElevado {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string]$Arguments = ""
    )
    $shell = New-Object -ComObject "Shell.Application"
    $shell.ShellExecute($FilePath, $Arguments, "", "open", 1)
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell)
}

# ---------------------------------------------------------------
# Verificacao completa (ping + porta)
# ---------------------------------------------------------------
function Executar-Verificacao {
    $ip = $txtIP.Text.Trim()
    if ($ip -notmatch $ipPattern) {
        Write-Log "[ERRO] Informe um endereco IP valido (ex: 192.168.1.10)." "Red"
        return
    }

    $porta = if ($txtPorta.Text.Trim() -match '^\d{1,5}$') { [int]$txtPorta.Text.Trim() } else { 5900 }

    $rtbLog.Clear()
    Write-Log "Verificando $ip (porta VNC $porta)..." "Cyan"
    Write-Log ""

    Write-Log "Testando ping (ICMP)..." "Gray"
    $pingResult = Test-Connection -ComputerName $ip -Count 2 -ErrorAction SilentlyContinue
    $pingOk = $false
    if ($pingResult) {
        $pingOk = $true
        $mediaMs = ($pingResult | Measure-Object -Property ResponseTime -Average).Average
        Write-Log "  Ping OK - latencia media: $([math]::Round($mediaMs,0)) ms" "Green"
    }
    else {
        Write-Log "  Sem resposta ao ping (host pode estar bloqueando ICMP ou desligado)" "Yellow"
    }

    Write-Log "Testando porta TCP $porta (VNC)..." "Gray"
    $portaOk = Test-TcpPort -ComputerName $ip -Port $porta -TimeoutMs 1500
    if ($portaOk) {
        Write-Log "  Porta $porta ABERTA - servico VNC respondendo" "Green"
    }
    else {
        Write-Log "  Porta $porta FECHADA ou sem resposta" "Red"
    }

    Write-Log ""
    if ($pingOk -and $portaOk) {
        Write-Log "Maquina ligada e pronta para conexao VNC." "Green"
    }
    elseif ($portaOk) {
        Write-Log "Servico VNC respondendo (ping bloqueado, mas a conexao deve funcionar)." "Cyan"
    }
    elseif ($pingOk) {
        Write-Log "Maquina ligada, mas o VNC nao esta respondendo na porta $porta. Verifique o servico na maquina remota." "Yellow"
    }
    else {
        Write-Log "Maquina nao respondeu - possivelmente desligada ou fora da rede." "Red"
    }
}

$btnVerificar.Add_Click({ Executar-Verificacao })

$txtIP.Add_KeyDown({
    if ($_.KeyCode -eq "Enter") {
        Executar-Verificacao
        $_.SuppressKeyPress = $true
    }
})

# ---------------------------------------------------------------
# Conectar via UltraVNC
# ---------------------------------------------------------------
$btnConectar.Add_Click({
    $ip = $txtIP.Text.Trim()
    if ($ip -notmatch $ipPattern) {
        Write-Log "[ERRO] Informe um IP valido antes de conectar." "Red"
        return
    }

    if (-not $script:vncViewerPath -or -not (Test-Path $script:vncViewerPath)) {
        Write-Log "[ERRO] Caminho do UltraVNC Viewer nao configurado. Clique em 'Localizar VNC...'." "Red"
        return
    }

    $porta = if ($txtPorta.Text.Trim() -match '^\d{1,5}$') { [int]$txtPorta.Text.Trim() } else { 5900 }

    Write-Log ""
    Write-Log "Verificando porta $porta em $ip antes de conectar..." "Gray"
    $portaOk = Test-TcpPort -ComputerName $ip -Port $porta -TimeoutMs 1200

    if ($portaOk) {
        Write-Log "Porta aberta - abrindo UltraVNC Viewer..." "Green"
    }
    else {
        Write-Log "[AVISO] Porta $porta nao respondeu em $ip. Tentando conectar mesmo assim..." "Yellow"
    }

    try {
        # host::porta na linha de comando (sintaxe padrao do vncviewer,
        # confirmada funcionando manualmente). Lancado via
        # Start-ProcessoNaoElevado para nao herdar elevacao do launcher.
        $conexao = "{0}::{1}" -f $ip, $porta
        Write-Log "Comando: `"$($script:vncViewerPath)`" $conexao" "DarkGray"
        Start-ProcessoNaoElevado -FilePath $script:vncViewerPath -Arguments $conexao
        Write-Log "UltraVNC Viewer iniciado para $ip (porta $porta)." "Cyan"
    }
    catch {
        Write-Log "[ERRO] Falha ao iniciar o UltraVNC Viewer: $($_.Exception.Message)" "Red"
    }
})

$btnLocalizarVnc.Add_Click({
    $dialog = New-Object System.Windows.Forms.OpenFileDialog
    $dialog.Title = "Selecione o executavel do UltraVNC Viewer"
    $dialog.Filter = "Executavel (*.exe)|*.exe"
    $dialog.InitialDirectory = "$env:ProgramFiles"
    if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $script:vncViewerPath = $dialog.FileName
        Salvar-CaminhoVNC -Caminho $script:vncViewerPath
        Write-Log "Caminho do UltraVNC definido: $($script:vncViewerPath)" "Cyan"
    }
})

$btnCopiar.Add_Click({
    if ($rtbLog.Text.Length -gt 0) {
        [System.Windows.Forms.Clipboard]::SetText($rtbLog.Text)
        Write-Log ""
        Write-Log "[Resultado copiado para a area de transferencia]" "DarkGray"
    }
})

$btnLimpar.Add_Click({
    $txtIP.Clear()
    $txtPorta.Text = "5900"
    $rtbLog.Clear()
    $txtIP.Focus()
})

# ---------------------------------------------------------------
# Inicializacao
# ---------------------------------------------------------------
$txtIP.Focus()
Write-Log "Conectar VNC - TRE-MA" "Cyan"
Write-Log "Digite o IP da maquina remota e clique em Verificar (ou pressione Enter)." "Gray"

if ($script:vncViewerPath) {
    Write-Log "UltraVNC Viewer localizado em: $($script:vncViewerPath)" "DarkGray"
}
else {
    Write-Log "UltraVNC Viewer nao encontrado automaticamente. Clique em 'Localizar VNC...' para configurar (uma unica vez)." "Yellow"
}

Write-Log ""

[void]$form.ShowDialog()