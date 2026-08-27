<#
    VisaoCliente.ps1

    Tela de PRODUCAO da "Visao" - roda LOCAL na estacao do tecnico, sem
    RDP, sem se autoelevar (nao precisa mais: varredura/robocopy/APIs do
    Google rodam no POLICY-SERVER via PowerShell Remoting; acesso a
    \\IP\InstSeg de maquinas de zona e AD rodam local, sem elevacao).

    Todas as 6 fases (A-F) do plano de construcao desta tela
    (C:\Users\029342881104\.claude\plans\splendid-enchanting-mochi.md)
    estao concluidas e testadas ao vivo: janela principal (grade de
    varredura, menu de contexto, exportar CSV), maquinas desligadas via
    OCS Inventory + Wake-on-LAN + Info de Impressora, Sistemas
    Eleitorais/Pacotes + envio de CVC, Campanhas (individual/zona) +
    Relatorio, Usuarios da ZE + Gerenciar Zonas, Configuracoes. Esta
    ferramenta e a versao de producao completa - ScannerRedeZona.ps1 (a
    versao antiga, via RDP) fica como referencia/fallback ate ser
    aposentado.
#>

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()

Import-Module (Join-Path $PSScriptRoot "VisaoRemoting.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "VisaoPlanilhas.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "VisaoOcs.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "VisaoAD.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "VisaoPacotes.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "VisaoAcoesLocais.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "VisaoJanelaPacotes.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "VisaoJanelaCampanhas.psm1") -Force
Import-Module (Join-Path $PSScriptRoot "VisaoJanelaAdmin.psm1") -Force

$script:NomeFerramenta = "Visao HOMOLOG"

# Le a versao DIRETO do manifesto do modulo (Visao.psd1, fica do lado de
# VisaoCliente.ps1 dentro da pasta instalada pelo Install-Module -
# C:\...\Modules\Visao\<versao>\) - nunca mais precisa lembrar de
# sincronizar um numero fixo aqui a mao toda vez que o modulo e
# republicado (ver projeto_distribuicao_visao). Import-PowerShellDataFile
# le em modo restrito (nao executa nada do .psd1, so avalia a tabela de
# dados) - seguro mesmo lendo um arquivo que veio de fora. Cai num valor
# fixo generico se rodar solto (fora do modulo, como no dia a dia de
# desenvolvimento/teste direto na pasta do repositorio, sem Visao.psd1
# do lado).
$script:VersaoFerramenta = "2.0 (dev)"
$caminhoManifestoVersao = Join-Path $PSScriptRoot "VisaoHomolog.psd1"
if (Test-Path $caminhoManifestoVersao) {
    try {
        $manifestoVersao = Import-PowerShellDataFile -Path $caminhoManifestoVersao
        if ($manifestoVersao.ModuleVersion) { $script:VersaoFerramenta = $manifestoVersao.ModuleVersion }
    } catch {}
}

# ============================================================
# ESTADO GLOBAL (client-side) - equivalente ao topo do
# ScannerRedeZona.ps1 original, so a parte que ainda faz sentido do lado
# cliente (a maior parte do estado de varredura/config agora vive no
# servidor, ver VisaoServidor.ps1).
# ============================================================
$script:Resultados            = New-Object System.Collections.Generic.List[object]
$script:MaquinasDesligadasOcs = New-Object System.Collections.Generic.List[object]   # populado na Fase B

# Estado compartilhado entre os handlers de evento (botoes/timer) - UM hashtable
# so, criado UMA VEZ aqui embaixo, SEMPRE MUTADO (nunca reatribuido por
# inteiro depois disso). Motivo: confirmado ao vivo (reproduzido em
# isolado varias vezes) que cada `.GetNewClosure()` cria uma copia
# PROPRIA e ISOLADA do escopo $script: - reatribuir uma variavel $script:
# ESCALAR (ou ate substituir uma variavel de referencia inteira, tipo
# "$script:Foo = @{...}") DENTRO de um closure NAO se propaga pra fora
# dele: nem pra OUTRO closure, nem pra uma FUNCAO comum chamada de
# dentro do mesmo closure, nem pro escopo do script depois que o
# ShowDialog retorna. So MUTACAO de um objeto que ja existia ANTES de
# qualquer closure ser criado (ex: $script:Estado.Chave = valor, ou
# $script:Resultados.Add(...)) atravessa essa fronteira corretamente,
# porque todo mundo aponta pra o MESMO objeto por referencia. Por isso
# $script:Estado precisa ser criado bem aqui no topo, antes de QUALQUER
# Add_Click/Add_Tick ser registrado.
$script:Estado = @{
    ZonaAtual                    = $null
    RedeCompartilhada            = $false
    MaquinasLiberadasInstalador  = $null
    IdSessaoVarredura            = $null   # GUID devolvido por Start-VarreduraRemota - ver comentario em Get-VarreduraNovosResultadosRemoto sobre deteccao de sessao perdida
    SistemasEleitoraisExtra      = @()     # preenchido na conexao via Get-SistemasEleitoraisExtraRemoto
    TabelaVersoes                = @{}     # preenchido via Get-VersoesRemoto (hashtable "SISTEMA|VERSAO" -> {NomeAmigavel})
    VersaoAtualPorSistema        = @{}     # preenchido via Get-VersoesRemoto (hashtable "SISTEMA" -> versao)
    Pacotes                      = @()     # preenchido via Get-VersoesRemoto (.Pacotes) - lista de pacotes baixaveis, ver VisaoJanelaPacotes.psm1
    Campanhas                    = @()     # preenchido via Get-CampanhasRemoto (.Campanhas) - ver VisaoJanelaCampanhas.psm1
    Zonas                        = @()     # preenchido via Get-ZonasRemoto (.Zonas) - ver VisaoJanelaAdmin.psm1 (Gerenciar Zonas)
    GruposSistemas               = @{}     # preenchido via Get-GruposSistemasRemoto (.GruposSistemas) - ver VisaoJanelaAdmin.psm1 (Usuarios da ZE)
    LinhaContextoAtual           = $null   # linha do grid selecionada pro menu de contexto (setada no MouseDown, lida no Add_Opening - dois closures separados)
    TickVarreduraEmAndamento     = $false  # guarda de reentrancia do timer de polling - ver comentario no Add_Tick
    EsperaAsyncVarredura         = $null   # chamada remota do polling em voo (Start/Test-VarreduraNovosResultadosRemotoAsync) - null quando nao ha nenhuma pendente
    VarreduraCancelada           = $false  # cancelamento pedido mas adiado ate a checagem em voo terminar - ver EVENTO: Cancelar
    EsperaAsyncKeepAlive         = $null   # chamada leve do keepalive em voo (Start/Test-ChamadaRemotaAssincrona) - null quando nao ha nenhuma pendente
}

function ConvertTo-HashtableLocal {
    <#
        Converte um PSCustomObject (o formato que ConvertFrom-Json
        sempre devolve) de volta pra Hashtable normal, restaurando a
        indexacao por chave ($h["Chave"]) que o resto do codigo (portado
        quase sem mudanca do ScannerRedeZona.ps1 original) espera.
    #>
    param($PSObject)
    $h = @{}
    if ($PSObject) {
        foreach ($p in $PSObject.PSObject.Properties) { $h[$p.Name] = $p.Value }
    }
    return $h
}

function Resolve-NomeAmigavelVersao {
    <#
        Relocada quase sem mudanca do ScannerRedeZona.ps1 original - so
        $script:Estado.TabelaVersoes/$script:Estado.VersaoAtualPorSistema agora vem do
        servidor (Get-VersoesRemoto) em vez de ler a planilha direto.
    #>
    param([string]$Sistema, [string]$Versao)
    if (-not $Versao -or $Versao -eq "-") { return $null }

    $sistemaUpper = $Sistema.ToUpper()
    $chave = "$sistemaUpper|$($Versao.Trim())"
    if (-not $script:Estado.TabelaVersoes.ContainsKey($chave)) { return $null }

    $versaoAtual = $script:Estado.VersaoAtualPorSistema[$sistemaUpper]
    return [PSCustomObject]@{
        NomeAmigavel = $script:Estado.TabelaVersoes[$chave].NomeAmigavel
        EhAtual      = if ($versaoAtual) { $versaoAtual -eq $Versao.Trim() } else { $null }
    }
}

# ============================================================
# JANELA PRINCIPAL - layout
# ============================================================
$form = New-Object System.Windows.Forms.Form
$form.Text = "$($script:NomeFerramenta) $($script:VersaoFerramenta) - TRE-MA / SEASU-COINF-STIC"
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
$numZona.Enabled = $false
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
$btnIniciar.Enabled = $false
$form.Controls.Add($btnIniciar)

$btnCancelar = New-Object System.Windows.Forms.Button
$btnCancelar.Text = "Cancelar"
$btnCancelar.Location = New-Object System.Drawing.Point(825, 13)
$btnCancelar.Width = 105
$btnCancelar.Height = 26
$btnCancelar.Enabled = $false
$form.Controls.Add($btnCancelar)

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

$btnRelatorioCampanhas = New-Object System.Windows.Forms.Button
$btnRelatorioCampanhas.Text = "Relatorio de Campanhas..."
$btnRelatorioCampanhas.Location = New-Object System.Drawing.Point(480, 611)
$btnRelatorioCampanhas.Width = 190
$btnRelatorioCampanhas.Height = 28
$btnRelatorioCampanhas.Anchor = "Bottom,Left"
$form.Controls.Add($btnRelatorioCampanhas)

$btnAtualizarFerramenta = New-Object System.Windows.Forms.Button
$btnAtualizarFerramenta.Text = "Atualizar Ferramenta"
$btnAtualizarFerramenta.Location = New-Object System.Drawing.Point(680, 611)
$btnAtualizarFerramenta.Width = 170
$btnAtualizarFerramenta.Height = 28
$btnAtualizarFerramenta.Anchor = "Bottom,Left"
$form.Controls.Add($btnAtualizarFerramenta)

$btnContaSenhaLaps = New-Object System.Windows.Forms.Button
$btnContaSenhaLaps.Text = "ContraSenha-LAPS"
$btnContaSenhaLaps.Location = New-Object System.Drawing.Point(860, 611)
$btnContaSenhaLaps.Width = 155
$btnContaSenhaLaps.Height = 28
$btnContaSenhaLaps.Anchor = "Bottom,Left"
$form.Controls.Add($btnContaSenhaLaps)

$btnTransferidorInstseg = New-Object System.Windows.Forms.Button
$btnTransferidorInstseg.Text = "Transferidor Instseg"
$btnTransferidorInstseg.Location = New-Object System.Drawing.Point(1025, 611)
$btnTransferidorInstseg.Width = 160
$btnTransferidorInstseg.Height = 28
$btnTransferidorInstseg.Anchor = "Bottom,Left"
$form.Controls.Add($btnTransferidorInstseg)

$btnUsuariosZona = New-Object System.Windows.Forms.Button
$btnUsuariosZona.Text = "Usuarios da ZE 1"
$btnUsuariosZona.Location = New-Object System.Drawing.Point(710, 43)
$btnUsuariosZona.Width = 150
$btnUsuariosZona.Height = 24
$form.Controls.Add($btnUsuariosZona)

$btnVerificarCampanhaZona = New-Object System.Windows.Forms.Button
$btnVerificarCampanhaZona.Text = "Verificar Campanha ZE 1"
$btnVerificarCampanhaZona.Location = New-Object System.Drawing.Point(870, 43)
$btnVerificarCampanhaZona.Width = 190
$btnVerificarCampanhaZona.Height = 24
$btnVerificarCampanhaZona.Enabled = $false
$form.Controls.Add($btnVerificarCampanhaZona)

$progressBar = New-Object System.Windows.Forms.ProgressBar
$progressBar.Location = New-Object System.Drawing.Point(15, 76)
$progressBar.Width = 1350
$progressBar.Height = 18
$form.Controls.Add($progressBar)

$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = "Conectando ao POLICY-SERVER..."
$lblStatus.Location = New-Object System.Drawing.Point(15, 98)
$lblStatus.AutoSize = $true
$form.Controls.Add($lblStatus)

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
# Colunas dinamicas de sistemas eleitorais extra so entram depois da
# conexao (Get-SistemasEleitoraisExtraRemoto, em $form.Add_Shown) - o
# schema delas vive no servidor, nao aqui.

$form.Controls.Add($grid)

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
# EXIBICAO DA GRADE (Add-LinhaGrid/Reconstruir-Grid/Atualizar-ResumoStatus)
#
# Relocadas do ScannerRedeZona.ps1 original PRATICAMENTE sem mudanca -
# dependem so do objeto $Resultado ja resolvido, que a varredura nova
# ja entrega com EhGateway/EhNobreakCentral/EhTelefoneVoip/
# PertenceZonaAtual prontos (migrado na Fase 5 da migracao de
# remoting) - exatamente como o timer antigo calculava antes de chamar
# Add-LinhaGrid.
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

    $colunasAtualizadas = @()
    $colunasDesatualizadas = @()
    $sisTxt = if ($Resultado.VersaoSis) { $Resultado.VersaoSis } else { "-" }
    if ($sisTxt -ne "-") {
        $versaoAtualSis = $script:Estado.VersaoAtualPorSistema["SIS"]
        if ($versaoAtualSis) {
            if ($sisTxt.Trim() -eq $versaoAtualSis.Trim()) { $colunasAtualizadas += "Sis" } else { $colunasDesatualizadas += "Sis" }
        }
    }

    $instaladorTxt = "-"
    if ($sisTxt -ne "-" -and $temNomeResolvido -and -not $Resultado.PossivelImpressora -and $null -ne $script:Estado.MaquinasLiberadasInstalador) {
        $hostnameCurto = ($Resultado.Hostname -split '\.')[0]
        if ($script:Estado.MaquinasLiberadasInstalador.Count -eq 0 -or $script:Estado.MaquinasLiberadasInstalador -contains $hostnameCurto) {
            $instaladorTxt = "Liberado"
        } else {
            $instaladorTxt = "Bloqueado"
        }
    }

    $hostnameExibido = if ($Resultado.PossivelImpressora) { "-" } else { $Resultado.Hostname }

    $valoresLinha = @($Resultado.IP, $tipo, $hostnameExibido, $modeloTxt, $tempoTxt, $Resultado.DetectadoPor, $vncTxt, $rcTxt, $sisTxt, $instaladorTxt)
    foreach ($sis in $script:Estado.SistemasEleitoraisExtra) {
        if (-not $sis.NaGradePrincipal) { continue }
        $valorExtra = $Resultado.($sis.Propriedade)
        $infoExtra = if ($sis.ComNomeAmigavel) { Resolve-NomeAmigavelVersao -Sistema $sis.NomeVersaoAtual -Versao $valorExtra } else { $null }
        $valoresLinha += $(if ($infoExtra) { "$($infoExtra.NomeAmigavel) ($valorExtra)" } elseif ($valorExtra) { $valorExtra } else { "-" })

        if ($valorExtra -and $valorExtra -ne "-") {
            $versaoAtualSistema = $script:Estado.VersaoAtualPorSistema[$sis.NomeVersaoAtual]
            if ($versaoAtualSistema) {
                if ($valorExtra.Trim() -eq $versaoAtualSistema.Trim()) { $colunasAtualizadas += $sis.Coluna } else { $colunasDesatualizadas += $sis.Coluna }
            }
        }
    }

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
    $ativos = @($script:Resultados | Where-Object { $_.Online })
    $exibidos = $grid.Rows.Count
    $impressorasExibidas = @($grid.Rows | Where-Object { $_.Tag.PossivelImpressora }).Count
    $vncsExibidos = @($grid.Rows | Where-Object { $_.Tag.VncAtivo }).Count
    $desligados = $script:MaquinasDesligadasOcs.Count

    if ($script:Estado.RedeCompartilhada -and $chkFiltrarZona.Checked) {
        $lblStatus.Text = "Concluido: $exibidos de $($ativos.Count) ativo(s) na rede pertencem a esta zona. $impressorasExibidas impressora(s), $vncsExibidos com VNC."
    } else {
        $lblStatus.Text = "Concluido: $($ativos.Count) ativo(s), $impressorasExibidas impressora(s), $vncsExibidos com VNC ativo."
    }
    if ($desligados -gt 0) {
        $lblStatus.Text += " $desligados possivelmente desligada(s)/desconectada(s) (OCS)."
    }
    $btnExportar.Enabled = ($ativos.Count -gt 0 -or $desligados -gt 0)
    $btnVerificarCampanhaZona.Enabled = ($ativos.Count -gt 0 -or $desligados -gt 0)
}

