<#
    VisaoPlanilhas.psm1

    Le direto do Google Sheets (CSV publicado, sem autenticacao) as 4
    tabelas de LEITURA que ate 2026-08-24 passavam pelo POLICY-SERVER via
    PowerShell Remoting: Zonas, Grupos de Sistemas Eleitorais,
    Campanhas/requisitos, Resultados de Campanhas.

    Por que migrar pro cliente (decisao com o usuario, 2026-08-24):
    - Sao chamadas HTTP simples e PUBLICAS - a mesma URL de exportacao
      CSV que o POLICY-SERVER ja chamava (confirmado lendo
      VisaoServidor.ps1: Invoke-WebRequest direto, sem token, sem Apps
      Script Web App envolvido), so que agora chamada direto da estacao
      do tecnico.
    - Nao e trafego de varredura (nao e broadcast, nao preocupa a
      Seguranca Cibernetica) - mesma logica ja usada pro AD, ver
      VisaoAD.psm1 (arquitetura "roda local, sem remoting" ja
      estabelecida neste projeto).
    - Elimina completamente a dependencia do WinRM pra essas 4 acoes -
      nao sofrem mais de nenhum dos bugs de reconexao/timeout/
      reentrancia ja documentados pra chamadas via Invoke-ComandoRemoto
      (VisaoRemoting.psm1) - foi justamente um relato de travamento no
      "Relatorio de Campanhas" que motivou essa migracao.

    As ESCRITAS (enviar resultado de campanha, atualizar zona, enviar
    CVC ao Drive) CONTINUAM centralizadas no POLICY-SERVER de proposito -
    usam um token de autenticacao de verdade (Google Apps Script Web
    App) que hoje so existe no servidor; descentralizar isso exigiria
    distribuir esse token pra cada estacao, uma decisao de seguranca que
    nao foi tomada ainda. Ver Send-AtualizacaoZonaRemoto/
    Send-ResultadoCampanhaZonaRemoto/Send-ArquivoParaGoogleDriveRemoto em
    VisaoRemoting.psm1 - ficam como estao.

    Mesma assinatura/formato de retorno das funcoes antigas (que viviam
    em VisaoRemoting.psm1) de proposito - substituicao "encaixa no
    lugar", nenhum lugar que ja chamava Get-ZonasRemoto/
    Get-GruposSistemasRemoto/Get-CampanhasRemoto/
    Get-ResultadosCampanhasRemoto precisou mudar.

    Cache local POR ESTACAO (antes era compartilhado entre todos os
    tecnicos, guardado no POLICY-SERVER) em
    %LOCALAPPDATA%\SuporteTI\Visao\CachePlanilhas\ - se a busca online
    falhar, usa a ultima copia baixada com sucesso NESTA maquina.
    Resultados de Campanhas continua SEM cache local, igual a versao
    anterior (e um historico que so faz sentido buscado fresco).
#>

$script:UrlPlanilhaZonasCSV = "https://docs.google.com/spreadsheets/d/1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I/export?format=csv&gid=0"
$script:UrlPlanilhaGruposSistemasCSV = "https://docs.google.com/spreadsheets/d/1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I/export?format=csv&gid=634558318"
$script:UrlPlanilhaCampanhasCSV = "https://docs.google.com/spreadsheets/d/1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I/gviz/tq?tqx=out:csv&sheet=CAMPANHAS"
$script:UrlPlanilhaResultadosCampanhasCSV = "https://docs.google.com/spreadsheets/d/1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I/gviz/tq?tqx=out:csv&sheet=RESULTADOS-CAMPANHAS"

$script:PastaCachePlanilhas = Join-Path $env:LOCALAPPDATA 'SuporteTI\Visao\CachePlanilhas'
$script:ArquivoZonasCache = Join-Path $script:PastaCachePlanilhas 'zonas_cache.csv'
$script:ArquivoGruposSistemasCache = Join-Path $script:PastaCachePlanilhas 'grupos_sistemas_cache.csv'
$script:ArquivoCampanhasCache = Join-Path $script:PastaCachePlanilhas 'campanhas_cache.csv'

