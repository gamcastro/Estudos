<#
    VisaoRemoting.psm1

    Camada fina do lado do CLIENTE que fala com o POLICY-SERVER via
    PowerShell Remoting (WinRM) - concentra toda a fronteira de remoting
    num lugar so, em vez de espalhar Invoke-Command cru pelos handlers de
    botao do VisaoCliente.ps1.

    Confirmado ao vivo (sessao de planejamento) que a conexao PRECISA ser
    pelo NOME do servidor (FQDN), nunca pelo IP puro - por IP o Kerberos
    quebra com HTTP 403 (falta de SPN resolvivel). Isso fica fixo aqui,
    no unico lugar que chama New-PSSession, de proposito - nao expor isso
    como configuravel (ex: campo de "endereco do servidor" na tela) sem
    documentar de novo esse motivo.

    Ver o plano completo da migracao em:
    C:\Users\029342881104\.claude\plans\splendid-enchanting-mochi.md
#>

$script:NomeServidorVisao = "POLICY-SERVER.tre-ma.gov.br"
$script:CaminhoVisaoServidorPs1 = Join-Path $PSScriptRoot "VisaoServidor.ps1"
$script:PSSessionServidor = $null
# Identidade da sessao ATUAL - trocada (novo GUID) toda vez que uma sessao
# NOVA e criada de verdade (nunca no caso de "ja estava aberta, so
# reaproveitou"). Existe so pra quem faz POLLING sobre estado acumulado no
# servidor (Get-VarreduraNovosResultadosRemoto) conseguir perceber quando a
# sessao caiu e foi reconectada NO MEIO do polling - sem isso, uma sessao
# nova (processo remoto novo, sem $script:EstadoVarredura nenhum) devolve
# "EmAndamento=$false, Total=0", visualmente identico a "varredura
# concluida com 0 resultados", confirmado ao vivo como um cenario real (ver
# teste de resiliencia da Fase 4).
$script:IdSessaoAtual = $null

# Pasta usada pelo instalador pra guardar o launcher/log de auto-
# atualizacao (ver Instalar-Visao.ps1) - reaproveitada aqui pro log de
# eventos de conexao, pelo mesmo motivo: fica visivel/coletavel pelo
# suporte sem precisar pegar o tecnico em flagrante com o problema
# acontecendo ao vivo.
$script:PastaLogVisao = Join-Path $env:LOCALAPPDATA 'SuporteTI\Visao'
$script:ArquivoLogConexao = Join-Path $script:PastaLogVisao 'Conexao.log'

function Registrar-LogConexao {
    <#
        Log local (nao vai pro servidor) de eventos de conexao/reconexao
        com o POLICY-SERVER - existe pra dar visibilidade de quanto
        tempo cada reconexao realmente leva e com que frequencia
        acontece, sem depender do tecnico "pegar no flagrante" e
        descrever o que viu. Guarda so as ultimas 200 linhas.
    #>
    <#
        Achado ao vivo (2026-08-25): o Set-Content abaixo pode falhar com
        "O fluxo nao era legivel" (ArgumentException) quando duas
        chamadas tentam ler/escrever este MESMO arquivo quase ao mesmo
        tempo (ex: aviso periodico do polling da varredura + Connect-
        ServidorVisao reconectando em paralelo) - e um erro NAO-
        TERMINANTE por padrao no Set-Content, entao o "catch {}" simples
        que existia antes NAO pegava (so aparecia em vermelho no console
        e seguia em frente) - confirmado ao vivo que isso escapou sem
        tratamento e derrubou a aplicacao inteira. -ErrorAction Stop em
        ambos + ate 3 tentativas com pequena pausa resolve a colisao
        pontual sem mudar o formato do log.
    #>
    param([string]$Linha)
    try {
        if (-not (Test-Path -LiteralPath $script:PastaLogVisao)) {
            New-Item -Path $script:PastaLogVisao -ItemType Directory -Force | Out-Null
        }
        $linhaComData = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Linha"

        for ($tentativa = 1; $tentativa -le 3; $tentativa++) {
            try {
                $linhasExistentes = @()
                if (Test-Path -LiteralPath $script:ArquivoLogConexao) {
                    $linhasExistentes = @(Get-Content -LiteralPath $script:ArquivoLogConexao -ErrorAction Stop)
                }
                $linhasFinais = @($linhasExistentes + $linhaComData) | Select-Object -Last 200
                Set-Content -LiteralPath $script:ArquivoLogConexao -Value $linhasFinais -Encoding utf8 -Force -ErrorAction Stop
                break
            } catch {
                if ($tentativa -eq 3) { throw }
                Start-Sleep -Milliseconds 50
            }
        }
    } catch {}
}