function Reconstruir-Grid {
    $grid.Rows.Clear()
    foreach ($r in $script:Resultados) {
        if (-not $r.Online) { continue }
        if (-not $script:Estado.RedeCompartilhada -or -not $chkFiltrarZona.Checked -or $r.PertenceZonaAtual -or $r.PossivelImpressora -or $r.EhGateway -or $r.EhNobreakCentral) {
            Add-LinhaGrid -Resultado $r
        }
    }
    foreach ($r in $script:MaquinasDesligadasOcs) {
        Add-LinhaGrid -Resultado $r
    }
    Atualizar-ResumoStatus
}

$chkFiltrarZona.Add_CheckedChanged({ Reconstruir-Grid }.GetNewClosure())

function Invoke-BuscarDesligadosOcs {
    <#
        Compara o cadastro do OCS Inventory da rede da zona com o que a
        varredura ja encontrou online, pra achar maquinas cadastradas que
        nao responderam ("possivelmente desligadas") - e corrige o
        Hostname de quem respondeu mas ficou sem nome resolvido. Ver
        Get-MaquinasDesligadasOcsRemoto/Get-MaquinasDesligadasOcs
        (servidor) - a comparacao em si roda la (nao esbarra no duplo-
        salto de Kerberos, e uma chamada de API HTTP, mesmo padrao do
        scriptBlock de varredura).
    #>
    if ($script:Resultados.Count -eq 0) { return }

    Add-Log "=== Buscando no OCS Inventory maquinas da Zona $($script:Estado.ZonaAtual) sem resposta na varredura ===" "Yellow"
    $grid.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $online = @($script:Resultados | Where-Object { $_.Online })
        # Resolve local (sem tocar rede - so opera sobre $script:Estado.Zonas
        # ja carregado) e manda pronto pro servidor, que nao tem mais como
        # resolver isso sozinho (ver comentario em Get-MaquinasDesligadasOcs).
        $prefixoRedeAtual = (Resolve-RedeDaZonaRemoto -Zona $script:Estado.ZonaAtual -Zonas $script:Estado.Zonas).Prefixo
        $resposta = Get-MaquinasDesligadasOcsRemoto -Zona $script:Estado.ZonaAtual -RedeCompartilhada $script:Estado.RedeCompartilhada -ResultadosOnline $online -PrefixoRede $prefixoRedeAtual -SistemasEleitoraisExtra $script:Estado.SistemasEleitoraisExtra
    } catch {
        Add-Log "[AVISO] Falha ao consultar o OCS Inventory: $($_.Exception.Message)" "Yellow"
        return
    } finally {
        $grid.Cursor = [System.Windows.Forms.Cursors]::Default
    }

    if (-not $resposta.Ok) {
        Add-Log "[AVISO] Consulta ao OCS Inventory nao retornou dados validos." "Yellow"
        return
    }

    foreach ($correcao in $resposta.Correcoes) {
        for ($i = 0; $i -lt $script:Resultados.Count; $i++) {
            if ($script:Resultados[$i].IP -eq $correcao.IP) { $script:Resultados[$i] = $correcao; break }
        }
    }
    if ($resposta.Correcoes.Count -gt 0) {
        Add-Log "$($resposta.Correcoes.Count) hostname(s) resolvido(s) via OCS Inventory (por ultimo IP conhecido) - DNS reverso/NetBIOS nao encontraram esses." "Cyan"
    }

    $script:MaquinasDesligadasOcs.Clear()
    foreach ($m in $resposta.Desligadas) { $script:MaquinasDesligadasOcs.Add($m) }

    Reconstruir-Grid
    $qtdCandidatas = @($resposta.Desligadas | Where-Object { $_.CandidatoExclusaoOcs }).Count
    Add-Log "=== $($resposta.Desligadas.Count) maquina(s) da Zona $($script:Estado.ZonaAtual) parecem desligadas/desconectadas (cadastradas no OCS, sem resposta na varredura) - $qtdCandidatas com mais de $($resposta.MesesParaCandidatoExclusao) meses sem contato ===" "OrangeRed"
}

