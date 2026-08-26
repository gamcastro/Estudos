<#
    VisaoPacotes.psm1

    Copia de pacotes de instalacao pro \\IP\InstSeg das maquinas de
    zona - roda DIRETO NA ESTACAO DO TECNICO, sem passar pelo PowerShell
    Remoting/POLICY-SERVER, no mesmo espirito do VisaoAD.psm1.

    Por que aqui e nao no VisaoServidor.ps1 (Fase 6 do plano em
    C:\Users\029342881104\.claude\plans\splendid-enchanting-mochi.md
    originalmente previa a copia rodando no servidor): testado ao vivo
    que QUALQUER acesso SMB de dentro da sessao remota no POLICY-SERVER
    pra uma TERCEIRA maquina (\\IP-da-zona\InstSeg, e ate \\IP-da-
    zona\C$) da "Access is denied" - o mesmo duplo-salto do Kerberos ja
    diagnosticado pro AD. A diferenca desta vez (decisao do usuario): o
    DOWNLOAD do Google Drive continua no servidor (cache compartilhado
    entre tecnicos, chamada a API do Google - ver VisaoServidor.ps1/
    Start-BaixarPacote), mas a COPIA final pro InstSeg roda na propria
    estacao do tecnico, que ja acessa tanto o cache compartilhado do
    servidor (\\POLICY-SERVER...\ScanZonas\CacheDownloads) quanto o
    InstSeg de qualquer zona com um UNICO salto Kerberos normal - e
    exatamente a mesma copia manual de arquivo que o tecnico ja faz
    hoje, nao trafego de varredura/scan.

    Relocacao praticamente pura de Get-CaminhoDestinoUnc/
    Get-NomeArquivoConhecidoPacote/Get-ArquivosInstSeg/
    Find-PacoteEmArquivosInstSeg/Get-StatusPacoteNoDestino/
    Format-DuracaoLegivel/Copy-ArquivoComRobocopy do
    ScannerRedeZona.ps1 original - a diferenca principal e
    Copy-ArquivoComRobocopy perder $GridStatus/$LinhaIndice (referencia
    direta de controle WinForms) em favor de um [scriptblock]
    $AoAtualizarStatus explicito (mesma disciplina de closure ja
    estabelecida nesta ferramenta: nunca $script: dentro de closure
    aninhada, sempre parametro).
#>

$script:PastaCacheDownloadsUnc = "\\POLICY-SERVER.tre-ma.gov.br\ScanZonas\CacheDownloads"
$script:UrlDrivePastaCvc       = "https://drive.google.com/drive/folders/1ssTe5V1qtDRtWTPJCS5Npw8EiiFJCp6o"
$script:PastaLocalEnvioCvc     = Join-Path $env:TEMP "CVC_GoogleDrive"

function Get-CaminhoDestinoUnc {
    param($Resultado, $Pacote)
    return "\\$($Resultado.IP)\InstSeg\$($Pacote.PastaDestino.Trim('\'))"
}

function Get-NomeArquivoConhecidoPacote {
    <#
        Descobre o nome de arquivo esperado do pacote no destino: (1)
        coluna NomeArquivo da planilha, se preenchida; (2) sidecar .nome
        no cache COMPARTILHADO do servidor (gravado por
        Start-BaixarPacote apos um download, via Content-Disposition do
        Drive) - lido aqui por caminho UNC direto, sem remoting nenhum
        (mesmo acesso de 1 salto so usado pelo resto deste modulo).
    #>
    param($Pacote)
    if ($Pacote.NomeArquivo) { return $Pacote.NomeArquivo }
    $nomeArquivoCache = "$($Pacote.IdArquivo)_$($Pacote.Pacote -replace '[\\/:*?"<>|]', '_')"
    $arquivoNome = Join-Path $script:PastaCacheDownloadsUnc "$nomeArquivoCache.nome"
    if (Test-Path $arquivoNome) { return (Get-Content -Path $arquivoNome -Raw -Encoding UTF8).Trim() }
    return $null
}

function Get-HashCachePacote {
    <#
        Mesma ideia de Get-NomeArquivoConhecidoPacote, so que pro sidecar
        .md5 (hash MD5 calculado pelo SERVIDOR no momento do download,
        gravado no mesmo cache compartilhado - ver Get-CaminhosCachePacote
        em VisaoServidor.ps1, EXATO mesmo padrao de nome de arquivo). Usado
        como referencia de fallback em Invoke-AcaoVerificarHashPacote
        quando a planilha nao tem a coluna Hash preenchida pra esse pacote.
    #>
    param($Pacote)
    $nomeArquivoCache = "$($Pacote.IdArquivo)_$($Pacote.Pacote -replace '[\\/:*?"<>|]', '_')"
    $arquivoHash = Join-Path $script:PastaCacheDownloadsUnc "$nomeArquivoCache.md5"
    if (Test-Path $arquivoHash) { return (Get-Content -Path $arquivoHash -Raw -Encoding UTF8).Trim() }
    return $null
}

