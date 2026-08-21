<#
    VisaoCliente.ps1

    FASE 0 da migracao pra arquitetura cliente-servidor (ver plano em
    C:\Users\029342881104\.claude\plans\splendid-enchanting-mochi.md) -
    ainda NAO e a tela completa da Visao. E so o arnes de teste da
    infraestrutura de conexao (VisaoRemoting.psm1 + VisaoServidor.ps1):
    conectar no POLICY-SERVER na abertura, provar que uma chamada remota
    de verdade executa do OUTRO lado, e provar que a reconexao automatica
    funciona quando a sessao cai no meio do uso.

    A tela WinForms completa (grade de zonas, varredura etc.) so entra
    aqui a partir da Fase 2+ do plano, conforme as funcoes reais forem
    migradas do ScannerRedeZona.ps1 - que continua sendo a versao de
    producao (via RDP) ate essa migracao estar madura.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

Import-Module (Join-Path $PSScriptRoot "VisaoRemoting.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "VisaoAD.psm1") -Force

$form = New-Object System.Windows.Forms.Form
$form.Text = "Visao - Teste de Conexao Remota (Fase 0)"
$form.Size = New-Object System.Drawing.Size(560, 490)
$form.StartPosition = "CenterScreen"
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$lblStatusConexao = New-Object System.Windows.Forms.Label
$lblStatusConexao.Text = "Conectando ao POLICY-SERVER..."
$lblStatusConexao.Location = New-Object System.Drawing.Point(15, 15)
$lblStatusConexao.Size = New-Object System.Drawing.Size(520, 24)
$lblStatusConexao.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$lblStatusConexao.ForeColor = [System.Drawing.Color]::Gray
$form.Controls.Add($lblStatusConexao)

$btnTestarChamada = New-Object System.Windows.Forms.Button
$btnTestarChamada.Text = "Chamar Get-TesteConexaoServidor"
$btnTestarChamada.Location = New-Object System.Drawing.Point(15, 50)
$btnTestarChamada.Width = 250
$btnTestarChamada.Height = 28
$btnTestarChamada.Enabled = $false
$form.Controls.Add($btnTestarChamada)

$btnDerrubarSessao = New-Object System.Windows.Forms.Button
$btnDerrubarSessao.Text = "Simular Queda da Sessao"
$btnDerrubarSessao.Location = New-Object System.Drawing.Point(275, 50)
$btnDerrubarSessao.Width = 220
$btnDerrubarSessao.Height = 28
$btnDerrubarSessao.Enabled = $false
$form.Controls.Add($btnDerrubarSessao)

$btnTestarFase1 = New-Object System.Windows.Forms.Button
$btnTestarFase1.Text = "Testar Fase 1 (Zonas/Grupos/Campanhas/Resultados)"
$btnTestarFase1.Location = New-Object System.Drawing.Point(15, 85)
$btnTestarFase1.Width = 480
$btnTestarFase1.Height = 28
$btnTestarFase1.Enabled = $false
$form.Controls.Add($btnTestarFase1)

$numZonaTesteAd = New-Object System.Windows.Forms.NumericUpDown
$numZonaTesteAd.Location = New-Object System.Drawing.Point(15, 120)
$numZonaTesteAd.Width = 60
$numZonaTesteAd.Minimum = 1
$numZonaTesteAd.Maximum = 253
$numZonaTesteAd.Value = 72
$form.Controls.Add($numZonaTesteAd)

$btnTestarFase2 = New-Object System.Windows.Forms.Button
$btnTestarFase2.Text = "Testar Fase 2 (AD local - Usuarios da ZE)"
$btnTestarFase2.Location = New-Object System.Drawing.Point(80, 118)
$btnTestarFase2.Width = 300
$btnTestarFase2.Height = 28
$form.Controls.Add($btnTestarFase2)

$txtIpTesteVarredura = New-Object System.Windows.Forms.TextBox
$txtIpTesteVarredura.Location = New-Object System.Drawing.Point(15, 153)
$txtIpTesteVarredura.Width = 110
$txtIpTesteVarredura.Text = ""
$form.Controls.Add($txtIpTesteVarredura)

$chkRedeCompartilhadaTeste = New-Object System.Windows.Forms.CheckBox
$chkRedeCompartilhadaTeste.Text = "Rede compartilhada"
$chkRedeCompartilhadaTeste.Location = New-Object System.Drawing.Point(135, 155)
$chkRedeCompartilhadaTeste.Width = 140
$form.Controls.Add($chkRedeCompartilhadaTeste)

$btnTestarFase4 = New-Object System.Windows.Forms.Button
$btnTestarFase4.Text = "Testar Fase 4 (Varredura remota - 1 IP)"
$btnTestarFase4.Location = New-Object System.Drawing.Point(280, 152)
$btnTestarFase4.Width = 255
$btnTestarFase4.Height = 28
$btnTestarFase4.Enabled = $false
$form.Controls.Add($btnTestarFase4)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(15, 188)
$txtLog.Size = New-Object System.Drawing.Size(520, 220)
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 9)
$form.Controls.Add($txtLog)