function Atualizar-MaximoZona {
    <#
        Sobe o maximo do campo "Numero da Zona" se a planilha tiver zona
        alem de 253 (raro, mas o original ja previa isso) - relocacao
        quase pura, so $script:TabelaZonas.Keys vira $script:Estado.Zonas
        (array de {Zona;...} em vez de Hashtable indexada por zona).
    #>
    if ($script:Estado.Zonas.Count -gt 0) {
        $maxZona = ($script:Estado.Zonas | Measure-Object -Property Zona -Maximum).Maximum
        $numZona.Maximum = [Math]::Max($maxZona, 253)
    }
}

function Update-LabelSedeInfo {
    $zona = [int]$numZona.Value
    try {
        $resolucao = Resolve-RedeDaZonaRemoto -Zona $zona -Zonas $script:Estado.Zonas
    } catch {
        $lblSedeInfo.Text = "Sede: -    Rede a varrer: (erro ao consultar o servidor)"
        $lblSedeInfo.ForeColor = [System.Drawing.Color]::FromArgb(220, 53, 69)
        return
    }
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
    $btnVerificarCampanhaZona.Text = "Verificar Campanha ZE $zona"
}

$numZona.Add_ValueChanged({
    Update-LabelSedeInfo
    $btnVerificarCampanhaZona.Enabled = $false
}.GetNewClosure())

# ============================================================
# VARREDURA - Timer de polling (750ms, ver Fase 5 da migracao de
# remoting) sobre Start-VarreduraRemota/Get-VarreduraNovosResultadosRemoto
# ============================================================
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 750

$timer.Add_Tick({
    # Guarda de reentrancia: desde que Invoke-ComandoRemoto passou a usar
    # DoEvents (nao trava mais a UI durante uma chamada remota), uma
    # mensagem WM_TIMER que ja estava na fila do Windows ANTES de
    # $timer.Stop() ainda pode ser entregue - inclusive DEPOIS do "not
    # EmAndamento" abaixo, enquanto Invoke-BuscarDesligadosOcs (que
    # tambem faz chamadas remotas) ainda esta rodando como continuacao
    # deste MESMO tick. Sem essa guarda, esse tick "fantasma" tentava
    # uma SEGUNDA chamada remota concorrente com a que ja estava em voo
    # e quebrava com "pipeline ja esta em execucao" (achado ao vivo,
    # 2026-08-24: varredura + relatorio de campanha + iniciar varredura
    # de outra zona logo em seguida).
    if ($script:Estado.TickVarreduraEmAndamento) { return }
    $script:Estado.TickVarreduraEmAndamento = $true
    try {
        Invoke-TickVarredura
    } finally {
        $script:Estado.TickVarreduraEmAndamento = $false
    }
}.GetNewClosure())