function Registrar-AvisosNativosJob {
    <#
        Um job -AsJob preserva os avisos NATIVOS que o proprio WinRM
        gera sozinho durante a reconexao robusta (ex: "A conexao de rede
        com POLICY-SERVER... foi interrompida. Tentando reconexao por
        ate 4 minutos...") no stream de Warning do job - normalmente so
        aparecem (sem hora nenhuma) na janela de console atras da GUI,
        sem nenhum jeito do tecnico saber QUANDO cada um aconteceu de
        verdade. Aqui pega qualquer aviso NOVO desde a ultima checagem
        (via $IndiceProcessado, guardado por quem chama no proprio
        objeto de estado) e grava no Conexao.log (COM timestamp, ja que
        Registrar-LogConexao sempre adiciona um). Devolve o indice
        atualizado.
    #>
    param($Job, [int]$IndiceProcessado = 0)

    $avisos = @($Job.Warning)
    for ($i = $IndiceProcessado; $i -lt $avisos.Count; $i++) {
        Registrar-LogConexao "[WinRM] $($avisos[$i].Message)"
    }
    return $avisos.Count
}

function Wait-RunspaceDisponivelParaNovoComando {
    <#
        Achado ao vivo (2026-08-27, depois do keepalive comecar a
        disparar chamadas a cada ~60s na MESMA sessao): o job.State de
        um Invoke-Command -AsJob anterior pode virar um estado terminal
        (Completed/Failed) um instante ANTES da Runspace subjacente
        (PSSession.Runspace.RunspaceAvailability) realmente voltar a
        "Available" - se um NOVO Invoke-Command -AsJob for disparado
        nessa janela estreita (ex: keepalive terminando bem na hora que
        o tecnico clica "Iniciar Varredura", ou um retry quase imediato
        depois do aviso "Ja ha uma chamada remota em andamento"), o
        proprio WinRM/PSRP rejeita na hora com "O pipeline nao foi
        executado porque um pipeline ja esta em execucao" - um erro
        RARO antes do keepalive existir (as chamadas ficavam bem mais
        espacadas), que passou a acontecer com chamadas costurando uma
        atras da outra na mesma sessao. Espera curta (no maximo ~2s,
        SEM DoEvents de proposito - ver historico de bugs de DoEvents
        aninhado) ate a Runspace realmente ficar disponivel de novo
        antes de tentar o proximo Invoke-Command -AsJob - na pratica
        deve resolver em bem menos de 1s; se estourar os 2s, so segue
        em frente mesmo assim (deixa o proprio Invoke-Command decidir).
    #>
    param([Parameter(Mandatory)]$Sessao)

    $cronometro = [System.Diagnostics.Stopwatch]::StartNew()
    while ($Sessao.Runspace -and $Sessao.Runspace.RunspaceAvailability -ne [System.Management.Automation.Runspaces.RunspaceAvailability]::Available) {
        if ($cronometro.Elapsed.TotalSeconds -ge 2) { return }
        Start-Sleep -Milliseconds 50
    }
}

function Connect-ServidorVisao {
    <#
        Abre (ou reabre) a sessao persistente com o POLICY-SERVER e
        carrega o VisaoServidor.ps1 nela (Invoke-Command -FilePath, uma
        vez por sessao - NAO recarrega a cada chamada, ver comentario no
        topo do VisaoServidor.ps1). Devolve $true/$false; quem chama
        decide o que fazer em caso de falha (ex: mostrar erro e nao abrir
        a janela principal).

        SessionOption com OperationTimeout/IdleTimeout/OpenTimeout MENORES
        que o padrao do PowerShell (3 minutos de OperationTimeout, 2
        horas de IdleTimeout, 3 minutos de OpenTimeout) - confirmado como
        causa real de "a ferramenta trava se ficar muito tempo ociosa":
        um firewall intermediario pode derrubar a conexao TCP em
        silencio (sem RST/FIN) enquanto a janela fica parada; sem um
        limite mais curto, a PROXIMA chamada remota (Invoke-ComandoRemoto,
        sincrona na thread de UI - trava a janela inteira enquanto
        espera) so percebe a sessao morta depois de ate 3 minutos parada,
        antes da reconexao automatica (ja existente em Invoke-ComandoRemoto)
        entrar em acao.

        O OpenTimeout (3 minutos por padrao) e um limite DIFERENTE do
        OperationTimeout - controla quanto tempo o New-PSSession abaixo
        espera enquanto tenta ABRIR uma sessao nova, nao uma ja aberta.
        Achado ao vivo (2026-08-23): um tecnico relatou a GUI travando de
        verdade (nao so ficando ociosa) no meio do uso, com a janela de
        console atras mostrando que ainda estava tentando conectar. A
        primeira correcao deste comentario (OperationTimeout/IdleTimeout)
        so cobria sessao JA aberta que ficou idle - deixava de fora
        justamente o caso de reconexao no meio de uma queda de rede de
        verdade, onde o New-PSSession do zero podia ficar ate 3 minutos
        tentando abrir antes de desistir, com a UI travada o tempo todo
        (sincrono). Com esses limites mais curtos, o pior caso vira uma
        pausa de segundos, nao minutos, tanto pra idle quanto pra queda
        de rede de verdade.

        Achado ao vivo nº2 (2026-08-23) - MaxConnectionRetryCount: um
        tecnico reportou telas mostrando a mensagem NATIVA do WinRM
        "A conexao de rede com POLICY-SERVER foi interrompida. Tentando
        reconexao por ate 4 minutos..." (com contador regressivo) - isso
        NAO e codigo nosso, e o proprio WinRM tentando se recuperar
        sozinho de uma queda de rede ENQUANTO um comando ja estava em
        andamento (diferente de abrir sessao nova, que e o que
        OpenTimeout cobre). MaxConnectionRetryCount foi setado pra 1
        aqui, mas isso NAO encurta essa janela de 4 minutos (testado ao
        vivo de novo em 2026-08-24 na versao 2.0.19, com o print
        mostrando o mesmo contador de 4 minutos) - confirmado via
        pesquisa que esse parametro rege as tentativas de ABRIR uma
        conexao nova (o que legitimamente ajuda no cenario original
        deste comentario), nao a reconexao robusta do WinRM durante uma
        chamada JA em andamento, que parece nao ser configuravel por
        nenhuma API publica do PowerShell (confirmado tambem por um
        issue sem solucao no repositorio oficial do PowerShell no
        GitHub com o mesmo resultado). Mantido em 1 mesmo assim porque
        ainda e correto pro proposito documentado acima (idle/queda
        antes de abrir sessao nova) - so nao e mais tratado como fix
        pro sintoma dos "4 minutos". Ver Invoke-ComandoRemotoJob (fix
        de verdade pra esse sintoma: nao trava a UI enquanto o WinRM
        tenta se recuperar sozinho, em vez de tentar encurtar algo que
        nao da pra encurtar).
    #>
    if ($script:PSSessionServidor -and $script:PSSessionServidor.State -eq [System.Management.Automation.Runspaces.RunspaceState]::Opened) {
        return $true
    }

    Disconnect-ServidorVisao

    $cronometro = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $opcoesSessao = New-PSSessionOption -OpenTimeout 45000 -OperationTimeout 60000 -IdleTimeout 900000 -CancelTimeout 15000 -MaxConnectionRetryCount 1
        $script:PSSessionServidor = New-PSSession -ComputerName $script:NomeServidorVisao -SessionOption $opcoesSessao -ErrorAction Stop
        Invoke-Command -Session $script:PSSessionServidor -FilePath $script:CaminhoVisaoServidorPs1 -ErrorAction Stop
        $script:IdSessaoAtual = [guid]::NewGuid()
        Registrar-LogConexao "Conectado com sucesso ($([math]::Round($cronometro.Elapsed.TotalSeconds, 1))s)"
        return $true
    } catch {
        Write-Warning "Falha ao conectar/carregar logica no servidor '$($script:NomeServidorVisao)': $($_.Exception.Message)"
        Registrar-LogConexao "Falha ao conectar ($([math]::Round($cronometro.Elapsed.TotalSeconds, 1))s): $($_.Exception.Message)"
        $script:PSSessionServidor = $null
        $script:IdSessaoAtual = $null
        return $false
    }
}

function Disconnect-ServidorVisao {
    <#
        Fecha a sessao persistente atual, se existir. Chamada antes de
        reconectar (Connect-ServidorVisao) e ao fechar a ferramenta.
    #>
    if ($script:PSSessionServidor) {
        try { Remove-PSSession -Session $script:PSSessionServidor -ErrorAction SilentlyContinue } catch {}
        $script:PSSessionServidor = $null
    }
    $script:IdSessaoAtual = $null
}