function Get-CsvPlanilhaOuCache {
    <#
        Baixa um CSV publicado de uma planilha Google Sheets (sem
        autenticacao) com fallback pro ultimo cache local baixado com
        sucesso NESTA estacao, se a busca online falhar. Mesma logica
        (timeout, decodificacao UTF-8 manual, fallback) que
        VisaoServidor.ps1 ja usava - so o CAMINHO do cache mudou (local
        por estacao em vez de compartilhado no servidor).
    #>
    param(
        [Parameter(Mandatory)][string]$Url,
        [string]$CaminhoCache = $null,
        [switch]$ForcarCache
    )
    $linhas = $null
    $avisos = New-Object System.Collections.Generic.List[string]
    $origem = "nenhuma"

    if (-not $ForcarCache) {
        try {
            $resp = Invoke-WebRequest -Uri $Url -TimeoutSec 8 -UseBasicParsing
            # O PowerShell 5.1 pode decodificar a resposta com a codificacao
            # errada quando o servidor nao informa o charset explicitamente -
            # pega os bytes brutos e decodifica como UTF-8 na mao.
            $bytesResposta = $resp.RawContentStream.ToArray()
            $textoUtf8 = [System.Text.Encoding]::UTF8.GetString($bytesResposta)
            $linhas = $textoUtf8 | ConvertFrom-Csv
            if ($linhas -and $linhas.Count -gt 0) {
                $origem = "online"
                if ($CaminhoCache) {
                    if (-not (Test-Path -LiteralPath $script:PastaCachePlanilhas)) {
                        New-Item -Path $script:PastaCachePlanilhas -ItemType Directory -Force | Out-Null
                    }
                    $linhas | Export-Csv -Path $CaminhoCache -NoTypeInformation -Encoding UTF8
                }
            }
        } catch {
            $avisos.Add("Nao foi possivel buscar a planilha online: $($_.Exception.Message)")
            $linhas = $null
        }
    }

    if (-not $linhas -and $CaminhoCache -and (Test-Path -LiteralPath $CaminhoCache)) {
        $avisos.Add("Usando cache local (ultima planilha baixada com sucesso nesta estacao).")
        $linhas = Import-Csv -Path $CaminhoCache
        $origem = "cache"
    }

    return [PSCustomObject]@{ Linhas = $linhas; Origem = $origem; Avisos = @($avisos) }
}

function Get-ZonasRemoto {
    <#
        Zona -> {Sede, RedePadrao, Substituta, Observacao}. Mesmo nome
        "Remoto" mantido de proposito (nao e mais remoting de verdade,
        mas trocar o nome exigiria atualizar todo lugar que ja chama
        esta funcao - nao vale o risco so por limpeza de nome).
    #>
    param([switch]$ForcarCache)

    $r = Get-CsvPlanilhaOuCache -Url $script:UrlPlanilhaZonasCSV -CaminhoCache $script:ArquivoZonasCache -ForcarCache:$ForcarCache.IsPresent
    if (-not $r.Linhas) {
        return [PSCustomObject]@{ Ok = $false; Origem = $r.Origem; Contagem = 0; Avisos = $r.Avisos; Erro = "Nenhuma tabela de zonas disponivel (nem online, nem cache local)."; Zonas = @() }
    }

    $zonas = New-Object System.Collections.Generic.List[object]
    foreach ($l in $r.Linhas) {
        $numZona = 0
        if ([int]::TryParse($l.'Zona Eleitoral', [ref]$numZona)) {
            $zonas.Add([PSCustomObject]@{
                Zona       = $numZona
                Sede       = $l.Sede
                RedePadrao = $l.'Rede Padrão'
                Substituta = $l.Substituta
                Observacao = $l.'Observação'
            })
        }
    }
    # .ToArray() em vez de @($zonas) DE PROPOSITO - confirmado ao vivo
    # (2026-08-24) que @() envolvendo um List[object] dentro de um
    # [PSCustomObject]@{...} quebra com "Os tipos de argumento nao
    # correspondem" (ArgumentException) neste PowerShell 5.1 - um bug
    # real do binder dinamico do PowerShell, NAO especifico de remoting
    # (acontece rodando 100% local, sem WinRM envolvido nenhum -
    # diferente do bug de serializacao ja documentado em
    # VisaoServidor.ps1). .ToArray() sempre funciona.
    return [PSCustomObject]@{ Ok = $true; Origem = $r.Origem; Contagem = $zonas.Count; Avisos = $r.Avisos; Erro = $null; Zonas = $zonas.ToArray() }
}

function Get-GruposSistemasRemoto {
    <#
        Grupo (do AD) -> {Sistema, Perfil}. .GruposSistemas devolvido
        como PSCustomObject (nao Hashtable nativa) DE PROPOSITO - quem
        chama (VisaoCliente.ps1) usa ConvertTo-HashtableLocal em cima,
        que so funciona lendo .PSObject.Properties (um Hashtable nativo
        tem .PSObject.Properties apontando pros MEMBROS .NET do tipo
        Hashtable - Count/Keys/Values -, nao pras entradas chave/valor -
        quebraria silenciosamente se devolvesse Hashtable direto aqui).
    #>
    param([switch]$ForcarCache)

    $r = Get-CsvPlanilhaOuCache -Url $script:UrlPlanilhaGruposSistemasCSV -CaminhoCache $script:ArquivoGruposSistemasCache -ForcarCache:$ForcarCache.IsPresent
    if (-not $r.Linhas) {
        return [PSCustomObject]@{ Ok = $false; Origem = $r.Origem; Contagem = 0; Avisos = $r.Avisos; Erro = $null; GruposSistemas = [PSCustomObject]@{} }
    }

    $gruposSistemas = @{}
    foreach ($l in $r.Linhas) {
        $grupo = if ($l.Grupo) { $l.Grupo.Trim() } else { $null }
        if (-not $grupo) { continue }
        $gruposSistemas[$grupo.ToUpper()] = [PSCustomObject]@{ Sistema = $l.Sistema; Perfil = $l.Perfil }
    }
    return [PSCustomObject]@{ Ok = $true; Origem = $r.Origem; Contagem = $gruposSistemas.Count; Avisos = $r.Avisos; Erro = $null; GruposSistemas = [PSCustomObject]$gruposSistemas }
}

