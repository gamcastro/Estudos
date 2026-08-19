<#
    Habilita Wake-on-LAN nesta maquina: "permitir que o dispositivo ative o
    computador" (powercfg), "Wake on Magic Packet" (placa de rede) e
    desabilita a Inicializacao Rapida (Fast Startup), que em algumas
    combinacoes de hardware atrapalha o WOL a partir de um "Desligar" normal.

    IMPORTANTE: este script roda LOCALMENTE, na propria maquina que voce
    quer preparar pra aceitar Wake-on-LAN - nao roda contra outra maquina
    remotamente (nao existe um jeito confiavel de mudar essas configuracoes
    de fora, ja vimos isso com WMI/WinRM nesse ambiente). Rode direto nela
    (fisicamente ou por qualquer acesso remoto que voce ja tenha, tipo VNC),
    com privilegio de administrador - o script se auto-eleva via UAC.

    O que este script NAO consegue fazer (precisa ser manual):
      - Habilitar "Wake on LAN" / "Power On by PCI-E" / "Resume by LAN" na
        BIOS/UEFI - isso e fora do alcance do Windows, entra antes do SO
        carregar.
      - Garantir que uma politica de grupo (GPO) do dominio nao vai
        sobrescrever essas configuracoes de novo depois.
#>

# ============================================================
# AUTO-ELEVACAO UAC (mesmo padrao do resto do toolkit)
# ============================================================
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $args = "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    Start-Process powershell.exe -ArgumentList $args -Verb RunAs
    exit
}

Write-Host "=== Habilitando Wake-on-LAN em $env:COMPUTERNAME ===" -ForegroundColor Cyan
Write-Host ""

$adaptadores = Get-NetAdapter -Physical | Where-Object { $_.Status -ne 'Disabled' }
if (-not $adaptadores) {
    Write-Host "[AVISO] Nenhuma placa de rede fisica ativa encontrada." -ForegroundColor Yellow
}

foreach ($nic in $adaptadores) {
    Write-Host "--- Placa: $($nic.Name) ($($nic.InterfaceDescription)) ---" -ForegroundColor Yellow

    # 1) "Permitir que este dispositivo ative o computador" (aba
    #    Gerenciamento de Energia, no Gerenciador de Dispositivos) - via
    #    powercfg, que funciona independente do driver expor isso como
    #    propriedade do modulo NetAdapter.
    try {
        powercfg -deviceenablewake "$($nic.InterfaceDescription)" 2>&1 | Out-Null
        Write-Host "[OK] 'Permitir que o dispositivo ative o computador' habilitado (powercfg)." -ForegroundColor Green
    } catch {
        Write-Host "[AVISO] Nao consegui habilitar via powercfg: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 2) "Wake on Magic Packet" via modulo NetAdapter (funciona na maioria
    #    das placas modernas com driver certificado pela Microsoft).
    try {
        Set-NetAdapterPowerManagement -Name $nic.Name -WakeOnMagicPacket Enabled -ErrorAction Stop
        Write-Host "[OK] 'Wake on Magic Packet' habilitado (Set-NetAdapterPowerManagement)." -ForegroundColor Green
    } catch {
        Write-Host "[AVISO] Essa placa/driver nao aceita WakeOnMagicPacket via Set-NetAdapterPowerManagement: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    # 3) Mesma coisa, como propriedade avancada do driver - alguns
    #    fabricantes (Realtek, algumas Intel) so expoem aqui, nao no
    #    PowerManagement acima. Nome do campo varia, entao procura por
    #    qualquer propriedade avancada que mencione "Magic Packet".
    try {
        $propsWol = Get-NetAdapterAdvancedProperty -Name $nic.Name -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like "*Magic Packet*" -or $_.RegistryKeyword -like "*WakeOnMagicPacket*" }
        if ($propsWol) {
            foreach ($prop in $propsWol) {
                $valorHabilitado = $prop.ValidDisplayValues | Where-Object { $_ -like "*Enabled*" -or $_ -eq "1" } | Select-Object -First 1
                if ($valorHabilitado -and $prop.DisplayValue -ne $valorHabilitado) {
                    Set-NetAdapterAdvancedProperty -Name $nic.Name -DisplayName $prop.DisplayName -DisplayValue $valorHabilitado -ErrorAction Stop
                    Write-Host "[OK] Propriedade avancada '$($prop.DisplayName)' definida como '$valorHabilitado'." -ForegroundColor Green
                } else {
                    Write-Host "[OK] Propriedade avancada '$($prop.DisplayName)' ja estava habilitada." -ForegroundColor Green
                }
            }
        } else {
            Write-Host "[INFO] Nenhuma propriedade avancada de 'Magic Packet' nessa placa (normal em varias - o passo 2 acima ja pode cobrir)." -ForegroundColor Gray
        }
    } catch {
        Write-Host "[AVISO] Falha ajustando propriedade avancada: $($_.Exception.Message)" -ForegroundColor Yellow
    }

    Write-Host ""
}

# 4) Desabilitar Inicializacao Rapida (Fast Startup) - em algumas
#    combinacoes de hardware/firmware atrapalha o WOL a partir de um
#    "Desligar" normal (nao afeta Hibernar, so o desligamento padrao).
Write-Host "--- Inicializacao Rapida (Fast Startup) ---" -ForegroundColor Yellow
try {
    $caminhoRegPower = "HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Power"
    Set-ItemProperty -Path $caminhoRegPower -Name "HiberbootEnabled" -Value 0 -Type DWord -Force
    Write-Host "[OK] Inicializacao Rapida desabilitada (HiberbootEnabled = 0)." -ForegroundColor Green
} catch {
    Write-Host "[ERRO] Falha ao desabilitar Inicializacao Rapida: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

Write-Host "=== Concluido. O que este script NAO consegue configurar por software: ===" -ForegroundColor Cyan
Write-Host " - BIOS/UEFI: precisa habilitar manualmente 'Wake on LAN' / 'Power On by PCI-E' / 'Resume by LAN' (varia por fabricante)." -ForegroundColor Gray
Write-Host " - GPO do dominio: se alguma politica de grupo sobrescrever essas configuracoes periodicamente, elas voltam ao estado anterior - vale conferir com quem administra o AD se isso acontece." -ForegroundColor Gray
Write-Host ""
Write-Host "Dica de verificacao: com a maquina desligada, o LED do cabo de rede deve continuar aceso/piscando - se apagar completamente, a placa nao esta recebendo energia em standby e WOL nao vai funcionar, independente da configuracao acima." -ForegroundColor Gray
