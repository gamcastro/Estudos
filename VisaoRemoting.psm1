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
    param([string]$Linha)
    try {
        if (-not (Test-Path -LiteralPath $script:PastaLogVisao)) {
            New-Item -Path $script:PastaLogVisao -ItemType Directory -Force | Out-Null
        }
        $linhaComData = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Linha"
        $linhasExistentes = @()
        if (Test-Path -LiteralPath $script:ArquivoLogConexao) {
            $linhasExistentes = @(Get-Content -LiteralPath $script:ArquivoLogConexao -ErrorAction SilentlyContinue)
        }
        $linhasFinais = @($linhasExistentes + $linhaComData) | Select-Object -Last 200
        Set-Content -LiteralPath $script:ArquivoLogConexao -Value $linhasFinais -Encoding utf8 -Force
    } catch {}
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
    #>
    param(
        [Parameter(Mandatory)]
        [System.Management.Automation.Runspaces.PSSession]$Sessao,
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    $job = Invoke-Command -Session $Sessao -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -AsJob -ErrorAction Stop
    try {
        while ($job.State -eq [System.Management.Automation.JobState]::Running -or $job.State -eq [System.Management.Automation.JobState]::NotStarted) {
            [System.Windows.Forms.Application]::DoEvents()
            Start-Sleep -Milliseconds 150
        }
        return Receive-Job -Job $job -ErrorAction Stop
    }
    finally {
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
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
    #>
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
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
            return Invoke-ComandoRemotoJob -Sessao $script:PSSessionServidor -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
        } catch {
            if ($script:PSSessionServidor -and $script:PSSessionServidor.State -eq [System.Management.Automation.Runspaces.RunspaceState]::Opened) {
                throw
            }
            Registrar-LogConexao "Sessao perdida durante operacao remota: $($_.Exception.Message)"
            if (-not (Connect-ServidorVisao)) {
                throw [System.InvalidOperationException]::new("Conexao com o POLICY-SERVER perdida e nao foi possivel reconectar. Verifique a rede/VPN e tente novamente.")
            }
            try {
                return Invoke-ComandoRemotoJob -Sessao $script:PSSessionServidor -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList
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
# polling) - cada uma so encaminha pra funcao equivalente do
# VisaoServidor.ps1 via Invoke-ComandoRemoto.
# ============================================================
function Get-ZonasRemoto {
    <#
        Import-TabelaZonas do lado servidor devolve uma STRING JSON
        (Zonas e um array de PSCustomObject - mesmo bug de serializacao
        de sempre). Aqui desserializa de volta; .Zonas vem como array
        normal do PowerShell, cada item com .Zona (int) embutido - Fase E
        (Gerenciar Zonas) usa isso pra montar a grade editavel.
    #>
    param([switch]$ForcarCache)
    $json = Invoke-ComandoRemoto -ScriptBlock { param($f) Import-TabelaZonas -ForcarCache:$f } -ArgumentList @($ForcarCache.IsPresent)
    return ($json | ConvertFrom-Json)
}

function Get-GruposSistemasRemoto {
    <#
        Import-TabelaGruposSistemas do lado servidor devolve uma STRING
        JSON. Aqui desserializa de volta - .GruposSistemas vem como
        PSCustomObject (converter pra Hashtable do lado cliente antes de
        indexar por chave, mesmo padrao de TabelaVersoes/VersaoAtualPorSistema).
    #>
    param([switch]$ForcarCache)
    $json = Invoke-ComandoRemoto -ScriptBlock { param($f) Import-TabelaGruposSistemas -ForcarCache:$f } -ArgumentList @($ForcarCache.IsPresent)
    return ($json | ConvertFrom-Json)
}

function Resolve-RedeDaZonaRemoto {
    <#
        Devolve um PSCustomObject simples (nao-array) - atravessa o
        remoting sem precisar do contorno JSON (so array de PSCustomObject
        tem o bug, ver comentario em Get-ResultadosCampanhas).
    #>
    param([Parameter(Mandatory)][int]$Zona)
    Invoke-ComandoRemoto -ScriptBlock { param($z) Resolve-RedeDaZona -Zona $z } -ArgumentList @($Zona)
}

function Test-RedeEhCompartilhadaRemoto {
    param([Parameter(Mandatory)][string]$Prefixo)
    Invoke-ComandoRemoto -ScriptBlock { param($p) Test-RedeEhCompartilhada -Prefixo $p } -ArgumentList @($Prefixo)
}

function Get-CampanhasRemoto {
    <#
        Import-TabelaCampanhas do lado servidor devolve uma STRING JSON
        (Campanhas e uma lista de PSCustomObject, cada uma com Requisitos
        aninhado - mesmo bug de serializacao de sempre). Aqui desserializa
        de volta; o objeto devolvido tem .Campanhas como array normal do
        PowerShell (cada item com .Nome/.Requisitos), pronto pra popular
        um ComboBox/conferir requisitos no cliente.
    #>
    param([switch]$ForcarCache)
    $json = Invoke-ComandoRemoto -ScriptBlock { param($f) Import-TabelaCampanhas -ForcarCache:$f } -ArgumentList @($ForcarCache.IsPresent)
    return ($json | ConvertFrom-Json)
}

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

function Get-ResultadosCampanhasRemoto {
    <#
        Get-ResultadosCampanhas do lado servidor devolve uma STRING JSON,
        nao um objeto direto - ver o comentario extenso dela em
        VisaoServidor.ps1 (bug confirmado de PS Remoting nesse servidor
        especifico com array de PSCustomObject cruzando a fronteira).
        Aqui e so desserializar de volta pro objeto que o resto do
        cliente espera.
    #>
    $json = Invoke-ComandoRemoto -ScriptBlock { Get-ResultadosCampanhas }
    return ($json | ConvertFrom-Json)
}

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
        [bool]$RedeCompartilhada = $false
    )
    Invoke-ComandoRemoto -ScriptBlock { param($i, $z, $rc) Start-VarreduraZona -Ips $i -Zona $z -RedeCompartilhada $rc } -ArgumentList @($Ips, $Zona, $RedeCompartilhada) | Out-Null
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
        [guid]$IdSessaoEsperado
    )

    if ($script:IdSessaoAtual -ne $IdSessaoEsperado) {
        return [PSCustomObject]@{ Novos = @(); Concluidos = 0; Total = 0; EmAndamento = $false; SessaoPerdida = $true }
    }

    $json = Invoke-ComandoRemoto -ScriptBlock { Get-VarreduraNovosResultados }

    if ($script:IdSessaoAtual -ne $IdSessaoEsperado) {
        return [PSCustomObject]@{ Novos = @(); Concluidos = 0; Total = 0; EmAndamento = $false; SessaoPerdida = $true }
    }

    $obj = $json | ConvertFrom-Json
    $obj | Add-Member -NotePropertyName SessaoPerdida -NotePropertyValue $false -PassThru
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
# ============================================================
function Send-AtualizacaoZonaRemoto {
    param(
        [Parameter(Mandatory)][int]$Zona,
        [string]$Substituta = "",
        [string]$Observacao = ""
    )
    Invoke-ComandoRemoto -ScriptBlock { param($z, $s, $o) Send-AtualizacaoZonaViaAppsScript -Zona $z -Substituta $s -Observacao $o } -ArgumentList @($Zona, $Substituta, $Observacao)
}

function Send-ResultadoCampanhaZonaRemoto {
    param(
        [Parameter(Mandatory)][int]$Zona,
        [Parameter(Mandatory)][string]$NomeCampanha,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][int]$Aptas,
        [string]$MaquinasAptas = "",
        [string]$Tecnico = $env:USERNAME
    )
    Invoke-ComandoRemoto -ScriptBlock { param($z, $c, $t, $a, $m, $tec) Send-ResultadoCampanhaZona -Zona $z -NomeCampanha $c -Total $t -Aptas $a -MaquinasAptas $m -Tecnico $tec } -ArgumentList @($Zona, $NomeCampanha, $Total, $Aptas, $MaquinasAptas, $Tecnico)
}

