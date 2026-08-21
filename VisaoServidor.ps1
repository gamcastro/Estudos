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
    FASE 1: leituras de planilha Google (Zonas, Grupos-Sistemas,
    Campanhas, Resultados-Campanhas) - request/resposta simples, sem
    efeito colateral, sem polling. Cada uma tinha uma chamada a Add-Log no
    caminho de erro no script original - aqui isso virou retorno
    estruturado (Ok/Avisos/Erro), ja que Add-Log escreve num RichTextBox
    que so existe do lado cliente.
    FASE 2: tentativa de prova de conceito com AD - REVERTIDA. Consulta
    LDAP via Invoke-Command deu "An operations error occurred" (problema
    classico de duplo-salto do Kerberos: a credencial usada pra
    autenticar no POLICY-SERVER nao e repassada por ele pra autenticar
    numa TERCEIRA maquina, o Controlador de Dominio). Decisao (do
    usuario, correta): consulta ao AD nao e trafego de varredura/scan -
    nao ha motivo pra rotear pelo servidor. As funcoes de AD (Get-
    UsuariosDaZona, Get-MaquinasLiberadasInstalador) ficam no
    VisaoAD.psm1, rodando DIRETO na estacao do tecnico, fora desta
    camada de remoting inteiramente.

    Ver o plano completo em
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

# Config da varredura de rede (copiada sem mudanca do topo do
# ScannerRedeZona.ps1 original - ver Start-VarreduraZona/$script:scriptBlock
# mais abaixo).
$script:PortasFallback   = @(445, 9100, 631)   # usadas quando o ICMP esta bloqueado
$script:PortasImpressora = @(9100, 515, 631)   # RAW/AppSocket, LPR, IPP
$script:PortaVnc         = 5900
$script:PortaRcIvanti    = 9535   # Ivanti/LANDesk Remote Control legado (RCViewer.exe)
$script:UrlOcsApiBase    = "http://inventario.tre-ma.jus.br/ocsapi/v1"

$script:MapaModelos = @{
    "C4400"                            = "Mini-Positivo"
    "HP Elite Mini 800 G9 Desktop PC"  = "Mini-HP"
    "D6200"                            = "Positivo Master"
    "OptiPlex 3020M"                   = "Mini-Dell"
}

$script:SistemasEleitoraisExtra = @(
    [PSCustomObject]@{ Chave = "BITLOCKER"; NomeVersaoAtual = "CRIPTOSIS"; Propriedade = "VersaoBitlocker"; Coluna = "Bitlocker"; Titulo = "Criptosis"; Largura = 90; ComNomeAmigavel = $false; NaGradePrincipal = $true }
    [PSCustomObject]@{ Chave = "GEDAI";     NomeVersaoAtual = "GEDAI-UE";  Propriedade = "VersaoGedai";     Coluna = "Gedai";     Titulo = "GEDAI-UE";  Largura = 150; ComNomeAmigavel = $true; NaGradePrincipal = $true }
    [PSCustomObject]@{ Chave = "HOLOCRON";  NomeVersaoAtual = "HOLOCRON";  Propriedade = "VersaoHolocron";  Coluna = "Holocron";  Titulo = "Holocron";  Largura = 150; ComNomeAmigavel = $true; NaGradePrincipal = $true }
    [PSCustomObject]@{ Chave = "PADA-UE";   NomeVersaoAtual = "PADA-UE";   Propriedade = "VersaoPadaUe";     Coluna = "PadaUe";    Titulo = "PADA-UE";   Largura = 150; ComNomeAmigavel = $true; NaGradePrincipal = $false }
    [PSCustomObject]@{ Chave = "FBR";       NomeVersaoAtual = "FBR";       Propriedade = "VersaoFbr";        Coluna = "Fbr";       Titulo = "FBR";       Largura = 150; ComNomeAmigavel = $true; NaGradePrincipal = $false }
    [PSCustomObject]@{ Chave = "TRANSPORTADORTDTOT"; NomeVersaoAtual = "TRANSPORTADOR TDTOT"; Propriedade = "VersaoTransportadorTdtot"; Coluna = "TransportadorTdtot"; Titulo = "Transportador TDTOT"; Largura = 150; ComNomeAmigavel = $false; NaGradePrincipal = $true }
    [PSCustomObject]@{ Chave = "EXECJAVA";          NomeVersaoAtual = "EXECJAVA";                    Propriedade = "VersaoExecJava";          Coluna = "ExecJava";          Titulo = "ExecJava";                  Largura = 150; ComNomeAmigavel = $false; NaGradePrincipal = $false }
    [PSCustomObject]@{ Chave = "TRANSPORTADOR-HMG"; NomeVersaoAtual = "TRANSPORTADOR HOMOLOGAÇÃO"; Propriedade = "VersaoTransportadorHmg";  Coluna = "TransportadorHmg";  Titulo = "Transportador Homologacao"; Largura = 150; ComNomeAmigavel = $false; NaGradePrincipal = $false }
    [PSCustomObject]@{ Chave = "CERTIFICADO P12";   NomeVersaoAtual = "CERTIFICADO P12";   Propriedade = "VersaoCertificadoP12";    Coluna = "CertificadoP12";    Titulo = "Certificado P12";           Largura = 150; ComNomeAmigavel = $false; NaGradePrincipal = $false }
)

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

