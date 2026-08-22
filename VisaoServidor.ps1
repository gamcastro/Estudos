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

# Config/cache de Versoes de Sistemas + Pacotes de Instalacao - mesmo
# arquivo/pasta ja usado pelo ScannerRedeZona.ps1 quando rodava via RDP
# neste servidor (confirmado ao vivo: E:\ScanZonas\versoes_config.json e
# versoes_cache.csv ja existiam aqui antes desta migracao) - continua
# sendo config COMPARTILHADA entre todos os tecnicos, nao por maquina.
$script:ArquivoConfigVersoes      = Join-Path $script:PastaBaseServidor "versoes_config.json"
$script:ArquivoVersoesCache       = Join-Path $script:PastaBaseServidor "versoes_cache.csv"
$script:TabelaVersoes             = @{}   # "SISTEMA|VERSAO" -> PSCustomObject { NomeAmigavel }
$script:VersaoAtualPorSistema     = @{}   # "SISTEMA" -> versao marcada "Atual" na planilha
$script:TabelaPacotes             = New-Object System.Collections.Generic.List[object]
$script:PastaCacheDownloadsServidor = Join-Path $script:PastaBaseServidor "CacheDownloads"
# Mesma pasta acima, mas pelo caminho UNC que a ESTACAO DO TECNICO enxerga
# (confirmado ao vivo que uma estacao comum acessa \\POLICY-SERVER...\
# ScanZonas direto, sem problema nenhum) - usado pra Start-BaixarPacote
# devolver ao cliente onde pegar o arquivo baixado. Ver a nota grande
# logo abaixo sobre por que a copia final NAO roda mais aqui no servidor.
$script:PastaCacheDownloadsUnc = "\\POLICY-SERVER.tre-ma.gov.br\ScanZonas\CacheDownloads"

# Estado dos jobs de DOWNLOAD de pacote EM ANDAMENTO nesta sessao -
# JobId (string/GUID gerado pelo CLIENTE) -> hashtable SINCRONIZADA (ver
# Start-BaixarPacote) com o snapshot atual (Texto/Concluido/Sucesso/
# Erro/Avisos/...). Sincronizada porque e escrita por um runspace em
# segundo plano (o download em si) e lida por Get-StatusPacote, chamada
# de uma invocacao SEPARADA de Invoke-Command (mesmo padrao de "estado
# vivendo na sessao" ja usado em $script:EstadoVarredura, so que aqui
# precisa ser thread-safe de verdade porque o job roda de fato em
# paralelo, nao so "ainda nao verificado" como os jobs de varredura).
#
# IMPORTANTE - por que so DOWNLOAD, sem a copia final pro InstSeg (ao
# contrario do desenho original do plano): testado ao vivo que qualquer
# acesso SMB do POLICY-SERVER (dentro da sessao WinRM) pra uma TERCEIRA
# maquina (\\IP-da-zona\InstSeg, e ate \\IP-da-zona\C$) da "Access is
# denied" - o classico duplo-salto do Kerberos, mesma causa-raiz ja
# diagnosticada pro AD (ver VisaoAD.psm1), so que aqui NAO da pra "rodar
# local no cliente" da mesma forma simples, porque desta vez o servidor
# faz sentido continuar no meio (cache compartilhado do download entre
# tecnicos, chamada a API do Google). A saida (decidida pelo usuario):
# o SERVIDOR baixa do Drive e guarda no cache compartilhado
# (E:\ScanZonas\CacheDownloads); a ESTACAO DO TECNICO, que ja tem acesso
# de 1 salto so tanto a esse cache (\\POLICY-SERVER...\ScanZonas\
# CacheDownloads) quanto ao InstSeg de qualquer zona (é a mesma copia
# manual de arquivo que o tecnico ja faz hoje, nao trafego de
# varredura/scan), faz o robocopy final - ver VisaoPacotes.psm1 (modulo
# cliente, sem remoting, mesmo espirito do VisaoAD.psm1).
$script:EstadoPacotes = [hashtable]::Synchronized(@{})

# Config dos 3 Web Apps do Apps Script usados pelas escritas na planilha
# (Fase 7) - mesmos arquivos ja usados pelo ScannerRedeZona.ps1 quando
# rodava via RDP neste servidor (confirmado ao vivo: os 3 ja existiam em
# E:\ScanZonas antes desta migracao, mesma situacao do versoes_config.json
# na Fase 6). So os LEITORES (Get-Config*) sao migrados aqui - os
# assistentes interativos de PRIMEIRA CONFIGURACAO (Read-Config*
# Interativo, que usam InputBox) nao entram nesta fase: os 3 Web Apps ja
# estao configurados, reconfigurar (se um dia precisar) continua sendo
# feito direto no servidor por enquanto.
$script:ArquivoConfigZonasWebApp     = Join-Path $script:PastaBaseServidor "zonas_webapp_config.json"
$script:ArquivoConfigCampanhasWebApp = Join-Path $script:PastaBaseServidor "campanhas_webapp_config.json"
$script:ArquivoConfigDrive           = Join-Path $script:PastaBaseServidor "drive_upload_config.json"

# Config da varredura de rede (copiada sem mudanca do topo do
# ScannerRedeZona.ps1 original - ver Start-VarreduraZona/$script:scriptBlock
# mais abaixo).
$script:PortasFallback   = @(445, 9100, 631)   # usadas quando o ICMP esta bloqueado
$script:PortasImpressora = @(9100, 515, 631)   # RAW/AppSocket, LPR, IPP
$script:PortaVnc         = 5900
$script:PortaRcIvanti    = 9535   # Ivanti/LANDesk Remote Control legado (RCViewer.exe)
$script:UrlOcsApiBase    = "http://inventario.tre-ma.jus.br/ocsapi/v1"
$script:MesesParaCandidatoExclusaoOcs = 6   # ultimo contato ha mais de X meses = candidata a exclusao no OCS

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

# ============================================================
# FASE 6: download de pacote de instalacao (Google Drive -> cache
# compartilhado em E:\ScanZonas\CacheDownloads). A COPIA final pro
# \\IP\InstSeg da maquina de destino NAO roda aqui - ver a nota grande
# acima de $script:EstadoPacotes (duplo-salto do Kerberos) e
# VisaoPacotes.psm1 (modulo cliente). Mesmo padrao de estado-por-sessao
# + polling da varredura (Fase 4/5), mas aqui o job roda de fato em
# paralelo (background runspace via [powershell]::Create/BeginInvoke)
# em vez de "so ainda nao verificado" - por isso $script:EstadoPacotes
# usa hashtable SINCRONIZADA.
# ============================================================

function Get-ConfigVersoes {
    if (-not (Test-Path $script:ArquivoConfigVersoes)) { return $null }
    try {
        $cfg = Get-Content -Path $script:ArquivoConfigVersoes -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.SpreadsheetId) { return $cfg }
    } catch {}
    return $null
}

function Resolve-NomeExibicaoSistema {
    <#
        Alguns "Sistema" da planilha tem nome de exibicao diferente da
        chave interna usada pra bater com o registro do OCS (ex: chave
        interna continua "GEDAI", mas o produto se chama comercialmente
        "GEDAI-UE") - reaproveita o campo Titulo ja definido em
        $script:SistemasEleitoraisExtra (mesma fonte dos cabecalhos da
        grade principal).
    #>
    param([string]$Sistema)
    if (-not $Sistema) { return $Sistema }
    $entrada = $script:SistemasEleitoraisExtra | Where-Object { $_.Chave -eq $Sistema.ToUpper().Trim() } | Select-Object -First 1
    if ($entrada) { return $entrada.Titulo }
    return $Sistema
}