function Send-ArquivoParaGoogleDriveRemoto {
    <#
        $NomeArquivo/$ConteudoBase64 ja vem PRONTO de quem chama - se o
        arquivo original vive numa maquina de zona (ex: CVC em
        \\IP\InstSeg\CVC), quem chama precisa te-lo lido DIRETO (sem
        remoting, mesmo motivo do VisaoPacotes.psm1) antes de chegar
        aqui. Ver comentario completo em
        Send-ArquivoParaGoogleDriveViaAppsScript no VisaoServidor.ps1.
    #>
    param(
        [Parameter(Mandatory)][string]$NomeArquivo,
        [Parameter(Mandatory)][string]$ConteudoBase64,
        [int]$TimeoutSec = 30
    )
    Invoke-ComandoRemoto -ScriptBlock { param($n, $c, $t) Send-ArquivoParaGoogleDriveViaAppsScript -NomeArquivo $n -ConteudoBase64 $c -TimeoutSec $t } -ArgumentList @($NomeArquivo, $ConteudoBase64, $TimeoutSec)
}

# ============================================================
# FASE B: maquinas desligadas via OCS + Wake-on-LAN - request/resposta
# unico, sem polling.
# ============================================================
function Get-MaquinasDesligadasOcsRemoto {
    <#
        $ResultadosOnline vai como ARGUMENTO de entrada (nao retorno) -
        confirmado ao vivo que array de PSCustomObject como parametro de
        Invoke-Command atravessa sem o contorno JSON (o bug conhecido e
        so em VALOR DE RETORNO). Ja a resposta do servidor (Correcoes/
        Desligadas) usa o contorno JSON de sempre, por ser retorno.
    #>
    param(
        [Parameter(Mandatory)][int]$Zona,
        [bool]$RedeCompartilhada = $false,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$ResultadosOnline
    )
    $json = Invoke-ComandoRemoto -ScriptBlock { param($z, $rc, $r) Get-MaquinasDesligadasOcs -Zona $z -RedeCompartilhada $rc -ResultadosOnline $r } -ArgumentList @($Zona, $RedeCompartilhada, $ResultadosOnline)
    return ($json | ConvertFrom-Json)
}

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