function Get-IdSessaoAtualVisao {
    <#
        Devolve o GUID da sessao atual (ou $null se nao conectado) - ver o
        comentario de $script:IdSessaoAtual acima. Usado por quem inicia
        uma operacao com estado acumulado no servidor (hoje so a
        varredura) pra depois conseguir detectar reconexao no meio.
    #>
    return $script:IdSessaoAtual
}

function Invoke-ComandoRemotoJob {
    <#
        Roda Invoke-Command -AsJob na sessao e espera o resultado
        bombeando a fila de mensagens do WinForms (Application]::DoEvents,
        mesmo padrao ja usado no polling do robocopy em
        Copy-ArquivoComRobocopy) em vez de bloquear a thread de UI com
        um Invoke-Command sincrono direto.

        Existe por causa de um achado ao vivo (2026-08-24): quando a
        rede cai NO MEIO de uma chamada ja em andamento, o proprio WinRM
        tenta se reconectar sozinho por ate ~4 minutos ANTES de
        qualquer excecao chegar ate o PowerShell (mensagem nativa "A
        conexao de rede... foi interrompida. Tentando reconexao por ate
        4 minutos..."). Confirmado ao vivo (e por um issue aberto no
        proprio repositorio do PowerShell no GitHub com o mesmo
        resultado) que NENHUM parametro de New-PSSessionOption
        (OpenTimeout/OperationTimeout/IdleTimeout/MaxConnectionRetryCount)
        encurta essa janela - nao e configuravel pelas APIs publicas do
        PowerShell. Como nao da pra deixar essa espera mais curta, a
        alternativa e nao deixar ela TRAVAR a janela inteira enquanto
        dura: com -AsJob + DoEvents, o resto da GUI continua respondendo
        durante a espera (e, no caso comum de a reconexao nativa do
        WinRM ter sucesso sozinha, a operacao original SIMPLESMENTE
        CONTINUA e devolve o resultado normal - abortar mais cedo por
        conta propria jogaria fora uma chamada que ia dar certo).

        Achado ao vivo nº2 (2026-08-24): tecnico relatou a ferramenta
        parecendo travar de vez ("teve que fechar a aplicacao") ao
        iniciar uma varredura logo apos usar o botao ContraSenha-LAPS/
        Transferidor Instseg - sem NENHUMA mensagem de erro, so silencio
        total. Suspeita (nao 100% confirmada - o log da ferramenta nao
        mostra o que acontece DENTRO desta espera): a espera acima nao
        tinha limite nenhum - se o job nunca saisse de Running/NotStarted
        (rede realmente ruim, nao so um blip curto), a ferramenta ficava
        "tecnicamente respondendo" (DoEvents continua rodando, a janela
        nao trava pro Windows) mas visualmente PARADA pra sempre, sem
        nenhum feedback nem erro - pro tecnico, indistinguivel de
        travado de verdade. Adicionado um limite maximo (5 minutos, bem
        acima do teto de ~4min do proprio WinRM, pra nunca abortar uma
        reconexao nativa que ia dar certo sozinha) que desiste e lanca
        erro claro, alem de avisos periodicos no Conexao.log durante
        esperas longas - da visibilidade de verdade (antes so tinhamos
        log de ANTES/DEPOIS de cada chamada, nada de dentro de uma
        chamada trava).

        Achado ao vivo nº4, o mais critico (2026-08-26): confirmado via
        pilha de excecao COMPLETA capturada ao vivo que o crash real
        (AccessViolationException em WSManReconnectShellCommandEx, ja
        documentado antes) acontece especificamente DENTRO de Stop-Job/
        Remove-Job quando chamados sobre um job cujo transporte WinRM
        ainda esta tentando se reconectar sozinho - Remove-Job (mesmo so
        de limpeza, SEM -Force) e Stop-Job chamam internamente
        PSRemotingJob.StopJob(), que por sua vez tenta uma "conexao" com
        o job antes de pará-lo de verdade - se o transporte nativo
        estiver numa reconexao ja em andamento (rede instavel de
        verdade, nao precisa nem ser provocado - confirmado ao vivo
        SEM nenhuma queda de rede forcada, so instabilidade real da
        rede), essa segunda tentativa de conexao crasha o processo
        inteiro (excecao de estado corrompido, NENHUM try/catch pega).
        Por isso o limite de 300s abaixo NAO chama mais Stop-Job nem
        Remove-Job no job que estourou o prazo - so abandona a
        referencia (o job fica orfao, nunca mais tocado; o custo e um
        pequeno vazamento de memoria nesse cenario raro, aceitavel
        comparado a derrubar a aplicacao inteira) e desconecta a SESSAO
        (Disconnect-ServidorVisao, que usa Remove-PSSession - operacao
        DIFERENTE, nao implicada neste crash) pra garantir uma conexao
        nova na proxima tentativa. Ver project_crash_winrm_reconexao na
        memoria do projeto.
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Sessao,
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [scriptblock]$AoAtualizarStatus = $null
    )

    Wait-RunspaceDisponivelParaNovoComando -Sessao $Sessao
    $job = Invoke-Command -Session $Sessao -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -AsJob -ErrorAction Stop
    $cronometro = [System.Diagnostics.Stopwatch]::StartNew()
    $proximoAvisoEspera = 15
    $abandonarJob = $false
    $indiceAvisos = 0
    try {
        while ($job.State -eq [System.Management.Automation.JobState]::Running -or $job.State -eq [System.Management.Automation.JobState]::NotStarted) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 150
            $indiceAvisos = Registrar-AvisosNativosJob -Job $job -IndiceProcessado $indiceAvisos

            $segundosDecorridos = $cronometro.Elapsed.TotalSeconds
            if ($segundosDecorridos -ge $proximoAvisoEspera) {
                $textoAviso = "Ainda aguardando resposta do servidor apos $([math]::Round($segundosDecorridos))s (WinRM pode estar tentando se reconectar sozinho em segundo plano)."
                Registrar-LogConexao $textoAviso
                if ($AoAtualizarStatus) { & $AoAtualizarStatus $textoAviso }
                $proximoAvisoEspera += 30
            }

            if ($segundosDecorridos -ge 300) {
                $abandonarJob = $true
                Registrar-LogConexao "Chamada abortada apos 300s sem resposta - forcando sessao a ser considerada perdida (job abandonado sem Stop-Job/Remove-Job, ver comentario acima)."
                # Forca a sessao a ser tratada como morta (nao so lanca o
                # erro) - o Invoke-ComandoRemoto que chamou isto decide
                # se reconecta com base no ESTADO da sessao depois da
                # falha; sem isto, uma sessao que ainda "parece" Opened
                # (mesmo travada de verdade) nao acionaria a reconexao
                # automatica na proxima tentativa do tecnico.
                Disconnect-ServidorVisao
                throw [System.TimeoutException]::new("O POLICY-SERVER nao respondeu em 5 minutos - a conexao foi considerada perdida.")
            }
        }
        $indiceAvisos = Registrar-AvisosNativosJob -Job $job -IndiceProcessado $indiceAvisos
        return Receive-Job -Job $job -ErrorAction Stop
    }
    finally {
        # So remove o job se ele CHEGOU sozinho a um estado terminal (nao
        # Running/NotStarted) - nunca com -Force, nunca no caso de
        # $abandonarJob (ver achado nº4 acima).
        if (-not $abandonarJob) {
            Remove-Job -Job $job -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-ComandoRemoto {
    <#
        Wrapper que TODA chamada remota do cliente deve usar em vez de
        Invoke-Command direto - confere o estado da sessao antes de usar
        e, se estiver quebrada/fechada, tenta reconectar (e recarregar o
        VisaoServidor.ps1) UMA VEZ antes de repetir a chamada. Se a
        propria chamada falhar e a sessao tiver caido de verdade (ver
        Invoke-ComandoRemotoJob), tambem tenta reconectar+repetir uma
        vez.

        Erros vindos de DENTRO do scriptblock (ex: uma excecao que a
        propria funcao remota lancou de proposito) NAO acionam reconexao
        - so propagam pra quem chamou, normal. A distincao e feita pelo
        ESTADO da sessao depois da falha (Opened = foi erro de logica,
        qualquer outra coisa = a sessao caiu de verdade) em vez de casar
        o TIPO da excecao - Receive-Job (usado por Invoke-ComandoRemotoJob)
        nao necessariamente preserva o mesmo tipo de excecao
        (PSRemotingTransportException) que um Invoke-Command direto
        preservava, entao checar o estado e mais confiavel.

        Devolve o que o scriptblock remoto devolver. Lanca excecao
        ([System.InvalidOperationException], mensagem em pt-BR, clara e
        consistente) se nao conseguir nem depois de tentar reconectar -
        pensado pra virar uma unica mensagem de erro exibida no cliente,
        em vez de cada tela inventar o proprio texto.

        Bloqueia chamadas concorrentes ($script:SessaoOcupada) - achado
        ao vivo (2026-08-24), no dia seguinte a Invoke-ComandoRemotoJob
        passar a usar DoEvents (ver comentario dela): como isso bombeia
        a fila de mensagens do Windows enquanto espera, um handler
        DIFERENTE (ex: o tick do Timer da varredura - mesmo depois de
        $timer.Stop(), uma mensagem WM_TIMER que ja estava na fila antes
        do Stop() ainda pode ser entregue) podia disparar uma SEGUNDA
        chamada remota enquanto a primeira ainda estava em voo. Um unico
        Runspace/sessao so processa 1 pipeline por vez - a segunda
        chamada quebrava com "O pipeline nao foi executado porque um
        pipeline ja esta em execucao" (reproduzido ao vivo: varredura +
        relatorio de campanha + iniciar varredura de outra zona logo em
        seguida).

        A causa raiz (tick fantasma do Timer) foi corrigida na origem -
        ver guarda de reentrancia no handler do Timer em VisaoCliente.ps1.
        Aqui fica so uma rede de seguranca: uma segunda chamada concorrente
        (de qualquer origem, nao so o Timer) e REJEITADA na hora com uma
        excecao clara, em vez de ESPERAR - tentar esperar bombeando
        DoEvents aqui dentro criava um DEADLOCK real (testado ao vivo):
        se a segunda chamada e disparada de DENTRO de um handler que a
        primeira chamada acionou via seu proprio DoEvents (like o Timer
        tick), a segunda fica empilhada DENTRO do mesmo DoEvents da
        primeira - a primeira nunca volta a rodar pra perceber que seu
        job terminou, porque isso so aconteceria depois que a segunda
        (que esta esperando ela) retornasse. Rejeitar na hora evita esse
        ciclo por completo.

        $AoAtualizarStatus (opcional) e repassado pra
        Invoke-ComandoRemotoJob - achado ao vivo (2026-08-24): tecnico
        ficou preso na janela "Relatorio de Campanhas" com o texto
        estatico "Buscando resultados..." (sem nenhuma atualizacao) e o
        botao Fechar sem efeito ate a chamada interna terminar - teve
        que matar o processo. O limite de 5 minutos ja evitava travar
        pra sempre, mas sem NENHUM feedback visivel na tela, uma espera
        legitima de so alguns segundos ja parece travamento total pro
        tecnico. Quem chamar pode passar um callback que atualiza um
        Label da propria tela com o mesmo aviso que ja ia so pro
        Conexao.log.
    #>
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [scriptblock]$AoAtualizarStatus = $null
    )

    if ($script:SessaoOcupada) {
        throw [System.InvalidOperationException]::new("Ja ha uma chamada remota em andamento - aguarde terminar e tente de novo.")
    }
    $script:SessaoOcupada = $true
    try {
        if (-not $script:PSSessionServidor -or $script:PSSessionServidor.State -ne [System.Management.Automation.Runspaces.RunspaceState]::Opened) {
            if (-not (Connect-ServidorVisao)) {
                throw [System.InvalidOperationException]::new("Nao foi possivel conectar ao POLICY-SERVER. Verifique a rede/VPN e tente novamente.")
            }
        }

        try {
            return Invoke-ComandoRemotoJob -Sessao $script:PSSessionServidor -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -AoAtualizarStatus $AoAtualizarStatus
        } catch {
            if ($script:PSSessionServidor -and $script:PSSessionServidor.State -eq [System.Management.Automation.Runspaces.RunspaceState]::Opened) {
                throw
            }
            Registrar-LogConexao "Sessao perdida durante operacao remota: $($_.Exception.Message)"
            if (-not (Connect-ServidorVisao)) {
                throw [System.InvalidOperationException]::new("Conexao com o POLICY-SERVER perdida e nao foi possivel reconectar. Verifique a rede/VPN e tente novamente.")
            }
            try {
                return Invoke-ComandoRemotoJob -Sessao $script:PSSessionServidor -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -AoAtualizarStatus $AoAtualizarStatus
            } catch {
                throw [System.InvalidOperationException]::new("Conexao com o POLICY-SERVER foi perdida durante a operacao. Se estava no meio de uma varredura, ela ficou incompleta - inicie de novo.")
            }
        }
    }
    finally {
        $script:SessaoOcupada = $false
    }
}

