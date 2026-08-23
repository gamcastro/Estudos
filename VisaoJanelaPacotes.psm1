<#
    VisaoJanelaPacotes.psm1

    Janela "Sistemas Eleitorais" - roda LOCAL na estacao do tecnico (a
    propria VisaoCliente.ps1 ja importa VisaoRemoting.psm1/
    VisaoPacotes.psm1, cujas funcoes exportadas ficam disponiveis pra
    qualquer modulo importado na MESMA sessao, inclusive este). Relocacao
    de Show-JanelaSistemasEleitorais do ScannerRedeZona.ps1 original, com
    duas mudancas estruturais:

    1) Nao le mais $script:TabelaPacotes/$script:SistemasEleitoraisExtra/
       $script:TabelaVersoes/$script:VersaoAtualPorSistema/
       $script:NomeFerramenta - esse modulo tem seu PROPRIO escopo
       $script:, separado do de VisaoCliente.ps1 (cada .psm1 e um escopo
       de modulo isolado em PowerShell). Em vez disso, tudo isso vira
       PARAMETRO de Show-JanelaSistemasEleitorais, passado por quem chama
       (que ja tem esses dados carregados em $script:Estado desde a
       conexao - ver VisaoCliente.ps1).

    2) O botao "Copiar" nao chama mais Invoke-AcaoBaixarPacote (unica
       chamada bloqueante que baixava do Drive E copiava pro InstSeg, na
       mesma runspace) - vira o fluxo em DUAS fases ja validado na Fase 6
       da migracao de remoting: Start-BaixarPacoteRemoto (dispara o
       download no SERVIDOR, cache compartilhado) + polling de
       Get-StatusPacoteRemoto ate concluir + Invoke-AcaoCopiarPacoteJaBaixado
       (copia do cache compartilhado pro InstSeg, rodando aqui no
       cliente, 1 salto Kerberos). Sem dado granular de "%" nas duas
       fases (so texto de status) - a barra de progresso fica em modo
       Marquee (indeterminado) em vez de preencher por porcentagem, unica
       diferenca de UX visivel em relacao ao original.
#>

function Format-VersaoComNomeAmigavel {
    <#
        "Versao (Nome Amigavel)" - direto na tabela de versoes (nao usa
        Resolve-NomeAmigavelVersao porque aqui precisamos do nome amigavel
        tanto da versao INSTALADA quanto da versao ATUAL, e aquela funcao
        so resolve uma versao concreta).
    #>
    param($TabelaVersoes, $Sistema, $Versao)
    if (-not $Versao -or $Versao -eq "-") { return "-" }
    $chave = "$($Sistema.ToUpper())|$($Versao.Trim())"
    if ($TabelaVersoes.ContainsKey($chave) -and $TabelaVersoes[$chave].NomeAmigavel) {
        return "$Versao ($($TabelaVersoes[$chave].NomeAmigavel))"
    }
    return $Versao
}

