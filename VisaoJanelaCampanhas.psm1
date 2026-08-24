<#
    VisaoJanelaCampanhas.psm1

    Janelas de Campanha - roda LOCAL na estacao do tecnico (mesmo espirito
    de VisaoJanelaPacotes.psm1: escopo de modulo proprio, tudo que precisa
    de $script:Estado do VisaoCliente.ps1 vem por PARAMETRO). Relocacao de
    Show-JanelaVerificarCampanha/Show-JanelaVerificarCampanhaZona/
    Show-JanelaRelatorioCampanhas do ScannerRedeZona.ps1 original, com as
    mesmas duas adaptacoes ja estabelecidas na Fase C:

    1) $script:TabelaCampanhas/$script:SistemasEleitoraisExtra/
       $script:ZonaAtual/$script:NomeFerramenta viram PARAMETRO - cada
       .psm1 tem seu proprio escopo $script:, isolado do de
       VisaoCliente.ps1.

    2) Verificar Campanha (1 maquina) e Verificar Campanha da Zona nao
       dependem de rede nenhuma - toda a informacao ja esta em memoria
       (dados da varredura + planilha de campanhas ja carregada via
       Get-CampanhasRemoto). So "Enviar Resultado..." (Web App do Apps
       Script, Fase 7 ja pronta) e o Relatorio de Campanhas (busca o
       historico via Get-ResultadosCampanhasRemoto, Fase 6 ja pronta)
       tocam a rede.
#>

function Compare-VersaoSistema {
    <#
        Compara duas versoes no formato N.N.N segmento por segmento,
        NUMERICAMENTE - "1.9" e menor que "1.10", mesmo sendo maior como
        texto puro. Devolve -1 (A < B), 0 (iguais) ou 1 (A > B); $null se
        algum segmento nao for um numero. Relocacao pura do original.
    #>
    param([string]$VersaoA, [string]$VersaoB)
    if (-not $VersaoA -or -not $VersaoB) { return $null }
    $a = $VersaoA.Trim() -split '\.'
    $b = $VersaoB.Trim() -split '\.'
    $max = [Math]::Max($a.Count, $b.Count)
    for ($i = 0; $i -lt $max; $i++) {
        $na = 0; $nb = 0
        $okA = if ($i -lt $a.Count) { [int]::TryParse($a[$i], [ref]$na) } else { $true }
        $okB = if ($i -lt $b.Count) { [int]::TryParse($b[$i], [ref]$nb) } else { $true }
        if (-not $okA -or -not $okB) { return $null }
        if ($na -ne $nb) { return [Math]::Sign($na - $nb) }
    }
    return 0
}

function Get-VersaoInstaladaPorNomeSistema {
    <#
        Acha a versao instalada (num $Resultado ja escaneado) do sistema
        cujo nome bate com $NomeSistema - aceita "SIS" (caso especial,
        propriedade VersaoSis) ou o Titulo/NomeVersaoAtual/Chave de
        qualquer entrada de $SistemasEleitoraisExtra (sem diferenciar
        maiusculas), pra aceitar tanto "ExecJava" quanto "EXECJAVA"
        cadastrado na planilha de Campanhas. Devolve $null se o nome do
        sistema nao for reconhecido.
    #>
    param($Resultado, [string]$NomeSistema, [object[]]$SistemasEleitoraisExtra)
    if (-not $NomeSistema) { return $null }
    $nomeUpper = $NomeSistema.Trim().ToUpper()
    if ($nomeUpper -eq "SIS") { return $Resultado.VersaoSis }
    $item = $SistemasEleitoraisExtra | Where-Object {
        $_.NomeVersaoAtual.ToUpper() -eq $nomeUpper -or $_.Titulo.ToUpper() -eq $nomeUpper -or $_.Chave.ToUpper() -eq $nomeUpper
    } | Select-Object -First 1
    if (-not $item) { return $null }
    return $Resultado.($item.Propriedade)
}