function Add-LinhaLog {
    param([string]$Texto)
    $txtLog.AppendText("[$(Get-Date -Format 'HH:mm:ss')] $Texto`r`n")
}

$btnTestarChamada.Add_Click({
    try {
        $resultado = Invoke-ComandoRemoto -ScriptBlock { Get-TesteConexaoServidor }
        Add-LinhaLog "OK - executado em '$($resultado.Hostname)' como '$($resultado.Usuario)' (PID remoto $($resultado.PID_Processo)), hora UTC do servidor: $($resultado.DataHoraUtc)"
    } catch {
        Add-LinhaLog "ERRO: $($_.Exception.Message)"
    }
}.GetNewClosure())

$btnDerrubarSessao.Add_Click({
    Add-LinhaLog "Derrubando a sessao de proposito (Disconnect-ServidorVisao)..."
    Disconnect-ServidorVisao
    Add-LinhaLog "Sessao derrubada. Clique em 'Chamar Get-TesteConexaoServidor' de novo - deve reconectar sozinho."
}.GetNewClosure())

$btnTestarFase1.Add_Click({
    try {
        $z = Get-ZonasRemoto
        Add-LinhaLog "Zonas: Ok=$($z.Ok) Origem=$($z.Origem) Contagem=$($z.Contagem)"

        $g = Get-GruposSistemasRemoto
        Add-LinhaLog "Grupos-Sistemas: Ok=$($g.Ok) Origem=$($g.Origem) Contagem=$($g.Contagem)"

        $c = Get-CampanhasRemoto
        Add-LinhaLog "Campanhas: Ok=$($c.Ok) Origem=$($c.Origem) Contagem=$($c.Contagem)"

        $rc = Get-ResultadosCampanhasRemoto
        Add-LinhaLog "Resultados-Campanhas: Ok=$($rc.Ok) Contagem=$($rc.Contagem)"
        foreach ($linha in $rc.Dados) {
            Add-LinhaLog "  Zona $($linha.Zona) ($($linha.Sede)): $($linha.Aptas)/$($linha.Total) aptas - $($linha.Campanha)"
        }
    } catch {
        Add-LinhaLog "ERRO: $($_.Exception.Message)"
    }
}.GetNewClosure())

