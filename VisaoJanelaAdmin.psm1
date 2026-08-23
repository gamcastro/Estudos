<#
    VisaoJanelaAdmin.psm1

    Janelas administrativas - roda LOCAL na estacao do tecnico (mesmo
    espirito dos outros modulos de janela: escopo proprio, tudo que
    precisa de $script:Estado do VisaoCliente.ps1 vem por PARAMETRO).
    Relocacao de Show-JanelaUsuariosZona/Show-GerenciarZonas do
    ScannerRedeZona.ps1 original.

    Show-JanelaUsuariosZona: consulta o AD (Get-UsuariosDaZona, ja pronta
    em VisaoAD.psm1 desde a migracao de remoting - sem duplo-salto de
    Kerberos, roda direto aqui) - nao precisa de remoting nenhum, so o
    mapeamento Grupo->Sistema/Perfil (planilha, ja carregado no servidor)
    vem por parametro.

    Show-GerenciarZonas: le/edita a planilha de Zonas via
    Get-ZonasRemoto/Send-AtualizacaoZonaRemoto (Fase 6/7 ja prontas,
    estendidas nesta fase pra devolver os dados de verdade, nao so um
    status de carregamento). Estado mutavel COMPARTILHADO entre os
    closures desta janela (a lista de zonas atual, que "Atualizar da
    Planilha"/"Salvar" recarregam) fica num hashtable UNICO criado antes
    de qualquer closure e sempre MUTADO - mesma disciplina de
    $script:Estado do VisaoCliente.ps1 (Descoberta critica no4), so que
    aqui e uma variavel LOCAL da funcao (nao precisa de $script:, ja que
    todos os closures desta janela sao de PRIMEIRO NIVEL, direto no corpo
    de Show-GerenciarZonas - nenhum aninhado dentro de outro).

    Show-Configuracoes (Fase F): VNC/RC/SNMP ficam so no cliente (sem
    remoting - sao caminho de exe/config de UI, ver
    VisaoAcoesLocais.psm1); os outros 4 (Envio ao Drive, Versoes de
    Sistemas, Atualizacao de Zonas, Envio de Campanha) sao configs
    COMPARTILHADOS gravados no servidor (Get/Set-Config*Remoto). O
    original so tinha abas de UI pras 2 primeiras (Drive/Versoes) - as
    outras 2 (Zonas/Campanhas) so existiam via um InputBox de
    "primeira configuracao" disparado sob demanda, que nao faz sentido
    mais porque o servidor roda headless (ninguem pra responder um
    InputBox la) - viraram abas de verdade aqui.
#>

function Remove-Acentos {
    <# Relocacao pura do original - usada so pro fallback "rede calculada" (Sao Luis). #>
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

function ConvertTo-CidrRede {
    <#
        Normaliza o que o tecnico digita no campo "Substituta" (ex:
        "10.50.3", "10.50.3.", "10.50.3.0/24") para o formato CIDR
        "10.50.3.0/24". Relocacao pura do original.
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
    return $Rede
}

function Show-JanelaUsuariosZona {
    param(
        [Parameter(Mandatory)][int]$Zona,
        [hashtable]$GruposSistemas,
        [string]$NomeFerramenta = "Visao",
        [scriptblock]$AoLog = $null
    )
    if (-not $AoLog) { $AoLog = { param($Texto, $Cor) } }
    if (-not $GruposSistemas) { $GruposSistemas = @{} }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "$NomeFerramenta - Usuarios da ZE $Zona"
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
        $lblItem.Text = "$Texto"
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
            $mapeamento = $GruposSistemas[$grupo.Nome.ToUpper()]
            if (-not $mapeamento) { continue }
            $idxGrupo = $gridGrupos.Rows.Add(@($grupo.Nome, $mapeamento.Sistema, $mapeamento.Perfil))
            $gridGrupos.Rows[$idxGrupo].Cells["Nome"].ToolTipText = $grupo.Caminho
        }
    }.GetNewClosure())

    $dlg.Add_Shown({
        [System.Windows.Forms.Application]::DoEvents()
        $usuarios = $null
        try {
            $usuarios = Get-UsuariosDaZona -Zona $Zona
        } catch {
            $lblStatusUsuarios.Text = "Falha ao consultar o AD: $($_.Exception.Message)"
            $lblStatusUsuarios.ForeColor = [System.Drawing.Color]::Firebrick
            & $AoLog "[ERRO] Falha ao consultar usuarios da zona $Zona no AD: $($_.Exception.Message)" "OrangeRed"
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

    [void]$dlg.ShowDialog()
}

function Show-GerenciarZonas {
    <#
        $Zonas (array de {Zona;Sede;RedePadrao;Substituta;Observacao}) vem
        PRONTO de quem chama, ja carregado na conexao (Get-ZonasRemoto) -
        evita uma chamada de rede redundante so pra abrir a janela.
        "Atualizar da Planilha"/"Salvar" recarregam de verdade.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Zonas,
        [string]$NomeFerramenta = "Visao",
        [scriptblock]$AoLog = $null,
        [scriptblock]$AoZonasAtualizadas = $null
    )
    if (-not $AoLog) { $AoLog = { param($Texto, $Cor) } }
    if (-not $AoZonasAtualizadas) { $AoZonasAtualizadas = { param($NovasZonas) } }

    # Estado mutavel desta janela - criado ANTES de qualquer closure,
    # sempre MUTADO (nunca reatribuido por inteiro). Ver nota no topo do
    # arquivo.
    $estadoJanela = @{ Zonas = @($Zonas) }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "$NomeFerramenta - Gerenciar Zonas Eleitorais - Redes e Substitutas (planilha)"
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
        param([string]$Filtro = "")
        $gridZonas.Rows.Clear()
        $filtroLower = $Filtro.Trim().ToLower()
        foreach ($z in ($estadoJanela.Zonas | Sort-Object Zona)) {
            $sede = $z.Sede
            if ($filtroLower) {
                $bate = ("$($z.Zona)".Contains($filtroLower)) -or ($sede -and $sede.ToLower().Contains($filtroLower))
                if (-not $bate) { continue }
            }

            $redePadraoTxt = if ($z.RedePadrao) {
                $z.RedePadrao
            } else {
                $sedeSemAcento = (Remove-Acentos $sede).ToUpper().Trim()
                if ($sedeSemAcento -eq "SAO LUIS") { "10.11.81.0/24 (calculado)" } else { "10.198.$($z.Zona).0/24 (calculado)" }
            }

            $substitutaAtual = if ($z.Substituta) { $z.Substituta } else { "" }
            $obsAtual = if ($z.Observacao) { $z.Observacao } else { "" }

            $rowIndex = $gridZonas.Rows.Add("$($z.Zona)", $sede, $redePadraoTxt, $substitutaAtual, $obsAtual)
            if ($substitutaAtual) {
                $gridZonas.Rows[$rowIndex].DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 245, 220)
            }
        }
        $lblContagem.Text = "$($gridZonas.Rows.Count) zona(s)"
    }.GetNewClosure()

    & $populaGridZonas -Filtro ""
    $txtFiltro.Add_TextChanged({ & $populaGridZonas -Filtro $txtFiltro.Text }.GetNewClosure())

    $btnAtualizarPlanilha.Add_Click({
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $resp = Get-ZonasRemoto
        } catch {
            $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
            & $AoLog "[ERRO] Falha ao atualizar tabela de zonas: $($_.Exception.Message)" "OrangeRed"
            [System.Windows.Forms.MessageBox]::Show("Falha ao atualizar: $($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
            return
        }
        $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
        if ($resp.Ok) {
            $estadoJanela.Zonas = @($resp.Zonas)
            & $populaGridZonas -Filtro $txtFiltro.Text
            & $AoZonasAtualizadas $estadoJanela.Zonas
            [System.Windows.Forms.MessageBox]::Show("Planilha de zonas atualizada: $($estadoJanela.Zonas.Count) zona(s).", "OK", "OK", "Information") | Out-Null
        } else {
            & $AoLog "[AVISO] Falha ao atualizar tabela de zonas: $($resp.Erro)" "Yellow"
            [System.Windows.Forms.MessageBox]::Show("Nao foi possivel atualizar: $($resp.Erro)", "Aviso", "OK", "Warning") | Out-Null
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
        $alterados = New-Object System.Collections.Generic.List[object]
        foreach ($row in $gridZonas.Rows) {
            $z = [int]$row.Cells["Zona"].Value
            $substitutaGrid = ConvertTo-CidrRede "$($row.Cells["Override"].Value)"
            $obsGrid = "$($row.Cells["Observacao"].Value)".Trim()

            $zonaInfo = $estadoJanela.Zonas | Where-Object { $_.Zona -eq $z } | Select-Object -First 1
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
            try {
                $resp = Send-AtualizacaoZonaRemoto -Zona $alt.Zona -Substituta $alt.Substituta -Observacao $alt.Observacao
                if ($resp.Ok) { $sucesso++ } else { $falha++; & $AoLog "[ERRO] $($resp.Mensagem)" "OrangeRed" }
            } catch {
                $falha++
                & $AoLog "[ERRO] Falha ao salvar zona $($alt.Zona): $($_.Exception.Message)" "OrangeRed"
            }
        }

        if ($sucesso -gt 0) {
            try {
                $respRecarregar = Get-ZonasRemoto
                if ($respRecarregar.Ok) { $estadoJanela.Zonas = @($respRecarregar.Zonas) }
            } catch {}
        }
        $dlg.Cursor = [System.Windows.Forms.Cursors]::Default

        & $AoLog "Planilha de zonas atualizada: $sucesso zona(s) salva(s)$(if ($falha -gt 0) { ", $falha falharam (ver log)" })." "Cyan"
        & $populaGridZonas -Filtro $txtFiltro.Text
        & $AoZonasAtualizadas $estadoJanela.Zonas

        $msg = "$sucesso zona(s) salva(s) na planilha."
        if ($falha -gt 0) { $msg += "`r`n$falha falharam - ver log da janela principal." }
        [System.Windows.Forms.MessageBox]::Show($msg, "Concluido", "OK", "Information") | Out-Null
    }.GetNewClosure())

    $btnFecharGz.Add_Click({ $dlg.Close() }.GetNewClosure())

    [void]$dlg.ShowDialog()
}