# As funcoes de AD (Get-RaizBuscaAd, ConvertTo-InfoObjetoAd,
# Get-UsuariosDaZona, Get-MaquinasLiberadasInstalador) NAO ficam aqui -
# ver VisaoAD.psm1 (rodam direto no cliente, sem remoting, por causa do
# problema de duplo-salto do Kerberos documentado no topo deste arquivo).

# ============================================================
# FASE 4/5: VARREDURA DE REDE (Invoke-AcaoAtualizarHost e o
# $btnIniciar.Add_Click original) - relocada pro polling sobre sessao
# persistente (ver "Redesenho do progresso ao vivo" no plano). O
# $script:scriptBlock em si e IDENTICO ao do ScannerRedeZona.ps1 original -
# ja era 100% parametro explicito, sem ler nenhum $script:/controle de
# UI, entao atravessa o remoting sem qualquer mudanca.
# ============================================================

$script:scriptBlock = {
    param($ip, $timeoutMs, $portasFallback, $portasImpressora, $portaVnc, $portaRc, $urlOcsApiBase, $zonaAtual, $redeCompartilhada, $mapaModelos, $sistemasEleitoraisExtra)

    function Test-PortaTCP {
        param([string]$IPAlvo, [int]$Porta, [int]$TimeoutMs = 250)
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $conn = $client.BeginConnect($IPAlvo, $Porta, $null, $null)
            $ok = $conn.AsyncWaitHandle.WaitOne($TimeoutMs, $false) -and $client.Connected
            $client.Close()
            return $ok
        } catch { return $false }
    }

    $resultado = [PSCustomObject]@{
        IP                 = $ip
        Online             = $false
        Hostname           = ""
        TempoMs            = $null
        PossivelImpressora = $false
        PortasAbertas      = ""
        DetectadoPor       = ""
        VncAtivo           = $false
        RcIvantiAtivo      = $false
        VersaoSis          = "-"
        Modelo             = "-"
    }
    foreach ($sis in $sistemasEleitoraisExtra) {
        $resultado | Add-Member -NotePropertyName $sis.Propriedade -NotePropertyValue "-"
    }

    $ping = New-Object System.Net.NetworkInformation.Ping
    try {
        $reply = $ping.Send($ip, $timeoutMs)
        if ($reply.Status -eq 'Success') {
            $resultado.Online = $true
            $resultado.TempoMs = $reply.RoundtripTime
            $resultado.DetectadoPor = "ping"
        }
    } catch {}

    if (-not $resultado.Online) {
        foreach ($porta in $portasFallback) {
            if (Test-PortaTCP -IPAlvo $ip -Porta $porta -TimeoutMs 200) {
                $resultado.Online = $true
                $resultado.DetectadoPor = "porta $porta (icmp bloqueado)"
                break
            }
        }
    }

    if (-not $resultado.Online) {
        try {
            $reply2 = $ping.Send($ip, [Math]::Max($timeoutMs * 3, 1000))
            if ($reply2.Status -eq 'Success') {
                $resultado.Online = $true
                $resultado.TempoMs = $reply2.RoundtripTime
                $resultado.DetectadoPor = "ping (2a tentativa)"
            }
        } catch {}
    }

    if ($resultado.Online) {
        $abertas = @()
        foreach ($porta in $portasImpressora) {
            if (Test-PortaTCP -IPAlvo $ip -Porta $porta -TimeoutMs 200) { $abertas += $porta }
        }
        if ($abertas.Count -gt 0) {
            $resultado.PossivelImpressora = $true
            $resultado.PortasAbertas = ($abertas -join ",")
        }

        if (Test-PortaTCP -IPAlvo $ip -Porta $portaVnc -TimeoutMs 200) {
            $resultado.VncAtivo = $true
        }

        if (Test-PortaTCP -IPAlvo $ip -Porta $portaRc -TimeoutMs 200) {
            $resultado.RcIvantiAtivo = $true
        }

        try {
            $dns = [System.Net.Dns]::GetHostEntry($ip)
            $resultado.Hostname = $dns.HostName
        } catch {
            try {
                $nbt = & nbtstat -A $ip 2>$null
                $linha = $nbt | Select-String -Pattern '<00>\s+UNIQUE' | Select-Object -First 1
                if ($linha) {
                    $resultado.Hostname = ($linha.ToString().Trim() -split '\s+')[0]
                } else {
                    $resultado.Hostname = "(sem resolucao de nome)"
                }
            } catch {
                $resultado.Hostname = "(sem resolucao de nome)"
            }
        }

        if ($resultado.Hostname -match '(?i)pantum') {
            $resultado.PossivelImpressora = $true
        }

        $temNomeValido = $resultado.Hostname -and $resultado.Hostname -ne "(sem resolucao de nome)"

        if ($temNomeValido -and -not $resultado.PossivelImpressora -and $urlOcsApiBase) {
            $consultarOcs = $true
            if ($redeCompartilhada) {
                $zonaPad = "{0:D3}" -f $zonaAtual
                $hostUpper = $resultado.Hostname.ToUpper()
                $consultarOcs = (
                    $hostUpper.Contains("ZMA$zonaPad") -or
                    $hostUpper.Contains("CMA$zonaPad") -or
                    $hostUpper.Contains("ZE-$zonaPad") -or
                    $hostUpper.Contains("ZE$zonaPad")
                )
            }

            if ($consultarOcs) {
                $encontradoNoOcs = $false
                $nomeCurto = ($resultado.Hostname -split '\.')[0]
                foreach ($chaveParam in @("NAME", "name")) {
                    try {
                        $urlBusca = "$urlOcsApiBase/computers/search?start=0&limit=5&$chaveParam=$nomeCurto"
                        $respBusca = Invoke-RestMethod -Uri $urlBusca -TimeoutSec 5
                        if (@($respBusca).Count -gt 0) {
                            $encontradoNoOcs = $true
                            $hwId = @($respBusca)[0].ID

                            try {
                                $urlReg = "$urlOcsApiBase/computer/$hwId/registry"
                                $respReg = Invoke-RestMethod -Uri $urlReg -TimeoutSec 5
                                $secaoRegistry = $null
                                try { $secaoRegistry = $respReg."$hwId".registry } catch {}
                                if ($secaoRegistry) {
                                    $entradaSis = @($secaoRegistry) | Where-Object { $_.NAME -eq "VERSAO_SIS" } | Select-Object -First 1
                                    if ($entradaSis) { $resultado.VersaoSis = $entradaSis.REGVALUE }

                                    foreach ($sis in $sistemasEleitoraisExtra) {
                                        $entradaExtra = @($secaoRegistry) | Where-Object { $_.NAME -eq $sis.Chave } | Select-Object -First 1
                                        if ($entradaExtra -and $entradaExtra.REGVALUE) { $resultado.($sis.Propriedade) = $entradaExtra.REGVALUE }
                                    }
                                }
                            } catch {}

                            try {
                                $urlBios = "$urlOcsApiBase/computer/$hwId/bios"
                                $respBios = Invoke-RestMethod -Uri $urlBios -TimeoutSec 5
                                $secaoBios = $null
                                try { $secaoBios = $respBios."$hwId".bios } catch {}
                                if ($secaoBios) {
                                    $modeloOriginal = @($secaoBios)[0].SMODEL
                                    if ($modeloOriginal) {
                                        if ($mapaModelos -and $mapaModelos.ContainsKey($modeloOriginal)) {
                                            $resultado.Modelo = $mapaModelos[$modeloOriginal]
                                        } else {
                                            $resultado.Modelo = $modeloOriginal
                                        }
                                    }
                                }
                            } catch {}

                            break
                        }
                    } catch {}
                }
                if (-not $encontradoNoOcs) {
                    $resultado.Modelo = "Nao encontrado no OCS"
                }
            }
        }
    }

    return $resultado
}