# ============================================================
# FASE 1: leituras de planilha Google (request/resposta simples, sem
# polling).
#
# Get-ZonasRemoto/Get-GruposSistemasRemoto/Get-CampanhasRemoto/
# Get-ResultadosCampanhasRemoto/Resolve-RedeDaZonaRemoto/
# Test-RedeEhCompartilhadaRemoto NAO vivem mais aqui - migradas pra
# VisaoPlanilhas.psm1 em 2026-08-24 (leem a planilha CSV publicada
# DIRETO da estacao do tecnico, sem passar pelo POLICY-SERVER - decisao
# com o usuario, ver cabecalho de VisaoPlanilhas.psm1). As duas ultimas
# entraram na migracao numa segunda passada - dependiam de um efeito
# colateral que o Get-ZonasRemoto ANTIGO tinha no servidor (populava
# $script:TabelaZonas la), que quebrou "Iniciar Varredura" quando so as
# 4 leituras foram migradas na primeira passada.
# ============================================================
function Get-VersoesRemoto {
    <#
        Import-TabelaVersoes do lado servidor devolve uma STRING JSON
        (Pacotes e uma lista de PSCustomObject - mesmo bug de sempre).
        Aqui desserializa de volta; o objeto devolvido tem .Pacotes como
        array normal do PowerShell, pronto pra popular um ComboBox/menu
        no cliente.
    #>
    param([switch]$ForcarCache)
    $json = Invoke-ComandoRemoto -ScriptBlock { param($f) Import-TabelaVersoes -ForcarCache:$f } -ArgumentList @($ForcarCache.IsPresent)
    return ($json | ConvertFrom-Json)
}

