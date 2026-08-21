<#
    VisaoServidor.ps1

    Logica de trabalho da ferramenta "Visao" (ScannerRedeZona.ps1) que roda
    DENTRO da sessao remota no POLICY-SERVER (nunca no processo do cliente).
    Este arquivo e carregado UMA VEZ por sessao, via:
        Invoke-Command -Session $s -FilePath .\VisaoServidor.ps1
    (semantica de dot-source - define as funcoes abaixo no runspace remoto,
    nao executa nada por conta propria). Ver VisaoRemoting.psm1 para quem
    chama isso, e o plano em
    C:\Users\029342881104\.claude\plans\splendid-enchanting-mochi.md para o
    desenho completo da migracao por fases.

    FASE 0: infraestrutura de teste de conexao (Get-TesteConexaoServidor).
    FASE 1 (atual): leituras de planilha Google (Zonas, Grupos-Sistemas,
    Campanhas, Resultados-Campanhas) - request/resposta simples, sem
    efeito colateral, sem polling. Cada uma tinha uma chamada a Add-Log no
    caminho de erro no script original - aqui isso virou retorno
    estruturado (Ok/Avisos/Erro), ja que Add-Log escreve num RichTextBox
    que so existe do lado cliente. Ver o plano completo em
    C:\Users\029342881104\.claude\plans\splendid-enchanting-mochi.md.

    NOTA: $PSScriptRoot fica VAZIO quando este arquivo e carregado via
    "Invoke-Command -FilePath" (confirmado ao vivo) - por isso os caches
    locais usam um caminho fixo no PROPRIO POLICY-SERVER
    ($script:PastaBaseServidor) em vez de Join-Path $PSScriptRoot como no
    ScannerRedeZona.ps1 original.
#>

# ============================================================
# ESTADO/CONFIG (equivalente ao topo do ScannerRedeZona.ps1 original,
# so a parte relevante pras funcoes ja migradas)
# ============================================================

# O PowerShell 5.1 usa a configuracao de TLS do .NET Framework, que em
# Windows Server mais antigo/menos atualizado pode nao incluir TLS 1.2
# por padrao - sem isso, todo Invoke-WebRequest pro Google falha com
# "underlying connection was closed" (confirmado ao vivo: sem essa
# linha, as 4 funcoes de leitura de planilha abaixo caiam direto pro
# cache local, mascarando o problema). Mesmo ajuste que ja existe no
# ScannerRedeZona.ps1 original - precisa ser repetido aqui porque este
# arquivo carrega numa sessao remota nova, sem a inicializacao do script
# principal.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

$script:PastaBaseServidor = "E:\ScanZonas"

$script:UrlPlanilhaZonasCSV  = "https://docs.google.com/spreadsheets/d/1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I/export?format=csv&gid=0"
$script:ArquivoZonasCache    = Join-Path $script:PastaBaseServidor "zonas_cache.csv"
$script:TabelaZonas          = @{}   # int (zona) -> PSCustomObject { Sede; RedePadrao; Substituta; Observacao }

$script:UrlPlanilhaGruposSistemasCSV = "https://docs.google.com/spreadsheets/d/1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I/export?format=csv&gid=634558318"
$script:ArquivoGruposSistemasCache   = Join-Path $script:PastaBaseServidor "grupos_sistemas_cache.csv"
$script:TabelaGruposSistemas         = @{}   # "GRUPO" (maiusculo) -> PSCustomObject { Sistema; Perfil }

$script:UrlPlanilhaCampanhasCSV = "https://docs.google.com/spreadsheets/d/1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I/gviz/tq?tqx=out:csv&sheet=CAMPANHAS"
$script:ArquivoCampanhasCache   = Join-Path $script:PastaBaseServidor "campanhas_cache.csv"
$script:TabelaCampanhas         = New-Object System.Collections.Generic.List[object]

$script:UrlPlanilhaResultadosCampanhasCSV = "https://docs.google.com/spreadsheets/d/1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I/gviz/tq?tqx=out:csv&sheet=RESULTADOS-CAMPANHAS"