# Estado da varredura em andamento NESTA sessao (uma varredura por vez por
# sessao/tecnico - se um novo Start-VarreduraZona chegar com uma varredura
# anterior ainda rodando, ela e descartada/cancelada, ver abaixo).
$script:EstadoVarredura = $null

function Start-VarreduraZona {
    <#
        Dispara a varredura de uma lista de IPs em paralelo (pool de
        runspaces, igual ao $btnIniciar.Add_Click/Invoke-AcaoAtualizarHost
        originais) e devolve NA HORA, sem esperar terminar - o estado fica
        guardado em $script:EstadoVarredura, na sessao, pra
        Get-VarreduraNovosResultados ir consultando por polling. Tamanho
        do pool fixo em 60 (igual ao original) mesmo pra varreduras de 1
        IP so - overhead insignificante e evita ter dois caminhos de
        codigo diferentes pra "1 maquina" vs "zona inteira".
    #>
    param(
        [Parameter(Mandatory)]
        [string[]]$Ips,
        [Parameter(Mandatory)]
        [int]$Zona,
        [bool]$RedeCompartilhada = $false
    )

    if ($script:EstadoVarredura -and $script:EstadoVarredura.Pool) {
        try { $script:EstadoVarredura.Pool.Close() } catch {}
        try { $script:EstadoVarredura.Pool.Dispose() } catch {}
    }

    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $pool = [runspacefactory]::CreateRunspacePool(1, 60, $sessionState, $Host)
    $pool.Open()

    $jobs = New-Object System.Collections.Generic.List[object]
    foreach ($ip in $Ips) {
        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($script:scriptBlock).AddArgument($ip).AddArgument(400).AddArgument($script:PortasFallback).AddArgument($script:PortasImpressora).AddArgument($script:PortaVnc).AddArgument($script:PortaRcIvanti).AddArgument($script:UrlOcsApiBase).AddArgument($Zona).AddArgument($RedeCompartilhada).AddArgument($script:MapaModelos).AddArgument($script:SistemasEleitoraisExtra)
        $handle = $ps.BeginInvoke()
        $jobs.Add([PSCustomObject]@{ Pipe = $ps; Handle = $handle; IP = $ip })
    }

    $script:EstadoVarredura = @{
        Jobs              = $jobs
        Total             = $Ips.Count
        Concluidos        = 0
        EmAndamento       = $true
        Pool              = $pool
        Zona              = $Zona
        RedeCompartilhada = $RedeCompartilhada
    }

    return $true
}