function Get-SistemasEleitoraisExtraRemoto {
    <#
        Get-SistemasEleitoraisExtra do lado servidor devolve uma STRING
        JSON (array de PSCustomObject). Aqui desserializa de volta -
        schema das colunas dinamicas da grade principal (Bitlocker/
        Gedai/Holocron/etc), buscado uma vez na conexao.
    #>
    $json = Invoke-ComandoRemoto -ScriptBlock { Get-SistemasEleitoraisExtra }
    return @($json | ConvertFrom-Json)
}

# NOTA: nao existe "Get-StatusPacoteNoDestinoRemoto" nem
# "Start-BaixarECopiarPacoteRemoto" (a copia INTEIRA, incluindo a
# checagem "ja esta copiado?") - ver VisaoPacotes.psm1: acesso a
# \\IP\InstSeg das zonas roda DIRETO na estacao do tecnico, sem
# remoting, pelo mesmo motivo do AD (duplo-salto do Kerberos, so que
# desta vez sem alternativa de rodar no servidor - ver a nota grande
# em VisaoServidor.ps1 acima de $script:EstadoPacotes). So o DOWNLOAD
# do Google Drive fica aqui (Start-BaixarPacoteRemoto/
# Get-StatusPacoteRemoto, mais abaixo).

# ============================================================
# FASE 4/5: varredura de rede - padrao de POLLING sobre a sessao
# persistente (ver "Redesenho do progresso ao vivo" no plano). Quem
# chama (o Timer do VisaoCliente.ps1) dispara Start-VarreduraRemota uma
# vez e depois fica chamando Get-VarreduraNovosResultadosRemoto em
# intervalo (~500-1000ms), acumulando o delta recebido a cada chamada.
# ============================================================
function Start-VarreduraRemota {
    <#
        Devolve o GUID da sessao (Get-IdSessaoAtualVisao) capturado DEPOIS
        que Invoke-ComandoRemoto garantiu que a sessao esta aberta (e,
        se precisou reconectar, ja reconectou) - quem chama guarda esse
        valor e passa em TODA chamada de Get-VarreduraNovosResultadosRemoto
        subsequente, pra conseguir detectar se a sessao caiu e foi
        recriada no meio do polling (ver comentario de $script:IdSessaoAtual
        no topo deste arquivo).
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Ips,
        [Parameter(Mandatory)]
        [int]$Zona,
        [bool]$RedeCompartilhada = $false,
        [scriptblock]$AoAtualizarStatus = $null
    )
    Invoke-ComandoRemoto -ScriptBlock { param($i, $z, $rc) Start-VarreduraZona -Ips $i -Zona $z -RedeCompartilhada $rc } -ArgumentList @($Ips, $Zona, $RedeCompartilhada) -AoAtualizarStatus $AoAtualizarStatus | Out-Null
    return $script:IdSessaoAtual
}

function Get-VarreduraNovosResultadosRemoto {
    <#
        Get-VarreduraNovosResultados do lado servidor devolve uma STRING
        JSON (mesmo motivo de Get-ResultadosCampanhas - array de
        PSCustomObject nao atravessa o remoting neste servidor). Aqui
        desserializa de volta.

        $IdSessaoEsperado e o GUID devolvido por Start-VarreduraRemota no
        inicio desta varredura. Se a sessao atual (antes OU depois de
        fazer a chamada - ela pode reconectar sozinha DURANTE a propria
        chamada, via Invoke-ComandoRemoto) nao bater com esse GUID, a
        sessao foi recriada no meio do caminho: o estado da varredura
        (`$script:EstadoVarredura`) que estava acumulado no servidor
        antigo se perdeu (processo remoto novo = do zero). Confirmado ao
        vivo que, sem essa checagem, esse cenario devolve
        "EmAndamento=$false, Total=0, Concluidos=0" - visualmente
        IDENTICO a uma varredura genuina que terminou sem nenhum host,
        em vez de aparecer como "conexao perdida". Por isso devolve
        SessaoPerdida=$true nesse caso, pra quem chama poder mostrar a
        mensagem certa ("varredura incompleta, comece de novo") em vez de
        reportar "concluida" por engano.
    #>
    param(
        [Parameter(Mandatory)]
        [guid]$IdSessaoEsperado,
        [scriptblock]$AoAtualizarStatus = $null
    )

    if ($script:IdSessaoAtual -ne $IdSessaoEsperado) {
        return [PSCustomObject]@{ Novos = @(); Concluidos = 0; Total = 0; EmAndamento = $false; SessaoPerdida = $true }
    }

    $json = Invoke-ComandoRemoto -ScriptBlock { Get-VarreduraNovosResultados } -AoAtualizarStatus $AoAtualizarStatus

    if ($script:IdSessaoAtual -ne $IdSessaoEsperado) {
        return [PSCustomObject]@{ Novos = @(); Concluidos = 0; Total = 0; EmAndamento = $false; SessaoPerdida = $true }
    }

    $obj = $json | ConvertFrom-Json
    $obj | Add-Member -NotePropertyName SessaoPerdida -NotePropertyValue $false -PassThru
}