function Show-JanelaVerificarCampanha {
    <#
        Confere se a maquina em $Resultado atende aos requisitos minimos
        de versao da campanha $Campanha. Nao depende de rede nem AD - toda
        a informacao ja esta em memoria.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Resultado,
        [Parameter(Mandatory)][PSCustomObject]$Campanha,
        [object[]]$SistemasEleitoraisExtra,
        [string]$NomeFerramenta = "Visao"
    )

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "$NomeFerramenta - Verificar Campanha - $($Resultado.Hostname) ($($Resultado.IP))"
    $dlg.Size = New-Object System.Drawing.Size(650, 430)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $lblCampanha = New-Object System.Windows.Forms.Label
    $lblCampanha.Text = "Campanha: $($Campanha.Nome)"
    $lblCampanha.Location = New-Object System.Drawing.Point(15, 15)
    $lblCampanha.AutoSize = $true
    $lblCampanha.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($lblCampanha)

    $gridReq = New-Object System.Windows.Forms.DataGridView
    $gridReq.Location = New-Object System.Drawing.Point(15, 45)
    $gridReq.Size = New-Object System.Drawing.Size(605, 270)
    $gridReq.Anchor = "Top,Bottom,Left,Right"
    $gridReq.AllowUserToAddRows = $false
    $gridReq.AllowUserToDeleteRows = $false
    $gridReq.ReadOnly = $true
    $gridReq.RowHeadersVisible = $false
    $gridReq.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $gridReq.MultiSelect = $false
    $gridReq.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None
    $dlg.Controls.Add($gridReq)

    function Add-ColunaGridReq {
        param($Nome, $Titulo, $Largura)
        $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $c.Name = $Nome; $c.HeaderText = $Titulo; $c.Width = $Largura
        [void]$gridReq.Columns.Add($c)
    }
    Add-ColunaGridReq "Sistema" "Sistema" 165
    Add-ColunaGridReq "Minimo" "Minimo Exigido" 130
    Add-ColunaGridReq "Instalado" "Instalado" 120
    Add-ColunaGridReq "Status" "Status" 175

    $lblResumo = New-Object System.Windows.Forms.Label
    $lblResumo.Location = New-Object System.Drawing.Point(15, 325)
    $lblResumo.Size = New-Object System.Drawing.Size(605, 40)
    $lblResumo.Anchor = "Bottom,Left,Right"
    $lblResumo.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($lblResumo)

    $btnFecharCampanha = New-Object System.Windows.Forms.Button
    $btnFecharCampanha.Text = "Fechar"
    $btnFecharCampanha.Location = New-Object System.Drawing.Point(535, 355)
    $btnFecharCampanha.Width = 85
    $btnFecharCampanha.Height = 28
    $btnFecharCampanha.Anchor = "Bottom,Right"
    $dlg.Controls.Add($btnFecharCampanha)
    $btnFecharCampanha.Add_Click({ $dlg.Close() }.GetNewClosure())

    $atendeTodos = $true
    foreach ($req in $Campanha.Requisitos) {
        $instalado = Get-VersaoInstaladaPorNomeSistema -Resultado $Resultado -NomeSistema $req.Sistema -SistemasEleitoraisExtra $SistemasEleitoraisExtra
        $temInstalado = $instalado -and $instalado -ne "-"
        $instaladoTxt = if ($temInstalado) { $instalado } else { "-" }

        if (-not $temInstalado) {
            $statusTxt = "Nao instalado"
            $cor = [System.Drawing.Color]::FromArgb(220, 53, 69)
            $atendeTodos = $false
        } else {
            $cmp = Compare-VersaoSistema -VersaoA $instalado -VersaoB $req.VersaoMinima
            if ($null -eq $cmp) {
                $statusTxt = "Versao nao reconhecida"
                $cor = [System.Drawing.Color]::FromArgb(200, 100, 0)
                $atendeTodos = $false
            } elseif ($cmp -ge 0) {
                $statusTxt = "OK"
                $cor = [System.Drawing.Color]::FromArgb(0, 128, 0)
            } else {
                $statusTxt = "Desatualizado"
                $cor = [System.Drawing.Color]::FromArgb(220, 53, 69)
                $atendeTodos = $false
            }
        }

        $idxReq = $gridReq.Rows.Add(@($req.Sistema, $req.VersaoMinima, $instaladoTxt, $statusTxt))
        $rowReq = $gridReq.Rows[$idxReq]
        $rowReq.Cells["Status"].Style.ForeColor = $cor
        $rowReq.Cells["Status"].Style.Font = New-Object System.Drawing.Font($gridReq.Font, [System.Drawing.FontStyle]::Bold)
    }

    if ($atendeTodos) {
        $lblResumo.Text = "ATENDE aos requisitos da campanha '$($Campanha.Nome)'."
        $lblResumo.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
    } else {
        $lblResumo.Text = "NAO atende aos requisitos da campanha '$($Campanha.Nome)'."
        $lblResumo.ForeColor = [System.Drawing.Color]::FromArgb(220, 53, 69)
    }

    [void]$dlg.ShowDialog()
}

function Update-GridCampanhaZona {
    <#
        Preenche $GridZona conforme a campanha selecionada em
        $ComboCampanha, e atualiza o resumo em $LblResumo. $LinhasComSis
        (array de $Resultado, nao de linhas de grade) vem PRONTO de quem
        chama - a janela nao le a grade principal diretamente (fica num
        modulo separado, sem acesso a ela).
    #>
    param(
        [System.Windows.Forms.ComboBox]$ComboCampanha,
        [System.Windows.Forms.DataGridView]$GridZona,
        [System.Windows.Forms.Label]$LblResumo,
        [object[]]$Campanhas,
        [object[]]$LinhasComSis,
        [object[]]$SistemasEleitoraisExtra,
        [int]$Zona,
        [string]$Sede
    )
    $GridZona.Rows.Clear()
    if ($ComboCampanha.SelectedIndex -lt 0) { return }
    $campanha = $Campanhas[$ComboCampanha.SelectedIndex]

    $aptas = 0
    foreach ($r in $LinhasComSis) {
        $faltando = New-Object System.Collections.Generic.List[string]
        foreach ($req in $campanha.Requisitos) {
            $instalado = Get-VersaoInstaladaPorNomeSistema -Resultado $r -NomeSistema $req.Sistema -SistemasEleitoraisExtra $SistemasEleitoraisExtra
            $temInstalado = $instalado -and $instalado -ne "-"
            if (-not $temInstalado) {
                $faltando.Add("$($req.Sistema) (nao instalado)")
                continue
            }
            $cmp = Compare-VersaoSistema -VersaoA $instalado -VersaoB $req.VersaoMinima
            if ($null -eq $cmp -or $cmp -lt 0) {
                $faltando.Add("$($req.Sistema) ($instalado < $($req.VersaoMinima))")
            }
        }

        $apta = $faltando.Count -eq 0
        if ($apta) { $aptas++ }
        $statusTxt = if ($apta) { "Apto" } else { "Nao apto" }
        $modeloTxt = if ($r.Modelo) { $r.Modelo } else { "-" }
        $idxZona = $GridZona.Rows.Add(@($r.IP, $r.Hostname, $modeloTxt, $statusTxt, ($faltando -join "; ")))
        $rowZona = $GridZona.Rows[$idxZona]
        $rowZona.Cells["Status"].Style.Font = New-Object System.Drawing.Font($GridZona.Font, [System.Drawing.FontStyle]::Bold)
        $rowZona.Cells["Status"].Style.ForeColor = if ($apta) { [System.Drawing.Color]::FromArgb(0, 128, 0) } else { [System.Drawing.Color]::FromArgb(220, 53, 69) }
    }

    $zonaTxt = "{0:D3}" -f $Zona
    $sedeTxt = if ($Sede) { $Sede } else { "" }
    $zonaDescricao = "A zona $zonaTxt $sedeTxt".Trim()

    if ($LinhasComSis.Count -eq 0) {
        $LblResumo.Text = "Nenhuma maquina com SIS encontrada nesta zona (rode a varredura primeiro)."
        $LblResumo.ForeColor = [System.Drawing.Color]::FromArgb(200, 100, 0)
    } elseif ($aptas -gt 0) {
        $LblResumo.Text = "$zonaDescricao TEM $aptas de $($LinhasComSis.Count) maquina(s) com SIS pronta(s) para a campanha '$($campanha.Nome)'."
        $LblResumo.ForeColor = [System.Drawing.Color]::FromArgb(0, 128, 0)
    } else {
        $LblResumo.Text = "$zonaDescricao NAO TEM nenhuma maquina pronta (0 de $($LinhasComSis.Count) com SIS) para a campanha '$($campanha.Nome)'."
        $LblResumo.ForeColor = [System.Drawing.Color]::FromArgb(220, 53, 69)
    }
}