function Get-ArquivosInstSeg {
    <#
        Lista (recursivo, ate 6 niveis) TODOS os arquivos do
        compartilhamento \\IP\InstSeg - usada como busca de fallback
        "tolerante quanto a pasta" quando o arquivo nao esta no caminho
        EXATO esperado (ver Get-StatusPacoteNoDestino). Testado ao vivo
        (2026-08-21, zona 34) que isso pode passar de 3 MINUTOS sem
        terminar num link de zona ruim - MUITO mais lento do que o
        Test-Path no caminho exato (~600ms no mesmo link, no mesmo
        teste). Por isso roda com um LIMITE DE TEMPO (padrao: 15s) num
        runspace em segundo plano - se estourar, cancela e devolve
        $null (equivale a "nao achei por essa busca", nao a erro fatal -
        Get-StatusPacoteNoDestino ja trata $null normalmente,
        Find-PacoteEmArquivosInstSeg simplesmente nao acha nada).

        Sem timeout (como no ScannerRedeZona.ps1 original) isso travava
        a tela inteira do tecnico por minutos num link ruim - so nao
        era tao visivel la porque a espera ficava dentro de um loop com
        DoEvents (a janela continuava "respondendo" aos cliques, mas o
        fluxo real de baixar/copiar ficava parado do mesmo jeito).

        Achado ao vivo (2026-08-27, reproduzido de forma isolada e
        repetida): ao estourar o timeout, chamar $ps.Stop() + $ps.Dispose()
        num pipeline que ainda esta rodando pode deixar a thread/runspace
        local presa de verdade se o Get-ChildItem estiver bloqueado numa
        chamada Win32 sincrona nao-cancelavel (link de rede realmente
        lento/travado) - o Stop() nao interrompe isso de verdade. Isso
        deixou operacoes assincronas FUTURAS (a varredura seguinte, via
        Invoke-Command -AsJob) travando esperando o WinRM - mesmo
        principio ja corrigido pro crash de Stop-Job/Remove-Job -Force
        (ver VisaoRemoting.psm1/Invoke-ComandoRemotoJob). Por isso, ao
        estourar o prazo, o pipeline e ABANDONADO (nunca mais tocado, sem
        Stop() nem Dispose()) em vez de forcado a parar - pequeno
        vazamento de recurso num cenario raro (link realmente travado),
        aceitavel em troca de nunca mais travar a ferramenta inteira.
    #>
    param($Resultado, [int]$TimeoutSec = 15)

    $raizInstSeg = "\\$($Resultado.IP)\InstSeg"
    if (-not (Test-Path $raizInstSeg)) { return $null }

    $scriptBlockListar = {
        param($Raiz)
        try { return @(Get-ChildItem -Path $Raiz -File -Recurse -Depth 6 -ErrorAction SilentlyContinue) } catch { return @() }
    }
    $ps = [powershell]::Create()
    $abandonar = $false
    try {
        [void]$ps.AddScript($scriptBlockListar).AddArgument($raizInstSeg)
        $handle = $ps.BeginInvoke()
        $cronometro = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $handle.IsCompleted -and $cronometro.Elapsed.TotalSeconds -lt $TimeoutSec) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        if (-not $handle.IsCompleted) {
            $abandonar = $true
            return $null
        }
        return @($ps.EndInvoke($handle))
    } catch {
        return $null
    } finally {
        if (-not $abandonar) { $ps.Dispose() }
    }
}

# ============================================================
# Versao NAO-BLOQUEANTE de Get-ArquivosInstSeg (2026-08-27) - pra usar
# de dentro de um dialog MODAL (Show-JanelaSistemasEleitorais), que
# nunca deve esperar bombeando DoEvents() manualmente. Mesmo motivo ja
# documentado pro polling da varredura (VisaoRemoting.psm1/
# Start-VarreduraNovosResultadosRemotoAsync): confirmado ao vivo que
# esperar com DoEvents() de dentro de um Add_Shown/dialog modal deixava
# a PROXIMA operacao assincrona (a varredura seguinte) travando -
# mesmo apos corrigir Get-ArquivosInstSeg pra nao forcar Stop()/Dispose()
# num pipeline preso (achado anterior, insuficiente sozinho). Quem
# chama deve dirigir a espera por um Timer proprio, nunca por um loop
# com DoEvents.
# ============================================================
function Start-ArquivosInstSegAsync {
    <#
        Dispara a listagem de \\IP\InstSeg em segundo plano e devolve NA
        HORA (sem esperar nada). Quem chama guarda o retorno e confere
        depois, tick a tick (Timer proprio), com Test-ArquivosInstSegAsync.
    #>
    param($Resultado)

    $raizInstSeg = "\\$($Resultado.IP)\InstSeg"
    if (-not (Test-Path $raizInstSeg)) {
        return [PSCustomObject]@{ NaoExiste = $true; Ps = $null; Handle = $null; Cronometro = $null }
    }

    $scriptBlockListar = {
        param($Raiz)
        try { return @(Get-ChildItem -Path $Raiz -File -Recurse -Depth 6 -ErrorAction SilentlyContinue) } catch { return @() }
    }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($scriptBlockListar).AddArgument($raizInstSeg)
    $handle = $ps.BeginInvoke()
    return [PSCustomObject]@{ NaoExiste = $false; Ps = $ps; Handle = $handle; Cronometro = [System.Diagnostics.Stopwatch]::StartNew() }
}