function Get-TesteConexaoServidor {
    <#
        Prova de vida simples: confirma que o VisaoServidor.ps1 foi
        carregado e executado DE VERDADE no runspace remoto (nao no
        cliente) - devolve o hostname/usuario/hora vistos DAQUELE lado.
        Usada por VisaoRemoting.psm1/VisaoCliente.ps1 pra validar a
        conexao e o ciclo de reconexao antes de mover qualquer logica
        real pra ca.
    #>
    [PSCustomObject]@{
        Hostname      = $env:COMPUTERNAME
        Usuario       = whoami
        DataHoraUtc   = (Get-Date).ToUniversalTime()
        PID_Processo  = $PID
    }
}

# ============================================================
# ZONAS ELEITORAIS
# ============================================================
function Remove-Acentos {
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

function ConvertTo-PrefixoRede {
    <#
        Converte uma rede no formato "10.198.4.0/24" (como vem da coluna
        "Rede Padrao"/"Substituta" da planilha) para o prefixo "10.198.4."
        que o resto da ferramenta usa internamente para montar IPs (ex:
        "10.198.4.15"). Tambem aceita "10.198.4.0" sem mascara, ou "10.198.4"
        (3 octetos, atalho comum). Devolve $null se vier vazio ou nao
        reconhecer o formato.
    #>
    param([string]$Rede)
    if (-not $Rede) { return $null }
    $Rede = $Rede.Trim()
    if (-not $Rede) { return $null }
    if ($Rede.EndsWith(".") -and ($Rede -notmatch '/')) { return $Rede }   # ja esta no formato prefixo

    $semMascara = ($Rede -split '/')[0].TrimEnd('.')
    $partes = $semMascara -split '\.'
    if ($partes.Count -eq 4) { return "$($partes[0]).$($partes[1]).$($partes[2])." }
    if ($partes.Count -eq 3) { return "$($partes[0]).$($partes[1]).$($partes[2])." }
    return $null
}

function Import-TabelaZonas {
    <#
        Carrega Zona -> {Sede, RedePadrao, Substituta, Observacao} a partir
        da planilha Google Sheets publicada como CSV. Se a busca online
        falhar, cai para o cache local (no PROPRIO POLICY-SERVER) salvo na
        ultima vez que funcionou.

        Reestruturada em relacao ao ScannerRedeZona.ps1 original: em vez
        de chamar Add-Log direto (que so existe do lado cliente) e devolver
        so $true/$false, devolve um resultado estruturado com os avisos
        e o motivo de falha, pra quem chamou (do lado cliente) decidir
        como mostrar isso.
    #>
    param([switch]$ForcarCache)

    $script:TabelaZonas = @{}
    $linhas = $null
    $avisos = New-Object System.Collections.Generic.List[string]
    $origem = "nenhuma"

    if (-not $ForcarCache) {
        try {
            $resp = Invoke-WebRequest -Uri $script:UrlPlanilhaZonasCSV -TimeoutSec 8 -UseBasicParsing
            # O PowerShell 5.1 pode decodificar a resposta com a codificacao
            # errada quando o servidor nao informa o charset explicitamente -
            # pega os bytes brutos e decodifica como UTF-8 na mao.
            $bytesResposta = $resp.RawContentStream.ToArray()
            $textoUtf8 = [System.Text.Encoding]::UTF8.GetString($bytesResposta)
            $linhas = $textoUtf8 | ConvertFrom-Csv
            if ($linhas -and $linhas.Count -gt 0) {
                $linhas | Export-Csv -Path $script:ArquivoZonasCache -NoTypeInformation -Encoding UTF8
                $origem = "online"
            }
        } catch {
            $avisos.Add("Nao foi possivel buscar a planilha de zonas online: $($_.Exception.Message)")
            $linhas = $null
        }
    }

    if (-not $linhas -and (Test-Path $script:ArquivoZonasCache)) {
        $avisos.Add("Usando cache local de zonas (ultima planilha baixada com sucesso).")
        $linhas = Import-Csv -Path $script:ArquivoZonasCache
        $origem = "cache"
    }

    if (-not $linhas) {
        return [PSCustomObject]@{ Ok = $false; Origem = $origem; Contagem = 0; Avisos = @($avisos); Erro = "Nenhuma tabela de zonas disponivel (nem online, nem cache local)." }
    }

    foreach ($l in $linhas) {
        $numZona = 0
        if ([int]::TryParse($l.'Zona Eleitoral', [ref]$numZona)) {
            $script:TabelaZonas[$numZona] = [PSCustomObject]@{
                Sede       = $l.Sede
                RedePadrao = $l.'Rede Padrão'
                Substituta = $l.Substituta
                Observacao = $l.'Observação'
            }
        }
    }
    return [PSCustomObject]@{ Ok = $true; Origem = $origem; Contagem = $script:TabelaZonas.Count; Avisos = @($avisos); Erro = $null }
}

function Resolve-RedeDaZona {
    <#
        Decide o prefixo de rede a varrer para uma zona, nesta ordem de
        prioridade: (1) coluna "Substituta" da planilha, (2) coluna "Rede
        Padrao" da planilha, (3) se a planilha nao tiver essa zona,
        calcula como antes (10.11.81. para Sao Luis, 10.198.<zona>. para
        o resto).
    #>
    param([int]$Zona)

    $zonaInfo = $script:TabelaZonas[$Zona]
    $sede = if ($zonaInfo) { $zonaInfo.Sede } else { $null }

    $prefixoSubstituta = if ($zonaInfo) { ConvertTo-PrefixoRede $zonaInfo.Substituta } else { $null }
    if ($prefixoSubstituta) {
        return [PSCustomObject]@{ Prefixo = $prefixoSubstituta; Origem = "Substituta (planilha)"; Sede = $sede; Observacao = $zonaInfo.Observacao; EhSubstituta = $true }
    }

    $prefixoPadrao = if ($zonaInfo) { ConvertTo-PrefixoRede $zonaInfo.RedePadrao } else { $null }
    if ($prefixoPadrao) {
        return [PSCustomObject]@{ Prefixo = $prefixoPadrao; Origem = "Rede Padrao (planilha)"; Sede = $sede; Observacao = $null; EhSubstituta = $false }
    }

    $sedeSemAcento = (Remove-Acentos $sede).ToUpper().Trim()
    if ($sedeSemAcento -eq "SAO LUIS") {
        return [PSCustomObject]@{ Prefixo = "10.11.81."; Origem = "Sao Luis (calculado, planilha incompleta)"; Sede = $sede; Observacao = $null; EhSubstituta = $false }
    }

    return [PSCustomObject]@{ Prefixo = "10.198.$Zona."; Origem = "Padrao interior (calculado, planilha incompleta)"; Sede = $sede; Observacao = $null; EhSubstituta = $false }
}

function Test-RedeEhCompartilhada {
    <#
        Uma rede e "compartilhada" quando mais de uma zona eleitoral resolve
        para o mesmo prefixo (varias zonas no mesmo predio/rede).
    #>
    param([string]$Prefixo)
    if (-not $Prefixo) { return $false }

    $contagem = 0
    foreach ($z in $script:TabelaZonas.Keys) {
        $res = Resolve-RedeDaZona -Zona $z
        if ($res.Prefixo -eq $Prefixo) {
            $contagem++
            if ($contagem -gt 1) { return $true }
        }
    }
    return $false
}

function Test-HostnamePertenceZona {
    <#
        Em redes compartilhadas entre varias zonas, o IP sozinho nao
        identifica a zona - olha o padrao do hostname, que costuma
        embutir o numero da zona com 3 digitos logo apos um prefixo.
    #>
    param([string]$Hostname, [int]$Zona)
    if (-not $Hostname -or $Hostname -eq "(sem resolucao de nome)") { return $false }

    $zonaPad = "{0:D3}" -f $Zona
    $hostUpper = $Hostname.ToUpper()
    return (
        $hostUpper.Contains("ZMA$zonaPad") -or
        $hostUpper.Contains("CMA$zonaPad") -or
        $hostUpper.Contains("ZE-$zonaPad") -or
        $hostUpper.Contains("ZE$zonaPad")
    )
}

# ============================================================
# GRUPOS-SISTEMAS-ELEITORAIS (mapeamento de grupo do AD -> Sistema/Perfil)
# ============================================================
function Import-TabelaGruposSistemas {
    <#
        Carrega Grupo (do AD) -> {Sistema, Perfil} a partir da aba
        "GRUPOS-SISTEMAS-ELEITORAIS" (mesma planilha de Zonas).
    #>
    param([switch]$ForcarCache)

    $script:TabelaGruposSistemas = @{}
    $linhas = $null
    $avisos = New-Object System.Collections.Generic.List[string]
    $origem = "nenhuma"

    if (-not $ForcarCache) {
        try {
            $resp = Invoke-WebRequest -Uri $script:UrlPlanilhaGruposSistemasCSV -TimeoutSec 8 -UseBasicParsing
            $bytesResposta = $resp.RawContentStream.ToArray()
            $textoUtf8 = [System.Text.Encoding]::UTF8.GetString($bytesResposta)
            $linhas = $textoUtf8 | ConvertFrom-Csv
            if ($linhas -and $linhas.Count -gt 0) {
                $linhas | Export-Csv -Path $script:ArquivoGruposSistemasCache -NoTypeInformation -Encoding UTF8
                $origem = "online"
            }
        } catch {
            $avisos.Add("Nao foi possivel buscar a planilha de grupos/sistemas online: $($_.Exception.Message)")
            $linhas = $null
        }
    }

    if (-not $linhas -and (Test-Path $script:ArquivoGruposSistemasCache)) {
        $avisos.Add("Usando cache local de grupos/sistemas (ultima planilha baixada com sucesso).")
        $linhas = Import-Csv -Path $script:ArquivoGruposSistemasCache
        $origem = "cache"
    }

    if (-not $linhas) {
        return [PSCustomObject]@{ Ok = $false; Origem = $origem; Contagem = 0; Avisos = @($avisos); Erro = $null }
    }

    foreach ($l in $linhas) {
        $grupo = if ($l.Grupo) { $l.Grupo.Trim() } else { $null }
        if (-not $grupo) { continue }
        $script:TabelaGruposSistemas[$grupo.ToUpper()] = [PSCustomObject]@{
            Sistema = $l.Sistema
            Perfil  = $l.Perfil
        }
    }
    return [PSCustomObject]@{ Ok = $true; Origem = $origem; Contagem = $script:TabelaGruposSistemas.Count; Avisos = @($avisos); Erro = $null }
}

# ============================================================
# CAMPANHAS (requisitos minimos de versao por campanha)
# ============================================================
function Import-TabelaCampanhas {
    <#
        Carrega a aba "CAMPANHAS" (mesma planilha de Zonas, buscada pelo
        NOME da aba) com os requisitos minimos de versao por campanha.
    #>
    param([switch]$ForcarCache)

    $script:TabelaCampanhas = New-Object System.Collections.Generic.List[object]
    $linhas = $null
    $avisos = New-Object System.Collections.Generic.List[string]
    $origem = "nenhuma"

    if (-not $ForcarCache) {
        try {
            $resp = Invoke-WebRequest -Uri $script:UrlPlanilhaCampanhasCSV -TimeoutSec 8 -UseBasicParsing
            $bytesResposta = $resp.RawContentStream.ToArray()
            $textoUtf8 = [System.Text.Encoding]::UTF8.GetString($bytesResposta)
            $linhas = $textoUtf8 | ConvertFrom-Csv
            if ($linhas -and $linhas.Count -gt 0) {
                $linhas | Export-Csv -Path $script:ArquivoCampanhasCache -NoTypeInformation -Encoding UTF8
                $origem = "online"
            }
        } catch {
            $avisos.Add("Nao foi possivel buscar a planilha de campanhas online: $($_.Exception.Message)")
            $linhas = $null
        }
    }

    if (-not $linhas -and (Test-Path $script:ArquivoCampanhasCache)) {
        $avisos.Add("Usando cache local de campanhas (ultima planilha baixada com sucesso).")
        $linhas = Import-Csv -Path $script:ArquivoCampanhasCache
        $origem = "cache"
    }

    if (-not $linhas) {
        return [PSCustomObject]@{ Ok = $false; Origem = $origem; Contagem = 0; Avisos = @($avisos); Erro = $null }
    }

    $indice = @{}
    foreach ($l in $linhas) {
        $nomeCampanha = if ($l.Campanha) { $l.Campanha.Trim() } else { $null }
        $sistema = if ($l.Sistema) { $l.Sistema.Trim() } else { $null }
        $versaoMinima = if ($l.VersaoMinima) { $l.VersaoMinima.Trim() } else { $null }
        if (-not $nomeCampanha -or -not $sistema -or -not $versaoMinima) { continue }

        $chave = $nomeCampanha.ToUpper()
        if (-not $indice.ContainsKey($chave)) {
            $campanha = [PSCustomObject]@{ Nome = $nomeCampanha; Requisitos = New-Object System.Collections.Generic.List[object] }
            $indice[$chave] = $campanha
            $script:TabelaCampanhas.Add($campanha)
        }
        $indice[$chave].Requisitos.Add([PSCustomObject]@{ Sistema = $sistema; VersaoMinima = $versaoMinima })
    }
    return [PSCustomObject]@{ Ok = $true; Origem = $origem; Contagem = $script:TabelaCampanhas.Count; Avisos = @($avisos); Erro = $null }
}

function Get-ResultadosCampanhas {
    <#
        Busca a aba RESULTADOS-CAMPANHAS (mesma planilha de Zonas) com o
        HISTORICO completo de envios de "Verificar Campanha" > "Enviar
        Resultado...". Sem cache local (diferente das outras 3 tabelas) -
        e um historico que so faz sentido buscado fresco.

        Devolve uma STRING JSON (nao um PSCustomObject direto) contendo
        @{ Ok; Contagem; Dados; Erro } - CONFIRMADO NA PRATICA que este
        POLICY-SERVER especifico (PowerShell 5.1 build 14393, antigo) tem
        um bug/limitacao real na serializacao do PowerShell Remoting: um
        ARRAY DE PSCUSTOMOBJECT devolvido direto por uma funcao remota
        (ex: "Dados = @($listaDePSCustomObject)") trava a chamada inteira
        com "System.ArgumentException: Argument types do not match" -
        mesmo dentro de um try/catch, mesmo em variavel intermediaria,
        mesmo com Add-Member em vez de hashtable literal. Um array de
        STRING ou um PSCustomObject SEM array-de-objeto dentro atravessa
        a fronteira normal. A saida via ConvertTo-Json (uma STRING pura)
        e imune a esse bug e foi validada funcionando ponta a ponta.

        ATENCAO PRAS PROXIMAS FASES: qualquer funcao daqui pra frente que
        precise devolver uma LISTA DE OBJETOS (varredura de rede, lista
        de usuarios do AD etc.) PRECISA usar este mesmo padrao (ConvertTo-
        Json aqui, ConvertFrom-Json do lado do VisaoRemoting.psm1) em vez
        de devolver o array de PSCustomObject cru.
    #>
    try {
        $resp = Invoke-WebRequest -Uri $script:UrlPlanilhaResultadosCampanhasCSV -TimeoutSec 10 -UseBasicParsing
        $bytesResposta = $resp.RawContentStream.ToArray()
        $textoUtf8 = [System.Text.Encoding]::UTF8.GetString($bytesResposta)
        $linhas = $textoUtf8 | ConvertFrom-Csv
        if (-not $linhas) { return ([PSCustomObject]@{ Ok = $true; Contagem = 0; Dados = @(); Erro = $null } | ConvertTo-Json -Depth 6 -Compress) }

        $resultado = New-Object System.Collections.Generic.List[object]
        foreach ($l in $linhas) {
            if (-not $l.Zona -or -not $l.Campanha) { continue }
            $totalNum = 0; [void][int]::TryParse($l.Total, [ref]$totalNum)
            $aptasNum = 0; [void][int]::TryParse($l.Aptas, [ref]$aptasNum)
            $resultado.Add([PSCustomObject]@{
                DataHora      = $l.DataHora
                Zona          = $l.Zona.Trim()
                Sede          = $l.Sede
                Campanha      = $l.Campanha.Trim()
                Total         = $totalNum
                Aptas         = $aptasNum
                Tecnico       = $l.Tecnico
                MaquinasAptas = $l.MaquinasAptas
            })
        }
        return ([PSCustomObject]@{ Ok = $true; Contagem = $resultado.Count; Dados = $resultado; Erro = $null } | ConvertTo-Json -Depth 6 -Compress)
    } catch {
        return ([PSCustomObject]@{ Ok = $false; Contagem = 0; Dados = @(); Erro = "Falha ao buscar resultados de campanhas: $($_.Exception.Message)" } | ConvertTo-Json -Depth 6 -Compress)
    }
}