$btnTestarFase2.Add_Click({
    # SEM Invoke-ComandoRemoto de proposito - roda local, direto na
    # estacao (ver VisaoAD.psm1: nao passa pelo servidor).
    $zona = [int]$numZonaTesteAd.Value
    try {
        $usuarios = Get-UsuariosDaZona -Zona $zona
        Add-LinhaLog "AD local (zona $zona): $($usuarios.Count) usuario(s) encontrado(s)."
        foreach ($u in $usuarios) {
            $situacao = if ($u.ContaDesabilitada) { " [DESABILITADA]" } elseif ($u.ContaBloqueada) { " [BLOQUEADA]" } else { "" }
            Add-LinhaLog "  $($u.Nome) ($($u.Login)) - $($u.Lotacao) - $($u.Grupos.Count) grupo(s)$situacao"
        }
    } catch {
        Add-LinhaLog "ERRO AD: $($_.Exception.Message)"
    }

    try {
        $maquinas = Get-MaquinasLiberadasInstalador
        if ($null -eq $maquinas) {
            Add-LinhaLog "Instalador: consulta falhou (usuario nao encontrado ou AD inacessivel)."
        } else {
            Add-LinhaLog "Instalador: liberado em $($maquinas.Count) maquina(s)."
        }
    } catch {
        Add-LinhaLog "ERRO Instalador: $($_.Exception.Message)"
    }
}.GetNewClosure())

$btnTestarFase4.Add_Click({
    $ip = $txtIpTesteVarredura.Text.Trim()
    if (-not $ip) {
        Add-LinhaLog "Informe um IP pra testar a varredura remota."
        return
    }
    $zona = [int]$numZonaTesteAd.Value
    $redeCompartilhada = $chkRedeCompartilhadaTeste.Checked

    try {
        Add-LinhaLog "Disparando varredura remota de '$ip' (zona $zona, rede compartilhada=$redeCompartilhada)..."
        $idSessao = Start-VarreduraRemota -Ips @($ip) -Zona $zona -RedeCompartilhada $redeCompartilhada

        # Loop de polling simples pra esta tela de teste (a tela real vai
        # usar um Timer, ver "Redesenho do progresso ao vivo" no plano) -
        # DoEvents mantem a janela respondendo enquanto espera. Teto de 60
        # iteracoes (~30s) cobre o pior caso (2 chamadas OCS de 5s cada +
        # checagens de porta) sem travar pra sempre se algo ficar preso.
        $iteracoes = 0
        do {
            Start-Sleep -Milliseconds 500
            [System.Windows.Forms.Application]::DoEvents()
            $resposta = Get-VarreduraNovosResultadosRemoto -IdSessaoEsperado $idSessao
            if ($resposta.SessaoPerdida) { break }
            foreach ($item in $resposta.Novos) {
                Add-LinhaLog "  IP $($item.IP): Online=$($item.Online) Hostname='$($item.Hostname)' DetectadoPor='$($item.DetectadoPor)' VersaoSis=$($item.VersaoSis) Modelo=$($item.Modelo)"
            }
            $iteracoes++
        } while ($resposta.EmAndamento -and $iteracoes -lt 60)

        if ($resposta.SessaoPerdida) {
            Add-LinhaLog "Conexao com o POLICY-SERVER foi perdida durante a varredura - incompleta, inicie de novo."
        } elseif ($resposta.EmAndamento) {
            Add-LinhaLog "Tempo limite de teste atingido (30s) com a varredura ainda em andamento no servidor."
        } else {
            Add-LinhaLog "Varredura concluida: $($resposta.Concluidos)/$($resposta.Total)."
        }
    } catch {
        Add-LinhaLog "ERRO na varredura: $($_.Exception.Message)"
    }
}.GetNewClosure())

$form.Add_Shown({
    if (Connect-ServidorVisao) {
        $lblStatusConexao.Text = "Conectado ao POLICY-SERVER."
        $lblStatusConexao.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
        Add-LinhaLog "Conexao inicial OK."
    } else {
        $lblStatusConexao.Text = "Falha ao conectar ao POLICY-SERVER."
        $lblStatusConexao.ForeColor = [System.Drawing.Color]::FromArgb(220, 53, 69)
        Add-LinhaLog "Falha na conexao inicial - veja aviso no console/terminal."
    }
    $btnTestarChamada.Enabled = $true
    $btnDerrubarSessao.Enabled = $true
    $btnTestarFase1.Enabled = $true
    $btnTestarFase4.Enabled = $true
}.GetNewClosure())

$form.Add_FormClosed({ Disconnect-ServidorVisao }.GetNewClosure())

[void]$form.ShowDialog()