function Test-ArquivosInstSegAsync {
    <#
        Chamada a cada tick de um Timer - devolve na hora, sem DoEvents()
        nenhum. .Concluido indica se ja da pra usar .Arquivos (que pode
        vir $null tanto por nao existir \\IP\InstSeg quanto por estourar
        o prazo - mesmo significado de sempre: "nao achei por essa
        busca", nao erro fatal).
    #>
    param($EstadoAsync, [int]$TimeoutSec = 15)

    if ($EstadoAsync.NaoExiste) {
        return [PSCustomObject]@{ Concluido = $true; Arquivos = $null }
    }

    if (-not $EstadoAsync.Handle.IsCompleted) {
        if ($EstadoAsync.Cronometro.Elapsed.TotalSeconds -ge $TimeoutSec) {
            # Abandona o pipeline preso - NUNCA Stop()/Dispose() aqui, ver
            # comentario grande em Get-ArquivosInstSeg (o mesmo achado se
            # aplica igual aqui).
            return [PSCustomObject]@{ Concluido = $true; Arquivos = $null }
        }
        return [PSCustomObject]@{ Concluido = $false; Arquivos = $null }
    }

    try {
        return [PSCustomObject]@{ Concluido = $true; Arquivos = @($EstadoAsync.Ps.EndInvoke($EstadoAsync.Handle)) }
    } catch {
        return [PSCustomObject]@{ Concluido = $true; Arquivos = $null }
    } finally {
        $EstadoAsync.Ps.Dispose()
    }
}

function Find-PacoteEmArquivosInstSeg {
    param($Pacote, $ArquivosInstSeg)
    if (-not $ArquivosInstSeg -or -not $Pacote.NomeArquivo) { return $null }
    return ($ArquivosInstSeg | Where-Object { $_.Name -eq $Pacote.NomeArquivo } | Select-Object -First 1)
}

function Get-StatusPacoteNoDestino {
    <#
        Confere se o pacote ja esta na maquina de destino, SEM baixar
        nem copiar nada. Primeiro tenta o caminho EXATO esperado; se nao
        achar (ou nem souber o nome esperado ainda), cai pra uma busca
        tolerante em todo o InstSeg (Find-PacoteEmArquivosInstSeg).

        $ArquivosInstSeg (opcional): quem chama pra VARIAS linhas de uma
        vez (ex: Show-JanelaSistemasEleitorais) pode listar o InstSeg UMA
        SO VEZ e passar aqui, evitando repetir a busca de ate 15s por
        pacote nao encontrado no caminho exato. Sentinela distingue "nao
        informado" (busca sozinho) de "informado, mesmo que vazio/$null"
        (listagem ja tentada, nao repete).
    #>
    param($Resultado, $Pacote, $ArquivosInstSeg = '__NAO_INFORMADO__')

    $pastaDestinoUnc = Get-CaminhoDestinoUnc -Resultado $Resultado -Pacote $Pacote
    $nomeConhecido = Get-NomeArquivoConhecidoPacote -Pacote $Pacote

    if ($nomeConhecido) {
        $arquivoDestino = Join-Path $pastaDestinoUnc $nomeConhecido
        if (Test-Path -LiteralPath $arquivoDestino) {
            try {
                $info = Get-Item -LiteralPath $arquivoDestino -ErrorAction Stop
                $tamanhoConfere = if ($Pacote.TamanhoEsperado) { $info.Length -eq $Pacote.TamanhoEsperado } else { $null }
                return [PSCustomObject]@{ Existe = $true; NomeConhecido = $true; Tamanho = $info.Length; TamanhoConfere = $tamanhoConfere; Data = $info.LastWriteTime; ArquivoDestino = $arquivoDestino; PastaDestinoUnc = $pastaDestinoUnc; ForaDoPadrao = $false }
            } catch {}
        }
    }

    $arquivosInstSeg = if ("$ArquivosInstSeg" -eq '__NAO_INFORMADO__') { Get-ArquivosInstSeg -Resultado $Resultado } else { $ArquivosInstSeg }
    $achadoFora = Find-PacoteEmArquivosInstSeg -Pacote $Pacote -ArquivosInstSeg $arquivosInstSeg
    if ($achadoFora) {
        $tamanhoConfere = if ($Pacote.TamanhoEsperado) { $achadoFora.Length -eq $Pacote.TamanhoEsperado } else { $null }
        return [PSCustomObject]@{ Existe = $true; NomeConhecido = [bool]$nomeConhecido; Tamanho = $achadoFora.Length; TamanhoConfere = $tamanhoConfere; Data = $achadoFora.LastWriteTime; ArquivoDestino = $achadoFora.FullName; PastaDestinoUnc = $pastaDestinoUnc; ForaDoPadrao = $true }
    }

    return [PSCustomObject]@{ Existe = $false; NomeConhecido = [bool]$nomeConhecido; Tamanho = $null; TamanhoConfere = $null; Data = $null; ArquivoDestino = $null; PastaDestinoUnc = $pastaDestinoUnc; ForaDoPadrao = $false }
}

function Format-DuracaoLegivel {
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

function Get-PercentualRobocopyDoLog {
    <#
        Le o conteudo ATUAL do log de saida do robocopy (ainda sendo
        escrito pelo processo filho) e devolve a ULTIMA porcentagem
        encontrada, ou $null se ainda nao apareceu nenhuma. O robocopy
        escreve cada atualizacao de "% copiado" com \r (retorno de carro,
        sem \n) pra sobrescrever a mesma linha num console de verdade -
        redirecionado pra arquivo, isso vira uma sequencia de
        "  0.0%\r  4.5%\r...\r100%\r" tudo tecnicamente "numa linha so",
        por isso le o arquivo INTEIRO de uma vez (nao linha por linha) e
        pega o ULTIMO casamento do regex, nao o primeiro.

        Abre o arquivo com FileShare.ReadWrite explicito porque o
        robocopy ainda esta com ele aberto pra escrita nesse momento -
        Get-Content sozinho pode esbarrar em erro de compartilhamento
        dependendo do momento exato do polling.

        Aceita PONTO OU VIRGULA como separador decimal no regex (ex:
        "45,5%" - Windows em portugues do Brasil, que e o padrao nas
        estacoes do TRE-MA, formata porcentagem do robocopy com virgula,
        nao ponto) - e converte pra double via CultureInfo.InvariantCulture
        depois de normalizar a virgula pra ponto, em vez de deixar o
        cast [double] usar a cultura da THREAD atual (que poderia
        interpretar errado um valor com ponto se a cultura local for
        pt-BR, ou vice-versa) - assim funciona igual em qualquer
        estacao, independente da configuracao regional do Windows.
    #>
    param([string]$CaminhoLog)
    if (-not (Test-Path -LiteralPath $CaminhoLog)) { return $null }
    try {
        $fs = [System.IO.File]::Open($CaminhoLog, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        try {
            $sr = New-Object System.IO.StreamReader($fs)
            $conteudo = $sr.ReadToEnd()
        } finally {
            $sr.Dispose()
            $fs.Dispose()
        }
    } catch {
        return $null
    }
    $casamentos = [regex]::Matches($conteudo, '(\d+(?:[.,]\d+)?)\s*%')
    if ($casamentos.Count -eq 0) { return $null }
    $valorTexto = $casamentos[$casamentos.Count - 1].Groups[1].Value -replace ',', '.'
    $valorConvertido = 0.0
    if (-not [double]::TryParse($valorTexto, [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$valorConvertido)) {
        return $null
    }
    return $valorConvertido
}

function Copy-ArquivoComRobocopy {
    <#
        Copia um arquivo (origem tipicamente \\POLICY-SERVER...\
        ScanZonas\CacheDownloads\... - o cache compartilhado do
        servidor) pro destino \\IP\InstSeg\... via robocopy.exe. Roda
        direto na thread de UI do cliente (DoEvents durante a espera,
        igual o ScannerRedeZona.ps1 original) - $AoAtualizarStatus
        (opcional) e chamado com o texto de status a cada atualizacao,
        $AoAtualizarPercentual (opcional) e chamado com a porcentagem
        NUMERICA (0-100, lida do log via Get-PercentualRobocopyDoLog) a
        cada tick do polling, no lugar de $GridStatus/$LinhaIndice do
        original.
    #>
    param(
        [string]$Origem,
        [string]$Destino,
        [string]$NomePacote = "pacote",
        [scriptblock]$AoAtualizarStatus = $null,
        [scriptblock]$AoAtualizarPercentual = $null
    )

    if ($AoAtualizarStatus) { & $AoAtualizarStatus "Iniciando copia de '$NomePacote'..." }

    $origemDir = Split-Path $Origem -Parent
    $nomeArquivo = Split-Path $Origem -Leaf
    $destinoDir = Split-Path $Destino -Parent
    $nomeFinalDesejado = Split-Path $Destino -Leaf
    $caminhoComNomeOrigem = Join-Path $destinoDir $nomeArquivo
    $totalBytes = (Get-Item $Origem).Length

    # /Z = restartable; /J = I/O nao-bufferizado; /R:5 /W:10 = tenta ate
    # 5x, esperando 10s; os /N*/NC/NS reduzem o log a praticamente nada -
    # mesmos flags do ScannerRedeZona.ps1 original, MENOS o /NP (que la
    # suprimia o progresso por bloco) - aqui e exatamente o dado que
    # $AoAtualizarPercentual precisa, entao fica ligado de proposito.
    $argsRobocopy = @(
        "`"$origemDir`""
        "`"$destinoDir`""
        "`"$nomeArquivo`""
        "/Z", "/J", "/R:5", "/W:10", "/NJH", "/NJS", "/NDL", "/NFL", "/NC", "/NS"
    )

    $pastaLogsTemp = Join-Path $env:TEMP "Visao_RobocopyLogs"
    if (-not (Test-Path $pastaLogsTemp)) { New-Item -ItemType Directory -Path $pastaLogsTemp -Force | Out-Null }
    $sufixoLog = [Guid]::NewGuid().ToString('N')
    $logSaida = Join-Path $pastaLogsTemp "robocopy_$sufixoLog.log"
    $logErro = Join-Path $pastaLogsTemp "robocopy_$sufixoLog.err.log"

    try {
        $processo = Start-Process -FilePath "robocopy.exe" -ArgumentList $argsRobocopy -NoNewWindow -PassThru -RedirectStandardOutput $logSaida -RedirectStandardError $logErro

        $mbTotal = [Math]::Round($totalBytes / 1MB, 1)
        $cronometro = [System.Diagnostics.Stopwatch]::StartNew()
        $proximaAtualizacao = [System.Diagnostics.Stopwatch]::StartNew()
        $ultimoPercentualNotificado = -1
        $ultimoPercentualConhecido = $null
        if ($AoAtualizarStatus) { & $AoAtualizarStatus "Copiando '$NomePacote' (robocopy, $mbTotal MB) ha $(Format-DuracaoLegivel 0)..." }
        while (-not $processo.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200

            # Le o percentual TODO tick (nao so quando $AoAtualizarPercentual
            # existe) porque o texto de status abaixo tambem mostra o
            # numero - visivel mesmo se ninguem estiver de olho na barra.
            $percentualAtual = Get-PercentualRobocopyDoLog -CaminhoLog $logSaida
            if ($null -ne $percentualAtual) {
                $ultimoPercentualConhecido = [Math]::Min(100, [Math]::Round($percentualAtual))
            }
            if ($AoAtualizarPercentual -and $null -ne $ultimoPercentualConhecido -and $ultimoPercentualConhecido -ne $ultimoPercentualNotificado) {
                $ultimoPercentualNotificado = $ultimoPercentualConhecido
                & $AoAtualizarPercentual $ultimoPercentualConhecido
            }

            if ($proximaAtualizacao.Elapsed.TotalSeconds -ge 3) {
                $proximaAtualizacao.Restart()
                $percentualTexto = if ($null -ne $ultimoPercentualConhecido) { " - $ultimoPercentualConhecido%" } else { "" }
                if ($AoAtualizarStatus) { & $AoAtualizarStatus "Copiando '$NomePacote' (robocopy, $mbTotal MB)$percentualTexto ha $(Format-DuracaoLegivel $cronometro.Elapsed.TotalSeconds)..." }
            }
        }
        $processo.WaitForExit()
        if ($AoAtualizarPercentual -and $ultimoPercentualNotificado -ne 100) { & $AoAtualizarPercentual 100 }
    } finally {
        Remove-Item -Path $logSaida, $logErro -Force -ErrorAction SilentlyContinue
    }

    # Codigo de saida do robocopy e BITMASK: 0-7 = variacoes de sucesso,
    # 8+ = falha real.
    if ($processo.ExitCode -ge 8) {
        throw "robocopy falhou (codigo de saida $($processo.ExitCode)) ao copiar '$NomePacote' para '$Destino'."
    }

    # robocopy sempre preserva o nome de ORIGEM no destino - renomeia pro
    # nome final esperado, se forem diferentes.
    if ($nomeFinalDesejado -ne $nomeArquivo) {
        try {
            $caminhoFinal = Join-Path $destinoDir $nomeFinalDesejado
            if ((Test-Path -LiteralPath $caminhoFinal) -and $caminhoFinal -ne $caminhoComNomeOrigem) {
                Remove-Item -LiteralPath $caminhoFinal -Force -ErrorAction SilentlyContinue
            }
            Rename-Item -LiteralPath $caminhoComNomeOrigem -NewName $nomeFinalDesejado -Force -ErrorAction Stop
        } catch {
            throw "robocopy copiou o arquivo, mas falhou ao renomear de '$nomeArquivo' para '$nomeFinalDesejado' no destino: $($_.Exception.Message)"
        }
    }

    $textoConcluido = "Copiando '$NomePacote' (robocopy, $mbTotal MB) concluido em $(Format-DuracaoLegivel $cronometro.Elapsed.TotalSeconds)."
    if ($AoAtualizarStatus) { & $AoAtualizarStatus $textoConcluido }
}

function Invoke-AcaoCopiarPacoteJaBaixado {
    <#
        Copia um pacote JA BAIXADO no cache compartilhado do servidor
        (ArquivoCacheUnc/NomeArquivoOriginal vem de Get-StatusPacoteRemoto
        depois que Start-BaixarPacoteRemoto termina, ver
        VisaoRemoting.psm1) pra maquina de destino - orquestra
        Get-StatusPacoteNoDestino (pula a copia se ja estiver la com o
        tamanho batendo) + Copy-ArquivoComRobocopy + conferencia final
        de tamanho, no mesmo espirito do Invoke-AcaoBaixarPacote do
        ScannerRedeZona.ps1 original (so que sem a parte de download,
        que ja aconteceu no servidor).
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Resultado,
        [Parameter(Mandatory)][PSCustomObject]$Pacote,
        [Parameter(Mandatory)][string]$ArquivoCacheUnc,
        [string]$NomeArquivoOriginal = $null,
        [scriptblock]$AoAtualizarStatus = $null,
        [scriptblock]$AoAtualizarPercentual = $null
    )

    if (-not $Pacote.PastaDestino) {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = "Pasta de destino nao informada na planilha para este pacote."; ArquivoDestino = $null }
    }

    if ($AoAtualizarStatus) { & $AoAtualizarStatus "Conferindo se o pacote ja esta na maquina..." }
    $statusAntes = Get-StatusPacoteNoDestino -Resultado $Resultado -Pacote $Pacote
    if ($statusAntes.Existe -and ($statusAntes.TamanhoConfere -eq $true -or ($null -eq $statusAntes.TamanhoConfere -and $statusAntes.NomeConhecido))) {
        return [PSCustomObject]@{ Sucesso = $true; Mensagem = "Pacote ja estava copiado em '$($statusAntes.ArquivoDestino)' (nao copiou de novo)."; ArquivoDestino = $statusAntes.ArquivoDestino }
    }

    $pastaDestinoUnc = Get-CaminhoDestinoUnc -Resultado $Resultado -Pacote $Pacote
    if (-not (Test-Path $pastaDestinoUnc)) {
        New-Item -ItemType Directory -Path $pastaDestinoUnc -Force | Out-Null
    }
    $nomeArquivoDestino = if ($Pacote.NomeArquivo) { $Pacote.NomeArquivo } elseif ($NomeArquivoOriginal) { $NomeArquivoOriginal } else { $Pacote.Pacote -replace '[\\/:*?"<>|]', '_' }
    $arquivoDestinoUnc = Join-Path $pastaDestinoUnc $nomeArquivoDestino

    Copy-ArquivoComRobocopy -Origem $ArquivoCacheUnc -Destino $arquivoDestinoUnc -NomePacote $Pacote.Pacote -AoAtualizarStatus $AoAtualizarStatus -AoAtualizarPercentual $AoAtualizarPercentual

    if ($AoAtualizarStatus) { & $AoAtualizarStatus "Conferindo tamanho no destino..." }
    $tamanhoLocal = (Get-Item -LiteralPath $ArquivoCacheUnc).Length
    $tamanhoRemoto = (Get-Item -LiteralPath $arquivoDestinoUnc).Length
    $bateTamanho = $tamanhoLocal -eq $tamanhoRemoto

    if ($bateTamanho) {
        return [PSCustomObject]@{ Sucesso = $true; Mensagem = "Pacote '$($Pacote.Pacote)' copiado com sucesso - tamanho confere ($([Math]::Round($tamanhoRemoto / 1MB, 1)) MB)."; ArquivoDestino = $arquivoDestinoUnc }
    } else {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = "Pacote copiado, mas o TAMANHO nao confere (local=$tamanhoLocal remoto=$tamanhoRemoto) - a copia pode ter sido truncada. Copie de novo."; ArquivoDestino = $arquivoDestinoUnc }
    }
}

function Invoke-AcaoGarantirPacoteEmCache {
    <#
        Garante que o pacote esteja no cache COMPARTILHADO do servidor
        (\\POLICY-SERVER...\ScanZonas\CacheDownloads), baixando do Google
        Drive DIRETO DAQUI (estacao do tecnico) se ainda nao estiver la -
        substitui o fluxo antigo (Start-BaixarPacoteRemoto/
        Get-StatusPacoteRemoto, servidor baixa, cliente so espera por
        polling) depois de confirmado AO VIVO (2026-08-22, zona 14) que
        manter uma sessao de PowerShell Remoting aberta por varios minutos
        enquanto um pacote de ate ~500MB baixa do Drive e fragil demais
        ("A conectividade de rede com POLICY-SERVER... foi perdida").

        O download em si e so uma chamada HTTPS pro Google - nao tem
        duplo-salto de Kerberos nem trafego de broadcast nenhum (diferente
        de varredura/WOL, que por isso continuam centralizados no
        servidor), entao rodar aqui e tao valido quanto rodar no
        servidor. Mantem o BENEFICIO do cache compartilhado (evita cada
        tecnico baixar o mesmo pacote de novo): confere primeiro se
        outro tecnico ja deixou o arquivo la (Test-Path via UNC, sem
        download nenhum); so baixa se realmente faltar.

        Baixa pra um arquivo TEMPORARIO LOCAL primeiro, nao direto pro
        caminho final do cache compartilhado - assim nenhum outro
        tecnico enxerga um arquivo parcial/incompleto no meio do
        download (dois tecnicos podem, em teoria, tentar baixar o mesmo
        pacote ao mesmo tempo; como o conteudo final e identico - mesmo
        arquivo do Drive - um "ganhar" a gravacao final por ultimo nao
        corrompe nada, so desperdica banda de um dos dois). A gravacao
        final no cache compartilhado reusa Copy-ArquivoComRobocopy (mesma
        funcao ja usada pra copiar pro InstSeg).
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Pacote,
        [scriptblock]$AoAtualizarStatus = $null
    )

    if (-not $Pacote -or -not $Pacote.IdArquivo) {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = "Pacote sem ID de arquivo do Drive valido."; ArquivoCacheUnc = $null; NomeArquivoOriginal = $null; Avisos = @() }
    }

    $avisos = New-Object System.Collections.Generic.List[string]
    $nomeArquivoCache = "$($Pacote.IdArquivo)_$($Pacote.Pacote -replace '[\\/:*?"<>|]', '_')"
    $caminhoCacheUnc = Join-Path $script:PastaCacheDownloadsUnc $nomeArquivoCache
    $caminhoNomeUnc = "$caminhoCacheUnc.nome"
    $caminhoHashUnc = "$caminhoCacheUnc.md5"

    if (Test-Path -LiteralPath $caminhoCacheUnc) {
        if ($AoAtualizarStatus) { & $AoAtualizarStatus "Pacote ja esta no cache compartilhado (baixado por outro tecnico) - pulando download..." }
        $nomeOriginal = if (Test-Path -LiteralPath $caminhoNomeUnc) { (Get-Content -Path $caminhoNomeUnc -Raw -Encoding UTF8).Trim() } else { $null }
        return [PSCustomObject]@{ Sucesso = $true; Mensagem = "Pacote ja estava no cache compartilhado."; ArquivoCacheUnc = $caminhoCacheUnc; NomeArquivoOriginal = $nomeOriginal; Avisos = @($avisos) }
    }

    $pastaTemp = Join-Path $env:TEMP "Visao_DownloadPacotes"
    if (-not (Test-Path $pastaTemp)) { New-Item -ItemType Directory -Path $pastaTemp -Force | Out-Null }
    $arquivoTempLocal = Join-Path $pastaTemp "$($nomeArquivoCache)_$([Guid]::NewGuid().ToString('N')).tmp"

    if ($AoAtualizarStatus) { & $AoAtualizarStatus "Baixando '$($Pacote.Pacote)' do Google Drive..." }

    # Roda o download num runspace em segundo plano (mesmo padrao ja usado
    # pra listar InstSeg/calcular hash) - a thread de UI so bombeia
    # DoEvents enquanto poll $EstadoDownload.Texto pra atualizar o status.
    # Isolado de proposito (sem acesso a funcoes de fora) - mesma
    # restricao ja documentada no $scriptBlock da varredura/do job de
    # download original no servidor, de onde essa logica foi portada
    # quase sem mudanca (so $EstadoJob vira $EstadoDownload).
    $scriptBlockDownload = {
        param($EstadoDownload, $FileId, $DestinoLocal, $NomePacote)

        function Get-NomeArquivoDeContentDisposition {
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
            param([string]$Url, [System.Net.CookieContainer]$Cookies, [string]$DestinoLocal, [string]$NomePacote, $EstadoDownload)

            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.CookieContainer = $Cookies
            $req.Timeout = 600000
            $req.ReadWriteTimeout = 600000
            $req.UserAgent = "Mozilla/5.0 (Visao-TRE-MA)"

            $resp = $req.GetResponse()
            try {
                $totalBytes = $resp.ContentLength
                $streamResposta = $resp.GetResponseStream()
                $streamArquivo = [System.IO.File]::Create($DestinoLocal)
                try {
                    $buffer = New-Object byte[] 262144
                    $totalLido = 0
                    $ultimoPercentLogado = -5
                    $cronometro = [System.Diagnostics.Stopwatch]::StartNew()

                    while (($lidos = $streamResposta.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        $streamArquivo.Write($buffer, 0, $lidos)
                        $totalLido += $lidos

                        if ($totalBytes -gt 0) {
                            $percent = [Math]::Floor(($totalLido / $totalBytes) * 100)
                            if ($percent -ge ($ultimoPercentLogado + 5) -or $percent -ge 100) {
                                $mbLido = [Math]::Round($totalLido / 1MB, 1)
                                $mbTotal = [Math]::Round($totalBytes / 1MB, 1)
                                $velocidade = if ($cronometro.Elapsed.TotalSeconds -gt 0) { [Math]::Round(($totalLido / 1MB) / $cronometro.Elapsed.TotalSeconds, 1) } else { 0 }
                                $EstadoDownload.Texto = "Baixando '$NomePacote': $percent% ($mbLido / $mbTotal MB, $velocidade MB/s)"
                                $ultimoPercentLogado = $percent
                            }
                        }
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
            param([string]$FileId, [string]$DestinoLocal, [string]$NomePacote, $EstadoDownload)

            $ProgressPreference = 'SilentlyContinue'
            $urlInicial = "https://drive.google.com/uc?export=download&id=$FileId"

            $resp1 = Invoke-WebRequest -Uri $urlInicial -SessionVariable sessaoWeb -UseBasicParsing -TimeoutSec 30
            $tipoConteudo = ($resp1.Headers["Content-Type"] -join ";")
            $ehHtml = $tipoConteudo -match "text/html"

            if (-not $ehHtml) {
                [System.IO.File]::WriteAllBytes($DestinoLocal, $resp1.Content)
                return (Get-NomeArquivoDeContentDisposition -Headers $resp1.Headers)
            }

            $html = $resp1.Content

            if ($html -match "(?i)accounts\.google\.com" -or $html -match "(?i)ServiceLogin" -or $html -match "(?i)You need permission" -or $html -match "(?i)Sign in to continue") {
                throw "O arquivo nao esta publico no Google Drive (o Google pediu login em vez de mandar o arquivo). Verifique o compartilhamento do arquivo: precisa ser 'Qualquer pessoa com o link', nao so o dominio TRE-MA."
            }

            $urlFinal = $null
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
            if (-not $urlFinal -and $html -match 'confirm=([0-9A-Za-z_-]+)&amp;id=') {
                $urlFinal = "https://drive.google.com/uc?export=download&confirm=$($Matches[1])&id=$FileId"
            }
            if (-not $urlFinal) {
                throw "Nao consegui reconhecer a pagina de confirmacao de download grande do Google Drive (formato mudou) - ajustar o parser em Invoke-DownloadGoogleDrivePublico."
            }

            return (Invoke-DownloadArquivoComProgresso -Url $urlFinal -Cookies $sessaoWeb.Cookies -DestinoLocal $DestinoLocal -NomePacote $NomePacote -EstadoDownload $EstadoDownload)
        }

        try {
            $EstadoDownload.NomeArquivoOriginal = Invoke-DownloadGoogleDrivePublico -FileId $FileId -DestinoLocal $DestinoLocal -NomePacote $NomePacote -EstadoDownload $EstadoDownload
        } catch {
            $EstadoDownload.Erro = $_.Exception.Message
        } finally {
            $EstadoDownload.Concluido = $true
        }
    }

    $estadoDownload = [hashtable]::Synchronized(@{ Texto = ""; NomeArquivoOriginal = $null; Erro = $null; Concluido = $false })
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript($scriptBlockDownload).AddArgument($estadoDownload).AddArgument($Pacote.IdArquivo).AddArgument($arquivoTempLocal).AddArgument($Pacote.Pacote)
        $handle = $ps.BeginInvoke()
        $ultimoTexto = ""
        while (-not $handle.IsCompleted) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
            if ($estadoDownload.Texto -and $estadoDownload.Texto -ne $ultimoTexto) {
                $ultimoTexto = $estadoDownload.Texto
                if ($AoAtualizarStatus) { & $AoAtualizarStatus $ultimoTexto }
            }
        }
        $ps.EndInvoke($handle) | Out-Null
        if ($ps.Streams.Error.Count -gt 0) { throw $ps.Streams.Error[0].Exception }
    } catch {
        if (Test-Path -LiteralPath $arquivoTempLocal) { Remove-Item -LiteralPath $arquivoTempLocal -Force -ErrorAction SilentlyContinue }
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = "Falha ao baixar '$($Pacote.Pacote)' do Google Drive: $($_.Exception.Message)"; ArquivoCacheUnc = $null; NomeArquivoOriginal = $null; Avisos = @($avisos) }
    } finally {
        $ps.Dispose()
    }

    if ($estadoDownload.Erro) {
        if (Test-Path -LiteralPath $arquivoTempLocal) { Remove-Item -LiteralPath $arquivoTempLocal -Force -ErrorAction SilentlyContinue }
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = "Falha ao baixar '$($Pacote.Pacote)' do Google Drive: $($estadoDownload.Erro)"; ArquivoCacheUnc = $null; NomeArquivoOriginal = $null; Avisos = @($avisos) }
    }

    if ($AoAtualizarStatus) { & $AoAtualizarStatus "Calculando hash MD5 do que foi baixado..." }
    $hashLocal = (Get-FileHash -Path $arquivoTempLocal -Algorithm MD5).Hash
    if ($Pacote.Hash -and $hashLocal -ne $Pacote.Hash) {
        $avisos.Add("ATENCAO: hash MD5 do pacote baixado NAO confere com o oficial da planilha (baixado=$hashLocal planilha=$($Pacote.Hash)) - o download pode ter vindo corrompido.")
    }

    try {
        Copy-ArquivoComRobocopy -Origem $arquivoTempLocal -Destino $caminhoCacheUnc -NomePacote $Pacote.Pacote -AoAtualizarStatus $AoAtualizarStatus
        if ($estadoDownload.NomeArquivoOriginal) {
            Set-Content -Path $caminhoNomeUnc -Value $estadoDownload.NomeArquivoOriginal -Encoding UTF8
        }
        Set-Content -Path $caminhoHashUnc -Value $hashLocal -Encoding UTF8
    } catch {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = "Download concluido, mas falhou ao gravar no cache compartilhado do servidor: $($_.Exception.Message)"; ArquivoCacheUnc = $null; NomeArquivoOriginal = $estadoDownload.NomeArquivoOriginal; Avisos = @($avisos) }
    } finally {
        Remove-Item -LiteralPath $arquivoTempLocal -Force -ErrorAction SilentlyContinue
    }

    return [PSCustomObject]@{ Sucesso = $true; Mensagem = "Pacote '$($Pacote.Pacote)' baixado e adicionado ao cache compartilhado."; ArquivoCacheUnc = $caminhoCacheUnc; NomeArquivoOriginal = $estadoDownload.NomeArquivoOriginal; Avisos = @($avisos) }
}

function Invoke-AcaoVerificarHashPacote {
    <#
        Reconfere o hash MD5 do arquivo JA copiado no destino, lendo o
        arquivo INTEIRO de volta pelo link da zona (por isso so roda sob
        demanda, nunca automatico). Relocacao de
        Invoke-AcaoVerificarHashPacote do ScannerRedeZona.ps1 original -
        diferencas: perde $GridStatus/$LinhaIndice (vira
        $AoAtualizarStatus, mesma disciplina do resto deste modulo) e NAO
        mostra MessageBox aqui dentro - devolve um resultado estruturado,
        quem chama (a janela) decide como exibir.

        Comparado, em ordem de preferencia: (1) coluna Hash da planilha
        (MD5 oficial do Google Drive); (2) sidecar .md5 do cache
        compartilhado do servidor (Get-HashCachePacote).
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Resultado,
        [Parameter(Mandatory)][PSCustomObject]$Pacote,
        $StatusInfo = $null,
        [scriptblock]$AoAtualizarStatus = $null
    )

    $statusInfo = $StatusInfo
    if (-not $statusInfo) { $statusInfo = Get-StatusPacoteNoDestino -Resultado $Resultado -Pacote $Pacote }
    if (-not $statusInfo.Existe) {
        return [PSCustomObject]@{ Sucesso = $false; Confere = $null; Mensagem = "Esse pacote ainda nao foi copiado pra essa maquina."; HashReferencia = $null; HashDestino = $null; OrigemHash = $null; ArquivoDestino = $null }
    }

    $origemHash = "planilha (oficial do Drive)"
    $hashReferencia = $Pacote.Hash
    if (-not $hashReferencia) {
        $hashReferencia = Get-HashCachePacote -Pacote $Pacote
        $origemHash = "cache compartilhado do servidor (baixado por esta ferramenta)"
    }
    if (-not $hashReferencia) {
        return [PSCustomObject]@{ Sucesso = $false; Confere = $null; Mensagem = "Sem hash de referencia pra comparar (nem a coluna Hash da planilha, nem o cache compartilhado do servidor tem esse pacote)."; HashReferencia = $null; HashDestino = $null; OrigemHash = $null; ArquivoDestino = $statusInfo.ArquivoDestino }
    }

    if ($AoAtualizarStatus) { & $AoAtualizarStatus "Verificando hash MD5 (lendo arquivo inteiro pela rede)..." }

    # Le o arquivo INTEIRO pela rede da zona pra calcular o hash - roda num
    # runspace em segundo plano com a thread da UI so bombeando DoEvents
    # enquanto espera. Nao usa Get-FileHash (usa
    # System.Security.Cryptography.MD5 direto, lendo em blocos de 4MB) -
    # o buffer interno do Get-FileHash e pequeno demais pra um link com
    # latencia alta.
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

    $cronometro = [System.Diagnostics.Stopwatch]::StartNew()
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
                if ($AoAtualizarStatus) { & $AoAtualizarStatus "Verificando hash MD5 ha $([Math]::Round($cronometro.Elapsed.TotalSeconds))s..." }
            }
        }
        $hashRemoto = $psHash.EndInvoke($handleHash)
        if ($psHash.Streams.Error.Count -gt 0) { throw $psHash.Streams.Error[0].Exception }
    } catch {
        return [PSCustomObject]@{ Sucesso = $false; Confere = $null; Mensagem = "Falha ao ler o arquivo no destino pra calcular o hash: $($_.Exception.Message)"; HashReferencia = $hashReferencia; HashDestino = $null; OrigemHash = $origemHash; ArquivoDestino = $statusInfo.ArquivoDestino }
    } finally {
        $psHash.Dispose()
    }

    $confere = $hashRemoto -eq $hashReferencia
    if ($AoAtualizarStatus) { & $AoAtualizarStatus $(if ($confere) { "Hash MD5 conferido - integro." } else { "Hash MD5 NAO confere - possivel corrupcao." }) }

    return [PSCustomObject]@{
        Sucesso        = $true
        Confere        = $confere
        Mensagem       = $(if ($confere) { "Os dois hashes conferem." } else { "ATENCAO: o arquivo no destino pode estar corrompido - recomendado copiar de novo." })
        HashReferencia = $hashReferencia
        HashDestino    = $hashRemoto
        OrigemHash     = $origemHash
        ArquivoDestino = $statusInfo.ArquivoDestino
    }
}

function Invoke-AcaoAbrirPastaPacote {
    <#
        Abre o Explorer na pasta onde o pacote REALMENTE esta - se foi
        achado fora do padrao, abre ESSA pasta em vez da esperada. So cai
        pra pasta esperada (\\IP\InstSeg\PastaDestino) se nada foi
        encontrado em lugar nenhum. Relocacao quase pura do original, so
        Start-ProcessoNaoElevado (auto-elevacao, nao existe mais nesta
        ferramenta) vira Start-Process simples.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Resultado,
        [Parameter(Mandatory)][PSCustomObject]$Pacote,
        $StatusInfo = $null
    )

    $statusInfo = $StatusInfo
    if (-not $statusInfo) { $statusInfo = Get-StatusPacoteNoDestino -Resultado $Resultado -Pacote $Pacote }

    $pastaParaAbrir = if ($statusInfo.Existe -and $statusInfo.ArquivoDestino) {
        Split-Path $statusInfo.ArquivoDestino -Parent
    } else {
        $statusInfo.PastaDestinoUnc
    }

    if (-not (Test-Path $pastaParaAbrir)) {
        return [PSCustomObject]@{ Sucesso = $false; Mensagem = "A pasta ainda nao existe no destino:`r`n$pastaParaAbrir`r`n`r`n(normal se nenhum pacote foi copiado pra la ainda)" }
    }
    Start-Process -FilePath $pastaParaAbrir
    return [PSCustomObject]@{ Sucesso = $true; Mensagem = "Pasta aberta: $pastaParaAbrir" }
}

function Get-ArquivoCvcMaisRecente {
    <#
        Procura, no compartilhamento \\<IP>\InstSeg\CVC da propria estacao,
        o arquivo .cvc cujo nome (sem extensao) e identico ao nome curto
        da maquina. Se houver mais de um, fica com o de data de
        modificacao mais recente. Relocacao pura do original.
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
        Localiza o CVC da maquina (\\IP\InstSeg\CVC, 1 salto Kerberos,
        acesso direto do cliente) e tenta enviar ao Google Drive via
        Send-ArquivoParaGoogleDriveRemoto (POST feito pelo SERVIDOR -
        Fase 7 ja pronta) - o cliente le os bytes e converte pra base64
        ANTES de chamar, porque ler o arquivo de dentro da sessao remota
        do servidor esbarraria no duplo-salto de Kerberos ja documentado
        (Fase 6). Se o envio automatico falhar por qualquer motivo (Web
        App nao configurado, fora do ar, erro de rede), cai no fallback
        manual: copia o arquivo pra uma pasta local e devolve os dados
        pra quem chama abrir a pasta local + a pasta do Drive no
        navegador, pro tecnico arrastar o arquivo manualmente.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Resultado,
        [scriptblock]$AoAtualizarStatus = $null
    )

    $temNomeResolvido = $Resultado.Hostname -and $Resultado.Hostname -ne "(sem resolucao de nome)"
    if (-not $temNomeResolvido) {
        return [PSCustomObject]@{ Sucesso = $false; Metodo = $null; Mensagem = "Este host nao tem nome resolvido - nao e possivel localizar o arquivo CVC pelo nome da maquina."; PastaLocal = $null; UrlDrive = $null }
    }

    $hostnameCurto = ($Resultado.Hostname -split '\.')[0]
    $pastaCvc = "\\$($Resultado.IP)\InstSeg\CVC"
    if ($AoAtualizarStatus) { & $AoAtualizarStatus "Procurando arquivo CVC de '$hostnameCurto' em $pastaCvc..." }

    $arquivo = $null
    try {
        $arquivo = Get-ArquivoCvcMaisRecente -IP $Resultado.IP -HostnameCurto $hostnameCurto
    } catch {
        return [PSCustomObject]@{ Sucesso = $false; Metodo = $null; Mensagem = "Falha ao acessar ${pastaCvc}: $($_.Exception.Message)"; PastaLocal = $null; UrlDrive = $null }
    }

    if (-not $arquivo) {
        return [PSCustomObject]@{ Sucesso = $false; Metodo = $null; Mensagem = "Nenhum arquivo '$hostnameCurto.cvc' encontrado em:`r`n$pastaCvc"; PastaLocal = $null; UrlDrive = $null }
    }

    if ($AoAtualizarStatus) { & $AoAtualizarStatus "CVC encontrado ($($arquivo.Name)) - enviando automaticamente ao Google Drive..." }

    try {
        $bytes = [System.IO.File]::ReadAllBytes($arquivo.FullName)
        $base64 = [System.Convert]::ToBase64String($bytes)
        $respEnvio = Send-ArquivoParaGoogleDriveRemoto -NomeArquivo $arquivo.Name -ConteudoBase64 $base64
    } catch {
        $respEnvio = [PSCustomObject]@{ Ok = $false; Mensagem = $_.Exception.Message; Url = $null }
    }

    if ($respEnvio -and $respEnvio.Ok) {
        return [PSCustomObject]@{ Sucesso = $true; Metodo = "automatico"; Mensagem = "CVC de '$hostnameCurto' enviado automaticamente para o Google Drive ($($respEnvio.Url))."; PastaLocal = $null; UrlDrive = $respEnvio.Url }
    }

    if ($AoAtualizarStatus) { & $AoAtualizarStatus "Envio automatico falhou - copiando localmente para envio manual (fallback)..." }

    try {
        if (-not (Test-Path $script:PastaLocalEnvioCvc)) {
            New-Item -ItemType Directory -Path $script:PastaLocalEnvioCvc -Force | Out-Null
        }
        $destino = Join-Path $script:PastaLocalEnvioCvc $arquivo.Name
        Copy-Item -Path $arquivo.FullName -Destination $destino -Force
    } catch {
        return [PSCustomObject]@{ Sucesso = $false; Metodo = $null; Mensagem = "Envio automatico falhou ($($respEnvio.Mensagem)) e a copia local tambem falhou: $($_.Exception.Message)"; PastaLocal = $null; UrlDrive = $null }
    }

    Start-Process -FilePath "explorer.exe" -ArgumentList "/select,`"$destino`""
    Start-Process -FilePath $script:UrlDrivePastaCvc

    return [PSCustomObject]@{
        Sucesso    = $true
        Metodo     = "manual"
        Mensagem   = "Envio automatico falhou ($($respEnvio.Mensagem)). CVC copiado para $destino - arraste o arquivo ate a janela do navegador (pasta do Drive ja aberta) para concluir o envio."
        PastaLocal = $destino
        UrlDrive   = $script:UrlDrivePastaCvc
    }
}

Export-ModuleMember -Function Get-CaminhoDestinoUnc, Get-NomeArquivoConhecidoPacote, Get-HashCachePacote, Get-ArquivosInstSeg, Start-ArquivosInstSegAsync, Test-ArquivosInstSegAsync, Find-PacoteEmArquivosInstSeg, Get-StatusPacoteNoDestino, Format-DuracaoLegivel, Copy-ArquivoComRobocopy, Invoke-AcaoCopiarPacoteJaBaixado, Invoke-AcaoVerificarHashPacote, Invoke-AcaoAbrirPastaPacote, Get-ArquivoCvcMaisRecente, Invoke-AcaoEnviarCvcDrive, Invoke-AcaoGarantirPacoteEmCache