function Resolve-IdArquivoDrive {
    <#
        Aceita o link de compartilhamento inteiro do ARQUIVO no Drive ou
        so o ID puro, e devolve so o ID.
    #>
    param([string]$Entrada)
    if (-not $Entrada) { return $null }
    $Entrada = $Entrada.Trim()
    if ($Entrada -match "/file/d/([a-zA-Z0-9_-]+)") { return $Matches[1] }
    if ($Entrada -match "[?&]id=([a-zA-Z0-9_-]+)") { return $Matches[1] }
    return $Entrada
}

function ConvertTo-CaminhoRelativoInstSeg {
    <#
        A coluna PastaDestino da planilha aceita tanto um caminho ja
        relativo ao compartilhamento InstSeg quanto um caminho local
        completo copiado da propria estacao - nesse 2o caso, corta tudo
        ate (e incluindo) o "InstSeg\" e fica so com o resto.
    #>
    param([string]$Caminho)
    if (-not $Caminho) { return $Caminho }
    $Caminho = $Caminho.Trim().Trim('\')
    if ($Caminho -match '(?i)InstSeg\\(.*)$') { return $Matches[1] }
    return $Caminho
}

function Import-TabelaVersoes {
    <#
        Fonte unica de verdade pra sistemas eleitorais: Sistema+Versao ->
        Nome Amigavel (usado na grade principal) e a lista de pacotes de
        instalacao baixaveis (LinkDrive + PastaDestino preenchidos).

        Reestruturada como os outros Import-Tabela* (Ok/Origem/Contagem/
        Avisos/Erro em vez de Add-Log + $true/$false) - e devolve como
        STRING JSON (ConvertTo-Json -Depth 6 -Compress) porque Pacotes e
        uma lista de PSCustomObject (mesmo bug de serializacao de sempre,
        ver comentario extenso em Get-ResultadosCampanhas).
    #>
    param([switch]$ForcarCache)

    $script:TabelaVersoes = @{}
    $script:VersaoAtualPorSistema = @{}
    $script:TabelaPacotes = New-Object System.Collections.Generic.List[object]
    $avisos = New-Object System.Collections.Generic.List[string]
    $origem = "nenhuma"

    $cfg = Get-ConfigVersoes
    if (-not $cfg) {
        return ([PSCustomObject]@{ Ok = $false; Origem = $origem; Contagem = 0; Avisos = @(); Erro = "Planilha de Versoes/Pacotes ainda nao configurada neste servidor ($script:ArquivoConfigVersoes)."; Pacotes = @() } | ConvertTo-Json -Depth 6 -Compress)
    }

    $linhas = $null
    if (-not $ForcarCache) {
        try {
            $gid = if ($cfg.Gid) { $cfg.Gid } else { "0" }
            $urlCsv = "https://docs.google.com/spreadsheets/d/$($cfg.SpreadsheetId)/export?format=csv&gid=$gid"
            $resp = Invoke-WebRequest -Uri $urlCsv -TimeoutSec 8 -UseBasicParsing
            $bytesResposta = $resp.RawContentStream.ToArray()
            $textoUtf8 = [System.Text.Encoding]::UTF8.GetString($bytesResposta)
            $linhas = $textoUtf8 | ConvertFrom-Csv
            if ($linhas -and $linhas.Count -gt 0) {
                $linhas | Export-Csv -Path $script:ArquivoVersoesCache -NoTypeInformation -Encoding UTF8
                $origem = "online"
            }
        } catch {
            $avisos.Add("Nao foi possivel buscar a planilha de sistemas eleitorais online: $($_.Exception.Message)") | Out-Null
            $linhas = $null
        }
    }

    if (-not $linhas -and (Test-Path $script:ArquivoVersoesCache)) {
        $avisos.Add("Usando cache local de sistemas eleitorais (ultima planilha baixada com sucesso).") | Out-Null
        $linhas = Import-Csv -Path $script:ArquivoVersoesCache
        $origem = "cache"
    }

    if (-not $linhas) {
        return ([PSCustomObject]@{ Ok = $false; Origem = $origem; Contagem = 0; Avisos = @($avisos); Erro = "Nenhuma tabela de versoes/pacotes disponivel (nem online, nem cache local)."; Pacotes = @() } | ConvertTo-Json -Depth 6 -Compress)
    }

    foreach ($l in $linhas) {
        $sistema = if ($l.Sistema) { $l.Sistema.ToUpper().Trim() } else { $null }
        $versao  = if ($l.Versao) { $l.Versao.Trim() } else { $null }
        if (-not $sistema -or -not $versao) { continue }

        $script:TabelaVersoes["$sistema|$versao"] = [PSCustomObject]@{ NomeAmigavel = $l.NomeAmigavel }

        $ehAtual = $l.Atual -and @("SIM", "S", "TRUE", "1", "X") -contains $l.Atual.ToUpper().Trim()
        if ($ehAtual) { $script:VersaoAtualPorSistema[$sistema] = $versao }

        if ($l.LinkDrive -and $l.PastaDestino) {
            $script:TabelaPacotes.Add([PSCustomObject]@{
                Pacote          = Resolve-NomeExibicaoSistema $sistema
                Sistema         = $sistema
                NomeAmigavel    = $l.NomeAmigavel
                IdArquivo       = Resolve-IdArquivoDrive $l.LinkDrive
                PastaDestino    = ConvertTo-CaminhoRelativoInstSeg $l.PastaDestino
                Versao          = $versao
                NomeArquivo     = if ($l.NomeArquivo) { $l.NomeArquivo.Trim() } else { $null }
                Hash            = if ($l.Hash) { $l.Hash.Trim().ToUpper() } else { $null }
                TamanhoEsperado = $(
                    $tmp = 0L
                    if ($l.Tamanho -and [long]::TryParse($l.Tamanho.Trim(), [ref]$tmp)) { $tmp } else { $null }
                )
            }) | Out-Null
        }
    }

    return ([PSCustomObject]@{
        Ok                    = $true
        Origem                = $origem
        Contagem              = $script:TabelaPacotes.Count
        Avisos                = @($avisos)
        Erro                  = $null
        Pacotes               = $script:TabelaPacotes
        # TabelaVersoes/VersaoAtualPorSistema tambem vao no retorno - o
        # CLIENTE precisa deles pra replicar Add-LinhaGrid (nome amigavel
        # + destaque verde/vermelho de versao atualizada/desatualizada na
        # grade principal), nao so a lista de pacotes baixaveis. Hashtable
        # vira objeto JSON normal (ConvertFrom-Json do lado cliente
        # devolve PSCustomObject, nao Hashtable - o cliente reconverte).
        TabelaVersoes         = $script:TabelaVersoes
        VersaoAtualPorSistema = $script:VersaoAtualPorSistema
    } | ConvertTo-Json -Depth 6 -Compress)
}

function Get-SistemasEleitoraisExtra {
    <#
        Devolve $script:SistemasEleitoraisExtra (schema das colunas
        dinamicas de sistemas eleitorais - Bitlocker/Gedai/Holocron/
        Transportador etc.) como STRING JSON (array de PSCustomObject,
        mesmo bug de serializacao de sempre). O CLIENTE precisa desse
        schema pra montar as colunas dinamicas da grade principal (nome
        da coluna, titulo, largura) sem duplicar essa definicao em dois
        arquivos - fica so aqui no servidor, fonte unica de verdade
        (mesma fonte que o $script:scriptBlock da varredura ja usa pra
        essas mesmas propriedades).
    #>
    return (@($script:SistemasEleitoraisExtra) | ConvertTo-Json -Depth 6 -Compress)
}

function Get-CaminhosCachePacote {
    <#
        Monta os 3 caminhos de cache local NO SERVIDOR de um pacote: o
        arquivo baixado em si e os dois sidecars (nome original vindo do
        Content-Disposition do Drive, hash MD5 ja calculado) - fica em
        E:\ScanZonas\CacheDownloads, COMPARTILHADO entre todos os
        tecnicos (tambem acessivel do lado cliente via
        \\POLICY-SERVER.tre-ma.gov.br\ScanZonas\CacheDownloads, ver
        $script:PastaCacheDownloadsUnc): um pacote baixado uma vez por
        qualquer um fica em cache pra todo mundo, nao so pra quem baixou.
    #>
    param($Pacote)
    $nomeArquivoCache = "$($Pacote.IdArquivo)_$($Pacote.Pacote -replace '[\\/:*?"<>|]', '_')"
    $base = Join-Path $script:PastaCacheDownloadsServidor $nomeArquivoCache
    return [PSCustomObject]@{
        ArquivoLocal = $base
        ArquivoNome  = "$base.nome"
        ArquivoHash  = "$base.md5"
    }
}