Export-ModuleMember -Function Connect-ServidorVisao, Disconnect-ServidorVisao, Invoke-ComandoRemoto, Get-IdSessaoAtualVisao, Get-ZonasRemoto, Get-GruposSistemasRemoto, Get-CampanhasRemoto, Get-ResultadosCampanhasRemoto, Resolve-RedeDaZonaRemoto, Test-RedeEhCompartilhadaRemoto, Start-VarreduraRemota, Get-VarreduraNovosResultadosRemoto, Get-VersoesRemoto, Get-SistemasEleitoraisExtraRemoto, Start-BaixarPacoteRemoto, Get-StatusPacoteRemoto, Send-AtualizacaoZonaRemoto, Send-ResultadoCampanhaZonaRemoto, Send-ArquivoParaGoogleDriveRemoto, Get-MaquinasDesligadasOcsRemoto, Invoke-LigarWolRemoto, Get-ConfigVersoesRemoto, Set-ConfigVersoesRemoto, Get-ConfigZonasWebAppRemoto, Set-ConfigZonasWebAppRemoto, Get-ConfigCampanhasWebAppRemoto, Set-ConfigCampanhasWebAppRemoto, Get-ConfigEnvioDriveRemoto, Set-ConfigEnvioDriveRemoto

# NOTA: as consultas ao AD (Usuarios da ZE, status do Instalador) NAO
# passam por aqui - ver VisaoAD.psm1. Nao sao trafego de varredura, e
# rotea-las pelo servidor esbarra no duplo-salto do Kerberos (a
# credencial do WinRM nao e repassada do POLICY-SERVER pro Controlador
# de Dominio) - ver o plano da migracao.
