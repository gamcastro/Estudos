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
    #>
    param($Resultado, [int]$TimeoutSec = 15)

    $raizInstSeg = "\\$($Resultado.IP)\InstSeg"
    if (-not (Test-Path $raizInstSeg)) { return $null }

    $scriptBlockListar = {
        param($Raiz)
        try { return @(Get-ChildItem -Path $Raiz -File -Recurse -Depth 6 -ErrorAction SilentlyContinue) } catch { return @() }
    }
    $ps = [powershell]::Create()
    try {
        [void]$ps.AddScript($scriptBlockListar).AddArgument($raizInstSeg)
        $handle = $ps.BeginInvoke()
        $cronometro = [System.Diagnostics.Stopwatch]::StartNew()
        while (-not $handle.IsCompleted -and $cronometro.Elapsed.TotalSeconds -lt $TimeoutSec) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 100
        }
        if (-not $handle.IsCompleted) {
            $ps.Stop()
            return $null
        }
        return @($ps.EndInvoke($handle))
    } catch {
        return $null
    } finally {
        $ps.Dispose()
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
    #>
    param($Resultado, $Pacote)

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

    $arquivosInstSeg = Get-ArquivosInstSeg -Resultado $Resultado
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

function Copy-ArquivoComRobocopy {
    <#
        Copia um arquivo (origem tipicamente \\POLICY-SERVER...\
        ScanZonas\CacheDownloads\... - o cache compartilhado do
        servidor) pro destino \\IP\InstSeg\... via robocopy.exe. Roda
        direto na thread de UI do cliente (DoEvents durante a espera,
        igual o ScannerRedeZona.ps1 original) - $AoAtualizarStatus
        (opcional) e chamado com o texto de status a cada atualizacao,
        no lugar de $GridStatus/$LinhaIndice do original.
    #>
    param(
        [string]$Origem,
        [string]$Destino,
        [string]$NomePacote = "pacote",
        [scriptblock]$AoAtualizarStatus = $null
    )

    if ($AoAtualizarStatus) { & $AoAtualizarStatus "Iniciando copia de '$NomePacote'..." }

    $origemDir = Split-Path $Origem -Parent
    $nomeArquivo = Split-Path $Origem -Leaf
    $destinoDir = Split-Path $Destino -Parent
    $nomeFinalDesejado = Split-Path $Destino -Leaf
    $caminhoComNomeOrigem = Join-Path $destinoDir $nomeArquivo
    $totalBytes = (Get-Item $Origem).Length

    # /Z = restartable; /J = I/O nao-bufferizado; /R:5 /W:10 = tenta ate
    # 5x, esperando 10s; /NP evita progresso por byte no console; os
    # /N*/NC/NS reduzem o log a praticamente nada - mesmos flags do
    # ScannerRedeZona.ps1 original.
    $argsRobocopy = @(
        "`"$origemDir`""
        "`"$destinoDir`""
        "`"$nomeArquivo`""
        "/Z", "/J", "/R:5", "/W:10", "/NP", "/NJH", "/NJS", "/NDL", "/NFL", "/NC", "/NS"
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
        if ($AoAtualizarStatus) { & $AoAtualizarStatus "Copiando '$NomePacote' (robocopy, $mbTotal MB) ha $(Format-DuracaoLegivel 0)..." }
        while (-not $processo.HasExited) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 200
            if ($proximaAtualizacao.Elapsed.TotalSeconds -ge 3) {
                $proximaAtualizacao.Restart()
                if ($AoAtualizarStatus) { & $AoAtualizarStatus "Copiando '$NomePacote' (robocopy, $mbTotal MB) ha $(Format-DuracaoLegivel $cronometro.Elapsed.TotalSeconds)..." }
            }
        }
        $processo.WaitForExit()
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
        [scriptblock]$AoAtualizarStatus = $null
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

    Copy-ArquivoComRobocopy -Origem $ArquivoCacheUnc -Destino $arquivoDestinoUnc -NomePacote $Pacote.Pacote -AoAtualizarStatus $AoAtualizarStatus

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

Export-ModuleMember -Function Get-CaminhoDestinoUnc, Get-NomeArquivoConhecidoPacote, Get-ArquivosInstSeg, Find-PacoteEmArquivosInstSeg, Get-StatusPacoteNoDestino, Format-DuracaoLegivel, Copy-ArquivoComRobocopy, Invoke-AcaoCopiarPacoteJaBaixado