$script:scriptBlockBaixarPacote = {
    <#
        Corpo do job de DOWNLOAD (so download - ver a nota grande acima
        de $script:EstadoPacotes sobre por que a copia pro InstSeg NAO
        acontece mais aqui), executado num runspace em segundo plano
        (ver Start-BaixarPacote). Roda ISOLADO - nao enxerga NENHUMA
        funcao definida no resto deste arquivo (mesma restricao ja
        confirmada e documentada no $script:scriptBlock da varredura,
        por isso todo helper que precisa e redefinido aqui dentro,
        aninhado).

        Reescrito em relacao ao Invoke-AcaoBaixarPacote/Invoke-Download*
        originais: sem $GridStatus/$LinhaIndice/MessageBox/Add-Log (UI
        que so existe do lado cliente) - o progresso vira
        $EstadoJob.Texto, avisos viram $EstadoJob.Avisos, e o resultado
        final vira $EstadoJob.Sucesso/Erro/ArquivoCacheUnc/
        NomeArquivoOriginal. Tambem sem os wrappers "ComDoEvents"
        (Write-BlocoStreamComDoEvents) - so existiam pra bombear
        DoEvents e nao travar a janela WinForms; aqui, sem thread de UI
        nenhuma, um Stream.Write() sincrono normal basta.
    #>
    param($EstadoJob, $Pacote, $PastaCacheDownloads, $PastaCacheDownloadsUnc)

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

    function Get-CaminhosCachePacote {
        param($Pacote)
        $nomeArquivoCache = "$($Pacote.IdArquivo)_$($Pacote.Pacote -replace '[\\/:*?"<>|]', '_')"
        $base = Join-Path $PastaCacheDownloads $nomeArquivoCache
        return [PSCustomObject]@{ ArquivoLocal = $base; ArquivoNome = "$base.nome"; ArquivoHash = "$base.md5"; NomeArquivoCache = $nomeArquivoCache }
    }

    function Invoke-DownloadArquivoComProgresso {
        param([string]$Url, [System.Net.CookieContainer]$Cookies, [string]$DestinoLocal, [string]$NomePacote, $EstadoJob)

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
                            $EstadoJob.Texto = "Baixando '$NomePacote': $percent% ($mbLido / $mbTotal MB, $velocidade MB/s)"
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
        param([string]$FileId, [string]$DestinoLocal, [string]$NomePacote, $EstadoJob)

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

        return (Invoke-DownloadArquivoComProgresso -Url $urlFinal -Cookies $sessaoWeb.Cookies -DestinoLocal $DestinoLocal -NomePacote $NomePacote -EstadoJob $EstadoJob)
    }

    try {
        if (-not $Pacote -or -not $Pacote.IdArquivo) { throw "Pacote sem ID de arquivo do Drive valido." }

        $caminhos = Get-CaminhosCachePacote -Pacote $Pacote

        if (-not (Test-Path $PastaCacheDownloads)) {
            New-Item -ItemType Directory -Path $PastaCacheDownloads -Force | Out-Null
        }

        if (Test-Path $caminhos.ArquivoLocal) {
            $EstadoJob.Texto = "Ja em cache no servidor - pulando download..."
            $nomeArquivoOriginal = if (Test-Path $caminhos.ArquivoNome) { (Get-Content -Path $caminhos.ArquivoNome -Raw -Encoding UTF8).Trim() } else { $null }
        } else {
            $EstadoJob.Texto = "Baixando do Google Drive..."
            try {
                $nomeArquivoOriginal = Invoke-DownloadGoogleDrivePublico -FileId $Pacote.IdArquivo -DestinoLocal $caminhos.ArquivoLocal -NomePacote $Pacote.Pacote -EstadoJob $EstadoJob
            } catch {
                if (Test-Path $caminhos.ArquivoLocal) { Remove-Item $caminhos.ArquivoLocal -Force -ErrorAction SilentlyContinue }
                throw
            }
            if ($nomeArquivoOriginal) {
                Set-Content -Path $caminhos.ArquivoNome -Value $nomeArquivoOriginal -Encoding UTF8
            } else {
                [void]$EstadoJob.Avisos.Add("Nao veio o nome original do arquivo no cabecalho do Drive - o cliente vai usar o nome do pacote da planilha como nome de arquivo no destino.")
            }
        }

        $hashLocal = if (Test-Path $caminhos.ArquivoHash) {
            (Get-Content -Path $caminhos.ArquivoHash -Raw -Encoding UTF8).Trim()
        } else {
            $EstadoJob.Texto = "Calculando hash MD5 (no servidor)..."
            $h = (Get-FileHash -Path $caminhos.ArquivoLocal -Algorithm MD5).Hash
            Set-Content -Path $caminhos.ArquivoHash -Value $h -Encoding UTF8
            $h
        }
        if ($Pacote.Hash -and $hashLocal -ne $Pacote.Hash) {
            [void]$EstadoJob.Avisos.Add("ATENCAO: hash MD5 do pacote baixado NAO confere com o oficial da planilha (baixado=$hashLocal planilha=$($Pacote.Hash)) - o download pode ter vindo corrompido. Apague o cache no servidor ($($caminhos.ArquivoLocal)) e baixe de novo.")
        }

        $EstadoJob.ArquivoCacheUnc = Join-Path $PastaCacheDownloadsUnc $caminhos.NomeArquivoCache
        $EstadoJob.NomeArquivoOriginal = $nomeArquivoOriginal
        $EstadoJob.Sucesso = $true
        $tamanhoMb = [Math]::Round((Get-Item -LiteralPath $caminhos.ArquivoLocal).Length / 1MB, 1)
        $EstadoJob.Texto = "Download concluido ($tamanhoMb MB) - pronto pra copiar (a copia pro InstSeg roda na propria estacao do tecnico, nao aqui)."
    } catch {
        $EstadoJob.Sucesso = $false
        $EstadoJob.Erro = $_.Exception.Message
        $EstadoJob.Texto = "ERRO: $($_.Exception.Message)"
    } finally {
        $EstadoJob.Concluido = $true
    }
}

