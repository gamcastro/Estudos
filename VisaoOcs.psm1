<#
    VisaoOcs.psm1

    Consulta o OCS Inventory (http://inventario.tre-ma.jus.br/ocsapi/v1)
    DIRETO da estacao do tecnico, sem passar pelo POLICY-SERVER - migrada
    em 2026-08-24 (decisao com o usuario): e uma chamada HTTP SEM
    autenticacao nenhuma (nao tem token pra proteger) e a estacao do
    tecnico esta confirmada na MESMA rede do servidor OCS - nao e trafego
    de broadcast (isso continua so na varredura/Wake-on-LAN, que ficam no
    POLICY-SERVER de proposito).

    Get-MaquinasDesligadasOcsRemoto e Get-OcsComputadoresPorIp sao
    portadas quase sem mudanca de VisaoServidor.ps1 (Get-MaquinasDesligadasOcs/
    Get-OcsComputadoresPorIp) - mesma logica, mesma assinatura de retorno
    (sem mais o STRING JSON de sempre - nao precisa mais do contorno de
    serializacao do remoting, devolve o PSCustomObject direto). Resolve-
    ModeloAmigavelOcs/Test-HostnamePertenceZonaOcs sao copias das
    homonimas do servidor (que continuam la, ainda usadas pela propria
    varredura - NAO foram removidas de VisaoServidor.ps1, so duplicadas
    aqui).

    NOTA: Get-MacAddressOcs (usada so por Wake-on-LAN, Invoke-AcaoLigarWol)
    NAO foi migrada - WoL manda um pacote de broadcast direcionado, e
    trafego que precisa continuar saindo do POLICY-SERVER (mesma
    categoria da varredura).
#>

$script:UrlOcsApiBase = "http://inventario.tre-ma.jus.br/ocsapi/v1"
$script:MesesParaCandidatoExclusaoOcs = 6   # ultimo contato ha mais de X meses = candidata a exclusao no OCS

$script:MapaModelosOcs = @{
    "C4400"                            = "Mini-Positivo"
    "HP Elite Mini 800 G9 Desktop PC"  = "Mini-HP"
    "D6200"                            = "Positivo Master"
    "OptiPlex 3020M"                   = "Mini-Dell"
}

function Resolve-ModeloAmigavelOcs {
    param([string]$ModeloOriginal)
    if (-not $ModeloOriginal) { return $null }
    if ($script:MapaModelosOcs.ContainsKey($ModeloOriginal)) { return $script:MapaModelosOcs[$ModeloOriginal] }
    return $ModeloOriginal
}

function Test-HostnamePertenceZonaOcs {
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

function Get-OcsComputadoresPorIp {
    <#
        Acha as maquinas do OCS Inventory cadastradas numa rede /24 fazendo
        uma busca EXATA por IP (coluna "IPADDR" da tabela hardware) pra
        cada um dos 254 enderecos, em paralelo - confirmado na pratica que
        /computers/search aceita IPADDR como :searchCriteria.
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

function Get-MaquinasDesligadasOcsRemoto {
    <#
        Compara o cadastro do OCS Inventory pra rede da zona com o que a
        varredura ja encontrou online, pra achar maquinas cadastradas que
        nao responderam (candidatas a "desligada/desconectada") - e de
        quebra corrige o Hostname de maquinas que responderam mas o DNS
        reverso/NetBIOS nao resolveram (cruzando pelo ultimo IP conhecido
        no OCS). Mesmo nome/formato de retorno da versao antiga (via
        remoting) de proposito - nenhum lugar que ja chamava esta funcao
        precisou mudar, so parou de fazer uma chamada remota.

        $SistemasEleitoraisExtra = $script:Estado.SistemasEleitoraisExtra
        (ja carregado do lado cliente na conexao, via
        Get-SistemasEleitoraisExtraRemoto - isso continua no servidor,
        chamado so uma vez, nao vale a pena migrar).
    #>
    param(
        [Parameter(Mandatory)]
        [int]$Zona,
        [bool]$RedeCompartilhada = $false,
        [Parameter(Mandatory)]
        [object[]]$ResultadosOnline,
        [string]$PrefixoRede = "",
        [object[]]$SistemasEleitoraisExtra = @()
    )

    $zonaPad = "{0:D3}" -f $Zona
    $padroes = @("ZMA$zonaPad", "CMA$zonaPad", "ZE-$zonaPad", "ZE$zonaPad")

    $comps = Get-OcsComputadoresPorIp -PrefixoRede $PrefixoRede

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
            $modeloNovo = Resolve-ModeloAmigavelOcs -ModeloOriginal $biosComp.SMODEL
        }
        $versaoSisNovo = $cand.VersaoSis
        $registryComp = @($compAchado.registry)
        $entradaSisComp = @($registryComp) | Where-Object { $_.NAME -eq "VERSAO_SIS" } | Select-Object -First 1
        if ($entradaSisComp -and $entradaSisComp.REGVALUE -and $versaoSisNovo -eq "-") {
            $versaoSisNovo = $entradaSisComp.REGVALUE
        }
        $pertenceZonaNovo = $cand.PertenceZonaAtual
        if ($RedeCompartilhada) {
            $pertenceZonaNovo = Test-HostnamePertenceZonaOcs -Hostname $hwComp.NAME -Zona $Zona
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
        foreach ($sisExtra in $SistemasEleitoraisExtra) {
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
        if (-not $hw -or -not $hw.NAME) { continue }
        $nomeOcs = $hw.NAME
        $nomeCurto = ($nomeOcs -split '\.')[0]

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
            Modelo                 = if ($modeloOriginal) { Resolve-ModeloAmigavelOcs -ModeloOriginal $modeloOriginal } else { "-" }
            EhGateway              = $false
            EhNobreakCentral       = $false
            EhTelefoneVoip         = $false
            PertenceZonaAtual      = if ($RedeCompartilhada) { Test-HostnamePertenceZonaOcs -Hostname $nomeOcs -Zona $Zona } else { $true }
            PossivelmenteDesligado = $true
            HardwareId             = $hw.ID
            CandidatoExclusaoOcs   = $candidatoExclusaoOcs
            SemLinkComunicacao     = $false
        }
        foreach ($sisExtra in $SistemasEleitoraisExtra) {
            $entradaExtra = @($registry) | Where-Object { $_.NAME -eq $sisExtra.Chave } | Select-Object -First 1
            $valorExtra = if ($entradaExtra -and $entradaExtra.REGVALUE) { $entradaExtra.REGVALUE } else { "-" }
            $pseudo | Add-Member -NotePropertyName $sisExtra.Propriedade -NotePropertyValue $valorExtra
        }
        $desligadas.Add($pseudo)
    }

    # .ToArray() DE PROPOSITO em vez de deixar List[object] cru ou usar
    # @() - achado ao vivo (2026-08-24, ver VisaoPlanilhas.psm1): montar
    # [PSCustomObject]@{...} com um List[object] (ou @(List[object])) como
    # valor pode quebrar com ArgumentException num binder dinamico do
    # PowerShell 5.1, dependendo do build/patch da maquina - so
    # .ToArray() se mostrou confiavel em todos os casos testados.
    return [PSCustomObject]@{
        Ok                          = $true
        Correcoes                   = $correcoes.ToArray()
        Desligadas                  = $desligadas.ToArray()
        TotalNoOcs                  = $comps.Count
        MesesParaCandidatoExclusao  = $script:MesesParaCandidatoExclusaoOcs
    }
}

Export-ModuleMember -Function Get-MaquinasDesligadasOcsRemoto, Get-OcsComputadoresPorIp