# ============================================================
# Polling da varredura SEM DoEvents aninhado (2026-08-25) - ver
# project_crash_winrm_reconexao na memoria do projeto.
#
# Get-VarreduraNovosResultadosRemoto (acima) e Invoke-ComandoRemoto
# esperam SINCRONAMENTE bombeando Application.DoEvents() - correto pra
# chamadas disparadas por um clique (uma vez so), mas quando chamado de
# DENTRO do Timer.Tick da varredura (a cada 750ms), o proprio DoEvents()
# pode despachar o PROXIMO tick do MESMO Timer enquanto o atual ainda
# esta esperando - empilhando chamadas cada vez mais fundo durante uma
# espera longa (15s-300s). Confirmado ao vivo como causa provavel de
# dois crashes reais da aplicacao inteira (AccessViolationException
# nativa em WSManReconnectShellCommandEx, e um erro de Set-Content
# escapando do proprio catch - ver Registrar-LogConexao) - os dois SO
# aconteceram com uma varredura em andamento, nunca em chamadas de
# clique unico.
#
# As duas funcoes abaixo existem SO pro polling da varredura (chamadas
# de Invoke-TickVarredura, VisaoCliente.ps1) - substituem Get-
# VarreduraNovosResultadosRemoto NESSE caminho especifico. Diferente do
# padrao normal (que devolve o resultado direto), aqui o TIMER e quem
# dirige a espera: Start-...Async dispara e devolve NA HORA (sem
# esperar nada), e cada tick seguinte chama Test-...Async so pra
# CONFERIR se ja terminou - nenhuma das duas chama DoEvents() em
# nenhum momento. Simplificacao deliberada em relacao a Invoke-
# ComandoRemoto: se a chamada falhar, NAO tenta reconectar+repetir
# sozinha (só devolve o erro) - quem chama (Invoke-TickVarredura) ja
# trata isso reiniciando a varredura, e Get-VarreduraNovosResultadosRemoto
# ja teria decidido "SessaoPerdida" no mesmo cenario mesmo com retry.
# ============================================================
function Start-VarreduraNovosResultadosRemotoAsync {
    <#
        Dispara a checagem de progresso (Invoke-Command -AsJob) e
        devolve IMEDIATAMENTE - nao espera nada. Mesma checagem de
        IdSessaoEsperado de Get-VarreduraNovosResultadosRemoto, feita
        ANTES de disparar (se a sessao ja mudou, nem chama o servidor).
    #>
    param(
        [Parameter(Mandatory)]
        [guid]$IdSessaoEsperado
    )

    if ($script:IdSessaoAtual -ne $IdSessaoEsperado) {
        return [PSCustomObject]@{ SessaoPerdidaImediato = $true; Estado = $null; IdSessaoEsperado = $IdSessaoEsperado }
    }

    if ($script:SessaoOcupada) {
        throw [System.InvalidOperationException]::new("Ja ha uma chamada remota em andamento - aguarde terminar e tente de novo.")
    }
    if (-not $script:PSSessionServidor -or $script:PSSessionServidor.State -ne [System.Management.Automation.Runspaces.RunspaceState]::Opened) {
        if (-not (Connect-ServidorVisao)) {
            throw [System.InvalidOperationException]::new("Nao foi possivel conectar ao POLICY-SERVER. Verifique a rede/VPN e tente novamente.")
        }
    }

    $script:SessaoOcupada = $true
    try {
        Wait-RunspaceDisponivelParaNovoComando -Sessao $script:PSSessionServidor
        $job = Invoke-Command -Session $script:PSSessionServidor -ScriptBlock { Get-VarreduraNovosResultados } -AsJob -ErrorAction Stop
    } catch {
        $script:SessaoOcupada = $false
        throw
    }

    return [PSCustomObject]@{
        SessaoPerdidaImediato = $false
        IdSessaoEsperado      = $IdSessaoEsperado
        Job                   = $job
        Cronometro            = [System.Diagnostics.Stopwatch]::StartNew()
        ProximoAvisoEspera    = 15
        IndiceAvisos          = 0
    }
}

function Test-VarreduraNovosResultadosRemotoAsync {
    <#
        Chamada a cada tick do Timer - devolve na hora, sem esperar nada
        (so olha o estado ATUAL do job). .Concluido indica se ja da pra
        processar (sucesso ou erro definitivo); enquanto $false, quem
        chama so tenta de novo no proximo tick.
    #>
    param(
        [Parameter(Mandatory)]
        $EstadoAsync,
        [scriptblock]$AoAtualizarStatus = $null
    )

    $job = $EstadoAsync.Job
    $rodando = ($job.State -eq [System.Management.Automation.JobState]::Running -or $job.State -eq [System.Management.Automation.JobState]::NotStarted)
    $EstadoAsync.IndiceAvisos = Registrar-AvisosNativosJob -Job $job -IndiceProcessado $EstadoAsync.IndiceAvisos

    if ($rodando) {
        $segundosDecorridos = $EstadoAsync.Cronometro.Elapsed.TotalSeconds
        if ($segundosDecorridos -ge $EstadoAsync.ProximoAvisoEspera) {
            $textoAviso = "Ainda aguardando resposta do servidor apos $([math]::Round($segundosDecorridos))s (WinRM pode estar tentando se reconectar sozinho em segundo plano)."
            Registrar-LogConexao $textoAviso
            if ($AoAtualizarStatus) { & $AoAtualizarStatus $textoAviso }
            $EstadoAsync.ProximoAvisoEspera += 30
        }

        if ($segundosDecorridos -ge 300) {
            # NAO chama Stop-Job/Remove-Job aqui de proposito - job
            # abandonado (referencia solta, nunca mais tocado). Ver achado
            # nº4 no comentario de Invoke-ComandoRemotoJob: Stop-Job/
            # Remove-Job num job cujo transporte WinRM ainda esta tentando
            # se reconectar sozinho e o que causa o AccessViolationException
            # real (confirmado ao vivo, 2026-08-26) - nao vale o risco so
            # pra evitar um pequeno vazamento de memoria num cenario ja
            # raro (5min+ sem resposta).
            Registrar-LogConexao "Chamada abortada apos 300s sem resposta - forcando sessao a ser considerada perdida (job abandonado sem Stop-Job/Remove-Job)."
            Disconnect-ServidorVisao
            $script:SessaoOcupada = $false
            return [PSCustomObject]@{ Concluido = $true; Erro = [System.TimeoutException]::new("O POLICY-SERVER nao respondeu em 5 minutos - a conexao foi considerada perdida."); Resposta = $null }
        }

        return [PSCustomObject]@{ Concluido = $false; Erro = $null; Resposta = $null }
    }

    try {
        try {
            $json = Receive-Job -Job $job -ErrorAction Stop
        } finally {
            $script:SessaoOcupada = $false
            # Sem -Force de proposito - o job ja esta num estado terminal
            # aqui ($rodando confirmado $false acima), entao nao ha nada
            # pra "parar" de verdade. Ver achado nº4 acima.
            Remove-Job -Job $job -ErrorAction SilentlyContinue
        }
    } catch {
        return [PSCustomObject]@{ Concluido = $true; Erro = $_.Exception; Resposta = $null }
    }

    if ($script:IdSessaoAtual -ne $EstadoAsync.IdSessaoEsperado) {
        $respostaPerdida = [PSCustomObject]@{ Novos = @(); Concluidos = 0; Total = 0; EmAndamento = $false; SessaoPerdida = $true }
        return [PSCustomObject]@{ Concluido = $true; Erro = $null; Resposta = $respostaPerdida }
    }

    $obj = $json | ConvertFrom-Json
    $resposta = $obj | Add-Member -NotePropertyName SessaoPerdida -NotePropertyValue $false -PassThru
    return [PSCustomObject]@{ Concluido = $true; Erro = $null; Resposta = $resposta }
}