function Start-BaixarPacote {
    <#
        Dispara, num runspace em segundo plano (SEM pool - e sempre 1 job
        por chamada, diferente da varredura), SO O DOWNLOAD do pacote do
        Google Drive pro cache compartilhado no servidor
        (E:\ScanZonas\CacheDownloads). Devolve NA HORA - Get-StatusPacote
        acompanha por polling.

        A copia final pro \\IP\InstSeg\<PastaDestino> da maquina de
        destino NAO acontece aqui (ver a nota grande sobre duplo-salto
        do Kerberos acima de $script:EstadoPacotes) - roda na propria
        estacao do tecnico, que ja tem acesso direto (1 salto so) tanto
        ao cache compartilhado (\\POLICY-SERVER...\ScanZonas\
        CacheDownloads) quanto ao InstSeg de qualquer zona, do mesmo
        jeito que uma copia manual de arquivo ja funciona hoje - ver
        VisaoPacotes.psm1 (modulo cliente, sem remoting).

        $JobId e um GUID gerado pelo CLIENTE (nao pelo servidor) - assim
        o cliente ja sabe a chave pra comecar a fazer polling
        imediatamente depois de chamar esta funcao.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$JobId,
        [Parameter(Mandatory)]
        [PSCustomObject]$Pacote
    )

    $estadoJob = [hashtable]::Synchronized(@{
        Texto               = "Iniciando..."
        Concluido           = $false
        Sucesso             = $false
        Erro                = $null
        ArquivoCacheUnc     = $null
        NomeArquivoOriginal = $null
        Avisos              = [System.Collections.ArrayList]::Synchronized((New-Object System.Collections.ArrayList))
    })
    $script:EstadoPacotes[$JobId] = $estadoJob

    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:scriptBlockBaixarPacote).AddArgument($estadoJob).AddArgument($Pacote).AddArgument($script:PastaCacheDownloadsServidor).AddArgument($script:PastaCacheDownloadsUnc)
    $handle = $ps.BeginInvoke()

    # So pra manter uma referencia viva (sem isso o GC poderia coletar o
    # [powershell] no meio da execucao) - Get-StatusPacote nao le Pipe/
    # Handle, so os libera (Dispose) quando o job termina.
    $estadoJob.Pipe = $ps
    $estadoJob.Handle = $handle

    return $true
}

function Get-StatusPacote {
    <#
        Devolve o snapshot ATUAL (nao um delta - so existe 1 job por
        chamada, entao devolver o estado inteiro toda vez e simples e
        barato) do job iniciado por Start-BaixarPacote. STRING JSON pelo
        mesmo motivo de sempre (Avisos e um array).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$JobId
    )

    $estadoJob = $script:EstadoPacotes[$JobId]
    if (-not $estadoJob) {
        return ([PSCustomObject]@{ Encontrado = $false; Texto = ""; Concluido = $false; Sucesso = $false; Erro = "Job nao encontrado nesta sessao (se a sessao foi reconectada no meio, o progresso anterior se perdeu - inicie o download de novo)."; Avisos = @(); ArquivoCacheUnc = $null; NomeArquivoOriginal = $null } | ConvertTo-Json -Depth 6 -Compress)
    }

    if ($estadoJob.Concluido -and $estadoJob.Pipe) {
        try { $estadoJob.Pipe.Dispose() } catch {}
        $estadoJob.Pipe = $null
    }

    return ([PSCustomObject]@{
        Encontrado          = $true
        Texto               = $estadoJob.Texto
        Concluido           = $estadoJob.Concluido
        Sucesso             = $estadoJob.Sucesso
        Erro                = $estadoJob.Erro
        Avisos              = @($estadoJob.Avisos)
        ArquivoCacheUnc     = $estadoJob.ArquivoCacheUnc
        NomeArquivoOriginal = $estadoJob.NomeArquivoOriginal
    } | ConvertTo-Json -Depth 6 -Compress)
}

# ============================================================
# FASE 7: escritas no Apps Script (request/resposta unico, sem
# polling). Os 3 Web Apps (atualizar Zonas, registrar resultado de
# Campanha, enviar arquivo ao Drive) ja estavam configurados neste
# servidor antes desta migracao (E:\ScanZonas\*_config.json, mesma
# situacao do versoes_config.json na Fase 6) - so os LEITORES (Get-
# Config*) sao migrados; os assistentes de PRIMEIRA CONFIGURACAO
# (Read-Config*Interativo, InputBox) ficam de fora por enquanto -
# reconfigurar continua sendo feito direto no servidor.
# ============================================================

function Get-ConfigZonasWebApp {
    if (-not (Test-Path $script:ArquivoConfigZonasWebApp)) { return $null }
    try {
        $cfg = Get-Content -Path $script:ArquivoConfigZonasWebApp -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.UrlWebApp -and $cfg.Token) { return $cfg }
    } catch {}
    return $null
}

function Get-ConfigCampanhasWebApp {
    if (-not (Test-Path $script:ArquivoConfigCampanhasWebApp)) { return $null }
    try {
        $cfg = Get-Content -Path $script:ArquivoConfigCampanhasWebApp -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.UrlWebApp -and $cfg.Token) { return $cfg }
    } catch {}
    return $null
}

function Get-ConfigEnvioDrive {
    if (-not (Test-Path $script:ArquivoConfigDrive)) { return $null }
    try {
        $cfg = Get-Content -Path $script:ArquivoConfigDrive -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($cfg.UrlWebApp -and $cfg.Token) { return $cfg }
    } catch {}
    return $null
}

