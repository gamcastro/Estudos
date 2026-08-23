<#
    VisaoAD.psm1

    Consultas ao Active Directory usadas pela "Visao" (janela "Usuarios da
    ZE" e a coluna "Instalador" da grade principal) - rodam DIRETO NA
    ESTACAO DO TECNICO, sem passar pelo PowerShell Remoting/POLICY-SERVER.

    Por que aqui e nao no VisaoServidor.ps1: consulta ao AD nao e trafego
    de varredura/scan (o motivo original de centralizar no servidor), e
    tentar rotea-la pelo servidor esbarrou num problema real - o duplo-
    salto do Kerberos. A credencial usada pra autenticar no POLICY-SERVER
    via WinRM nao e repassada por ele pra autenticar numa TERCEIRA
    maquina (o Controlador de Dominio) - a busca LDAP falhava com "An
    operations error occurred" mesmo com a sessao remota funcionando
    perfeitamente pra tudo o resto. Resolver isso exigiria CredSSP
    (delega senha de verdade, risco de seguranca) ou Delegacao Kerberos
    Restrita configurada no AD (precisa de admin de dominio no objeto de
    computador do POLICY-SERVER) - nenhum dos dois vale a pena pra um
    tipo de consulta que rodar local resolve de graca, com um unico
    salto Kerberos normal (estacao -> Controlador de Dominio).

    Ver o plano completo em
    C:\Users\029342881104\.claude\plans\splendid-enchanting-mochi.md.

    Relocacao praticamente pura do ScannerRedeZona.ps1 original - so
    Get-MaquinasLiberadasInstalador perdeu as chamadas a Add-Log (que
    so existiam la porque a janela principal tinha um RichTextBox de log;
    aqui devolve $null e quem chamar decide como avisar) e o
    $script:NomeUsuarioInstalador virou uma constante local do modulo.
#>

$script:NomeUsuarioInstalador = "instalador"

function Get-RaizBuscaAd {
    <#
        Amarra a raiz de busca do AD explicitamente na RAIZ DO DOMINIO
        (LDAP://DC=tre-ma,DC=gov,DC=br) em vez de deixar o
        DirectoryEntry() vazio decidir sozinho onde "comeca" a busca -
        confirmado na pratica que o bind vazio pode nao alcancar certas
        OUs (ex: OU=ZONAS_CAPITAL, usada pelos usuarios das zonas de Sao
        Luis). Cai pro bind vazio se nao conseguir detectar o dominio.
    #>
    try {
        $dominioAtual = [System.DirectoryServices.ActiveDirectory.Domain]::GetCurrentDomain()
        $dnDominio = "DC=" + ($dominioAtual.Name -split '\.' -join ',DC=')
        return New-Object System.DirectoryServices.DirectoryEntry("LDAP://$dnDominio")
    } catch {
        return New-Object System.DirectoryServices.DirectoryEntry
    }
}

function ConvertTo-InfoObjetoAd {
    <#
        Quebra um DN de objeto do AD (ex: "CN=GEDAI2K1GAdmin,OU=Grupos,
        OU=TRIBUNAL,DC=tre-ma,DC=gov,DC=br") em Nome (o proprio objeto) e
        Caminho (dominio + containers, na mesma ordem "de cima pra baixo"
        que a tela nativa de propriedades do AD mostra em "Pastas de
        Active Directory Domain..." - ex: "tre-ma.gov.br/TRIBUNAL/Grupos").
    #>
    param([string]$Dn)
    if (-not $Dn) { return $null }
    $partes = $Dn -split ','
    if ($partes.Count -eq 0) { return $null }
    $nome = $partes[0] -replace '^(CN|OU)=', ''
    $dcs = @()
    $containers = @()
    for ($i = 1; $i -lt $partes.Count; $i++) {
        $p = $partes[$i].Trim()
        if ($p -match '^DC=(.+)$') { $dcs += $Matches[1] }
        elseif ($p -match '^(CN|OU)=(.+)$') { $containers += $Matches[2] }
    }
    [array]::Reverse($containers)
    $caminho = $dcs -join '.'
    if ($containers.Count -gt 0) { $caminho += "/" + ($containers -join '/') }
    return [PSCustomObject]@{ Nome = $nome; Caminho = $caminho }
}

function Get-UsuariosDaZona {
    <#
        Busca no AD os usuarios lotados numa zona eleitoral - o cadastro
        NAO e padronizado (as vezes fica no atributo "Escritorio"
        (physicalDeliveryOfficeName), as vezes em "Departamento"
        (department), confirmado na pratica olhando varios usuarios), e
        quando esta em Departamento segue o padrao "ZE-<zona> - <zona>a
        ZONA ELEITORAL - <SEDE>". Por isso a busca cobre as duas
        possibilidades por OR. Retorna array de PSCustomObject (Nome,
        Login, Descricao, Lotacao, Email, Telefone, ContaDesabilitada,
        ContaBloqueada, Grupos). NAO trata falha internamente - a excecao
        propaga pra quem chamou tratar.
    #>
    param([int]$Zona)

    $busca = $null
    $resultados = $null
    try {
        $raizBusca = Get-RaizBuscaAd
        $busca = New-Object System.DirectoryServices.DirectorySearcher($raizBusca)
        $busca.ReferralChasing = [System.DirectoryServices.ReferralChasingOption]::None
        $busca.PageSize = 1000
        # O AD usa a zona SEMPRE com 2 digitos no minimo (ex: zona 1 vira
        # "ZE-01", confirmado na pratica - "ZE-1" sozinho nao existe) - zonas
        # de 2+ digitos (10, 72, 105...) ja tem naturalmente 2+ digitos,
        # entao a formatacao nao muda nada pra elas. Ainda assim inclui a
        # forma SEM padding tambem no OR, por seguranca contra cadastro
        # manual inconsistente (o proprio motivo de ter essa tela).
        $zonaPad = "{0:D2}" -f $Zona
        $busca.Filter = "(&(objectClass=user)(objectCategory=person)(|(physicalDeliveryOfficeName=ZE-$Zona)(physicalDeliveryOfficeName=ZE-$zonaPad)(department=ZE-$Zona)(department=ZE-$Zona *)(department=ZE-$zonaPad)(department=ZE-$zonaPad *)))"
        foreach ($p in @("samAccountName", "displayName", "description", "department", "physicalDeliveryOfficeName", "mail", "telephoneNumber", "userAccountControl", "lockoutTime", "memberOf")) {
            [void]$busca.PropertiesToLoad.Add($p)
        }
        $resultados = $busca.FindAll()

        $usuarios = New-Object System.Collections.Generic.List[object]
        foreach ($r in $resultados) {
            $props = $r.Properties
            $uac = if ($props["useraccountcontrol"].Count -gt 0) { [int]$props["useraccountcontrol"][0] } else { 0 }
            # "Bloqueado" (lockout por tentativas de senha erradas) e um
            # status DIFERENTE de "Desabilitado" (uac bit ACCOUNTDISABLE) -
            # nao tem bit proprio no userAccountControl, fica no atributo
            # lockoutTime: 0 (ou ausente) = nunca bloqueado/desbloqueado,
            # qualquer valor diferente de 0 = bloqueado desde aquele
            # instante (FILETIME do Windows).
            $lockoutTime = if ($props["lockouttime"].Count -gt 0) { [long]$props["lockouttime"][0] } else { 0 }
            $grupos = New-Object System.Collections.Generic.List[object]
            foreach ($g in $props["memberof"]) {
                $info = ConvertTo-InfoObjetoAd -Dn $g
                if ($info) { $grupos.Add($info) }
            }
            $usuarios.Add([PSCustomObject]@{
                Nome              = if ($props["displayname"].Count -gt 0) { $props["displayname"][0] } elseif ($props["samaccountname"].Count -gt 0) { $props["samaccountname"][0] } else { "(sem nome)" }
                Login             = if ($props["samaccountname"].Count -gt 0) { $props["samaccountname"][0] } else { "" }
                Descricao         = if ($props["description"].Count -gt 0) { $props["description"][0] } else { "" }
                Lotacao           = if ($props["department"].Count -gt 0) { $props["department"][0] } elseif ($props["physicaldeliveryofficename"].Count -gt 0) { $props["physicaldeliveryofficename"][0] } else { "" }
                Email             = if ($props["mail"].Count -gt 0) { $props["mail"][0] } else { "" }
                Telefone          = if ($props["telephonenumber"].Count -gt 0) { $props["telephonenumber"][0] } else { "" }
                ContaDesabilitada = (($uac -band 2) -ne 0)
                ContaBloqueada    = ($lockoutTime -ne 0)
                Grupos            = ($grupos | Sort-Object Nome)
            })
        }
        return ($usuarios | Sort-Object Nome)
    } finally {
        # SEM catch aqui de proposito - deixa a excecao propagar pra quem
        # chamou tratar (mostrar a mensagem completa, mais confiavel do
        # que so logar em algum lugar).
        if ($resultados) { $resultados.Dispose() }
        if ($busca) { $busca.Dispose() }
    }
}

function Get-MaquinasLiberadasInstalador {
    <#
        Consulta o atributo LDAP userWorkstations do usuario
        $script:NomeUsuarioInstalador (lista de hostnames NetBIOS separados
        por virgula onde ele esta liberado pra logar agora) via ADSI puro,
        sem depender do modulo ActiveDirectory/RSAT. Retorna um array de
        hostnames (vazio = sem restricao, liberado em qualquer maquina) ou
        $null se a consulta falhou (dominio inacessivel, usuario nao
        encontrado etc) - nesse caso a coluna "Status Instalador" fica "-"
        pra todo mundo, ja que nao da pra saber o status real. Nao loga
        nada (diferente do ScannerRedeZona.ps1 original) - quem chamar
        decide como avisar sobre o $null.
    #>
    try {
        $raizBusca = Get-RaizBuscaAd
        $busca = New-Object System.DirectoryServices.DirectorySearcher($raizBusca)
        $busca.ReferralChasing = [System.DirectoryServices.ReferralChasingOption]::None
        $busca.Filter = "(&(objectClass=user)(objectCategory=person)(samAccountName=$script:NomeUsuarioInstalador))"
        [void]$busca.PropertiesToLoad.Add("userWorkstations")
        $resultado = $busca.FindOne()
        if (-not $resultado) { return $null }
        if ($resultado.Properties["userworkstations"].Count -eq 0) { return @() }
        $valorCru = $resultado.Properties["userworkstations"][0]
        return @($valorCru -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    } catch {
        return $null
    }
}

Export-ModuleMember -Function Get-UsuariosDaZona, Get-MaquinasLiberadasInstalador