# ============================================================
# KEEPALIVE (2026-08-27) - Start/Test-ChamadaRemotaAssincrona sao a
# versao GENERICA (qualquer ScriptBlock) de Start/Test-
# VarreduraNovosResultadosRemotoAsync acima - mesma base seguranca (sem
# DoEvents, sem Stop-Job/Remove-Job -Force num job ainda rodando), sem
# nada especifico de varredura. Usadas por um Timer proprio no cliente
# (VisaoCliente.ps1) que dispara uma chamada leve pro servidor a cada
# ~60s enquanto a ferramenta esta ociosa, pra manter a conexao TCP
# subjacente "viva" - confirmado ao vivo (2026-08-27) que a conexao cai
# por INATIVIDADE mesmo sem nenhuma acao do tecnico (so ficar parado
# ~4min ja reproduziu, com ou sem antivirus, sem abrir nenhuma janela)
# - provavelmente algum dispositivo de rede intermediario (firewall/NAT)
# derrubando conexoes TCP ociosas. Nao elimina o problema por completo
# (uma queda NO MEIO de uma operacao ativa ainda pode acontecer), mas
# deve cobrir o caso mais comum de ociosidade entre uma acao e outra.
# ============================================================
function Start-ChamadaRemotaAssincrona {
    <#
        Versao GENERICA de Start-VarreduraNovosResultadosRemotoAsync -
        dispara qualquer ScriptBlock via Invoke-Command -AsJob e devolve
        NA HORA, sem esperar nada.
    #>
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    if ($script:SessaoOcupada) {
        throw [System.InvalidOperationException]::new("Ja ha uma chamada remota em andamento - aguarde terminar e tente de novo.")
    }
    if (-not $script:PSSessionServidor -or $script:PSSessionServidor.State -ne [System.Management.Automation.Runspaces.RunspaceState]::Opened) {
        if (-not (Connect-ServidorVisao)) {
            throw [System.InvalidOperationException]::new("Nao foi possivel conectar ao POLICY-SERVER. Verifique a rede/VPN e tente novamente.")
        }
    }

    $script:SessaoOcupada = $true
    try {
        Wait-RunspaceDisponivelParaNovoComando -Sessao $script:PSSessionServidor
        $job = Invoke-Command -Session $script:PSSessionServidor -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -AsJob -ErrorAction Stop
    } catch {
        $script:SessaoOcupada = $false
        throw
    }

    return [PSCustomObject]@{ Job = $job; Cronometro = [System.Diagnostics.Stopwatch]::StartNew(); IndiceAvisos = 0 }
}

function Test-ChamadaRemotaAssincronaConcluida {
    <#
        Chamada a cada tick de um Timer - devolve na hora, sem DoEvents()
        nenhum. Ao estourar o TimeoutSec com o job ainda rodando, o job e
        ABANDONADO (nunca Stop-Job/Remove-Job) - mesmo principio de
        Invoke-ComandoRemotoJob (ver comentario grande la).
    #>
    param(
        [Parameter(Mandatory)]
        $EstadoAsync,
        [int]$TimeoutSec = 60
    )

    $job = $EstadoAsync.Job
    $rodando = ($job.State -eq [System.Management.Automation.JobState]::Running -or $job.State -eq [System.Management.Automation.JobState]::NotStarted)
    $EstadoAsync.IndiceAvisos = Registrar-AvisosNativosJob -Job $job -IndiceProcessado $EstadoAsync.IndiceAvisos

    if ($rodando) {
        if ($EstadoAsync.Cronometro.Elapsed.TotalSeconds -ge $TimeoutSec) {
            $script:SessaoOcupada = $false
            return [PSCustomObject]@{ Concluido = $true; Sucesso = $false }
        }
        return [PSCustomObject]@{ Concluido = $false; Sucesso = $false }
    }

    $script:SessaoOcupada = $false
    try {
        Receive-Job -Job $job -ErrorAction Stop | Out-Null
        return [PSCustomObject]@{ Concluido = $true; Sucesso = $true }
    } catch {
        return [PSCustomObject]@{ Concluido = $true; Sucesso = $false }
    } finally {
        Remove-Job -Job $job -ErrorAction SilentlyContinue
    }
}

# ============================================================
# FASE 6: download de pacote (SO download - a copia final pro InstSeg
# roda direto no cliente, ver VisaoPacotes.psm1 e a nota grande em
# VisaoServidor.ps1). Mesmo padrao "dispara sem esperar + poll" da
# varredura, mas SEM precisar do guard de IdSessaoAtual: aqui "job nao
# encontrado" (Encontrado=$false) ja e, por si so, inequivoco -
# diferente da varredura, nao existe um "Concluido=$false" que pudesse
# ser confundido com "ainda rodando". Se a sessao cair e reconectar no
# meio de um download, o PROCESSO remoto antigo (e o job em segundo
# plano rodando nele) morre junto - Encontrado=$false nesse caso
# reflete a realidade (o job parou mesmo), nao so "esqueceu".
# ============================================================
function Start-BaixarPacoteRemoto {
    <#
        Gera o JobId (GUID) aqui no cliente e devolve pra quem chamou
        comecar o polling (Get-StatusPacoteRemoto) imediatamente, sem
        precisar de uma resposta a mais so pra descobrir o id.
    #>
    param(
        [Parameter(Mandatory)][PSCustomObject]$Pacote
    )
    $jobId = [guid]::NewGuid().ToString()
    Invoke-ComandoRemoto -ScriptBlock { param($j, $p) Start-BaixarPacote -JobId $j -Pacote $p } -ArgumentList @($jobId, $Pacote) | Out-Null
    return $jobId
}