function Send-AtualizacaoZonaViaAppsScript {
    <#
        Manda a Substituta/Observacao de uma zona por HTTP POST ao Web
        App do Apps Script, que grava direto nas colunas D/E da linha
        correspondente na planilha "Zonas".

        Reestruturada em relacao ao original: ja recebia so parametros
        explicitos (nada de controle WinForms), so precisou perder o
        parametro $Config (resolvido aqui dentro via
        Get-ConfigZonasWebApp, ja que roda no servidor agora) e trocar
        Add-Log + $true/$false por um retorno estruturado
        [PSCustomObject]@{ Ok; Mensagem }.
    #>
    param(
        [Parameter(Mandatory)][int]$Zona,
        [string]$Substituta = "",
        [string]$Observacao = ""
    )

    $cfg = Get-ConfigZonasWebApp
    if (-not $cfg) {
        return [PSCustomObject]@{ Ok = $false; Mensagem = "Atualizacao da planilha de zonas ainda nao configurada neste servidor ($script:ArquivoConfigZonasWebApp)." }
    }

    $zonaPad = "{0:D3}" -f $Zona
    try {
        $corpo = @{ token = $cfg.Token; zona = $zonaPad; rede = $Substituta; observacao = $Observacao } | ConvertTo-Json -Compress
        # Bytes UTF-8 explicitos (nao a string direto) - o PowerShell 5.1
        # nao usa UTF-8 sozinho pra converter uma string com acento pro
        # corpo da requisicao, corrompendo Observacao com acento.
        $corpoBytesUtf8 = [System.Text.Encoding]::UTF8.GetBytes($corpo)
        $resp = Invoke-RestMethod -Uri $cfg.UrlWebApp -Method Post -Body $corpoBytesUtf8 -ContentType "application/json; charset=utf-8" -TimeoutSec 20
    } catch {
        # O Web App do Apps Script as vezes devolve erro HTTP MESMO
        # quando o doPost ja gravou certinho (comum logo apos implantar
        # um Web App novo) - antes de considerar falha de verdade,
        # confere se o valor foi mesmo gravado buscando a planilha de
        # novo.
        $resultadoImport = Import-TabelaZonas
        if ($resultadoImport.Ok) {
            $zonaInfo = $script:TabelaZonas[$Zona]
            $substitutaGravada = if ($zonaInfo -and $zonaInfo.Substituta) { $zonaInfo.Substituta.Trim() } else { "" }
            $obsGravada = if ($zonaInfo -and $zonaInfo.Observacao) { $zonaInfo.Observacao.Trim() } else { "" }
            if ($substitutaGravada -eq $Substituta.Trim() -and $obsGravada -eq $Observacao.Trim()) {
                return [PSCustomObject]@{ Ok = $true; Mensagem = "Confirmado: zona $zonaPad foi gravada na planilha apesar do erro HTTP (falso alarme conhecido do Apps Script)." }
            }
        }
        return [PSCustomObject]@{ Ok = $false; Mensagem = "Falha ao atualizar zona $zonaPad na planilha: $($_.Exception.Message)" }
    }

    if (-not $resp.ok) {
        return [PSCustomObject]@{ Ok = $false; Mensagem = "Planilha recusou atualizar a zona $zonaPad`: $($resp.erro)" }
    }
    return [PSCustomObject]@{ Ok = $true; Mensagem = "Zona $zonaPad atualizada na planilha." }
}