function Show-JanelaSistemasEleitorais {
    <#
        Consolida, pra cada sistema conhecido (SIS + $SistemasEleitoraisExtra),
        a versao instalada (ja lida na varredura) x a versao atual da
        planilha, se esta atualizado, o status de copia do pacote no
        InstSeg, e os botoes de acao (Baixar e Copiar / Verificar Hash /
        Abrir Pasta).
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Resultado,
        [Parameter(Mandatory)][object[]]$SistemasEleitoraisExtra,
        [Parameter(Mandatory)][hashtable]$TabelaVersoes,
        [Parameter(Mandatory)][hashtable]$VersaoAtualPorSistema,
        [Parameter(Mandatory)][object[]]$Pacotes,
        [string]$NomeFerramenta = "Visao",
        [scriptblock]$AoLog = $null
    )

    if (-not $AoLog) { $AoLog = { param($Texto, $Cor) } }

    # Cada item junta os dados de "sistema eleitoral" (versao instalada,
    # versao atual) com o pacote de instalacao correspondente (achado por
    # NomeVersaoAtual, texto exato da coluna "Sistema" da planilha) - se
    # nao houver LinkDrive/PastaDestino configurado pra esse sistema,
    # Pacote fica $null e as acoes de copia/hash/pasta nao aparecem.
    $itens = New-Object System.Collections.Generic.List[object]
    $itens.Add([PSCustomObject]@{ Titulo = "SIS"; Versao = $Resultado.VersaoSis; NomeVersaoAtual = "SIS" })
    foreach ($sis in $SistemasEleitoraisExtra) {
        $itens.Add([PSCustomObject]@{ Titulo = $sis.Titulo; Versao = $Resultado.($sis.Propriedade); NomeVersaoAtual = $sis.NomeVersaoAtual })
    }
    foreach ($item in $itens) {
        $pacote = $Pacotes | Where-Object { $_.Sistema -eq $item.NomeVersaoAtual } | Select-Object -First 1
        $item | Add-Member -NotePropertyName Pacote -NotePropertyValue $pacote
    }

    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "$NomeFerramenta - Sistemas Eleitorais - $($Resultado.Hostname) ($($Resultado.IP))"
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
        $lblItem.Text = "$Texto"
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

    $lblProgressoPacoteAtual = New-Object System.Windows.Forms.Label
    $lblProgressoPacoteAtual.Text = ""
    $lblProgressoPacoteAtual.Location = New-Object System.Drawing.Point(12, 6)
    $lblProgressoPacoteAtual.Size = New-Object System.Drawing.Size(700, 18)
    $lblProgressoPacoteAtual.Anchor = "Top,Left,Right"
    $lblProgressoPacoteAtual.ForeColor = [System.Drawing.Color]::FromArgb(0, 90, 158)
    $painelRodape.Controls.Add($lblProgressoPacoteAtual)

    $barraProgressoPacoteAtual = New-Object System.Windows.Forms.ProgressBar
    $barraProgressoPacoteAtual.Location = New-Object System.Drawing.Point(12, 26)
    $barraProgressoPacoteAtual.Size = New-Object System.Drawing.Size(400, 20)
    $barraProgressoPacoteAtual.Anchor = "Top,Left,Right"
    $barraProgressoPacoteAtual.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
    $barraProgressoPacoteAtual.MarqueeAnimationSpeed = 30
    $barraProgressoPacoteAtual.Visible = $false
    $painelRodape.Controls.Add($barraProgressoPacoteAtual)

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
    # pratica que o cabecalho de coluna nao renderiza nesta janela com
    # Dock=Fill (mesmo achado ja documentado em VisaoCliente.ps1/$grid).
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

    # Preenche Sistema/Versao Instalada/Versao Atual/Status NA HORA (nao
    # depende de rede - so dados ja lidos na varredura + planilha ja
    # carregada em memoria). So a coluna de Pacote e os botoes de acao
    # dependem do InstSeg (rede) - ficam "Verificando..." ate a janela
    # aparecer e o levantamento (evento Shown) terminar.
    $popularLinhaBaseSis = {
        param([System.Windows.Forms.DataGridView]$Grid, [int]$Indice, $Item, $TabVersoes, $VerAtualPorSistema)
        $row = $Grid.Rows[$Indice]
        $instalado = $Item.Versao -and $Item.Versao -ne "-"
        $versaoAtual = if ($Item.NomeVersaoAtual) { $VerAtualPorSistema[$Item.NomeVersaoAtual] } else { $null }

        $row.Cells["Sistema"].Value = $Item.Titulo
        $row.Cells["VersaoInstalada"].Value = if ($instalado) { Format-VersaoComNomeAmigavel -TabelaVersoes $TabVersoes -Sistema $Item.NomeVersaoAtual -Versao $Item.Versao } else { "-" }
        $row.Cells["VersaoAtual"].Value = if ($versaoAtual) { Format-VersaoComNomeAmigavel -TabelaVersoes $TabVersoes -Sistema $Item.NomeVersaoAtual -Versao $versaoAtual } else { "-" }
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
    # ja estar visivel (Add_Shown) ou apos uma acao de copiar/verificar
    # mudar o status de uma linha especifica.
    $popularLinhaPacoteSis = {
        param([System.Windows.Forms.DataGridView]$Grid, [int]$Indice, $Item, $Resultado2, $ArquivosInstSeg = '__NAO_INFORMADO__')
        $row = $Grid.Rows[$Indice]
        if (-not $Item.Pacote) { return }

        $statusInfo = Get-StatusPacoteNoDestino -Resultado $Resultado2 -Pacote $Item.Pacote -ArquivosInstSeg $ArquivosInstSeg
        $row.Tag = [PSCustomObject]@{ Pacote = $Item.Pacote; StatusInfo = $statusInfo }
        $row.Cells["StatusPacote"].ToolTipText = ""
        $row.Cells["StatusPacote"].Style.Font = $Grid.Font

        if ($statusInfo.Existe) {
            $raizInstSeg = "\\$($Resultado2.IP)\InstSeg\"
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
        & $popularLinhaBaseSis -Grid $gridSis -Indice $i -Item $itens[$i] -TabVersoes $TabelaVersoes -VerAtualPorSistema $VersaoAtualPorSistema
        if ($itens[$i].Pacote) { $gridSis.Rows[$i].Cells["StatusPacote"].Value = "Verificando..." }
    }

    $recarregarPacotesSis = {
        param([System.Windows.Forms.DataGridView]$Grid, $Itens, $Resultado2, $LblCarregando)

        foreach ($item2 in $Itens) {
            if ($item2.Pacote) {
                $idxLinha = $Itens.IndexOf($item2)
                $Grid.Rows[$idxLinha].Cells["StatusPacote"].Value = "Verificando..."
                $Grid.Rows[$idxLinha].Cells["StatusPacote"].Style.ForeColor = [System.Drawing.Color]::Gray
            }
        }
        if ($LblCarregando) {
            $LblCarregando.Text = "Verificando pacotes em \\$($Resultado2.IP)\InstSeg (pode demorar em links de zona lentos)..."
            $LblCarregando.Visible = $true
        }
        [System.Windows.Forms.Application]::DoEvents()

        $arquivosInstSeg = Get-ArquivosInstSeg -Resultado $Resultado2

        if ($LblCarregando) { $LblCarregando.Visible = $false }

        for ($i = 0; $i -lt $Itens.Count; $i++) {
            & $popularLinhaPacoteSis -Grid $Grid -Indice $i -Item $Itens[$i] -Resultado2 $Resultado2 -ArquivosInstSeg $arquivosInstSeg
        }
    }.GetNewClosure()

    # So comeca a buscar o InstSeg DEPOIS da janela ja estar visivel -
    # senao a janela nao aparece na tela ate a busca de rede terminar.
    $dlg.Add_Shown({ & $recarregarPacotesSis -Grid $gridSis -Itens $itens -Resultado2 $Resultado -LblCarregando $lblCarregandoSis }.GetNewClosure())
    $btnAtualizarSis.Add_Click({ & $recarregarPacotesSis -Grid $gridSis -Itens $itens -Resultado2 $Resultado -LblCarregando $lblCarregandoSis }.GetNewClosure())

    $gridSis.Add_CellContentClick({
        param($sender, $e)
        if ($e.RowIndex -lt 0) { return }
        $nomeColuna = $gridSis.Columns[$e.ColumnIndex].Name
        $row = $gridSis.Rows[$e.RowIndex]
        $tagLinha = $row.Tag
        if (-not $tagLinha) { return }
        $item = $itens[$e.RowIndex]

        # Alias LOCAL (atribuido AQUI, na propria execucao deste
        # Add_CellContentClick) de $lblProgressoPacoteAtual - confirmado
        # ao vivo (2026-08-22, erro "propriedade Text nao encontrada")
        # que um .GetNewClosure() criado em tempo de execucao DENTRO de
        # outro closure ja em execucao (os $callbackXxx abaixo, aninhados
        # dentro deste Add_CellContentClick que ja e ele mesmo um
        # closure) so enxerga variaveis atribuidas NAQUELA MESMA
        # execucao - nao variaveis so herdadas do escopo da funcao de
        # fora (Show-JanelaSistemasEleitorais) via o GetNewClosure deste
        # proprio Add_CellContentClick. Mesma familia da Descoberta
        # critica no4/no5 (script:), so que aqui e variavel local comum -
        # o fix e o mesmo: realiasar localmente antes de aninhar mais um
        # closure.
        $lblProgressoLocal = $lblProgressoPacoteAtual
        $barraProgressoLocal = $barraProgressoPacoteAtual

        if ($nomeColuna -eq "Copiar") {
            $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $barraProgressoPacoteAtual.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
            $barraProgressoPacoteAtual.Value = 0
            $barraProgressoPacoteAtual.Visible = $true
            $lblProgressoPacoteAtual.Text = "Iniciando..."
            [System.Windows.Forms.Application]::DoEvents()
            try {
                # Download roda AQUI (estacao do tecnico), nao mais via
                # Start-BaixarPacoteRemoto/Get-StatusPacoteRemoto no
                # servidor - confirmado ao vivo (2026-08-22) que segurar
                # uma sessao de PowerShell Remoting por varios minutos
                # enquanto um pacote grande baixa do Drive e fragil
                # demais ("conectividade... perdida"). O cache
                # compartilhado do servidor continua sendo usado (so
                # nao baixa de novo se outro tecnico ja deixou o arquivo
                # la) - ver Invoke-AcaoGarantirPacoteEmCache. A barra
                # fica em Marquee (indeterminada) nesta fase - o download
                # ainda nao tem % ligado na barra, so texto de status.
                $callbackDownload = { param($texto) $lblProgressoLocal.Text = $texto; [System.Windows.Forms.Application]::DoEvents() }.GetNewClosure()
                $resultadoDownload = Invoke-AcaoGarantirPacoteEmCache -Pacote $tagLinha.Pacote -AoAtualizarStatus $callbackDownload

                if (-not $resultadoDownload.Sucesso) {
                    & $AoLog "[ERRO] $($resultadoDownload.Mensagem)" "OrangeRed"
                    [System.Windows.Forms.MessageBox]::Show($resultadoDownload.Mensagem, "Erro", "OK", "Error") | Out-Null
                } else {
                    foreach ($aviso in $resultadoDownload.Avisos) { & $AoLog "[AVISO] $aviso" "Yellow" }
                    $lblProgressoPacoteAtual.Text = "Copiando para o InstSeg..."
                    # A fase de copia (robocopy) tem porcentagem REAL
                    # (Get-PercentualRobocopyDoLog em VisaoPacotes.psm1,
                    # le o log do robocopy sem a flag /NP) - troca a
                    # barra pra modo com valor de verdade so aqui.
                    $barraProgressoLocal.Style = [System.Windows.Forms.ProgressBarStyle]::Blocks
                    $barraProgressoLocal.Value = 0
                    [System.Windows.Forms.Application]::DoEvents()
                    $callbackCopia = { param($texto) $lblProgressoLocal.Text = $texto; [System.Windows.Forms.Application]::DoEvents() }.GetNewClosure()
                    $callbackPercentual = { param($p) $barraProgressoLocal.Value = $p; [System.Windows.Forms.Application]::DoEvents() }.GetNewClosure()
                    $resultadoCopia = Invoke-AcaoCopiarPacoteJaBaixado -Resultado $Resultado -Pacote $tagLinha.Pacote -ArquivoCacheUnc $resultadoDownload.ArquivoCacheUnc -NomeArquivoOriginal $resultadoDownload.NomeArquivoOriginal -AoAtualizarStatus $callbackCopia -AoAtualizarPercentual $callbackPercentual
                    if ($resultadoCopia.Sucesso) {
                        & $AoLog $resultadoCopia.Mensagem "LightGreen"
                        [System.Windows.Forms.MessageBox]::Show($resultadoCopia.Mensagem, "Concluido", "OK", "Information") | Out-Null
                    } else {
                        & $AoLog "[AVISO] $($resultadoCopia.Mensagem)" "Yellow"
                        [System.Windows.Forms.MessageBox]::Show($resultadoCopia.Mensagem, "Aviso", "OK", "Warning") | Out-Null
                    }
                }
            } catch {
                & $AoLog "[ERRO] Falha ao baixar/copiar '$($tagLinha.Pacote.Pacote)': $($_.Exception.Message)" "OrangeRed"
                [System.Windows.Forms.MessageBox]::Show("Falha ao baixar/copiar o pacote:`r`n$($_.Exception.Message)", "Erro", "OK", "Error") | Out-Null
            } finally {
                $barraProgressoPacoteAtual.Visible = $false
                $barraProgressoPacoteAtual.Style = [System.Windows.Forms.ProgressBarStyle]::Marquee
                $lblProgressoPacoteAtual.Text = ""
                $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
            }
            & $popularLinhaPacoteSis -Grid $gridSis -Indice $e.RowIndex -Item $item -Resultado2 $Resultado
        } elseif ($nomeColuna -eq "Verificar") {
            $dlg.Cursor = [System.Windows.Forms.Cursors]::WaitCursor
            $lblProgressoPacoteAtual.Text = "Verificando hash..."
            $lblProgressoPacoteAtual.Visible = $true
            try {
                $callbackHash = { param($texto) $lblProgressoLocal.Text = $texto; [System.Windows.Forms.Application]::DoEvents() }.GetNewClosure()
                $resultadoHash = Invoke-AcaoVerificarHashPacote -Resultado $Resultado -Pacote $tagLinha.Pacote -StatusInfo $tagLinha.StatusInfo -AoAtualizarStatus $callbackHash
                if (-not $resultadoHash.Sucesso) {
                    & $AoLog "[AVISO] $($resultadoHash.Mensagem)" "Yellow"
                    [System.Windows.Forms.MessageBox]::Show($resultadoHash.Mensagem, "Aviso", "OK", "Warning") | Out-Null
                } elseif ($resultadoHash.Confere) {
                    & $AoLog "Hash MD5 confere para '$($tagLinha.Pacote.Pacote)' em '$($Resultado.Hostname)' (referencia: $($resultadoHash.OrigemHash))." "Green"
                    [System.Windows.Forms.MessageBox]::Show("O sistema '$($tagLinha.Pacote.Pacote)' esta INTEGRO em '$($Resultado.Hostname)' ($($Resultado.IP)).`r`n`r`nHash MD5 origem ($($resultadoHash.OrigemHash)):`r`n$($resultadoHash.HashReferencia)`r`n`r`nHash MD5 destino ($($resultadoHash.ArquivoDestino)):`r`n$($resultadoHash.HashDestino)`r`n`r`n$($resultadoHash.Mensagem)", "Integridade OK", "OK", "Information") | Out-Null
                } else {
                    & $AoLog "[ERRO] Hash MD5 NAO confere para '$($tagLinha.Pacote.Pacote)' em '$($Resultado.Hostname)' (referencia: $($resultadoHash.OrigemHash))." "OrangeRed"
                    [System.Windows.Forms.MessageBox]::Show("ATENCAO: o sistema '$($tagLinha.Pacote.Pacote)' em '$($Resultado.Hostname)' ($($Resultado.IP)) NAO esta integro.`r`n`r`nHash MD5 origem ($($resultadoHash.OrigemHash)):`r`n$($resultadoHash.HashReferencia)`r`n`r`nHash MD5 destino ($($resultadoHash.ArquivoDestino)):`r`n$($resultadoHash.HashDestino)`r`n`r`n$($resultadoHash.Mensagem)", "Hash NAO confere", "OK", "Warning") | Out-Null
                }
            } finally {
                $lblProgressoPacoteAtual.Visible = $false
                $lblProgressoPacoteAtual.Text = ""
                $dlg.Cursor = [System.Windows.Forms.Cursors]::Default
            }
        } elseif ($nomeColuna -eq "AbrirPasta") {
            $resultadoAbrir = Invoke-AcaoAbrirPastaPacote -Resultado $Resultado -Pacote $tagLinha.Pacote -StatusInfo $tagLinha.StatusInfo
            if (-not $resultadoAbrir.Sucesso) {
                [System.Windows.Forms.MessageBox]::Show($resultadoAbrir.Mensagem, "Pasta nao encontrada", "OK", "Warning") | Out-Null
            }
        }
    }.GetNewClosure())

    [void]$dlg.ShowDialog()
}

Export-ModuleMember -Function Show-JanelaSistemasEleitorais