function Get-StatusPacoteRemoto {
    <#
        Get-StatusPacote do lado servidor devolve uma STRING JSON (Avisos
        e um array). Aqui desserializa de volta. Quando Concluido+Sucesso,
        .ArquivoCacheUnc e o caminho \\POLICY-SERVER...\ScanZonas\
        CacheDownloads\<arquivo> pronto pra o cliente copiar dali pro
        InstSeg da maquina de destino (ver VisaoPacotes.psm1).
    #>
    param([Parameter(Mandatory)][string]$JobId)
    $json = Invoke-ComandoRemoto -ScriptBlock { param($j) Get-StatusPacote -JobId $j } -ArgumentList @($JobId)
    return ($json | ConvertFrom-Json)
}

# ============================================================
# FASE 7: escritas no Apps Script - request/resposta unico, sem
# polling (cada uma faz 1 chamada HTTP so, no maximo 60s de timeout
# server-side) - cada wrapper so encaminha pra funcao equivalente do
# VisaoServidor.ps1, que ja devolve um PSCustomObject simples
# {Ok; Mensagem} (nao-array, atravessa sem contorno JSON).
#
# Send-ResultadoCampanhaZonaRemoto NAO vive mais aqui - migrada pra
# VisaoPlanilhas.psm1 em 2026-08-24 (decisao explicita do usuario:
# RESULTADOS-CAMPANHAS nao e sensivel, token distribuido no pacote do
# modulo). Send-ArquivoParaGoogleDriveRemoto (CVC) e Send-AtualizacaoZonaRemoto
# (zonas) migradas pelo MESMO motivo em 2026-08-27 - nenhuma das
# escritas restantes daqui e trafego de broadcast, so Wake-on-LAN
# (abaixo) continua de proposito.
# ============================================================

# ============================================================
# FASE B: Wake-on-LAN - request/resposta unico, sem polling.
#
# Get-MaquinasDesligadasOcsRemoto NAO vive mais aqui - migrada pra
# VisaoOcs.psm1 em 2026-08-24 (chamada HTTP sem autenticacao, tecnico
# confirmado na mesma rede do servidor OCS - nao precisa mais do
# POLICY-SERVER de passagem). Invoke-LigarWolRemoto CONTINUA aqui - WoL
# manda um pacote de broadcast direcionado, mesma categoria da
# varredura, fica no servidor de proposito.
# ============================================================
function Invoke-LigarWolRemoto {
    param(
        [Parameter(Mandatory)][int]$HardwareId,
        [string]$Ip
    )
    Invoke-ComandoRemoto -ScriptBlock { param($hid, $ip) Invoke-AcaoLigarWol -HardwareId $hid -Ip $ip } -ArgumentList @($HardwareId, $Ip)
}

# ============================================================
# FASE F: leitura/gravacao dos 4 configs de Web App do Apps Script -
# leitores ja existiam do lado servidor (Fases 6/7, usados internamente
# por Import-TabelaVersoes/Send-AtualizacaoZonaViaAppsScript/etc), mas
# nunca tinham sido expostos via remoting porque nenhuma tela ainda
# precisava MOSTRAR o valor atual pro tecnico editar - a tela de
# Configuracoes (VisaoJanelaAdmin.psm1) e a primeira a precisar. Todos
# devolvem PSCustomObject simples (nao-array) ou $null - atravessam sem
# o contorno JSON (mesmo motivo de sempre).
# ============================================================
function Get-ConfigVersoesRemoto {
    Invoke-ComandoRemoto -ScriptBlock { Get-ConfigVersoes }
}

function Set-ConfigVersoesRemoto {
    param([Parameter(Mandatory)][string]$SpreadsheetId, [string]$Gid = "0")
    Invoke-ComandoRemoto -ScriptBlock { param($id, $g) Set-ConfigVersoes -SpreadsheetId $id -Gid $g } -ArgumentList @($SpreadsheetId, $Gid)
}

function Get-ConfigZonasWebAppRemoto {
    Invoke-ComandoRemoto -ScriptBlock { Get-ConfigZonasWebApp }
}

function Set-ConfigZonasWebAppRemoto {
    param([Parameter(Mandatory)][string]$UrlWebApp, [Parameter(Mandatory)][string]$Token)
    Invoke-ComandoRemoto -ScriptBlock { param($u, $t) Set-ConfigZonasWebApp -UrlWebApp $u -Token $t } -ArgumentList @($UrlWebApp, $Token)
}

function Get-ConfigCampanhasWebAppRemoto {
    Invoke-ComandoRemoto -ScriptBlock { Get-ConfigCampanhasWebApp }
}

function Set-ConfigCampanhasWebAppRemoto {
    param([Parameter(Mandatory)][string]$UrlWebApp, [Parameter(Mandatory)][string]$Token)
    Invoke-ComandoRemoto -ScriptBlock { param($u, $t) Set-ConfigCampanhasWebApp -UrlWebApp $u -Token $t } -ArgumentList @($UrlWebApp, $Token)
}

function Get-ConfigEnvioDriveRemoto {
    Invoke-ComandoRemoto -ScriptBlock { Get-ConfigEnvioDrive }
}

function Set-ConfigEnvioDriveRemoto {
    param([Parameter(Mandatory)][string]$UrlWebApp, [Parameter(Mandatory)][string]$Token)
    Invoke-ComandoRemoto -ScriptBlock { param($u, $t) Set-ConfigEnvioDrive -UrlWebApp $u -Token $t } -ArgumentList @($UrlWebApp, $Token)
}

Export-ModuleMember -Function Connect-ServidorVisao, Disconnect-ServidorVisao, Invoke-ComandoRemoto, Get-IdSessaoAtualVisao, Start-VarreduraRemota, Get-VarreduraNovosResultadosRemoto, Start-VarreduraNovosResultadosRemotoAsync, Test-VarreduraNovosResultadosRemotoAsync, Start-ChamadaRemotaAssincrona, Test-ChamadaRemotaAssincronaConcluida, Get-VersoesRemoto, Get-SistemasEleitoraisExtraRemoto, Start-BaixarPacoteRemoto, Get-StatusPacoteRemoto, Invoke-LigarWolRemoto, Get-ConfigVersoesRemoto, Set-ConfigVersoesRemoto, Get-ConfigZonasWebAppRemoto, Set-ConfigZonasWebAppRemoto, Get-ConfigCampanhasWebAppRemoto, Set-ConfigCampanhasWebAppRemoto, Get-ConfigEnvioDriveRemoto, Set-ConfigEnvioDriveRemoto

# NOTA: as consultas ao AD (Usuarios da ZE, status do Instalador) NAO
# passam por aqui - ver VisaoAD.psm1. Nao sao trafego de varredura, e
# rotea-las pelo servidor esbarra no duplo-salto do Kerberos (a
# credencial do WinRM nao e repassada do POLICY-SERVER pro Controlador
# de Dominio) - ver o plano da migracao.