function Send-ResultadoCampanhaZona {
    <#
        Manda o resultado JA CALCULADO de uma verificacao de campanha por
        HTTP POST ao Web App do Apps Script, que acrescenta uma linha na
        aba RESULTADOS-CAMPANHAS da planilha.

        Reestruturada: o original lia total/aptas/maquinas DIRETO das
        linhas de um DataGridView (via $GridZona) e a campanha de um
        ComboBox (via $ComboCampanha.SelectedIndex) - nenhum dos dois
        atravessa remoting. Aqui o CLIENTE ja manda tudo pronto (a grade
        e o combo continuam existindo do lado cliente, sao so lidos ANTES
        de chamar esta funcao, nao durante). $Tecnico tambem vem do
        cliente ($env:USERNAME de la) em vez de ler daqui - mais simples
        e robusto do que depender de como o WinRM propaga variaveis de
        ambiente pra dentro da sessao.
    #>
    param(
        [Parameter(Mandatory)][int]$Zona,
        [Parameter(Mandatory)][string]$NomeCampanha,
        [Parameter(Mandatory)][int]$Total,
        [Parameter(Mandatory)][int]$Aptas,
        [string]$MaquinasAptas = "",
        [Parameter(Mandatory)][string]$Tecnico
    )

    $cfg = Get-ConfigCampanhasWebApp
    if (-not $cfg) {
        return [PSCustomObject]@{ Ok = $false; Mensagem = "Envio de resultado de campanha ainda nao configurado neste servidor ($script:ArquivoConfigCampanhasWebApp)." }
    }

    $resolucaoZona = Resolve-RedeDaZona -Zona $Zona
    $sedeTxt = if ($resolucaoZona.Sede) { $resolucaoZona.Sede } else { "" }
    $zonaPad = "{0:D3}" -f $Zona

    try {
        $corpo = @{
            token         = $cfg.Token
            zona          = $zonaPad
            sede          = $sedeTxt
            campanha      = $NomeCampanha
            total         = $Total
            aptas         = $Aptas
            tecnico       = $Tecnico
            maquinasAptas = $MaquinasAptas
        } | ConvertTo-Json -Compress
        # 60s (nao 20s) de proposito - a PRIMEIRA chamada a um Web App
        # recem-implantado pode demorar bem mais que o normal pro Google
        # "esquentar" o ambiente de execucao (confirmado na pratica no
        # ScannerRedeZona.ps1 original).
        $corpoBytesUtf8 = [System.Text.Encoding]::UTF8.GetBytes($corpo)
        $resp = Invoke-RestMethod -Uri $cfg.UrlWebApp -Method Post -Body $corpoBytesUtf8 -ContentType "application/json; charset=utf-8" -TimeoutSec 60
    } catch {
        # Mesmo caso do Send-AtualizacaoZonaViaAppsScript - confere se
        # gravou mesmo assim antes de considerar falha de verdade.
        # Get-ResultadosCampanhas (definida mais acima NESTE MESMO
        # arquivo) e chamada aqui como funcao local normal, nao via
        # Invoke-Command - ainda assim devolve STRING JSON (e o
        # contrato dela pra QUALQUER chamador, direto ou remoto),
        # entao precisa do ConvertFrom-Json mesmo sem cruzar remoting.
        $todosVerificacao = (Get-ResultadosCampanhas | ConvertFrom-Json)
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

function Send-ArquivoParaGoogleDriveViaAppsScript {
    <#
        Manda um arquivo (nome + conteudo em base64) por HTTP POST ao Web
        App do Apps Script, que grava direto na pasta do Drive.

        Reestruturada: o original recebia um [System.IO.FileInfo] e lia
        os bytes AQUI dentro - nao da mais, porque o arquivo tipicamente
        vem de uma maquina de ZONA (ex: \\IP\InstSeg\CVC\<host>.cvc, usado
        por Invoke-AcaoEnviarCvcDrive) e ler isso de dentro da sessao
        remota do servidor esbarraria no MESMO duplo-salto de Kerberos ja
        documentado na Fase 6 (SMB pra uma terceira maquina). Por isso
        quem chama (o cliente, que ja acessa a maquina de zona direto,
        1 salto so) le o arquivo e converte pra base64 ANTES de chamar
        esta funcao - aqui so falta o POST em si (chamada a API do
        Google, centralizada por preferencia do usuario, nao por
        limitacao tecnica desta parte).

        ATENCAO: arquivos GRANDES podem esbarrar no limite padrao de
        tamanho de mensagem do WinRM (MaxEnvelopeSizekb, ~500KB) - CVCs
        sao tipicamente pequenos (arquivo por maquina, nao a zona
        inteira), entao nao deve ser problema na pratica, mas se um dia
        precisar mandar algo maior, ajustar essa quota no servidor (ver
        Fase 8) ou repensar pra upload em pedacos.
    #>
    param(
        [Parameter(Mandatory)][string]$NomeArquivo,
        [Parameter(Mandatory)][string]$ConteudoBase64,
        [int]$TimeoutSec = 30
    )

    $cfg = Get-ConfigEnvioDrive
    if (-not $cfg) {
        return [PSCustomObject]@{ Ok = $false; Mensagem = "Envio automatico ao Google Drive ainda nao configurado neste servidor ($script:ArquivoConfigDrive)."; Url = $null }
    }

    try {
        $corpo = @{ token = $cfg.Token; nomeArquivo = $NomeArquivo; conteudoBase64 = $ConteudoBase64 } | ConvertTo-Json -Compress
        # Bytes UTF-8 explicitos - mesmo motivo de sempre (nomeArquivo
        # pode ter acento).
        $corpoBytesUtf8 = [System.Text.Encoding]::UTF8.GetBytes($corpo)
        $resp = Invoke-RestMethod -Uri $cfg.UrlWebApp -Method Post -Body $corpoBytesUtf8 -ContentType "application/json; charset=utf-8" -TimeoutSec $TimeoutSec
    } catch {
        return [PSCustomObject]@{ Ok = $false; Mensagem = "Falha ao enviar '$NomeArquivo' via Apps Script: $($_.Exception.Message)"; Url = $null }
    }

    if (-not $resp.ok) {
        return [PSCustomObject]@{ Ok = $false; Mensagem = "Apps Script recusou o envio de '$NomeArquivo': $($resp.erro)"; Url = $null }
    }

    return [PSCustomObject]@{ Ok = $true; Mensagem = "Arquivo '$NomeArquivo' enviado ao Google Drive."; Url = $resp.url }
}

# ============================================================
# FASE B: maquinas "possivelmente desligadas" via OCS Inventory +
# Wake-on-LAN. Ambos rodam aqui no servidor porque nao esbarram no
# duplo-salto de Kerberos (sao chamadas de API HTTP/UDP pro OCS
# Inventory e pra rede da zona, nao SMB/autenticacao Windows contra
# uma terceira maquina) - o mesmo padrao ja usado pelo $script:
# scriptBlock da varredura, que ja consulta o OCS Inventory direto
# daqui. Wake-on-LAN especificamente FAZ SENTIDO ficar centralizado
# aqui pelo MESMO motivo que centralizou a varredura desde o inicio:
# o magic packet e mandado como BROADCAST UDP, exatamente o tipo de
# trafego que a Secao de Seguranca Cibernetica pediu pra concentrar
# numa unica maquina confiavel.
# ============================================================

function Resolve-ModeloAmigavel {
    param([string]$ModeloOriginal)
    if (-not $ModeloOriginal) { return $null }
    if ($script:MapaModelos.ContainsKey($ModeloOriginal)) { return $script:MapaModelos[$ModeloOriginal] }
    return $ModeloOriginal
}

function Get-OcsComputadoresPorIp {
    <#
        Acha as maquinas do OCS Inventory cadastradas numa rede /24 fazendo
        uma busca EXATA por IP (coluna "IPADDR" da tabela hardware) pra
        cada um dos 254 enderecos, em paralelo - confirmado na pratica que
        /computers/search aceita IPADDR como :searchCriteria.

        Como a busca e por IP (nao por padrao de nome), dispensa
        Test-HostnamePertenceZona pra decidir se uma maquina "e desta
        zona" - o ULTIMO IP CONHECIDO (hardware.IPADDR) ja fica dentro da
        rede fisica da propria zona/predio, mesmo em rede compartilhada
        entre varias zonas.

        Relocada do ScannerRedeZona.ps1 original sem mudanca de logica -
        so perdeu o polling com DoEvents (nao ha thread de UI aqui pra
        proteger) e o Add-Log de aviso de erro parcial (quem chama decide
        o que fazer com uma lista eventualmente incompleta).
    #>
    param([string]$PrefixoRede, [int]$TimeoutSec = 8, [int]$Paralelismo = 40)

    $scriptBlockPorIp = {
        param($UrlBase, $Ip, $TimeoutSec)
        try {
            $urlBusca = "$UrlBase/computers/search?start=0&limit=5&IPADDR=$Ip"
            $respBusca = Invoke-RestMethod -Uri $urlBusca -TimeoutSec $TimeoutSec
            $ids = @($respBusca) | Where-Object { $_.ID } | Select-Object -ExpandProperty ID -Unique
            if (@($ids).Count -eq 0) { return [PSCustomObject]@{ Comps = @(); Erro = $null } }

            $comps = New-Object System.Collections.Generic.List[object]
            $erroDetalhe = $null
            foreach ($id in $ids) {
                try {
                    $respHw = Invoke-RestMethod -Uri "$UrlBase/computer/$id/hardware" -TimeoutSec $TimeoutSec
                    $hw = $respHw."$id".hardware
                    if (-not $hw -or -not $hw.NAME) { continue }

                    $bios = $null
                    try {
                        $respBios = Invoke-RestMethod -Uri "$UrlBase/computer/$id/bios" -TimeoutSec $TimeoutSec
                        $bios = $respBios."$id".bios
                    } catch {}

                    $registry = $null
                    try {
                        $respReg = Invoke-RestMethod -Uri "$UrlBase/computer/$id/registry" -TimeoutSec $TimeoutSec
                        $registry = $respReg."$id".registry
                    } catch {}

                    $comps.Add([PSCustomObject]@{ hardware = $hw; bios = $bios; registry = $registry })
                } catch {
                    $erroDetalhe = $_.Exception.Message
                }
            }
            return [PSCustomObject]@{ Comps = $comps; Erro = $erroDetalhe }
        } catch {
            return [PSCustomObject]@{ Comps = @(); Erro = $_.Exception.Message }
        }
    }

    $sessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $pool = [runspacefactory]::CreateRunspacePool(1, $Paralelismo, $sessionState, $Host)
    $pool.Open()

    $encontrados = New-Object System.Collections.Generic.List[object]
    try {
        $jobs = New-Object System.Collections.Generic.List[object]
        for ($i = 1; $i -le 254; $i++) {
            $ip = "$PrefixoRede$i"
            $ps = [powershell]::Create()
            $ps.RunspacePool = $pool
            [void]$ps.AddScript($scriptBlockPorIp).AddArgument($script:UrlOcsApiBase).AddArgument($ip).AddArgument($TimeoutSec)
            $jobs.Add([PSCustomObject]@{ Pipe = $ps; Handle = $ps.BeginInvoke() })
        }

        while ($jobs | Where-Object { -not $_.Handle.IsCompleted }) {
            Start-Sleep -Milliseconds 50
        }

        foreach ($job in $jobs) {
            $r = $job.Pipe.EndInvoke($job.Handle)
            $job.Pipe.Dispose()
            if ($r.Erro) { continue }
            foreach ($comp in $r.Comps) { $encontrados.Add($comp) }
        }
    } finally {
        $pool.Close()
        $pool.Dispose()
    }

    return $encontrados
}

function Get-MaquinasDesligadasOcs {
    <#
        Compara o cadastro do OCS Inventory pra rede da zona com o que a
        varredura ja encontrou online, pra achar maquinas cadastradas que
        nao responderam (candidatas a "desligada/desconectada") - e de
        quebra corrige o Hostname de maquinas que responderam mas o DNS
        reverso/NetBIOS nao resolveram (cruzando pelo ultimo IP conhecido
        no OCS).

        Reestruturada em relacao ao Invoke-BuscarDesligadosOcs original:
        recebe $ResultadosOnline (so as entradas Online=true da varredura
        ja feita, mandadas pelo cliente) em vez de ler $script:Resultados
        direto (que so existe do lado cliente agora) - e devolve as
        CORRECOES e as DESLIGADAS pro cliente aplicar na propria copia
        local, em vez de mutar `$script:Resultados`/`$script:
        MaquinasDesligadasOcs` e chamar `Reconstruir-Grid` (que so
        existem do lado cliente). STRING JSON no retorno pelo motivo de
        sempre (Correcoes/Desligadas sao listas de PSCustomObject).
    #>
    param(
        [Parameter(Mandatory)]
        [int]$Zona,
        [bool]$RedeCompartilhada = $false,
        [Parameter(Mandatory)]
        [object[]]$ResultadosOnline
    )

    $zonaPad = "{0:D3}" -f $Zona
    $padroes = @("ZMA$zonaPad", "CMA$zonaPad", "ZE-$zonaPad", "ZE$zonaPad")
    $resolucaoAtual = Resolve-RedeDaZona -Zona $Zona

    $comps = Get-OcsComputadoresPorIp -PrefixoRede $resolucaoAtual.Prefixo

    # Corrige o Hostname (e Modelo/VersaoSis/sistemas extra, se ainda "-")
    # de quem respondeu a varredura mas ficou sem nome resolvido - cruza
    # pelo ULTIMO IP CONHECIDO no OCS. Precisa rodar ANTES de montar
    # $nomesOnline logo abaixo, senao essas maquinas (agora com nome
    # conhecido) seriam contadas de novo como "possivelmente desligadas"
    # por engano.
    $correcoes = New-Object System.Collections.Generic.List[object]
    $resultadosCorrigidos = New-Object System.Collections.Generic.List[object]
    foreach ($cand in $ResultadosOnline) {
        if (-not $cand.Online -or ($cand.Hostname -and $cand.Hostname -ne "(sem resolucao de nome)")) {
            $resultadosCorrigidos.Add($cand)
            continue
        }

        $compAchado = $null
        foreach ($comp in $comps) {
            if ($comp.hardware.IPADDR -eq $cand.IP -and $comp.hardware.NAME) { $compAchado = $comp; break }
        }
        if (-not $compAchado) { $resultadosCorrigidos.Add($cand); continue }
        $hwComp = $compAchado.hardware

        $modeloNovo = $cand.Modelo
        $biosComp = @($compAchado.bios) | Select-Object -First 1
        if ($biosComp -and $biosComp.SMODEL -and $modeloNovo -eq "-") {
            $modeloNovo = Resolve-ModeloAmigavel -ModeloOriginal $biosComp.SMODEL
        }
        $versaoSisNovo = $cand.VersaoSis
        $registryComp = @($compAchado.registry)
        $entradaSisComp = @($registryComp) | Where-Object { $_.NAME -eq "VERSAO_SIS" } | Select-Object -First 1
        if ($entradaSisComp -and $entradaSisComp.REGVALUE -and $versaoSisNovo -eq "-") {
            $versaoSisNovo = $entradaSisComp.REGVALUE
        }
        $pertenceZonaNovo = $cand.PertenceZonaAtual
        if ($RedeCompartilhada) {
            $pertenceZonaNovo = Test-HostnamePertenceZona -Hostname $hwComp.NAME -Zona $Zona
        }

        $copia = [PSCustomObject]@{
            IP                 = $cand.IP
            Online             = $cand.Online
            Hostname           = $hwComp.NAME
            TempoMs            = $cand.TempoMs
            PossivelImpressora = $cand.PossivelImpressora
            PortasAbertas      = $cand.PortasAbertas
            DetectadoPor       = "$($cand.DetectadoPor) (nome via OCS Inventory)"
            VncAtivo           = $cand.VncAtivo
            RcIvantiAtivo      = $cand.RcIvantiAtivo
            VersaoSis          = $versaoSisNovo
            Modelo             = $modeloNovo
            EhGateway          = $cand.EhGateway
            EhNobreakCentral   = $cand.EhNobreakCentral
            EhTelefoneVoip     = $cand.EhTelefoneVoip
            PertenceZonaAtual  = $pertenceZonaNovo
        }
        foreach ($sisExtra in $script:SistemasEleitoraisExtra) {
            $valorExtraNovo = $cand.($sisExtra.Propriedade)
            $entradaExtraComp = @($registryComp) | Where-Object { $_.NAME -eq $sisExtra.Chave } | Select-Object -First 1
            if ($entradaExtraComp -and $entradaExtraComp.REGVALUE -and $valorExtraNovo -eq "-") {
                $valorExtraNovo = $entradaExtraComp.REGVALUE
            }
            $copia | Add-Member -NotePropertyName $sisExtra.Propriedade -NotePropertyValue $valorExtraNovo
        }
        $correcoes.Add($copia)
        $resultadosCorrigidos.Add($copia)
    }

    $nomesOnline = @{}
    foreach ($r in $resultadosCorrigidos) {
        if ($r.Online -and $r.Hostname -and $r.Hostname -ne "(sem resolucao de nome)") {
            $nomesOnline[(($r.Hostname -split '\.')[0]).ToUpper()] = $true
        }
    }

    $desligadas = New-Object System.Collections.Generic.List[object]
    $nomesJaAdicionados = @{}
    foreach ($comp in $comps) {
        $hw = $comp.hardware
        # Registro incompleto/orfao no proprio OCS (sem nome, sem IP) -
        # nao da pra mostrar como "possivelmente desligado" util, pula.
        if (-not $hw -or -not $hw.NAME) { continue }
        $nomeOcs = $hw.NAME
        $nomeCurto = ($nomeOcs -split '\.')[0]

        # Rede compartilhada entre varias zonas - so o padrao de nome
        # (ZMA075 etc) separa qual maquina e desta zona especifica.
        if ($RedeCompartilhada) {
            $nomeUpper = if ($nomeOcs) { $nomeOcs.ToUpper() } else { "" }
            $bateNome = $false
            foreach ($padrao in $padroes) {
                if ($nomeUpper.Contains($padrao)) { $bateNome = $true; break }
            }
            if (-not $bateNome) { continue }
        }

        if ($nomesOnline.ContainsKey($nomeCurto.ToUpper())) { continue }
        if ($nomesJaAdicionados.ContainsKey($nomeCurto.ToUpper())) { continue }
        $nomesJaAdicionados[$nomeCurto.ToUpper()] = $true

        $bios = @($comp.bios) | Select-Object -First 1
        $modeloOriginal = if ($bios) { $bios.SMODEL } else { $null }
        $registry = @($comp.registry)
        $versaoSis = (@($registry) | Where-Object { $_.NAME -eq "VERSAO_SIS" } | Select-Object -First 1).REGVALUE

        $ultimoContatoBruto = if ($hw.LASTDATE) { $hw.LASTDATE } elseif ($hw.LASTCOME) { $hw.LASTCOME } else { $null }
        $ultimoContato = $null
        $candidatoExclusaoOcs = $false
        if ($ultimoContatoBruto) {
            $dataParseada = [DateTime]::MinValue
            if ([DateTime]::TryParseExact($ultimoContatoBruto, "yyyy-MM-dd HH:mm:ss", [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dataParseada)) {
                $ultimoContato = $dataParseada.ToString("dd/MM/yy HH:mm:ss")
                $candidatoExclusaoOcs = $dataParseada -lt (Get-Date).AddMonths(-$script:MesesParaCandidatoExclusaoOcs)
            } else {
                $ultimoContato = $ultimoContatoBruto
            }
        }
        $detectadoPor = if ($ultimoContato) { "OCS Inventory - ultimo contato $ultimoContato" } else { "OCS Inventory (sem resposta na varredura)" }
        if ($candidatoExclusaoOcs) { $detectadoPor += " (candidata a exclusao - +$($script:MesesParaCandidatoExclusaoOcs)m sem contato)" }

        $pseudo = [PSCustomObject]@{
            IP                     = if ($hw.IPADDR) { $hw.IPADDR } else { "-" }
            Online                 = $false
            Hostname               = $nomeOcs
            TempoMs                = $null
            PossivelImpressora     = $false
            PortasAbertas          = ""
            DetectadoPor           = $detectadoPor
            VncAtivo               = $false
            RcIvantiAtivo          = $false
            VersaoSis              = if ($versaoSis) { $versaoSis } else { "-" }
            Modelo                 = if ($modeloOriginal) { Resolve-ModeloAmigavel -ModeloOriginal $modeloOriginal } else { "-" }
            EhGateway              = $false
            EhNobreakCentral       = $false
            EhTelefoneVoip         = $false
            PertenceZonaAtual      = if ($RedeCompartilhada) { Test-HostnamePertenceZona -Hostname $nomeOcs -Zona $Zona } else { $true }
            PossivelmenteDesligado = $true
            HardwareId             = $hw.ID
            CandidatoExclusaoOcs   = $candidatoExclusaoOcs
            SemLinkComunicacao     = $false
        }
        foreach ($sisExtra in $script:SistemasEleitoraisExtra) {
            $entradaExtra = @($registry) | Where-Object { $_.NAME -eq $sisExtra.Chave } | Select-Object -First 1
            $valorExtra = if ($entradaExtra -and $entradaExtra.REGVALUE) { $entradaExtra.REGVALUE } else { "-" }
            $pseudo | Add-Member -NotePropertyName $sisExtra.Propriedade -NotePropertyValue $valorExtra
        }
        $desligadas.Add($pseudo)
    }

    return ([PSCustomObject]@{
        Ok                          = $true
        Correcoes                   = $correcoes
        Desligadas                  = $desligadas
        TotalNoOcs                  = $comps.Count
        MesesParaCandidatoExclusao  = $script:MesesParaCandidatoExclusaoOcs
    } | ConvertTo-Json -Depth 6 -Compress)
}

function Get-MacAddressOcs {
    <#
        Busca o endereco MAC de uma maquina no OCS Inventory (secao
        "networks" do /computer/:id). Se a maquina tiver mais de uma
        interface de rede, prioriza a que bate com o ultimo IP conhecido
        ($IpConhecido); senao usa a primeira interface com MAC
        preenchido. Devolve $null se nao achar.
    #>
    param([int]$HardwareId, [string]$IpConhecido = $null)
    if (-not $HardwareId) { return $null }

    try {
        $url = "$($script:UrlOcsApiBase)/computer/$HardwareId/networks"
        $resp = Invoke-RestMethod -Uri $url -TimeoutSec 8
        $secaoRedes = $null
        try { $secaoRedes = $resp."$HardwareId".networks } catch {}
        $redes = @($secaoRedes)
        if ($redes.Count -eq 0) { return $null }

        $candidatosMac = @("MACADDR", "MACADDRESS", "MAC")
        $candidatosIp  = @("IPADDRESS", "IPADDR", "IP")

        $redeEscolhida = $null
        if ($IpConhecido) {
            foreach ($campoIp in $candidatosIp) {
                $redeEscolhida = $redes | Where-Object { $_.$campoIp -eq $IpConhecido } | Select-Object -First 1
                if ($redeEscolhida) { break }
            }
        }
        if (-not $redeEscolhida) { $redeEscolhida = $redes | Select-Object -First 1 }

        foreach ($campoMac in $candidatosMac) {
            if ($redeEscolhida.$campoMac) { return $redeEscolhida.$campoMac }
        }
        return $null
    } catch {
        return $null
    }
}

function Send-MagicPacketWol {
    <#
        Monta e manda o "magic packet" padrao de Wake-on-LAN (6 bytes
        0xFF seguidos do MAC repetido 16x) por UDP broadcast, nas portas
        7 e 9 (as duas convencoes mais comuns).
    #>
    param([string]$MacAddress, [string]$IpBroadcast)

    $macLimpo = ($MacAddress -replace "[^0-9A-Fa-f]", "")
    if ($macLimpo.Length -ne 12) { throw "Endereco MAC invalido: '$MacAddress'" }

    $bytesMac = New-Object byte[] 6
    for ($i = 0; $i -lt 6; $i++) {
        $bytesMac[$i] = [Convert]::ToByte($macLimpo.Substring($i * 2, 2), 16)
    }

    $pacote = New-Object byte[] 102
    for ($i = 0; $i -lt 6; $i++) { $pacote[$i] = 0xFF }
    for ($rep = 0; $rep -lt 16; $rep++) {
        [Array]::Copy($bytesMac, 0, $pacote, 6 + ($rep * 6), 6)
    }

    $udp = New-Object System.Net.Sockets.UdpClient
    try {
        $udp.EnableBroadcast = $true
        foreach ($porta in @(9, 7)) {
            [void]$udp.Send($pacote, $pacote.Length, $IpBroadcast, $porta)
        }
    } finally {
        $udp.Close()
    }
}

function Invoke-AcaoLigarWol {
    <#
        Wake-on-LAN pra uma maquina "Possivelmente Desligado": busca o
        MAC no OCS Inventory e manda o magic packet pro broadcast
        direcionado da rede da zona (assume /24 - ex: IP 10.198.72.145
        -> broadcast 10.198.72.255).

        AVISO IMPORTANTE (preservado do original): so funciona se os
        roteadores entre o POLICY-SERVER e a rede da zona permitirem
        encaminhar broadcast direcionado ate aquele segmento - por
        padrao de seguranca (mitigar ataque smurf), a maioria dos
        roteadores bloqueia isso, sem como confirmar por aqui se vai
        funcionar.

        Reestruturada: recebia $Resultado (objeto de linha da grade) no
        original - agora recebe HardwareId/Ip ja extraidos, e devolve
        [PSCustomObject]@{ Ok; Mensagem } em vez de Add-Log/MessageBox.
    #>
    param(
        [Parameter(Mandatory)]
        [int]$HardwareId,
        [string]$Ip
    )

    $mac = Get-MacAddressOcs -HardwareId $HardwareId -IpConhecido $Ip
    if (-not $mac) {
        return [PSCustomObject]@{ Ok = $false; Mensagem = "Nao foi possivel obter o endereco MAC no OCS Inventory (ID $HardwareId)." }
    }
    if (-not $Ip -or $Ip -eq "-") {
        return [PSCustomObject]@{ Ok = $false; Mensagem = "Sem IP conhecido - nao da pra calcular o broadcast da rede." }
    }

    $partesIp = $Ip -split "\."
    $ipBroadcast = "$($partesIp[0]).$($partesIp[1]).$($partesIp[2]).255"

    try {
        Send-MagicPacketWol -MacAddress $mac -IpBroadcast $ipBroadcast
        return [PSCustomObject]@{ Ok = $true; Mensagem = "Pacote Wake-on-LAN enviado (MAC $mac) via broadcast $ipBroadcast, portas 7 e 9. So funciona se a rede permitir broadcast ate essa zona - sem garantia. Aguarde uns 30-60s e varra de novo pra conferir." }
    } catch {
        return [PSCustomObject]@{ Ok = $false; Mensagem = "Falha ao enviar o pacote Wake-on-LAN: $($_.Exception.Message)" }
    }
}
