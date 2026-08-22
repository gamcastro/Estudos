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

Export-ModuleMember -Function Get-CaminhoVncViewer, Get-CaminhoRcViewer, Open-VncViewer, Open-RcViewer, Start-PingContinuo