function Resolve-IdEGidPlanilha {
    <#
        Aceita tanto o ID puro da planilha quanto a URL inteira colada do
        navegador (.../spreadsheets/d/<ID>/edit#gid=123456) e devolve
        {Id;Gid}, pra o tecnico nao precisar recortar nada na mao. Sem
        gid na URL (ou so o ID puro), assume gid=0 (1a aba). Relocacao
        pura do original.
    #>
    param([string]$Entrada)
    if (-not $Entrada) { return $null }
    $Entrada = $Entrada.Trim()
    $id = if ($Entrada -match "/d/([a-zA-Z0-9_-]+)") { $Matches[1] } else { $Entrada }
    $gid = if ($Entrada -match "[#&?]gid=(\d+)") { $Matches[1] } else { "0" }
    return [PSCustomObject]@{ Id = $id; Gid = $gid }
}

function Show-Configuracoes {
    param(
        [string]$NomeFerramenta = "Visao",
        [scriptblock]$AoLog = $null,
        [scriptblock]$AoVersoesAtualizadas = $null
    )
    if (-not $AoLog) { $AoLog = { param($Texto, $Cor) } }
    if (-not $AoVersoesAtualizadas) { $AoVersoesAtualizadas = {} }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "$NomeFerramenta - Configuracoes da Ferramenta"
    $dlg.Size = New-Object System.Drawing.Size(530, 560)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $tabs = New-Object System.Windows.Forms.TabControl
    $tabs.Location = New-Object System.Drawing.Point(12, 12)
    $tabs.Size = New-Object System.Drawing.Size(495, 455)
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
    $txtVnc.Text = Get-CaminhoVncViewerAtual
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
    $txtRc.Text = Get-CaminhoRcViewerAtual
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
    $txtSnmp.Text = Get-ComunidadeSnmp
    $tabSnmp.Controls.Add($txtSnmp)

    # --- Aba Envio ao Google Drive ---
    $tabDrive = New-Object System.Windows.Forms.TabPage
    $tabDrive.Text = "Envio ao Drive"
    $tabs.TabPages.Add($tabDrive)

    $cfgDriveAtual = $null
    try { $cfgDriveAtual = Get-ConfigEnvioDriveRemoto } catch {}

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

    $cfgVersoesAtual = $null
    try { $cfgVersoesAtual = Get-ConfigVersoesRemoto } catch {}

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

    # --- Aba Atualizacao de Zonas (nova - Fase F) ---
    $tabZonasWebApp = New-Object System.Windows.Forms.TabPage
    $tabZonasWebApp.Text = "Atualizacao de Zonas"
    $tabs.TabPages.Add($tabZonasWebApp)

    $cfgZonasAtual = $null
    try { $cfgZonasAtual = Get-ConfigZonasWebAppRemoto } catch {}

    $lblZonasUrl = New-Object System.Windows.Forms.Label
    $lblZonasUrl.Text = "URL do Web App do Apps Script que ATUALIZA a planilha de zonas (usado por 'Gerenciar Redes Zonas' > Salvar), termina em /exec:"
    $lblZonasUrl.Location = New-Object System.Drawing.Point(15, 20)
    $lblZonasUrl.Size = New-Object System.Drawing.Size(455, 35)
    $tabZonasWebApp.Controls.Add($lblZonasUrl)

    $txtZonasUrl = New-Object System.Windows.Forms.TextBox
    $txtZonasUrl.Location = New-Object System.Drawing.Point(15, 60)
    $txtZonasUrl.Width = 455
    $txtZonasUrl.Text = if ($cfgZonasAtual) { $cfgZonasAtual.UrlWebApp } else { "" }
    $tabZonasWebApp.Controls.Add($txtZonasUrl)

    $lblZonasToken = New-Object System.Windows.Forms.Label
    $lblZonasToken.Text = "Token combinado com o script (mesmo valor da constante TOKEN no Apps Script):"
    $lblZonasToken.Location = New-Object System.Drawing.Point(15, 100)
    $lblZonasToken.Size = New-Object System.Drawing.Size(455, 20)
    $tabZonasWebApp.Controls.Add($lblZonasToken)

    $txtZonasToken = New-Object System.Windows.Forms.TextBox
    $txtZonasToken.Location = New-Object System.Drawing.Point(15, 125)
    $txtZonasToken.Width = 455
    $txtZonasToken.Text = if ($cfgZonasAtual) { $cfgZonasAtual.Token } else { "" }
    $tabZonasWebApp.Controls.Add($txtZonasToken)

    # --- Aba Envio de Campanha (nova - Fase F) ---
    $tabCampanhasWebApp = New-Object System.Windows.Forms.TabPage
    $tabCampanhasWebApp.Text = "Envio de Campanha"
    $tabs.TabPages.Add($tabCampanhasWebApp)

    $cfgCampanhasAtual = $null
    try { $cfgCampanhasAtual = Get-ConfigCampanhasWebAppRemoto } catch {}

    $lblCampanhasUrl = New-Object System.Windows.Forms.Label
    $lblCampanhasUrl.Text = "URL do Web App do Apps Script que REGISTRA o resultado de 'Verificar Campanha da Zona' > Enviar Resultado, termina em /exec:"
    $lblCampanhasUrl.Location = New-Object System.Drawing.Point(15, 20)
    $lblCampanhasUrl.Size = New-Object System.Drawing.Size(455, 35)
    $tabCampanhasWebApp.Controls.Add($lblCampanhasUrl)

    $txtCampanhasUrl = New-Object System.Windows.Forms.TextBox
    $txtCampanhasUrl.Location = New-Object System.Drawing.Point(15, 60)
    $txtCampanhasUrl.Width = 455
    $txtCampanhasUrl.Text = if ($cfgCampanhasAtual) { $cfgCampanhasAtual.UrlWebApp } else { "" }
    $tabCampanhasWebApp.Controls.Add($txtCampanhasUrl)

    $lblCampanhasToken = New-Object System.Windows.Forms.Label
    $lblCampanhasToken.Text = "Token combinado com o script (mesmo valor da constante TOKEN no Apps Script):"
    $lblCampanhasToken.Location = New-Object System.Drawing.Point(15, 100)
    $lblCampanhasToken.Size = New-Object System.Drawing.Size(455, 20)
    $tabCampanhasWebApp.Controls.Add($lblCampanhasToken)

    $txtCampanhasToken = New-Object System.Windows.Forms.TextBox
    $txtCampanhasToken.Location = New-Object System.Drawing.Point(15, 125)
    $txtCampanhasToken.Width = 455
    $txtCampanhasToken.Text = if ($cfgCampanhasAtual) { $cfgCampanhasAtual.Token } else { "" }
    $tabCampanhasWebApp.Controls.Add($txtCampanhasToken)

    # --- Botoes ---
    $btnSalvarConfig = New-Object System.Windows.Forms.Button
    $btnSalvarConfig.Text = "Salvar"
    $btnSalvarConfig.Location = New-Object System.Drawing.Point(320, 478)
    $btnSalvarConfig.Width = 90
    $btnSalvarConfig.Height = 30
    $btnSalvarConfig.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
    $btnSalvarConfig.ForeColor = [System.Drawing.Color]::White
    $dlg.Controls.Add($btnSalvarConfig)

    $btnFecharConfig = New-Object System.Windows.Forms.Button
    $btnFecharConfig.Text = "Fechar"
    $btnFecharConfig.Location = New-Object System.Drawing.Point(415, 478)
    $btnFecharConfig.Width = 90
    $btnFecharConfig.Height = 30
    $dlg.Controls.Add($btnFecharConfig)

    $btnSalvarConfig.Add_Click({
        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        $itensSalvos = New-Object System.Collections.Generic.List[string]
        $itensComErro = New-Object System.Collections.Generic.List[string]

        if ($txtVnc.Text -and $txtVnc.Text.Trim()) {
            Set-CaminhoVncViewer -Caminho $txtVnc.Text.Trim()
            $itensSalvos.Add("VNC Viewer")
        }
        if ($txtRc.Text -and $txtRc.Text.Trim()) {
            Set-CaminhoRcViewer -Caminho $txtRc.Text.Trim()
            $itensSalvos.Add("RCViewer")
        }
        if ($txtSnmp.Text -and $txtSnmp.Text.Trim()) {
            Set-ComunidadeSnmp -Comunidade $txtSnmp.Text.Trim()
            $itensSalvos.Add("SNMP")
        }
        if ($txtDriveUrl.Text.Trim() -and $txtDriveToken.Text.Trim()) {
            try {
                $resp = Set-ConfigEnvioDriveRemoto -UrlWebApp $txtDriveUrl.Text.Trim() -Token $txtDriveToken.Text.Trim()
                if ($resp.Ok) { $itensSalvos.Add("Envio ao Drive") } else { $itensComErro.Add("Envio ao Drive ($($resp.Mensagem))") }
            } catch { $itensComErro.Add("Envio ao Drive ($($_.Exception.Message))") }
        }
        if ($txtVersoes.Text -and $txtVersoes.Text.Trim()) {
            $refVersoes = Resolve-IdEGidPlanilha $txtVersoes.Text
            try {
                $resp = Set-ConfigVersoesRemoto -SpreadsheetId $refVersoes.Id -Gid $refVersoes.Gid
                if ($resp.Ok) {
                    $itensSalvos.Add("Versoes de Sistemas")
                    & $AoVersoesAtualizadas
                } else {
                    $itensComErro.Add("Versoes de Sistemas ($($resp.Mensagem))")
                }
            } catch { $itensComErro.Add("Versoes de Sistemas ($($_.Exception.Message))") }
        }
        if ($txtZonasUrl.Text.Trim() -and $txtZonasToken.Text.Trim()) {
            try {
                $resp = Set-ConfigZonasWebAppRemoto -UrlWebApp $txtZonasUrl.Text.Trim() -Token $txtZonasToken.Text.Trim()
                if ($resp.Ok) { $itensSalvos.Add("Atualizacao de Zonas") } else { $itensComErro.Add("Atualizacao de Zonas ($($resp.Mensagem))") }
            } catch { $itensComErro.Add("Atualizacao de Zonas ($($_.Exception.Message))") }
        }
        if ($txtCampanhasUrl.Text.Trim() -and $txtCampanhasToken.Text.Trim()) {
            try {
                $resp = Set-ConfigCampanhasWebAppRemoto -UrlWebApp $txtCampanhasUrl.Text.Trim() -Token $txtCampanhasToken.Text.Trim()
                if ($resp.Ok) { $itensSalvos.Add("Envio de Campanha") } else { $itensComErro.Add("Envio de Campanha ($($resp.Mensagem))") }
            } catch { $itensComErro.Add("Envio de Campanha ($($_.Exception.Message))") }
        }

        $dlg.Cursor = [System.Windows.Forms.Cursors]::Default

        if ($itensSalvos.Count -gt 0) { & $AoLog "Configuracoes salvas: $($itensSalvos -join ', ')." "Cyan" }
        foreach ($erro in $itensComErro) { & $AoLog "[ERRO] Falha ao salvar $erro" "OrangeRed" }

        $msg = if ($itensSalvos.Count -gt 0) { "Salvo: $($itensSalvos -join ', ')." } else { "Nada pra salvar (nenhum campo preenchido)." }
        if ($itensComErro.Count -gt 0) { $msg += "`r`n`r`nFalhou: $($itensComErro -join '; ')" }
        [System.Windows.Forms.MessageBox]::Show($msg, "Configuracoes", "OK", $(if ($itensComErro.Count -gt 0) { "Warning" } else { "Information" })) | Out-Null
    }.GetNewClosure())

    $btnFecharConfig.Add_Click({ $dlg.Close() }.GetNewClosure())

    [void]$dlg.ShowDialog()
}

Export-ModuleMember -Function Remove-Acentos, ConvertTo-CidrRede, Resolve-IdEGidPlanilha, Show-JanelaUsuariosZona, Show-GerenciarZonas, Show-Configuracoes