function Get-CampanhasRemoto {
    <#
        Lista de {Nome; Requisitos: [{Sistema; VersaoMinima}]}.
    #>
    param([switch]$ForcarCache)

    $r = Get-CsvPlanilhaOuCache -Url $script:UrlPlanilhaCampanhasCSV -CaminhoCache $script:ArquivoCampanhasCache -ForcarCache:$ForcarCache.IsPresent
    if (-not $r.Linhas) {
        return [PSCustomObject]@{ Ok = $false; Origem = $r.Origem; Contagem = 0; Avisos = $r.Avisos; Erro = $null; Campanhas = @() }
    }

    $indice = [ordered]@{}
    foreach ($l in $r.Linhas) {
        $nomeCampanha = if ($l.Campanha) { $l.Campanha.Trim() } else { $null }
        $sistema = if ($l.Sistema) { $l.Sistema.Trim() } else { $null }
        $versaoMinima = if ($l.VersaoMinima) { $l.VersaoMinima.Trim() } else { $null }
        if (-not $nomeCampanha -or -not $sistema -or -not $versaoMinima) { continue }

        $chave = $nomeCampanha.ToUpper()
        if (-not $indice.Contains($chave)) {
            $indice[$chave] = [PSCustomObject]@{ Nome = $nomeCampanha; Requisitos = New-Object System.Collections.Generic.List[object] }
        }
        $indice[$chave].Requisitos.Add([PSCustomObject]@{ Sistema = $sistema; VersaoMinima = $versaoMinima })
    }
    # Requisitos vira array de verdade (.ToArray(), nao List[object] cru)
    # so por consistencia com o formato que a versao anterior (via JSON)
    # devolvia - ver comentario sobre o bug do binder em Get-ZonasRemoto.
    foreach ($c in $indice.Values) { $c.Requisitos = $c.Requisitos.ToArray() }
    $campanhas = @($indice.Values)
    return [PSCustomObject]@{ Ok = $true; Origem = $r.Origem; Contagem = $campanhas.Count; Avisos = $r.Avisos; Erro = $null; Campanhas = $campanhas }
}

function Get-ResultadosCampanhasRemoto {
    <#
        Historico completo de envios de "Verificar Campanha" > "Enviar
        Resultado...". Sem cache local (igual a versao anterior) - so
        faz sentido buscado fresco. $AoAtualizarStatus mantido na
        assinatura por compatibilidade com quem chama
        (Import-ResultadosCampanhasNaJanela, VisaoJanelaCampanhas.psm1)
        mas nao e mais usado - sem o salto pelo WinRM nao ha mais espera
        longa nenhuma pra dar feedback sobre.
    #>
    param([scriptblock]$AoAtualizarStatus = $null)

    try {
        $resp = Invoke-WebRequest -Uri $script:UrlPlanilhaResultadosCampanhasCSV -TimeoutSec 10 -UseBasicParsing
        $bytesResposta = $resp.RawContentStream.ToArray()
        $textoUtf8 = [System.Text.Encoding]::UTF8.GetString($bytesResposta)
        $linhas = $textoUtf8 | ConvertFrom-Csv
        if (-not $linhas) { return [PSCustomObject]@{ Ok = $true; Contagem = 0; Dados = @(); Erro = $null } }

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
        # .ToArray() em vez de @($resultado) - ver comentario em
        # Get-ZonasRemoto (mesmo bug do binder dinamico do PowerShell 5.1).
        return [PSCustomObject]@{ Ok = $true; Contagem = $resultado.Count; Dados = $resultado.ToArray(); Erro = $null }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Contagem = 0; Dados = @(); Erro = "Falha ao buscar resultados de campanhas: $($_.Exception.Message)" }
    }
}

Export-ModuleMember -Function Get-ZonasRemoto, Get-GruposSistemasRemoto, Get-CampanhasRemoto, Get-ResultadosCampanhasRemoto