function Get-VarreduraNovosResultados {
    <#
        Devolve so o que completou DESDE A ULTIMA CHAMADA (delta) - quem
        chama (VisaoRemoting.psm1/o Timer do cliente) acumula/mostra
        conforme for chegando, igual o $timer.Add_Tick original fazia
        lendo direto da colecao de jobs. Devolve uma STRING JSON (ver o
        comentario extenso em Get-ResultadosCampanhas mais acima sobre o
        bug de serializacao de array de PSCustomObject no PS Remoting
        deste servidor) com a forma:
            { Novos: [...]; Concluidos; Total; EmAndamento }
        Se nao houver varredura em andamento nesta sessao (nunca chamou
        Start-VarreduraZona, ou a sessao e nova), devolve
        EmAndamento=$false e Novos vazio - nao e erro, e um estado valido.
    #>
    if (-not $script:EstadoVarredura) {
        return ([PSCustomObject]@{ Novos = @(); Concluidos = 0; Total = 0; EmAndamento = $false } | ConvertTo-Json -Depth 6 -Compress)
    }

    $estado = $script:EstadoVarredura
    $aindaPendentes = New-Object System.Collections.Generic.List[object]
    $novos = New-Object System.Collections.Generic.List[object]

    foreach ($job in $estado.Jobs) {
        if (-not $job.Handle.IsCompleted) {
            $aindaPendentes.Add($job)
            continue
        }
        try {
            $saida = $job.Pipe.EndInvoke($job.Handle)
            $item = @($saida)[0]
            if ($item) {
                if ($item.Online) {
                    # Classificacao que no ScannerRedeZona.ps1 original
                    # acontecia no $timer.Add_Tick, do lado cliente - move
                    # pra ca porque ja tem tudo que precisa (Zona/
                    # RedeCompartilhada guardados no Start-VarreduraZona,
                    # e Test-HostnamePertenceZona ja roda neste mesmo
                    # servidor) e evita o cliente ter que chamar de volta
                    # pro servidor pra cada um dos ate 254 resultados.
                    $ultimoOcteto = [int]($item.IP -split '\.')[3]
                    $ehGateway = (-not $estado.RedeCompartilhada) -and $item.IP.EndsWith(".70")
                    $ehNobreakCentral = ($ultimoOcteto -eq 10 -or $ultimoOcteto -eq 11)
                    $ehTelefoneVoip = (-not $estado.RedeCompartilhada) -and ($ultimoOcteto -ge 190 -and $ultimoOcteto -le 195)
                    $pertence = if ($estado.RedeCompartilhada) { Test-HostnamePertenceZona -Hostname $item.Hostname -Zona $estado.Zona } else { $true }

                    $item | Add-Member -NotePropertyName EhGateway -NotePropertyValue $ehGateway -Force
                    $item | Add-Member -NotePropertyName EhNobreakCentral -NotePropertyValue $ehNobreakCentral -Force
                    $item | Add-Member -NotePropertyName EhTelefoneVoip -NotePropertyValue $ehTelefoneVoip -Force
                    $item | Add-Member -NotePropertyName PertenceZonaAtual -NotePropertyValue $pertence -Force
                }
                $novos.Add($item)
            }
        } catch {
            # Um IP especifico falhou de um jeito inesperado (nao coberto
            # pelos try/catch internos do proprio $scriptBlock) - marca
            # esse IP como offline/com erro em vez de simplesmente
            # sumir da varredura sem explicacao nenhuma.
            $novos.Add([PSCustomObject]@{
                IP = $job.IP; Online = $false; Hostname = ""; TempoMs = $null
                PossivelImpressora = $false; PortasAbertas = ""
                DetectadoPor = "erro na varredura: $($_.Exception.Message)"
                VncAtivo = $false; RcIvantiAtivo = $false; VersaoSis = "-"; Modelo = "-"
                EhGateway = $false; EhNobreakCentral = $false; EhTelefoneVoip = $false; PertenceZonaAtual = $false
            })
        } finally {
            $job.Pipe.Dispose()
        }
        $estado.Concluidos++
    }
    $estado.Jobs = $aindaPendentes

    if ($estado.Jobs.Count -eq 0) {
        $estado.EmAndamento = $false
        if ($estado.Pool) {
            try { $estado.Pool.Close() } catch {}
            try { $estado.Pool.Dispose() } catch {}
            $estado.Pool = $null
        }
    }

    return ([PSCustomObject]@{
        Novos       = $novos
        Concluidos  = $estado.Concluidos
        Total       = $estado.Total
        EmAndamento = $estado.EmAndamento
    } | ConvertTo-Json -Depth 6 -Compress)
}
