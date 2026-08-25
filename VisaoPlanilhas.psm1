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

    ATUALIZACAO (2026-08-24, decisao explicita do usuario): o ENVIO de
    resultado de campanha (Send-ResultadoCampanhaZonaRemoto) TAMBEM foi
    migrado pra ca, e por isso o token do Apps Script (RESULTADOS-
    CAMPANHAS) passou a ser distribuido dentro deste modulo - decisao
    consciente do usuario apos eu explicar o risco (o token fica em texto
    puro em todas as estacoes, qualquer um com acesso a maquina do
    tecnico ou ao pacote no PSRepo consegue le-lo) porque os dados de
    RESULTADOS-CAMPANHAS nao sao sensiveis. Send-AtualizacaoZonaRemoto/
    Send-ArquivoParaGoogleDriveRemoto (zonas/CVC) CONTINUAM centralizadas
    no POLICY-SERVER - essa decisao foi so pra campanhas, nao foi
    generalizada pras outras escritas. Ver VisaoRemoting.psm1.

    Mesma assinatura/formato de retorno das funcoes antigas (que viviam
    em VisaoRemoting.psm1) de proposito - substituicao "encaixa no
    lugar", nenhum lugar que ja chamava Get-ZonasRemoto/
    Get-GruposSistemasRemoto/Get-CampanhasRemoto/
    Get-ResultadosCampanhasRemoto precisou mudar.

    Cache local POR ESTACAO (antes era compartilhado entre todos os
    tecnicos, guardado no POLICY-SERVER) em
    %LOCALAPPDATA%\SuporteTI\VisaoHomolog\CachePlanilhas\ - se a busca online
    falhar, usa a ultima copia baixada com sucesso NESTA maquina.
    Resultados de Campanhas continua SEM cache local, igual a versao
    anterior (e um historico que so faz sentido buscado fresco).

    Resolve-RedeDaZonaRemoto/Test-RedeEhCompartilhadaRemoto (usadas por
    "Iniciar Varredura") TAMBEM foram trazidas pra ca (portadas de
    Resolve-RedeDaZona/Test-RedeEhCompartilhada em VisaoServidor.ps1) -
    achado ao vivo (2026-08-24): a primeira versao desta migracao so
    trouxe as 4 leituras e deixou essas duas no servidor, o que quebrou
    "Iniciar Varredura" na hora (toda zona virava "nao encontrada na
    planilha") - elas dependiam de um EFEITO COLATERAL que o
    Get-ZonasRemoto ANTIGO (via remoting) tinha: populava
    $script:TabelaZonas no PROPRIO SERVIDOR de passagem, que essas duas
    funcoes liam depois. Sem mais nada chamando o Import-TabelaZonas do
    servidor, essa tabela nunca mais era populada. Corrigido migrando as
    duas junto - agora recebem a lista de zonas JA CARREGADA (
    $script:Estado.Zonas, ja populado na conexao) como parametro, em vez
    de ler um estado de servidor.
#>

$script:UrlPlanilhaZonasCSV = "https://docs.google.com/spreadsheets/d/1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I/export?format=csv&gid=0"
$script:UrlPlanilhaGruposSistemasCSV = "https://docs.google.com/spreadsheets/d/1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I/export?format=csv&gid=634558318"
$script:UrlPlanilhaCampanhasCSV = "https://docs.google.com/spreadsheets/d/1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I/gviz/tq?tqx=out:csv&sheet=CAMPANHAS"
$script:UrlPlanilhaResultadosCampanhasCSV = "https://docs.google.com/spreadsheets/d/1_2aZhFgplRqCdPVV_lq4XJT9wgqkfbZpEFZRu1Zu9_I/gviz/tq?tqx=out:csv&sheet=RESULTADOS-CAMPANHAS"

# Token do Apps Script (RESULTADOS-CAMPANHAS) distribuido de proposito
# neste modulo - decisao explicita do usuario em 2026-08-24, dado que os
# dados desta aba nao sao sensiveis. NAO usar este mesmo padrao pra
# atualizacao de Zonas nem envio de CVC (Send-AtualizacaoZonaRemoto/
# Send-ArquivoParaGoogleDriveRemoto) sem uma decisao explicita igual -
# essas continuam centralizadas no POLICY-SERVER, ver VisaoRemoting.psm1.
$script:UrlWebAppCampanhas = "https://script.google.com/macros/s/AKfycbxcI7FfmnoWEjuOnO32WkaLwg-AiFxCSAXvdfiET9e29mrYvPx5QHRTIeRdU7yrGT3Z4A/exec"
$script:TokenWebAppCampanhas = "Super@dmin2025"

$script:PastaCachePlanilhas = Join-Path $env:LOCALAPPDATA 'SuporteTI\VisaoHomolog\CachePlanilhas'
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

function Remove-AcentosLocal {
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

function ConvertTo-PrefixoRedeLocal {
    <#
        Converte uma rede no formato "10.198.4.0/24" (como vem da coluna
        "Rede Padrao"/"Substituta" da planilha) para o prefixo "10.198.4."
        que o resto da ferramenta usa internamente pra montar IPs (ex:
        "10.198.4.15"). Tambem aceita "10.198.4.0" sem mascara, ou
        "10.198.4" (3 octetos, atalho comum). Devolve $null se vier vazio
        ou nao reconhecer o formato.
    #>
    param([string]$Rede)
    if (-not $Rede) { return $null }
    $Rede = $Rede.Trim()
    if (-not $Rede) { return $null }
    if ($Rede.EndsWith(".") -and ($Rede -notmatch '/')) { return $Rede }

    $semMascara = ($Rede -split '/')[0].TrimEnd('.')
    $partes = $semMascara -split '\.'
    if ($partes.Count -eq 4) { return "$($partes[0]).$($partes[1]).$($partes[2])." }
    if ($partes.Count -eq 3) { return "$($partes[0]).$($partes[1]).$($partes[2])." }
    return $null
}

function Resolve-RedeDaZonaRemoto {
    <#
        Decide o prefixo de rede a varrer pra uma zona, nesta ordem de
        prioridade: (1) coluna "Substituta" da planilha, (2) coluna
        "Rede Padrao", (3) se a planilha nao tiver essa zona, calcula
        como o original ja fazia (10.11.81. pra Sao Luis, 10.198.<zona>.
        pro resto). $Zonas e o array ja carregado por Get-ZonasRemoto
        (normalmente $script:Estado.Zonas, ja populado na conexao) - NAO
        busca a planilha de novo a cada chamada.
    #>
    param(
        [Parameter(Mandatory)][int]$Zona,
        [object[]]$Zonas = @()
    )

    $zonaInfo = $Zonas | Where-Object { $_.Zona -eq $Zona } | Select-Object -First 1
    $sede = if ($zonaInfo) { $zonaInfo.Sede } else { $null }

    $prefixoSubstituta = if ($zonaInfo) { ConvertTo-PrefixoRedeLocal $zonaInfo.Substituta } else { $null }
    if ($prefixoSubstituta) {
        return [PSCustomObject]@{ Prefixo = $prefixoSubstituta; Origem = "Substituta (planilha)"; Sede = $sede; Observacao = $zonaInfo.Observacao; EhSubstituta = $true }
    }

    $prefixoPadrao = if ($zonaInfo) { ConvertTo-PrefixoRedeLocal $zonaInfo.RedePadrao } else { $null }
    if ($prefixoPadrao) {
        return [PSCustomObject]@{ Prefixo = $prefixoPadrao; Origem = "Rede Padrao (planilha)"; Sede = $sede; Observacao = $null; EhSubstituta = $false }
    }

    $sedeSemAcento = (Remove-AcentosLocal $sede).ToUpper().Trim()
    if ($sedeSemAcento -eq "SAO LUIS") {
        return [PSCustomObject]@{ Prefixo = "10.11.81."; Origem = "Sao Luis (calculado, planilha incompleta)"; Sede = $sede; Observacao = $null; EhSubstituta = $false }
    }

    return [PSCustomObject]@{ Prefixo = "10.198.$Zona."; Origem = "Padrao interior (calculado, planilha incompleta)"; Sede = $sede; Observacao = $null; EhSubstituta = $false }
}

function Test-RedeEhCompartilhadaRemoto {
    <#
        Uma rede e "compartilhada" quando mais de uma zona eleitoral
        resolve pro mesmo prefixo (varias zonas no mesmo predio/rede).
        $Zonas mesmo array ja carregado - ver Resolve-RedeDaZonaRemoto.
    #>
    param(
        [Parameter(Mandatory)][string]$Prefixo,
        [object[]]$Zonas = @()
    )
    if (-not $Prefixo) { return $false }

    $contagem = 0
    foreach ($z in $Zonas) {
        $res = Resolve-RedeDaZonaRemoto -Zona $z.Zona -Zonas $Zonas
        if ($res.Prefixo -eq $Prefixo) {
            $contagem++
            if ($contagem -gt 1) { return $true }
        }
    }
    return $false
}

function Send-ResultadoCampanhaZonaRemoto {
    <#
        Manda o resultado JA CALCULADO de uma verificacao de campanha por
        HTTP POST direto ao Web App do Apps Script, que acrescenta uma
        linha na aba RESULTADOS-CAMPANHAS da planilha - portada quase sem
        mudanca de VisaoServidor.ps1 (Send-ResultadoCampanhaZona), so
        trocando Get-ConfigCampanhasWebApp (le de um arquivo local no
        servidor) pelas constantes $script:UrlWebAppCampanhas/
        $script:TokenWebAppCampanhas deste modulo, e a verificacao de
        "gravou mesmo assim apesar do erro HTTP" reaproveitando
        Get-ResultadosCampanhasRemoto (a leitura, ja migrada acima) em
        vez de chamar a funcao equivalente do servidor.

        Mesmo nome/formato de retorno da versao antiga de proposito -
        nenhum lugar que ja chamava esta funcao precisou mudar.
    #>
    param(
        [Parameter(Mandatory)][int]$Zona,
        [Parameter(Mandatory)][string]$NomeCampanha,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][int]$Aptas,
        [string]$MaquinasAptas = "",
        [string]$Tecnico = $env:USERNAME,
        [string]$Sede = ""
    )

    $sedeTxt = $Sede
    $zonaPad = "{0:D3}" -f $Zona

    try {
        $corpo = @{
            token         = $script:TokenWebAppCampanhas
            zona          = $zonaPad
            sede          = $sedeTxt
            campanha      = $NomeCampanha
            total         = $Total
            aptas         = $Aptas
            tecnico       = $Tecnico
            maquinasAptas = $MaquinasAptas
        } | ConvertTo-Json -Compress
        # 60s (nao 20s) de proposito - a PRIMEIRA chamada a um Web App
        # recem-implantado (ou muito tempo ocioso) pode demorar bem mais
        # que o normal pro Google "esquentar" o ambiente de execucao -
        # ja confirmado ao vivo nesta ferramenta.
        $corpoBytesUtf8 = [System.Text.Encoding]::UTF8.GetBytes($corpo)
        $resp = Invoke-RestMethod -Uri $script:UrlWebAppCampanhas -Method Post -Body $corpoBytesUtf8 -ContentType "application/json; charset=utf-8" -TimeoutSec 60
    } catch {
        # O Web App do Apps Script as vezes devolve erro HTTP MESMO
        # quando o doPost ja gravou certinho - confere se gravou mesmo
        # assim antes de considerar falha de verdade.
        $todosVerificacao = Get-ResultadosCampanhasRemoto
        $gravouMesmoAssim = $null
        if ($todosVerificacao.Ok) {
            $gravouMesmoAssim = $todosVerificacao.Dados | Where-Object {
                $_.Zona -eq $zonaPad -and $_.Campanha -eq $NomeCampanha -and $_.Total -eq $Total -and $_.Aptas -eq $Aptas -and $_.Tecnico -eq $Tecnico
            } | Select-Object -Last 1
        }
        if ($gravouMesmoAssim) {
            return [PSCustomObject]@{ Ok = $true; Mensagem = "Resultado enviado com sucesso (o aviso de erro foi um falso alarme - conferido na planilha)." }
        }
        return [PSCustomObject]@{ Ok = $false; Mensagem = "Falha ao enviar resultado da campanha '$NomeCampanha' (zona $zonaPad): $($_.Exception.Message)" }
    }

    if (-not $resp.ok) {
        return [PSCustomObject]@{ Ok = $false; Mensagem = "Planilha recusou o resultado da campanha '$NomeCampanha' (zona $zonaPad): $($resp.erro)" }
    }

    return [PSCustomObject]@{ Ok = $true; Mensagem = "Resultado da campanha '$NomeCampanha' (zona $zonaPad - $sedeTxt, $Aptas de $Total aptas) enviado para a planilha." }
}

Export-ModuleMember -Function Get-ZonasRemoto, Get-GruposSistemasRemoto, Get-CampanhasRemoto, Get-ResultadosCampanhasRemoto, Resolve-RedeDaZonaRemoto, Test-RedeEhCompartilhadaRemoto, Send-ResultadoCampanhaZonaRemoto