function Invoke-TickVarredura {
    <#
        Modelo NAO-BLOQUEANTE de proposito (2026-08-25) - ver
        Start/Test-VarreduraNovosResultadosRemotoAsync em
        VisaoRemoting.psm1. Cada tick SO dispara a checagem (se nao
        houver nenhuma em voo) ou SO confere se a que ja estava em voo
        terminou - nunca bloqueia esperando, nunca chama DoEvents() de
        dentro deste handler. Isso elimina de proposito o padrao de
        DoEvents() aninhado (Timer.Tick chamando DoEvents que podia
        disparar o PROPRIO Timer de novo, empilhando cada vez mais
        fundo durante uma espera longa) - confirmado ao vivo como causa
        provavel de dois crashes reais da aplicacao (AccessViolationException
        nativa em WSManReconnectShellCommandEx, e um erro de Set-Content
        escapando do proprio catch), ambos SO durante varredura em
        andamento. Ver project_crash_winrm_reconexao na memoria do
        projeto.
    #>
    if (-not $script:Estado.EsperaAsyncVarredura) {
        try {
            $inicio = Start-VarreduraNovosResultadosRemotoAsync -IdSessaoEsperado $script:Estado.IdSessaoVarredura
        } catch {
            $timer.Stop()
            Add-Log "[ERRO] Falha ao consultar progresso da varredura: $($_.Exception.Message)" "OrangeRed"
            $btnIniciar.Enabled = $true
            $btnCancelar.Enabled = $false
            $numZona.Enabled = $true
            return
        }
        if ($inicio.SessaoPerdidaImediato) {
            $timer.Stop()
            Add-Log "[ERRO] Conexao com o POLICY-SERVER foi perdida durante a varredura - incompleta, inicie de novo." "OrangeRed"
            $btnIniciar.Enabled = $true
            $btnCancelar.Enabled = $false
            $numZona.Enabled = $true
            return
        }
        # So dispara - o resultado so chega num tick FUTURO (proximo
        # Test-VarreduraNovosResultadosRemotoAsync que devolver Concluido).
        $script:Estado.EsperaAsyncVarredura = $inicio
        return
    }

    $status = Test-VarreduraNovosResultadosRemotoAsync -EstadoAsync $script:Estado.EsperaAsyncVarredura -AoAtualizarStatus { param($t) Add-Log $t "Gray" }
    if (-not $status.Concluido) { return }

    $script:Estado.EsperaAsyncVarredura = $null

    if ($script:Estado.VarreduraCancelada) {
        $script:Estado.VarreduraCancelada = $false
        Concluir-CancelamentoVarredura
        return
    }

    if ($status.Erro) {
        $timer.Stop()
        Add-Log "[ERRO] Falha ao consultar progresso da varredura: $($status.Erro.Message)" "OrangeRed"
        $btnIniciar.Enabled = $true
        $btnCancelar.Enabled = $false
        $numZona.Enabled = $true
        return
    }

    $resposta = $status.Resposta

    if ($resposta.SessaoPerdida) {
        $timer.Stop()
        Add-Log "[ERRO] Conexao com o POLICY-SERVER foi perdida durante a varredura - incompleta, inicie de novo." "OrangeRed"
        $btnIniciar.Enabled = $true
        $btnCancelar.Enabled = $false
        $numZona.Enabled = $true
        return
    }

    foreach ($resultado in $resposta.Novos) {
        $script:Resultados.Add($resultado)
        if ($resultado.Online) {
            if ($resultado.PossivelImpressora) {
                Add-Log "[IMPRESSORA] $($resultado.IP)  $($resultado.Hostname)  portas: $($resultado.PortasAbertas)" "DeepPink"
            } elseif ($resultado.EhGateway) {
                Add-Log "[GATEWAY]    $($resultado.IP)  $($resultado.Hostname)" "Cyan"
            } elseif ($resultado.EhNobreakCentral) {
                Add-Log "[NOBREAK]    $($resultado.IP)  $($resultado.Hostname)" "Yellow"
            } elseif ($resultado.EhTelefoneVoip) {
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

            if (-not $script:Estado.RedeCompartilhada -or -not $chkFiltrarZona.Checked -or $resultado.PertenceZonaAtual -or $resultado.PossivelImpressora -or $resultado.EhGateway -or $resultado.EhNobreakCentral) {
                Add-LinhaGrid -Resultado $resultado
            }
        }
    }

    $progressBar.Value = [Math]::Min($resposta.Concluidos, $progressBar.Maximum)
    $lblStatus.Text = "Verificando... $($resposta.Concluidos) de $($resposta.Total) enderecos analisados."

    if (-not $resposta.EmAndamento) {
        $timer.Stop()

        Atualizar-ResumoStatus
        # @(...) forcando contexto de array e de proposito - sem isso,
        # Where-Object devolve um objeto SOLTO (nao array) quando ha
        # exatamente 1 resultado, e ".Count" nesse caso fica vazio em vez
        # de "1" (confirmado ao vivo: "1 impressora(s)" apareceu em
        # branco na varredura da zona 34).
        $ativos = @($script:Resultados | Where-Object { $_.Online })
        $impressoras = @($ativos | Where-Object { $_.PossivelImpressora })
        $vncs = @($ativos | Where-Object { $_.VncAtivo })
        Add-Log "=== Varredura concluida: $($ativos.Count) ativo(s) / $($impressoras.Count) impressora(s) / $($vncs.Count) com VNC ===" "Cyan"

        Invoke-BuscarDesligadosOcs

        $btnIniciar.Enabled = $true
        $btnCancelar.Enabled = $false
        $numZona.Enabled = $true
    }
}

# ============================================================
# KEEPALIVE (2026-08-27) - confirmado ao vivo que a conexao com o
# POLICY-SERVER cai por INATIVIDADE (algum dispositivo de rede
# intermediario, nao codigo nosso) mesmo sem nenhuma acao do tecnico -
# reproduzido so ficando parado ~4min, com ou sem antivirus, sem abrir
# nenhuma janela. Este Timer dispara uma chamada bem leve pro servidor
# a cada ~60s enquanto a ferramenta esta ociosa (varredura NAO em
# andamento), so pra manter a conexao TCP subjacente "viva" - nunca usa
# DoEvents() nem forca Stop-Job/Remove-Job (ver Start/Test-
# ChamadaRemotaAssincrona, VisaoRemoting.psm1). Nao dispara durante uma
# varredura ativa de proposito - o polling dela ja gera trafego
# constante, nao precisa de mais nada.
#
# Achado ao vivo (2026-08-27): o INTERVALO do Timer NAO pode ser os
# mesmos 60s do disparo - isso so CONFERE se a chamada terminou uma vez
# a cada 60s tambem, entao $script:SessaoOcupada ficava travado em
# $true por quase 1 minuto inteiro a cada ciclo (mesmo o Get-Date
# remoto terminando em 1-2s), bloqueando QUALQUER outra acao do
# tecnico (Iniciar Varredura, Atualizar Zona, etc) com "Ja ha uma
# chamada remota em andamento" durante essa janela. Por isso o Timer
# roda a cada 2s (confere rapido), mas so DISPARA uma chamada nova a
# cada 60s de verdade ($ultimoKeepAlive, um Stopwatch mutavel).
# ============================================================
$ultimoKeepAlive = [System.Diagnostics.Stopwatch]::StartNew()
$intervaloKeepAliveSegundos = 60

$timerKeepAlive = New-Object System.Windows.Forms.Timer
$timerKeepAlive.Interval = 2000
$timerKeepAlive.Add_Tick({
    if ($timer.Enabled) { return }

    if ($script:Estado.EsperaAsyncKeepAlive) {
        $status = Test-ChamadaRemotaAssincronaConcluida -EstadoAsync $script:Estado.EsperaAsyncKeepAlive
        if ($status.Concluido) { $script:Estado.EsperaAsyncKeepAlive = $null }
        return
    }

    if ($ultimoKeepAlive.Elapsed.TotalSeconds -lt $intervaloKeepAliveSegundos) { return }

    try {
        $script:Estado.EsperaAsyncKeepAlive = Start-ChamadaRemotaAssincrona -ScriptBlock { Get-Date }
    } catch {
        # Silencioso de proposito - se a sessao ainda nao existir, ou
        # estiver ocupada com outra coisa (ex: Verificar Campanha, Enviar
        # CVC), so tenta de novo no proximo ciclo de 60s.
    } finally {
        $ultimoKeepAlive.Restart()
    }
}.GetNewClosure())
$timerKeepAlive.Start()

# ============================================================
# EVENTO: Iniciar Varredura
# ============================================================
$btnIniciar.Add_Click({
    $zona = [int]$numZona.Value

    # Feedback IMEDIATO - Resolve-RedeDaZonaRemoto/Start-VarreduraRemota
    # logo abaixo sao chamadas de rede SINCRONAS (sem DoEvents no meio,
    # de proposito - mesma disciplina do resto desta ferramenta), podem
    # levar alguns segundos e travam a repintura da janela nesse meio
    # tempo. Sem isto aqui, o clique parece "nao fez nada" ate a
    # primeira chamada terminar.
    $btnIniciar.Enabled = $false
    $lblStatus.Text = "Iniciando varredura..."
    [System.Windows.Forms.Application]::DoEvents()

    try {
        $resolucao = Resolve-RedeDaZonaRemoto -Zona $zona -Zonas $script:Estado.Zonas
    } catch {
        [System.Windows.Forms.MessageBox]::Show("Falha ao resolver a rede da zona: $($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
        $btnIniciar.Enabled = $true
        return
    }
    $baseIP = $resolucao.Prefixo
    if (-not $baseIP) {
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel determinar a rede da zona $zona.", "Erro", "OK", "Error") | Out-Null
        $btnIniciar.Enabled = $true
        return
    }

    $script:Estado.ZonaAtual = $zona
    try {
        $script:Estado.MaquinasLiberadasInstalador = Get-MaquinasLiberadasInstalador
        if ($null -eq $script:Estado.MaquinasLiberadasInstalador) {
            Add-Log "Nao foi possivel consultar o AD para o status do instalador nesta varredura." "Gray"
        } elseif ($script:Estado.MaquinasLiberadasInstalador.Count -eq 0) {
            Add-Log "Usuario do Instalador sem restricao de maquina no AD (liberado em qualquer uma)." "Gray"
        } else {
            Add-Log "Usuario do Instalador liberado em $($script:Estado.MaquinasLiberadasInstalador.Count) maquina(s) no AD." "Gray"
        }
    } catch {
        $script:Estado.MaquinasLiberadasInstalador = $null
        Add-Log "[AVISO] Falha ao consultar o AD para o status do instalador: $($_.Exception.Message)" "Yellow"
    }

    try {
        $script:Estado.RedeCompartilhada = Test-RedeEhCompartilhadaRemoto -Prefixo $baseIP -Zonas $script:Estado.Zonas
    } catch {
        $script:Estado.RedeCompartilhada = $false
        Add-Log "[AVISO] Falha ao verificar se a rede e compartilhada: $($_.Exception.Message)" "Yellow"
    }

    $grid.Rows.Clear()
    $rtbLog.Clear()
    $script:Resultados.Clear()
    $script:MaquinasDesligadasOcs.Clear()
    $btnExportar.Enabled = $false
    $btnVerificarCampanhaZona.Enabled = $false
    $numZona.Enabled = $false

    $sedeTxt = if ($resolucao.Sede) { $resolucao.Sede } else { "(sede desconhecida)" }
    Add-Log "=== Iniciando varredura da Zona $zona - $sedeTxt ($($baseIP)0/24) ===" "Yellow"
    Add-Log "Rede determinada por: $($resolucao.Origem)" "Gray"
    if ($script:Estado.RedeCompartilhada) {
        $filtroTxt = if ($chkFiltrarZona.Checked) { "ativo (so mostra hosts desta zona)" } else { "desativado (mostra todos os hosts da rede)" }
        Add-Log "Rede compartilhada entre varias zonas - filtro por hostname $filtroTxt." "Gray"
    }

    $ips = 1..254 | ForEach-Object { "$baseIP$_" }
    $progressBar.Maximum = $ips.Count
    $progressBar.Value = 0
    # Limpa qualquer resquicio de uma varredura anterior cancelada com uma
    # checagem assincrona ainda em voo (rara, mas evita o polling novo
    # confundir com o resultado de uma checagem antiga - ver comentario
    # em Invoke-TickVarredura).
    $script:Estado.EsperaAsyncVarredura = $null

    try {
        $script:Estado.IdSessaoVarredura = Start-VarreduraRemota -Ips $ips -Zona $zona -RedeCompartilhada $script:Estado.RedeCompartilhada -AoAtualizarStatus { param($t) Add-Log $t "Gray" }.GetNewClosure()
    } catch {
        Add-Log "[ERRO] Falha ao iniciar a varredura no servidor: $($_.Exception.Message)" "OrangeRed"
        $numZona.Enabled = $true
        $btnIniciar.Enabled = $true
        return
    }
    $btnIniciar.Enabled = $false
    $btnCancelar.Enabled = $true
    $timer.Start()
}.GetNewClosure())

# ============================================================
# EVENTO: Cancelar
#
# So para o POLLING do lado cliente - a varredura em si continua
# rodando no servidor ate terminar sozinha (nao ha uma funcao de
# "abortar" server-side ainda; cada varredura de zona termina em
# poucos segundos de qualquer forma, entao o custo de deixar terminar
# em segundo plano e baixo). Ver plano da Fase A.
# ============================================================
function Concluir-CancelamentoVarredura {
    $timer.Stop()
    Add-Log "=== Varredura cancelada pelo usuario (o servidor pode levar mais alguns segundos pra terminar em segundo plano) ===" "OrangeRed"
    $lblStatus.Text = "Cancelado."
    $btnIniciar.Enabled = $true
    $btnCancelar.Enabled = $false
    $numZona.Enabled = $true
    $ativos = @($script:Resultados | Where-Object { $_.Online })
    $btnExportar.Enabled = ($ativos.Count -gt 0 -or $script:MaquinasDesligadasOcs.Count -gt 0)
    $btnVerificarCampanhaZona.Enabled = $btnExportar.Enabled
}

$btnCancelar.Add_Click({
    if ($script:Estado.EsperaAsyncVarredura) {
        # Ha uma checagem remota em voo (Start/Test-VarreduraNovosResultadosRemotoAsync,
        # VisaoRemoting.psm1) - nao da pra parar o Timer agora: ele e o
        # UNICO lugar que ainda vai chamar Test-VarreduraNovosResultadosRemotoAsync
        # de novo pra perceber que ela terminou e liberar
        # $script:SessaoOcupada. Parar aqui deixaria isso preso pra
        # sempre, travando qualquer chamada remota futura. So marca o
        # pedido - Invoke-TickVarredura finaliza de verdade assim que a
        # checagem pendente concluir (sucesso, erro ou timeout).
        $script:Estado.VarreduraCancelada = $true
        $btnCancelar.Enabled = $false
        Add-Log "Cancelando... aguardando a checagem em andamento terminar." "Gray"
        return
    }
    Concluir-CancelamentoVarredura
}.GetNewClosure())

# ============================================================
# EVENTO: Exportar CSV
# ============================================================
$btnExportar.Add_Click({
    $exportarFiltrado = $script:Estado.RedeCompartilhada -and $chkFiltrarZona.Checked
    $ativos = @(if ($exportarFiltrado) {
        $script:Resultados | Where-Object { $_.Online -and $_.PertenceZonaAtual } | Sort-Object { [int]($_.IP -split '\.')[3] }
    } else {
        $script:Resultados | Where-Object { $_.Online } | Sort-Object { [int]($_.IP -split '\.')[3] }
    })
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
}.GetNewClosure())

# ============================================================
# ATUALIZAR STATUS DE 1 MAQUINA (menu de contexto)
# ============================================================
function Invoke-AcaoAtualizarHost {
    param($Resultado)
    if (-not $Resultado -or -not $Resultado.IP) { return }

    Add-Log "Atualizando status de '$($Resultado.Hostname)' ($($Resultado.IP))..." "Cyan"
    $grid.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $idSessao = Start-VarreduraRemota -Ips @($Resultado.IP) -Zona $script:Estado.ZonaAtual -RedeCompartilhada $script:Estado.RedeCompartilhada
        $novoResultado = $null
        $tentativas = 0
        do {
            Start-Sleep -Milliseconds 400
            [System.Windows.Forms.Application]::DoEvents()
            $resp = Get-VarreduraNovosResultadosRemoto -IdSessaoEsperado $idSessao
            if ($resp.SessaoPerdida) { throw "Conexao com o servidor foi perdida." }
            foreach ($n in $resp.Novos) { $novoResultado = $n }
            $tentativas++
        } while ($resp.EmAndamento -and $tentativas -lt 30)

        if (-not $novoResultado) {
            Add-Log "[ERRO] Falha ao atualizar '$($Resultado.IP)' (tempo esgotado)." "OrangeRed"
            return
        }

        # A varredura nova ja devolve a classificacao (EhGateway/
        # PertenceZonaAtual/etc) pronta, diferente do original (que
        # calculava so 1x e preservava por cima do objeto antigo) - aqui
        # da pra so SUBSTITUIR a entrada antiga pela nova inteira.
        $indice = -1
        for ($i = 0; $i -lt $script:Resultados.Count; $i++) {
            if ($script:Resultados[$i].IP -eq $Resultado.IP) { $indice = $i; break }
        }
        if ($indice -ge 0) { $script:Resultados[$indice] = $novoResultado } else { $script:Resultados.Add($novoResultado) }

        try { $script:Estado.MaquinasLiberadasInstalador = Get-MaquinasLiberadasInstalador } catch {}

        Reconstruir-Grid
        Add-Log "Status de '$($novoResultado.Hostname)' ($($novoResultado.IP)) atualizado." "Green"
    } catch {
        Add-Log "[ERRO] Falha ao atualizar '$($Resultado.IP)': $($_.Exception.Message)" "OrangeRed"
    } finally {
        $grid.Cursor = [System.Windows.Forms.Cursors]::Default
    }
}

# ============================================================
# MENU DE CONTEXTO DO GRID (subconjunto da Fase A - Ping, Atualizar,
# VNC, RC; Info de Impressora/WOL/Sistemas Eleitorais/Campanha/CVC
# entram nas fases seguintes)
# ============================================================
$script:Estado.LinhaContextoAtual = $null

$grid.Add_MouseDown({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) {
        # Achado ao vivo (2026-08-27): sem isso, o PRIMEIRO clique direito
        # depois do grid perder o foco (ex: acabou de digitar no campo
        # Numero da Zona) so tira o foco do outro controle e devolve pro
        # grid - o Windows consome esse clique so pra ativar/focar o
        # controle, sem chegar a abrir o ContextMenuStrip; um SEGUNDO
        # clique direito, com o grid ja focado, ai sim abre o menu.
        # Focar explicitamente aqui garante que o MESMO clique que ativa
        # o grid tambem consiga abrir o menu.
        if (-not $grid.Focused) { $grid.Focus() | Out-Null }
        $hit = $grid.HitTest($e.X, $e.Y)
        if ($hit.RowIndex -ge 0) {
            $grid.ClearSelection()
            $grid.Rows[$hit.RowIndex].Selected = $true
            $script:Estado.LinhaContextoAtual = $grid.Rows[$hit.RowIndex]
        } else {
            $script:Estado.LinhaContextoAtual = $null
        }
    }
}.GetNewClosure())

