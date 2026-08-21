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

function Connect-ServidorVisao {
    <#
        Abre (ou reabre) a sessao persistente com o POLICY-SERVER e
        carrega o VisaoServidor.ps1 nela (Invoke-Command -FilePath, uma
        vez por sessao - NAO recarrega a cada chamada, ver comentario no
        topo do VisaoServidor.ps1). Devolve $true/$false; quem chama
        decide o que fazer em caso de falha (ex: mostrar erro e nao abrir
        a janela principal).
    #>
    if ($script:PSSessionServidor -and $script:PSSessionServidor.State -eq [System.Management.Automation.Runspaces.RunspaceState]::Opened) {
        return $true
    }

    Disconnect-ServidorVisao

    try {
        $script:PSSessionServidor = New-PSSession -ComputerName $script:NomeServidorVisao -ErrorAction Stop
        Invoke-Command -Session $script:PSSessionServidor -FilePath $script:CaminhoVisaoServidorPs1 -ErrorAction Stop
        $script:IdSessaoAtual = [guid]::NewGuid()
        return $true
    } catch {
        Write-Warning "Falha ao conectar/carregar logica no servidor '$($script:NomeServidorVisao)': $($_.Exception.Message)"
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

function Invoke-ComandoRemoto {
    <#
        Wrapper que TODA chamada remota do cliente deve usar em vez de
        Invoke-Command direto - confere o estado da sessao antes de usar
        e, se estiver quebrada/fechada, tenta reconectar (e recarregar o
        VisaoServidor.ps1) UMA VEZ antes de repetir a chamada. Se a
        propria chamada falhar por erro de TRANSPORTE remoto (sessao
        caiu no meio), tambem tenta reconectar+repetir uma vez.

        Erros vindos de DENTRO do scriptblock (ex: uma excecao que a
        propria funcao remota lancou de proposito) NAO acionam reconexao
        - so propagam pra quem chamou, normal.

        Devolve o que o scriptblock remoto devolver. Lanca excecao
        ([System.InvalidOperationException], mensagem em pt-BR, clara e
        consistente) se nao conseguir nem depois de tentar reconectar -
        pensado pra virar uma unica mensagem de erro exibida no cliente,
        em vez de cada tela inventar o proprio texto.
    #>
    param(
        [Parameter(Mandatory)]
        [scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @()
    )

    if (-not $script:PSSessionServidor -or $script:PSSessionServidor.State -ne [System.Management.Automation.Runspaces.RunspaceState]::Opened) {
        if (-not (Connect-ServidorVisao)) {
            throw [System.InvalidOperationException]::new("Nao foi possivel conectar ao POLICY-SERVER. Verifique a rede/VPN e tente novamente.")
        }
    }

    try {
        return Invoke-Command -Session $script:PSSessionServidor -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
    } catch [System.Management.Automation.Remoting.PSRemotingTransportException] {
        # Erro de TRANSPORTE (sessao caiu, WinRM parou de responder etc.) -
        # so esse tipo de erro justifica tentar reconectar; um erro de
        # LOGICA vindo de dentro do scriptblock remoto e outro tipo de
        # excecao e cai no catch generico abaixo, propagando normal.
        if (-not (Connect-ServidorVisao)) {
            throw [System.InvalidOperationException]::new("Conexao com o POLICY-SERVER perdida e nao foi possivel reconectar. Verifique a rede/VPN e tente novamente.")
        }
        try {
            return Invoke-Command -Session $script:PSSessionServidor -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -ErrorAction Stop
        } catch {
            throw [System.InvalidOperationException]::new("Conexao com o POLICY-SERVER foi perdida durante a operacao. Se estava no meio de uma varredura, ela ficou incompleta - inicie de novo.")
        }
    }
}

# ============================================================
# FASE 1: leituras de planilha Google (request/resposta simples, sem
# polling) - cada uma so encaminha pra funcao equivalente do
# VisaoServidor.ps1 via Invoke-ComandoRemoto.
# ============================================================
function Get-ZonasRemoto {
    param([switch]$ForcarCache)
    Invoke-ComandoRemoto -ScriptBlock { param($f) Import-TabelaZonas -ForcarCache:$f } -ArgumentList @($ForcarCache.IsPresent)
}

function Get-GruposSistemasRemoto {
    param([switch]$ForcarCache)
    Invoke-ComandoRemoto -ScriptBlock { param($f) Import-TabelaGruposSistemas -ForcarCache:$f } -ArgumentList @($ForcarCache.IsPresent)
}

function Get-CampanhasRemoto {
    param([switch]$ForcarCache)
    Invoke-ComandoRemoto -ScriptBlock { param($f) Import-TabelaCampanhas -ForcarCache:$f } -ArgumentList @($ForcarCache.IsPresent)
}

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

Export-ModuleMember -Function Connect-ServidorVisao, Disconnect-ServidorVisao, Invoke-ComandoRemoto, Get-IdSessaoAtualVisao, Get-ZonasRemoto, Get-GruposSistemasRemoto, Get-CampanhasRemoto, Get-ResultadosCampanhasRemoto, Start-VarreduraRemota, Get-VarreduraNovosResultadosRemoto

# NOTA: as consultas ao AD (Usuarios da ZE, status do Instalador) NAO
# passam por aqui - ver VisaoAD.psm1. Nao sao trafego de varredura, e
# rotea-las pelo servidor esbarra no duplo-salto do Kerberos (a
# credencial do WinRM nao e repassada do POLICY-SERVER pro Controlador
# de Dominio) - ver o plano da migracao.