function Show-JanelaVerificarCampanhaZona {
    <#
        Versao "zona inteira" do Verificar Campanha - deixa escolher a
        campanha e mostra, pra TODAS as maquinas com SIS instalado
        ($LinhasComSis, ja filtrada por quem chama a partir da grade
        principal), quantas estao aptas e o que falta em cada uma. Nao
        depende de rede pra calcular - so "Enviar Resultado..." toca a
        rede (Send-ResultadoCampanhaZonaRemoto, ja pronta desde a Fase 7,
        resolvida por nome de funcao exportada de VisaoRemoting.psm1 -
        nao precisa importar nada aqui, module-exported functions ficam
        visiveis pra sessao inteira uma vez importadas em VisaoCliente.ps1).
    #>
    param(
        [Parameter(Mandatory)][object[]]$Campanhas,
        [Parameter(Mandatory)][object[]]$LinhasComSis,
        [object[]]$SistemasEleitoraisExtra,
        [Parameter(Mandatory)][int]$Zona,
        [string]$Sede = "",
        [string]$NomeFerramenta = "Visao",
        [scriptblock]$AoLog = $null
    )

    if (-not $AoLog) { $AoLog = { param($Texto, $Cor) } }

    if ($Campanhas.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Nenhuma campanha cadastrada ainda (aba CAMPANHAS da planilha).", "Verificar Campanha", "OK", "Information") | Out-Null
        return
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "$NomeFerramenta - Verificar Campanha - Zona $Zona"
    $dlg.Size = New-Object System.Drawing.Size(900, 560)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $lblCampanhaSel = New-Object System.Windows.Forms.Label
    $lblCampanhaSel.Text = "Campanha:"
    $lblCampanhaSel.Location = New-Object System.Drawing.Point(15, 18)
    $lblCampanhaSel.AutoSize = $true
    $dlg.Controls.Add($lblCampanhaSel)

    $comboCampanha = New-Object System.Windows.Forms.ComboBox
    $comboCampanha.Location = New-Object System.Drawing.Point(90, 15)
    $comboCampanha.Width = 320
    $comboCampanha.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    foreach ($campanha in $Campanhas) { [void]$comboCampanha.Items.Add($campanha.Nome) }
    $dlg.Controls.Add($comboCampanha)

    $btnVerificarZonaCampanha = New-Object System.Windows.Forms.Button
    $btnVerificarZonaCampanha.Text = "Verificar"
    $btnVerificarZonaCampanha.Location = New-Object System.Drawing.Point(420, 13)
    $btnVerificarZonaCampanha.Width = 90
    $btnVerificarZonaCampanha.Height = 26
    $dlg.Controls.Add($btnVerificarZonaCampanha)

    $lblResumoZona = New-Object System.Windows.Forms.Label
    $lblResumoZona.Location = New-Object System.Drawing.Point(15, 50)
    $lblResumoZona.Size = New-Object System.Drawing.Size(855, 24)
    $lblResumoZona.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($lblResumoZona)

    $gridZona = New-Object System.Windows.Forms.DataGridView
    $gridZona.Location = New-Object System.Drawing.Point(15, 80)
    $gridZona.Size = New-Object System.Drawing.Size(855, 400)
    $gridZona.Anchor = "Top,Bottom,Left,Right"
    $gridZona.AllowUserToAddRows = $false
    $gridZona.AllowUserToDeleteRows = $false
    $gridZona.ReadOnly = $true
    $gridZona.RowHeadersVisible = $false
    $gridZona.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $gridZona.MultiSelect = $false
    $gridZona.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None
    $dlg.Controls.Add($gridZona)

    function Add-ColunaGridZonaCampanha {
        param($Nome, $Titulo, $Largura)
        $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $c.Name = $Nome; $c.HeaderText = $Titulo; $c.Width = $Largura
        [void]$gridZona.Columns.Add($c)
    }
    Add-ColunaGridZonaCampanha "IP" "IP" 110
    Add-ColunaGridZonaCampanha "Hostname" "Hostname" 220
    Add-ColunaGridZonaCampanha "Modelo" "Modelo" 130
    Add-ColunaGridZonaCampanha "Status" "Status" 90
    Add-ColunaGridZonaCampanha "Faltando" "Requisitos Faltando" 290

    $btnFecharZonaCampanha = New-Object System.Windows.Forms.Button
    $btnFecharZonaCampanha.Text = "Fechar"
    $btnFecharZonaCampanha.Location = New-Object System.Drawing.Point(785, 490)
    $btnFecharZonaCampanha.Width = 85
    $btnFecharZonaCampanha.Height = 28
    $btnFecharZonaCampanha.Anchor = "Bottom,Right"
    $dlg.Controls.Add($btnFecharZonaCampanha)
    $btnFecharZonaCampanha.Add_Click({ $dlg.Close() }.GetNewClosure())

    $btnEnviarResultado = New-Object System.Windows.Forms.Button
    $btnEnviarResultado.Text = "Enviar Resultado..."
    $btnEnviarResultado.Location = New-Object System.Drawing.Point(645, 490)
    $btnEnviarResultado.Width = 130
    $btnEnviarResultado.Height = 28
    $btnEnviarResultado.Anchor = "Bottom,Right"
    $dlg.Controls.Add($btnEnviarResultado)
    $btnEnviarResultado.Add_Click({
        if ($comboCampanha.SelectedIndex -lt 0 -or $gridZona.Rows.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("Clique em 'Verificar' antes de enviar o resultado.", "Enviar Resultado", "OK", "Warning") | Out-Null
            return
        }
        $campanhaSel = $Campanhas[$comboCampanha.SelectedIndex]
        $linhasAptas = @($gridZona.Rows | Where-Object { $_.Cells["Status"].Value -eq "Apto" })
        $totalEnvio = $gridZona.Rows.Count
        $aptasEnvio = $linhasAptas.Count
        $maquinasAptasTxt = ($linhasAptas | ForEach-Object { $_.Cells["Hostname"].Value }) -join "; "

        $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
        try {
            $resp = Send-ResultadoCampanhaZonaRemoto -Zona $Zona -NomeCampanha $campanhaSel.Nome -Total $totalEnvio -Aptas $aptasEnvio -MaquinasAptas $maquinasAptasTxt -Sede $Sede
            if ($resp.Ok) {
                & $AoLog $resp.Mensagem "Cyan"
                [System.Windows.Forms.MessageBox]::Show("Resultado enviado com sucesso.", "Enviar Resultado", "OK", "Information") | Out-Null
            } else {
                & $AoLog "[ERRO] $($resp.Mensagem)" "OrangeRed"
                [System.Windows.Forms.MessageBox]::Show("Falha ao enviar resultado:`r`n$($resp.Mensagem)", "Erro", "OK", "Error") | Out-Null
            }
        } catch {
            & $AoLog "[ERRO] Falha ao enviar resultado da campanha: $($_.Exception.Message)" "OrangeRed"
            [System.Windows.Forms.MessageBox]::Show("Falha ao enviar resultado:`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
        } finally {
            $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
        }
    }.GetNewClosure())

    $comboCampanha.Add_SelectedIndexChanged({ Update-GridCampanhaZona -ComboCampanha $comboCampanha -GridZona $gridZona -LblResumo $lblResumoZona -Campanhas $Campanhas -LinhasComSis $LinhasComSis -SistemasEleitoraisExtra $SistemasEleitoraisExtra -Zona $Zona -Sede $Sede }.GetNewClosure())
    $btnVerificarZonaCampanha.Add_Click({ Update-GridCampanhaZona -ComboCampanha $comboCampanha -GridZona $gridZona -LblResumo $lblResumoZona -Campanhas $Campanhas -LinhasComSis $LinhasComSis -SistemasEleitoraisExtra $SistemasEleitoraisExtra -Zona $Zona -Sede $Sede }.GetNewClosure())
    if ($comboCampanha.Items.Count -gt 0) { $comboCampanha.SelectedIndex = 0 }

    # A troca de SelectedIndex ACIMA acontece antes da janela existir de
    # verdade (handle nativo do ComboBox so e criado no ShowDialog), e
    # nesse caso o evento SelectedIndexChanged pode nao disparar - reforca
    # a populacao no Shown tambem (mesmo motivo ja documentado no
    # original).
    $dlg.Add_Shown({ Update-GridCampanhaZona -ComboCampanha $comboCampanha -GridZona $gridZona -LblResumo $lblResumoZona -Campanhas $Campanhas -LinhasComSis $LinhasComSis -SistemasEleitoraisExtra $SistemasEleitoraisExtra -Zona $Zona -Sede $Sede }.GetNewClosure())

    [void]$dlg.ShowDialog()
}

function Get-FiltroRelatorioCampanhas {
    <# Le qual RadioButton "Todas as Zonas"/"Aptas"/"Nao Aptas" esta marcado. #>
    param(
        [System.Windows.Forms.RadioButton]$RadioAptas,
        [System.Windows.Forms.RadioButton]$RadioNaoAptas
    )
    if ($RadioAptas.Checked) { return "Aptas" }
    if ($RadioNaoAptas.Checked) { return "NaoAptas" }
    return "Todas"
}

function Import-ResultadosCampanhasNaJanela {
    <#
        Busca os resultados NO SERVIDOR (Get-ResultadosCampanhasRemoto) e
        recarrega a janela do zero. Guarda os dados crus em $GridRel.Tag
        (pra Update-GridRelatorioCampanhas reaproveitar sem buscar de novo
        a cada troca de campanha no combo).
    #>
    param(
        [System.Windows.Forms.ComboBox]$ComboCampanha,
        [System.Windows.Forms.DataGridView]$GridRel,
        [System.Windows.Forms.Label]$LblStatus,
        [string]$Filtro = "Todas",
        [scriptblock]$AoLog = $null
    )
    if (-not $AoLog) { $AoLog = { param($Texto, $Cor) } }

    $LblStatus.Text = "Buscando resultados..."
    $LblStatus.ForeColor = [System.Drawing.Color]::Gray
    [System.Windows.Forms.Application]::DoEvents()

    try {
        # Achado ao vivo (2026-08-24): sem feedback nenhum aqui, uma
        # espera longa (rede lenta, WinRM tentando se reconectar sozinho
        # - ver comentario de Invoke-ComandoRemotoJob) deixava o texto
        # estatico em "Buscando resultados..." indefinidamente, e o
        # tecnico nao tinha como saber se ainda estava tentando ou se
        # tinha travado de verdade - teve que matar o processo. Agora
        # mostra o mesmo aviso que ja ia so pro Conexao.log.
        $resp = Get-ResultadosCampanhasRemoto -AoAtualizarStatus {
            param($t)
            $LblStatus.Text = $t
            [System.Windows.Forms.Application]::DoEvents()
        }.GetNewClosure()
    } catch {
        $resp = [PSCustomObject]@{ Ok = $false; Erro = $_.Exception.Message; Dados = @() }
    }

    if ($resp.Ok) {
        # TESTE-MIGRACAO-FASE7 foi um resultado enviado durante a migracao
        # desta ferramenta pra uma campanha que nunca existiu de verdade
        # na aba CAMPANHAS da planilha (diferente de "Simulado TDTOT 4",
        # que E uma campanha real cadastrada la, com requisitos de
        # verdade - essa continua aparecendo normalmente). Filtrada aqui
        # (nao apagada da planilha) pra nao aparecer no relatorio. Se
        # aparecer outro resultado de teste parecido no futuro (enviado
        # pra uma campanha que nao esta na aba CAMPANHAS), adicionar o
        # nome aqui.
        $campanhasDeTeste = @('TESTE-MIGRACAO-FASE7', '__TESTE_DIAGNOSTICO_SEDE__')
        $resp.Dados = @($resp.Dados | Where-Object { $_.Campanha -notin $campanhasDeTeste })
    }
    $GridRel.Tag = $resp

    if (-not $resp.Ok) {
        $GridRel.Rows.Clear()
        $LblStatus.Text = "Falha ao buscar resultados: $($resp.Erro)"
        $LblStatus.ForeColor = [System.Drawing.Color]::Firebrick
        & $AoLog "[ERRO] Falha ao buscar resultados de campanhas: $($resp.Erro)" "OrangeRed"
        return
    }

    $todos = @($resp.Dados)
    $selecaoAtual = $ComboCampanha.SelectedItem
    $nomes = @($todos | Select-Object -ExpandProperty Campanha -Unique | Sort-Object)
    $ComboCampanha.Items.Clear()
    foreach ($nome in $nomes) { [void]$ComboCampanha.Items.Add($nome) }

    if ($nomes.Count -eq 0) {
        $GridRel.Rows.Clear()
        $LblStatus.Text = "Nenhum resultado de campanha enviado ainda (use 'Enviar Resultado...' na janela Verificar Campanha)."
        $LblStatus.ForeColor = [System.Drawing.Color]::FromArgb(200, 100, 0)
        return
    }

    if ($selecaoAtual -and $nomes -contains $selecaoAtual) {
        $ComboCampanha.SelectedItem = $selecaoAtual
    } else {
        $ComboCampanha.SelectedIndex = 0
    }
    Update-GridRelatorioCampanhas -ComboCampanha $ComboCampanha -GridRel $GridRel -LblStatus $LblStatus -Filtro $Filtro
}

function Get-LinhasVerificadasCampanha {
    <#
        Pega SO A ULTIMA linha de cada zona (do array bruto ja buscado
        por Import-ResultadosCampanhasNaJanela) pra uma campanha - SEM
        aplicar o filtro Aptas/Nao Aptas. Usado tanto pra popular a
        grade (Update-GridRelatorioCampanhas) quanto pra Show-
        RelatorioCampanhaHtml conseguir saber se a campanha tem ALGUMA
        zona verificada mesmo quando o filtro atual zera a grade (ex:
        filtro "Nao Aptas" com todas as zonas aptas - grade vazia nao
        deveria impedir gerar um relatorio dizendo "sem pendencias").
    #>
    param(
        [Parameter(Mandatory)][array]$Dados,
        [Parameter(Mandatory)][string]$CampanhaNome
    )
    $ultimaPorZona = [ordered]@{}
    foreach ($linha in $Dados) {
        if ($linha.Campanha -ne $CampanhaNome) { continue }
        $ultimaPorZona[$linha.Zona] = $linha
    }
    return @($ultimaPorZona.Values | Sort-Object { $zn = 0; [void][int]::TryParse($_.Zona, [ref]$zn); $zn })
}

function Update-GridRelatorioCampanhas {
    <#
        Filtra $GridRel.Tag.Dados (ja buscado antes por
        Import-ResultadosCampanhasNaJanela) pra campanha selecionada,
        pega SO A ULTIMA linha de cada zona e popula a grade + o resumo.
        NAO busca nada na rede.
    #>
    param(
        [System.Windows.Forms.ComboBox]$ComboCampanha,
        [System.Windows.Forms.DataGridView]$GridRel,
        [System.Windows.Forms.Label]$LblStatus,
        [string]$Filtro = "Todas"
    )
    $GridRel.Rows.Clear()
    $resp = $GridRel.Tag
    if (-not $resp -or -not $resp.Ok -or $ComboCampanha.SelectedIndex -lt 0) { return }
    $todos = @($resp.Dados)
    $campanhaNome = $ComboCampanha.SelectedItem

    $linhasOrdenadas = Get-LinhasVerificadasCampanha -Dados $todos -CampanhaNome $campanhaNome
    $prontas = 0
    foreach ($linha in $linhasOrdenadas) {
        $statusTxt = if ($linha.Total -le 0) { "Sem maquina com SIS" } elseif ($linha.Aptas -gt 0) { "Apta" } else { "Nenhuma apta" }
        if ($statusTxt -eq "Apta") { $prontas++ }

        if ($Filtro -eq "Aptas" -and $statusTxt -ne "Apta") { continue }
        if ($Filtro -eq "NaoAptas" -and $statusTxt -eq "Apta") { continue }

        $maquinasAptasTxt = if ($linha.MaquinasAptas) { $linha.MaquinasAptas } else { "-" }
        $idx = $GridRel.Rows.Add(@($linha.Zona, $linha.Sede, $linha.Total, $linha.Aptas, $statusTxt, $maquinasAptasTxt, $linha.DataHora, $linha.Tecnico))
        $row = $GridRel.Rows[$idx]
        $row.Cells["Status"].Style.Font = New-Object System.Drawing.Font($GridRel.Font, [System.Drawing.FontStyle]::Bold)
        $row.Cells["Status"].Style.ForeColor = switch ($statusTxt) {
            "Apta" { [System.Drawing.Color]::FromArgb(0, 128, 0) }
            default { [System.Drawing.Color]::FromArgb(220, 53, 69) }
        }
    }

    $LblStatus.Text = "$prontas de $($linhasOrdenadas.Count) zona(s) verificada(s) com pelo menos 1 maquina pronta para a campanha '$campanhaNome'."
    $LblStatus.ForeColor = if ($linhasOrdenadas.Count -gt 0 -and $prontas -eq $linhasOrdenadas.Count) { [System.Drawing.Color]::FromArgb(0, 128, 0) } else { [System.Drawing.Color]::FromArgb(0, 90, 158) }
}

function Show-RelatorioCampanhaHtml {
    <#
        Monta um relatorio em HTML (formatado pra impressao, A4) com o
        que esta exibido AGORA em $GridRel, e abre no navegador padrao -
        de la o usuario aperta Ctrl+P e escolhe "Salvar como PDF". Le as
        linhas DIRETO da grade (nao recalcula nada), pra o PDF bater
        exatamente com o que a pessoa esta vendo na tela.
    #>
    param(
        [System.Windows.Forms.ComboBox]$ComboCampanha,
        [System.Windows.Forms.DataGridView]$GridRel,
        [string]$Filtro = "Todas",
        [scriptblock]$AoLog = $null
    )
    if (-not $AoLog) { $AoLog = { param($Texto, $Cor) } }

    $campanhaNome = $ComboCampanha.SelectedItem
    $resp = $GridRel.Tag
    $linhasVerificadas = if ($resp -and $resp.Ok -and $campanhaNome) { Get-LinhasVerificadasCampanha -Dados @($resp.Dados) -CampanhaNome $campanhaNome } else { @() }

    if ($ComboCampanha.SelectedIndex -lt 0 -or $linhasVerificadas.Count -eq 0) {
        [System.Windows.Forms.MessageBox]::Show("Nao ha resultados pra gerar relatorio - escolha uma campanha com pelo menos 1 zona verificada.", "Relatorio de Campanhas", "OK", "Warning") | Out-Null
        return
    }

    $linhasHtml = New-Object System.Collections.Generic.List[string]
    $prontas = 0
    $totalMaquinasAptas = 0
    $totalMaquinasComSis = 0
    $blocoResultados = ""

    if ($GridRel.Rows.Count -eq 0) {
        # O filtro Aptas/Nao Aptas atual zerou a grade, mas a campanha
        # TEM zonas verificadas ($linhasVerificadas, ja confirmado
        # acima) - gera o relatorio mesmo assim, com um aviso no lugar
        # da tabela em vez de bloquear. Achado ao vivo: filtro "Nao
        # Aptas" com 100% das zonas aptas mostrava "sem resultados",
        # confuso pro tecnico que queria justamente confirmar que nao ha
        # pendencia nenhuma.
        foreach ($linha in $linhasVerificadas) {
            $totalMaquinasComSis += [int]$linha.Total
            $totalMaquinasAptas += [int]$linha.Aptas
            if ($linha.Aptas -gt 0) { $prontas++ }
        }
        $totalZonas = $linhasVerificadas.Count
        $mensagemFiltro = switch ($Filtro) {
            "NaoAptas" { "Nenhuma zona pendente encontrada com o filtro atual (Nao Aptas) - todas as $totalZonas zona(s) verificada(s) ja estao aptas para esta campanha." }
            "Aptas" { "Nenhuma zona apta encontrada com o filtro atual (Aptas) - das $totalZonas zona(s) verificada(s), nenhuma tem maquina apta ainda para esta campanha." }
            default { "Nenhuma zona corresponde ao filtro atual." }
        }
        $blocoResultados = "<div class=`"sem-pendencias`">$([System.Net.WebUtility]::HtmlEncode($mensagemFiltro))</div>"
    }
    else {
        foreach ($row in $GridRel.Rows) {
            $zona = [System.Net.WebUtility]::HtmlEncode("$($row.Cells['Zona'].Value)")
            $sede = [System.Net.WebUtility]::HtmlEncode("$($row.Cells['Sede'].Value)")
            $total = [int]$row.Cells["Total"].Value
            $aptas = [int]$row.Cells["Aptas"].Value
            $status = [System.Net.WebUtility]::HtmlEncode("$($row.Cells['Status'].Value)")
            $maquinasAptas = [System.Net.WebUtility]::HtmlEncode("$($row.Cells['MaquinasAptas'].Value)")
            $dataHora = [System.Net.WebUtility]::HtmlEncode("$($row.Cells['UltimaVerificacao'].Value)")
            $tecnico = [System.Net.WebUtility]::HtmlEncode("$($row.Cells['Tecnico'].Value)")
            $totalMaquinasComSis += $total
            $totalMaquinasAptas += $aptas
            if ($status -eq "Apta") { $prontas++ }
            $corClasse = switch ($status) { "Apta" { "ok" }; default { "ruim" } }
            $linhasHtml.Add("<tr><td>$zona</td><td>$sede</td><td class=`"num`">$total</td><td class=`"num`">$aptas</td><td class=`"$corClasse`">$status</td><td>$maquinasAptas</td><td>$dataHora</td><td>$tecnico</td></tr>")
        }
        $totalZonas = $GridRel.Rows.Count
        $blocoResultados = @"
  <table>
    <thead>
      <tr><th>Zona</th><th>Sede</th><th>Total c/ SIS</th><th>Aptas</th><th>Status</th><th>Maquinas Aptas</th><th>Ultima Verificacao</th><th>Tecnico</th></tr>
    </thead>
    <tbody>
      $($linhasHtml -join "`r`n      ")
    </tbody>
  </table>
"@
    }

    $campanhaEnc = [System.Net.WebUtility]::HtmlEncode($campanhaNome)
    $geradoEm = Get-Date -Format "dd/MM/yyyy"
    $horaGerado = Get-Date -Format "HH:mm:ss"

    # Brasao oficial embutido como base64 - deixa o HTML AUTOSSUFICIENTE.
    # $PSScriptRoot aqui e a pasta deste MODULO (mesma pasta de
    # VisaoCliente.ps1, ambos vivem em d:\Comum\PowerShell\Estudos).
    $arquivoBrasao = Join-Path $PSScriptRoot "brasao-oficial-colorido.png"
    $brasaoImgTag = ""
    if (Test-Path $arquivoBrasao) {
        try {
            $bytesBrasao = [System.IO.File]::ReadAllBytes($arquivoBrasao)
            $base64Brasao = [System.Convert]::ToBase64String($bytesBrasao)
            $brasaoImgTag = "<img src=`"data:image/png;base64,$base64Brasao`" class=`"brasao`" alt=`"Brasao da Republica`">"
        } catch {}
    }

    $html = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
<meta charset="UTF-8">
<title>Relatorio de Campanha - $campanhaEnc</title>
<style>
  @page { size: A4; margin: 15mm; }
  body { font-family: 'Segoe UI', Arial, sans-serif; color: #222; margin: 0; }
  .cabecalho { display: flex; justify-content: space-between; align-items: center; border-bottom: 2px solid #005a9e; padding-bottom: 6px; margin-bottom: 12px; }
  .cabecalho-esq { display: flex; align-items: center; gap: 10px; }
  .brasao { width: 105px; height: 105px; object-fit: contain; }
  .cabecalho-texto p { margin: 0; line-height: 1.35; font-size: 13px; }
  .cabecalho-texto p.titulo { font-size: 15px; font-weight: bold; }
  .cabecalho-texto p.campanha { font-size: 15px; font-weight: bold; text-transform: uppercase; color: #005a9e; }
  .cabecalho-dir { text-align: right; font-size: 12px; color: #444; white-space: nowrap; }
  .resumo { background: #f2f2f2; border-radius: 6px; padding: 10px 14px; margin-bottom: 16px; font-size: 13px; }
  .resumo b { color: #005a9e; }
  table { width: 100%; border-collapse: collapse; font-size: 12px; }
  th, td { border: 1px solid #ccc; padding: 6px 8px; text-align: left; }
  th { background: #005a9e; color: #fff; }
  td.num { text-align: center; }
  td.ok { color: #007f00; font-weight: bold; }
  td.ruim { color: #dc3545; font-weight: bold; }
  .sem-pendencias { background: #eaf4ea; border: 1px solid #b7dcb7; border-radius: 6px; padding: 18px; font-size: 14px; text-align: center; color: #1e5f27; font-weight: 600; }
  .rodape { margin-top: 14px; font-size: 10px; color: #888; }
  @media print { .rodape { position: fixed; bottom: 0; } }
</style>
</head>
<body>
  <div class="cabecalho">
    <div class="cabecalho-esq">
      $brasaoImgTag
      <div class="cabecalho-texto">
        <p class="titulo">Justica Eleitoral</p>
        <p>TRE-MA / SEASU-COINF-STIC</p>
        <p>Relatorio de Verificacao de Campanha</p>
        <p class="campanha">$campanhaEnc</p>
      </div>
    </div>
    <div class="cabecalho-dir">
      $geradoEm<br>$horaGerado
    </div>
  </div>
  <div class="resumo">
    <b>$prontas</b> de <b>$totalZonas</b> zona(s) verificada(s) com pelo menos 1 maquina pronta para esta campanha.
    Total de <b>$totalMaquinasAptas</b> maquina(s) apta(s) de <b>$totalMaquinasComSis</b> com SIS instalado nas zonas verificadas.
  </div>
  $blocoResultados
  <div class="rodape">Gerado pela ferramenta Visao - TRE-MA em $geradoEm $horaGerado.</div>
</body>
</html>
"@

    $pastaRelatorios = Join-Path $env:TEMP "Visao_Relatorios"
    if (-not (Test-Path $pastaRelatorios)) { New-Item -ItemType Directory -Path $pastaRelatorios -Force | Out-Null }
    $nomeArquivoSeguro = ($campanhaNome -replace '[\\/:*?"<>|]', '_')
    $caminhoHtml = Join-Path $pastaRelatorios "Relatorio_${nomeArquivoSeguro}_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"
    Set-Content -Path $caminhoHtml -Value $html -Encoding UTF8

    Start-Process $caminhoHtml
    & $AoLog "Relatorio da campanha '$campanhaNome' aberto no navegador ($caminhoHtml) - use Ctrl+P > Salvar como PDF." "Cyan"
}

function Show-JanelaRelatorioCampanhas {
    param(
        [string]$NomeFerramenta = "Visao",
        [scriptblock]$AoLog = $null
    )
    if (-not $AoLog) { $AoLog = { param($Texto, $Cor) } }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "$NomeFerramenta - Relatorio de Campanhas"
    $dlg.Size = New-Object System.Drawing.Size(1170, 580)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = "FixedDialog"
    $dlg.MaximizeBox = $false
    $dlg.MinimizeBox = $false
    $dlg.Font = New-Object System.Drawing.Font("Segoe UI", 9)

    $lblCampanhaRel = New-Object System.Windows.Forms.Label
    $lblCampanhaRel.Text = "Campanha:"
    $lblCampanhaRel.Location = New-Object System.Drawing.Point(15, 18)
    $lblCampanhaRel.AutoSize = $true
    $dlg.Controls.Add($lblCampanhaRel)

    $comboCampanhaRel = New-Object System.Windows.Forms.ComboBox
    $comboCampanhaRel.Location = New-Object System.Drawing.Point(90, 15)
    $comboCampanhaRel.Width = 320
    $comboCampanhaRel.DropDownStyle = [System.Windows.Forms.ComboBoxStyle]::DropDownList
    $dlg.Controls.Add($comboCampanhaRel)

    $btnAtualizarRel = New-Object System.Windows.Forms.Button
    $btnAtualizarRel.Text = "Atualizar"
    $btnAtualizarRel.Location = New-Object System.Drawing.Point(420, 13)
    $btnAtualizarRel.Width = 90
    $btnAtualizarRel.Height = 26
    $dlg.Controls.Add($btnAtualizarRel)

    $lblFiltroRel = New-Object System.Windows.Forms.Label
    $lblFiltroRel.Text = "Filtro:"
    $lblFiltroRel.Location = New-Object System.Drawing.Point(530, 18)
    $lblFiltroRel.AutoSize = $true
    $dlg.Controls.Add($lblFiltroRel)

    $radioTodasRel = New-Object System.Windows.Forms.RadioButton
    $radioTodasRel.Text = "Todas as Zonas"
    $radioTodasRel.Location = New-Object System.Drawing.Point(580, 16)
    $radioTodasRel.AutoSize = $true
    $radioTodasRel.Checked = $true
    $dlg.Controls.Add($radioTodasRel)

    $radioAptasRel = New-Object System.Windows.Forms.RadioButton
    $radioAptasRel.Text = "Aptas"
    $radioAptasRel.Location = New-Object System.Drawing.Point(710, 16)
    $radioAptasRel.AutoSize = $true
    $dlg.Controls.Add($radioAptasRel)

    $radioNaoAptasRel = New-Object System.Windows.Forms.RadioButton
    $radioNaoAptasRel.Text = "Nao Aptas"
    $radioNaoAptasRel.Location = New-Object System.Drawing.Point(790, 16)
    $radioNaoAptasRel.AutoSize = $true
    $dlg.Controls.Add($radioNaoAptasRel)

    $lblStatusRel = New-Object System.Windows.Forms.Label
    $lblStatusRel.Location = New-Object System.Drawing.Point(15, 50)
    $lblStatusRel.Size = New-Object System.Drawing.Size(1125, 24)
    $lblStatusRel.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($lblStatusRel)

    $gridRel = New-Object System.Windows.Forms.DataGridView
    $gridRel.Location = New-Object System.Drawing.Point(15, 80)
    $gridRel.Size = New-Object System.Drawing.Size(1125, 420)
    $gridRel.Anchor = "Top,Bottom,Left,Right"
    $gridRel.AllowUserToAddRows = $false
    $gridRel.AllowUserToDeleteRows = $false
    $gridRel.ReadOnly = $true
    $gridRel.RowHeadersVisible = $false
    $gridRel.SelectionMode = [System.Windows.Forms.DataGridViewSelectionMode]::FullRowSelect
    $gridRel.MultiSelect = $false
    $gridRel.AutoSizeColumnsMode = [System.Windows.Forms.DataGridViewAutoSizeColumnsMode]::None
    $dlg.Controls.Add($gridRel)

    function Add-ColunaGridRel {
        param($Nome, $Titulo, $Largura)
        $c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $c.Name = $Nome; $c.HeaderText = $Titulo; $c.Width = $Largura
        [void]$gridRel.Columns.Add($c)
    }
    Add-ColunaGridRel "Zona" "Zona" 55
    Add-ColunaGridRel "Sede" "Sede" 170
    Add-ColunaGridRel "Total" "Total c/ SIS" 85
    Add-ColunaGridRel "Aptas" "Aptas" 60
    Add-ColunaGridRel "Status" "Status" 110
    Add-ColunaGridRel "MaquinasAptas" "Maquinas Aptas" 280
    Add-ColunaGridRel "UltimaVerificacao" "Ultima Verificacao" 140
    Add-ColunaGridRel "Tecnico" "Tecnico" 120

    $btnFecharRel = New-Object System.Windows.Forms.Button
    $btnFecharRel.Text = "Fechar"
    $btnFecharRel.Location = New-Object System.Drawing.Point(1055, 510)
    $btnFecharRel.Width = 85
    $btnFecharRel.Height = 28
    $btnFecharRel.Anchor = "Bottom,Right"
    $dlg.Controls.Add($btnFecharRel)
    $btnFecharRel.Add_Click({ $dlg.Close() }.GetNewClosure())

    $btnPdfRel = New-Object System.Windows.Forms.Button
    $btnPdfRel.Text = "Gerar Relatorio PDF..."
    $btnPdfRel.Location = New-Object System.Drawing.Point(885, 510)
    $btnPdfRel.Width = 155
    $btnPdfRel.Height = 28
    $btnPdfRel.Anchor = "Bottom,Right"
    $dlg.Controls.Add($btnPdfRel)
    $btnPdfRel.Add_Click({ Show-RelatorioCampanhaHtml -ComboCampanha $comboCampanhaRel -GridRel $gridRel -Filtro (Get-FiltroRelatorioCampanhas -RadioAptas $radioAptasRel -RadioNaoAptas $radioNaoAptasRel) -AoLog $AoLog }.GetNewClosure())

    $comboCampanhaRel.Add_SelectedIndexChanged({ Update-GridRelatorioCampanhas -ComboCampanha $comboCampanhaRel -GridRel $gridRel -LblStatus $lblStatusRel -Filtro (Get-FiltroRelatorioCampanhas -RadioAptas $radioAptasRel -RadioNaoAptas $radioNaoAptasRel) }.GetNewClosure())
    $btnAtualizarRel.Add_Click({ Import-ResultadosCampanhasNaJanela -ComboCampanha $comboCampanhaRel -GridRel $gridRel -LblStatus $lblStatusRel -Filtro (Get-FiltroRelatorioCampanhas -RadioAptas $radioAptasRel -RadioNaoAptas $radioNaoAptasRel) -AoLog $AoLog }.GetNewClosure())
    $dlg.Add_Shown({ Import-ResultadosCampanhasNaJanela -ComboCampanha $comboCampanhaRel -GridRel $gridRel -LblStatus $lblStatusRel -Filtro (Get-FiltroRelatorioCampanhas -RadioAptas $radioAptasRel -RadioNaoAptas $radioNaoAptasRel) -AoLog $AoLog }.GetNewClosure())

    $atualizarFiltroRel = { Update-GridRelatorioCampanhas -ComboCampanha $comboCampanhaRel -GridRel $gridRel -LblStatus $lblStatusRel -Filtro (Get-FiltroRelatorioCampanhas -RadioAptas $radioAptasRel -RadioNaoAptas $radioNaoAptasRel) }.GetNewClosure()
    $radioTodasRel.Add_CheckedChanged($atualizarFiltroRel)
    $radioAptasRel.Add_CheckedChanged($atualizarFiltroRel)
    $radioNaoAptasRel.Add_CheckedChanged($atualizarFiltroRel)

    [void]$dlg.ShowDialog()
}

Export-ModuleMember -Function Compare-VersaoSistema, Get-VersaoInstaladaPorNomeSistema, Show-JanelaVerificarCampanha, Update-GridCampanhaZona, Show-JanelaVerificarCampanhaZona, Get-FiltroRelatorioCampanhas, Import-ResultadosCampanhasNaJanela, Update-GridRelatorioCampanhas, Show-RelatorioCampanhaHtml, Show-JanelaRelatorioCampanhas