$menuContextoGrid = New-Object System.Windows.Forms.ContextMenuStrip
$grid.ContextMenuStrip = $menuContextoGrid

$menuContextoGrid.Add_Opening({
    param($sender, $e)
    $menuContextoGrid.Items.Clear()
    $linha = $script:Estado.LinhaContextoAtual
    if (-not $linha -or -not $linha.Tag) { $e.Cancel = $true; return }
    $r = $linha.Tag

    # Aliases LOCAIS (sem prefixo $script:) de $script:Estado.* - confirmado
    # ao vivo (2026-08-22) que ler $script:Estado.Chave direto de dentro de
    # um Add_Click ANINHADO dentro deste Add_Opening (dois .GetNewClosure()
    # empilhados, um criado em tempo de execucao de dentro do outro) pode
    # devolver $null mesmo com a chave populada corretamente - o
    # ScannerRedeZona.ps1 original ja tinha batido nesse mesmo caso
    # (aliases locais em Show-JanelaSistemasEleitorais). Variaveis LOCAIS
    # (como $r/$linha logo acima, que sempre funcionaram) sao capturadas
    # corretamente por GetNewClosure() mesmo aninhado - so leitura de
    # $script: aninhada que nao e confiavel.
    $sistemasEleitoraisExtraLocal = $script:Estado.SistemasEleitoraisExtra
    $tabelaVersoesLocal = $script:Estado.TabelaVersoes
    $versaoAtualPorSistemaLocal = $script:Estado.VersaoAtualPorSistema
    $pacotesLocal = $script:Estado.Pacotes
    $campanhasLocal = $script:Estado.Campanhas

    $itemPing = $menuContextoGrid.Items.Add("Ping")
    $itemPing.Add_Click({ Start-PingContinuo -IP $r.IP }.GetNewClosure())

    if ($r.PossivelImpressora) {
        [void]$menuContextoGrid.Items.Add("-")
        $itemInfoImpressora = $menuContextoGrid.Items.Add("Info Impressora")
        $itemInfoImpressora.Add_Click({ Invoke-AcaoInfoImpressoraNaLinha -Resultado $r -Linha $linha }.GetNewClosure())
    }

    $ehHostPc = $r.Hostname -and $r.Hostname -ne "(sem resolucao de nome)" -and -not $r.PossivelImpressora -and -not $r.EhGateway -and -not $r.EhNobreakCentral -and -not $r.EhTelefoneVoip -and -not $r.PossivelmenteDesligado

    if ($ehHostPc) {
        [void]$menuContextoGrid.Items.Add("-")

        if ($r.VncAtivo) {
            $itemVnc = $menuContextoGrid.Items.Add("Abrir VNC")
            $itemVnc.Add_Click({
                $resultadoAcao = Open-VncViewer -IP $r.IP
                if ($resultadoAcao.Sucesso) { Add-Log $resultadoAcao.Mensagem "Cyan" } else { Add-Log "[ERRO] $($resultadoAcao.Mensagem)" "OrangeRed" }
            }.GetNewClosure())
        }
        if ($r.RcIvantiAtivo) {
            $itemRc = $menuContextoGrid.Items.Add("Abrir RCViewer")
            $itemRc.Add_Click({
                $resultadoAcao = Open-RcViewer -IP $r.IP
                if ($resultadoAcao.Sucesso) { Add-Log $resultadoAcao.Mensagem "Cyan" } else { Add-Log "[ERRO] $($resultadoAcao.Mensagem)" "OrangeRed" }
            }.GetNewClosure())
        }

        # So faz sentido oferecer o envio do CVC se a maquina tem SIS
        # instalado - sem SIS, nao ha CVC gerado no InstSeg\CVC pra achar.
        $temSis = $r.VersaoSis -and $r.VersaoSis -ne "-"
        if ($temSis) {
            [void]$menuContextoGrid.Items.Add("-")
            $itemCvc = $menuContextoGrid.Items.Add("Enviar CVC para o Google Drive...")
            $itemCvc.Add_Click({
                $resultadoAcao = Invoke-AcaoEnviarCvcDrive -Resultado $r -AoAtualizarStatus { param($t) Add-Log $t "Gray" }.GetNewClosure()
                if (-not $resultadoAcao.Sucesso) {
                    Add-Log "[ERRO] $($resultadoAcao.Mensagem)" "OrangeRed"
                    [System.Windows.Forms.MessageBox]::Show($resultadoAcao.Mensagem, "Erro", "OK", "Warning") | Out-Null
                } elseif ($resultadoAcao.Metodo -eq "automatico") {
                    Add-Log $resultadoAcao.Mensagem "LightGreen"
                    [System.Windows.Forms.MessageBox]::Show($resultadoAcao.Mensagem, "Envio concluido", "OK", "Information") | Out-Null
                } else {
                    # Fallback manual: a pasta local + a pasta do Drive ja
                    # abrem sozinhas (Explorer/navegador) - isso ja e o
                    # feedback visual, sem precisar de MessageBox tambem
                    # (mesmo comportamento do ScannerRedeZona.ps1 original).
                    Add-Log $resultadoAcao.Mensagem "Cyan"
                }
            }.GetNewClosure())
        }

        # So aparece se a maquina TEM SIS instalado - pedido explicito do
        # usuario (2026-08-27): antes tambem aparecia so por ter algum
        # pacote configurado na planilha, mesmo sem SIS na maquina, o que
        # nao faz sentido pro tecnico (nao ha nada de Sistemas Eleitorais
        # pra verificar/copiar numa maquina sem SIS).
        if ($temSis) {
            [void]$menuContextoGrid.Items.Add("-")
            $itemSistemas = $menuContextoGrid.Items.Add("Sistemas Eleitorais...")
            $itemSistemas.Add_Click({
                try {
                    Show-JanelaSistemasEleitorais -Resultado $r -SistemasEleitoraisExtra $sistemasEleitoraisExtraLocal -TabelaVersoes $tabelaVersoesLocal -VersaoAtualPorSistema $versaoAtualPorSistemaLocal -Pacotes $pacotesLocal -NomeFerramenta $script:NomeFerramenta -AoLog { param($t, $c) Add-Log $t $c }.GetNewClosure()
                } catch {
                    Add-Log "[ERRO] Falha ao abrir a janela de Sistemas Eleitorais: $($_.Exception.Message)" "OrangeRed"
                    [System.Windows.Forms.MessageBox]::Show("Falha ao abrir a janela de Sistemas Eleitorais:`r`n$($_.Exception.Message)`r`n`r`n$($_.ScriptStackTrace)", "Erro", "OK", "Error") | Out-Null
                }
            }.GetNewClosure())
        }

        # Submenu com 1 item por campanha cadastrada - so aparece se a
        # maquina tiver SIS instalado e existir pelo menos 1 campanha
        # configurada (sem isso nao ha o que verificar). $campanha (a
        # variavel do loop) e atribuida FRESCA a cada iteracao, dentro
        # da propria execucao deste Add_Opening - atravessa corretamente
        # pro Add_Click aninhado (mesma familia da Descoberta critica
        # no5/no6: so variavel HERDADA de um closure mais externo, nao
        # atribuida na execucao atual, e que nao atravessa).
        if ($temSis -and $campanhasLocal.Count -gt 0) {
            [void]$menuContextoGrid.Items.Add("-")
            $itemCampanhas = $menuContextoGrid.Items.Add("Verificar Campanha")
            foreach ($campanha in $campanhasLocal) {
                $itemCampanha = $itemCampanhas.DropDownItems.Add($campanha.Nome)
                $itemCampanha.Add_Click({
                    try {
                        Show-JanelaVerificarCampanha -Resultado $r -Campanha $campanha -SistemasEleitoraisExtra $sistemasEleitoraisExtraLocal -NomeFerramenta $script:NomeFerramenta
                    } catch {
                        Add-Log "[ERRO] Falha ao abrir Verificar Campanha: $($_.Exception.Message)" "OrangeRed"
                        [System.Windows.Forms.MessageBox]::Show("Falha ao abrir Verificar Campanha:`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
                    }
                }.GetNewClosure())
            }
        }

        [void]$menuContextoGrid.Items.Add("-")
        $itemAtualizar = $menuContextoGrid.Items.Add("Atualizar Status desta Maquina")
        $itemAtualizar.Add_Click({ Invoke-AcaoAtualizarHost -Resultado $r }.GetNewClosure())
    } elseif ($r.PossivelmenteDesligado -and $r.HardwareId) {
        [void]$menuContextoGrid.Items.Add("-")

        $itemWol = $menuContextoGrid.Items.Add("Ligar Computador (Wake-on-LAN)")
        $itemWol.Add_Click({
            Add-Log "Buscando endereco MAC de '$($r.Hostname)' no OCS Inventory (ID $($r.HardwareId))..." "Gray"
            try {
                $resultadoAcao = Invoke-LigarWolRemoto -HardwareId $r.HardwareId -Ip $r.IP
                if ($resultadoAcao.Ok) {
                    Add-Log $resultadoAcao.Mensagem "Cyan"
                    [System.Windows.Forms.MessageBox]::Show($resultadoAcao.Mensagem, "Wake-on-LAN enviado", "OK", "Information") | Out-Null
                } else {
                    Add-Log "[ERRO] $($resultadoAcao.Mensagem)" "OrangeRed"
                    [System.Windows.Forms.MessageBox]::Show($resultadoAcao.Mensagem, "Erro", "OK", "Error") | Out-Null
                }
            } catch {
                Add-Log "[ERRO] Falha ao enviar Wake-on-LAN: $($_.Exception.Message)" "OrangeRed"
            }
        }.GetNewClosure())

        $itemExcluirOcs = $menuContextoGrid.Items.Add("Abrir para Excluir no OCS Inventory...")
        $itemExcluirOcs.Add_Click({
            $resultadoAcao = Open-ExclusaoOcs -HardwareId $r.HardwareId
            if ($resultadoAcao.Sucesso) { Add-Log $resultadoAcao.Mensagem "Cyan" } else { Add-Log "[ERRO] $($resultadoAcao.Mensagem)" "OrangeRed" }
        }.GetNewClosure())
    }

    if ($menuContextoGrid.Items.Count -eq 0) { $e.Cancel = $true }
}.GetNewClosure())

function Invoke-AcaoInfoImpressoraNaLinha {
    <#
        Chama Invoke-AcaoInfoImpressora (VisaoAcoesLocais.psm1, roda
        local) e, se confirmar Pantum, atualiza a celula "Tipo" da linha
        na grade - a funcao do modulo nao conhece a grade principal (so
        devolve EhPantum), quem decide atualizar a UI e este chamador.
    #>
    param($Resultado, $Linha)

    $grid.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
    try {
        $resultadoAcao = Invoke-AcaoInfoImpressora -Resultado $Resultado
    } finally {
        $grid.Cursor = [System.Windows.Forms.Cursors]::Default
    }
    foreach ($aviso in $resultadoAcao.Avisos) { Add-Log $aviso "Gray" }
    if ($resultadoAcao.EhPantum -and $Linha -and $Linha.Cells["Tipo"]) {
        $Linha.Cells["Tipo"].Value = "Impressora Pantum"
    }
}

$grid.Add_CellDoubleClick({
    param($sender, $e)
    if ($e.RowIndex -lt 0) { return }
    $linhaAtual = $grid.Rows[$e.RowIndex]
    $r = $linhaAtual.Tag
    if (-not $r) { return }
    if ($r.PossivelImpressora) {
        Invoke-AcaoInfoImpressoraNaLinha -Resultado $r -Linha $linhaAtual
    } elseif ($r.VncAtivo) {
        $resultadoAcao = Open-VncViewer -IP $r.IP
        if ($resultadoAcao.Sucesso) { Add-Log $resultadoAcao.Mensagem "Cyan" } else { Add-Log "[ERRO] $($resultadoAcao.Mensagem)" "OrangeRed" }
    } elseif ($r.RcIvantiAtivo) {
        $resultadoAcao = Open-RcViewer -IP $r.IP
        if ($resultadoAcao.Sucesso) { Add-Log $resultadoAcao.Mensagem "Cyan" } else { Add-Log "[ERRO] $($resultadoAcao.Mensagem)" "OrangeRed" }
    }
}.GetNewClosure())

# ============================================================
# BOTOES DE JANELAS AINDA NAO MIGRADAS (Fases B-F)
# ============================================================
$btnGerenciarZonas.Add_Click({
    try {
        Show-GerenciarZonas -Zonas $script:Estado.Zonas -NomeFerramenta $script:NomeFerramenta -AoLog { param($t, $c) Add-Log $t $c }.GetNewClosure() -AoZonasAtualizadas { param($novasZonas) $script:Estado.Zonas = $novasZonas; Atualizar-MaximoZona; Update-LabelSedeInfo }.GetNewClosure()
    } catch {
        Add-Log "[ERRO] Falha ao abrir Gerenciar Zonas: $($_.Exception.Message)" "OrangeRed"
        [System.Windows.Forms.MessageBox]::Show("Falha ao abrir Gerenciar Zonas:`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
    }
}.GetNewClosure())
$btnRelatorioCampanhas.Add_Click({
    try {
        Show-JanelaRelatorioCampanhas -NomeFerramenta $script:NomeFerramenta -AoLog { param($t, $c) Add-Log $t $c }.GetNewClosure()
    } catch {
        Add-Log "[ERRO] Falha ao abrir Relatorio de Campanhas: $($_.Exception.Message)" "OrangeRed"
        [System.Windows.Forms.MessageBox]::Show("Falha ao abrir Relatorio de Campanhas:`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
    }
}.GetNewClosure())
$btnAtualizarFerramenta.Add_Click({
    <#
        Roda de novo o mesmo Instalar-Visao.ps1 usado na instalacao
        inicial (registra o repositorio se precisar, reinstala o modulo,
        desbloqueia os arquivos, recria o atalho/icone da Area de
        Trabalho) - so que com -ReabrirAoTerminar, que faz ele reabrir a
        Visao sozinho ao final em vez de so parar e esperar ENTER. A
        janela atual fecha logo depois de disparar o processo, pra nao
        segurar arquivo nenhum da versao instalada durante a reinstalacao
        (Install-Module -Force reinstala mesmo se a versao for a mesma
        ja instalada - nao so quando ha versao nova).
    #>
    $resposta = [System.Windows.Forms.MessageBox]::Show(
        "Isso vai fechar a Visao agora, atualizar a ferramenta (e o atalho/icone da Area de Trabalho) e reabrir automaticamente a versao mais nova.`r`n`r`nContinuar?",
        "Atualizar Ferramenta",
        [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question
    )
    if ($resposta -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    try {
        Add-Log "Iniciando atualizacao completa da ferramenta - a janela vai fechar e reabrir sozinha em instantes..." "Cyan"
        $caminhoInstalador = '\\POLICY-SERVER.tre-ma.gov.br\ScanZonas\Instalar-VisaoHomolog.ps1'
        $comandoInstalador = "Start-Sleep -Seconds 3; & '$caminhoInstalador' -ReabrirAoTerminar"
        Start-Process -FilePath "powershell.exe" -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-Command', $comandoInstalador)
        $form.Close()
    } catch {
        Add-Log "[ERRO] Falha ao iniciar a atualizacao: $($_.Exception.Message)" "OrangeRed"
        [System.Windows.Forms.MessageBox]::Show("Falha ao iniciar a atualizacao:`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
    }
}.GetNewClosure())
$btnContaSenhaLaps.Add_Click({
    try {
        $resultadoAcao = Invoke-AcaoAbrirContaSenhaLaps -AoAtualizarStatus { param($t) Add-Log $t "Cyan" }.GetNewClosure()
        if ($resultadoAcao.Sucesso) {
            Add-Log $resultadoAcao.Mensagem "Cyan"
        } else {
            Add-Log "[ERRO] $($resultadoAcao.Mensagem)" "OrangeRed"
            [System.Windows.Forms.MessageBox]::Show($resultadoAcao.Mensagem, "ContraSenha-LAPS", "OK", "Error") | Out-Null
        }
    } catch {
        Add-Log "[ERRO] Falha ao abrir ContraSenha-LAPS: $($_.Exception.Message)" "OrangeRed"
        [System.Windows.Forms.MessageBox]::Show("Falha ao abrir ContraSenha-LAPS:`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
    }
}.GetNewClosure())
$btnTransferidorInstseg.Add_Click({
    try {
        $resultadoAcao = Invoke-AcaoAbrirTransferidorInstseg -AoAtualizarStatus { param($t) Add-Log $t "Cyan" }.GetNewClosure()
        if ($resultadoAcao.Sucesso) {
            Add-Log $resultadoAcao.Mensagem "Cyan"
        } else {
            Add-Log "[ERRO] $($resultadoAcao.Mensagem)" "OrangeRed"
            [System.Windows.Forms.MessageBox]::Show($resultadoAcao.Mensagem, "Transferidor Instseg", "OK", "Error") | Out-Null
        }
    } catch {
        Add-Log "[ERRO] Falha ao abrir o Transferidor Instseg: $($_.Exception.Message)" "OrangeRed"
        [System.Windows.Forms.MessageBox]::Show("Falha ao abrir o Transferidor Instseg:`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
    }
}.GetNewClosure())
$btnUsuariosZona.Add_Click({
    try {
        Show-JanelaUsuariosZona -Zona ([int]$numZona.Value) -GruposSistemas $script:Estado.GruposSistemas -NomeFerramenta $script:NomeFerramenta -AoLog { param($t, $c) Add-Log $t $c }.GetNewClosure()
    } catch {
        Add-Log "[ERRO] Falha ao abrir Usuarios da ZE: $($_.Exception.Message)" "OrangeRed"
        [System.Windows.Forms.MessageBox]::Show("Falha ao abrir Usuarios da ZE:`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
    }
}.GetNewClosure())
$btnVerificarCampanhaZona.Add_Click({
    if ($script:Estado.Campanhas.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Nenhuma campanha cadastrada ainda (aba CAMPANHAS da planilha).", "Verificar Campanha", "OK", "Information") | Out-Null
        return
    }
    $linhasComSis = @($grid.Rows | Where-Object { $_.Tag -and $_.Tag.VersaoSis -and $_.Tag.VersaoSis -ne "-" } | ForEach-Object { $_.Tag })
    try {
        $resolucaoZona = Resolve-RedeDaZonaRemoto -Zona $script:Estado.ZonaAtual -Zonas $script:Estado.Zonas
    } catch {
        $resolucaoZona = $null
    }
    $sedeZona = if ($resolucaoZona -and $resolucaoZona.Sede) { $resolucaoZona.Sede } else { "" }
    try {
        Show-JanelaVerificarCampanhaZona -Campanhas $script:Estado.Campanhas -LinhasComSis $linhasComSis -SistemasEleitoraisExtra $script:Estado.SistemasEleitoraisExtra -Zona $script:Estado.ZonaAtual -Sede $sedeZona -NomeFerramenta $script:NomeFerramenta -AoLog { param($t, $c) Add-Log $t $c }.GetNewClosure()
    } catch {
        Add-Log "[ERRO] Falha ao abrir Verificar Campanha da Zona: $($_.Exception.Message)" "OrangeRed"
        [System.Windows.Forms.MessageBox]::Show("Falha ao abrir Verificar Campanha da Zona:`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
    }
}.GetNewClosure())
$btnConfiguracoes.Add_Click({
    # Alias LOCAL de $script:Estado, atribuido AQUI (closure de primeiro
    # nivel) - o callback -AoVersoesAtualizadas abaixo e um SEGUNDO
    # .GetNewClosure() aninhado dentro deste, e ler $script:Estado direto
    # de dentro dele nao seria confiavel (Descoberta critica no5/no6) -
    # mutar $estadoLocal.Chave mesmo assim atualiza o MESMO hashtable que
    # $script:Estado aponta (mesmo objeto por referencia).
    $estadoLocal = $script:Estado
    try {
        Show-Configuracoes -NomeFerramenta $script:NomeFerramenta -AoLog { param($t, $c) Add-Log $t $c }.GetNewClosure() -AoVersoesAtualizadas {
            try {
                $v = Get-VersoesRemoto
                if ($v.Ok) {
                    $estadoLocal.TabelaVersoes = ConvertTo-HashtableLocal $v.TabelaVersoes
                    $estadoLocal.VersaoAtualPorSistema = ConvertTo-HashtableLocal $v.VersaoAtualPorSistema
                    $estadoLocal.Pacotes = @($v.Pacotes)
                    Add-Log "Planilha de versoes de sistemas eleitorais recarregada: $($v.Contagem) pacote(s) (origem: $($v.Origem))." "Cyan"
                    Reconstruir-Grid
                }
            } catch {
                Add-Log "[AVISO] Falha ao recarregar planilha de versoes apos salvar: $($_.Exception.Message)" "Yellow"
            }
        }.GetNewClosure()
    } catch {
        Add-Log "[ERRO] Falha ao abrir Configuracoes: $($_.Exception.Message)" "OrangeRed"
        [System.Windows.Forms.MessageBox]::Show("Falha ao abrir Configuracoes:`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
    }
}.GetNewClosure())
$btnFechar.Add_Click({ $form.Close() }.GetNewClosure())

# ============================================================
# INICIALIZACAO
# ============================================================
$form.Add_Shown({
    if (-not (Connect-ServidorVisao)) {
        $lblStatus.Text = "Falha ao conectar ao POLICY-SERVER - a ferramenta nao pode funcionar sem essa conexao."
        Add-Log "[ERRO] Falha ao conectar ao POLICY-SERVER.tre-ma.gov.br - verifique a rede/VPN e reabra a ferramenta." "OrangeRed"
        [System.Windows.Forms.MessageBox]::Show("Nao foi possivel conectar ao POLICY-SERVER. Verifique a rede/VPN e tente novamente.", "Erro de conexao", "OK", "Error") | Out-Null
        return
    }
    Add-Log "Conectado ao POLICY-SERVER." "Cyan"

    try {
        $script:Estado.SistemasEleitoraisExtra = Get-SistemasEleitoraisExtraRemoto
        foreach ($sis in $script:Estado.SistemasEleitoraisExtra) {
            if (-not $sis.NaGradePrincipal) { continue }
            Add-ColunaGrid $sis.Coluna $sis.Titulo $sis.Largura
        }
    } catch {
        Add-Log "[AVISO] Falha ao carregar schema de sistemas eleitorais: $($_.Exception.Message)" "Yellow"
    }

    try {
        $z = Get-ZonasRemoto
        $script:Estado.Zonas = @($z.Zonas)
        Add-Log "Tabela de zonas carregada: $($z.Contagem) zona(s) (origem: $($z.Origem))." "Gray"
        foreach ($aviso in $z.Avisos) { Add-Log "[AVISO] $aviso" "Yellow" }
        Atualizar-MaximoZona
    } catch {
        Add-Log "[ERRO] Falha ao carregar tabela de zonas: $($_.Exception.Message)" "OrangeRed"
    }

    try {
        $g = Get-GruposSistemasRemoto
        if ($g.Ok) {
            $script:Estado.GruposSistemas = ConvertTo-HashtableLocal $g.GruposSistemas
            Add-Log "Planilha de grupos/sistemas carregada: $($g.Contagem) grupo(s) (origem: $($g.Origem))." "Gray"
        } else {
            Add-Log "Planilha de grupos/sistemas nao configurada/vazia - segue sem mapeamento de grupos." "Gray"
        }
        foreach ($aviso in $g.Avisos) { Add-Log "[AVISO] $aviso" "Yellow" }
    } catch {
        Add-Log "[AVISO] Falha ao carregar planilha de grupos/sistemas: $($_.Exception.Message)" "Yellow"
    }

    try {
        $v = Get-VersoesRemoto
        if ($v.Ok) {
            $script:Estado.TabelaVersoes = ConvertTo-HashtableLocal $v.TabelaVersoes
            $script:Estado.VersaoAtualPorSistema = ConvertTo-HashtableLocal $v.VersaoAtualPorSistema
            $script:Estado.Pacotes = @($v.Pacotes)
            Add-Log "Planilha de versoes de sistemas eleitorais carregada: $($v.Contagem) pacote(s) (origem: $($v.Origem))." "Gray"
        } else {
            Add-Log "Planilha de versoes de sistemas eleitorais nao configurada ($($v.Erro)) - segue sem destaque de versao atualizada/desatualizada." "Gray"
        }
    } catch {
        Add-Log "[AVISO] Falha ao carregar planilha de versoes: $($_.Exception.Message)" "Yellow"
    }

    try {
        $c = Get-CampanhasRemoto
        if ($c.Ok) {
            $script:Estado.Campanhas = @($c.Campanhas)
            Add-Log "Planilha de campanhas carregada: $($c.Contagem) campanha(s) (origem: $($c.Origem))." "Gray"
        } else {
            Add-Log "Planilha de campanhas nao configurada/vazia - segue sem campanhas." "Gray"
        }
        foreach ($aviso in $c.Avisos) { Add-Log "[AVISO] $aviso" "Yellow" }
    } catch {
        Add-Log "[AVISO] Falha ao carregar planilha de campanhas: $($_.Exception.Message)" "Yellow"
    }

    Update-LabelSedeInfo
    $numZona.Enabled = $true
    $btnIniciar.Enabled = $true
    $lblStatus.Text = "Pronto. Informe a zona e clique em Iniciar Varredura."
}.GetNewClosure())

$form.Add_FormClosing({
    if ($timer.Enabled) {
        $timer.Stop()
    }
}.GetNewClosure())

$form.Add_FormClosed({ Disconnect-ServidorVisao }.GetNewClosure())

[void]$form.ShowDialog()
