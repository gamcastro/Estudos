<#
    Diagnostico de conexao RCViewer (Ivanti/LANDesk Remote Control) a nivel
    de socket bruto, sem depender do RCViewer.exe - mesma ideia do
    vnc_diagnostico.ps1, adaptado pra porta 9535 (Remote Control legado).

    Diferente do VNC (protocolo RFB documentado, com banner ASCII
    previsivel tipo "RFB 003.008"), o protocolo do Ivanti/LANDesk Remote
    Control e proprietario e nao documentado publicamente - entao aqui NAO
    assumimos como e o banner: so mostramos em HEX + ASCII o que (se
    algo) o servidor manda depois do TCP conectar. O que importa pro
    diagnostico e o mesmo do VNC: TCP conecta, mas os dados chegam ou nao?

    COMO USAR: rode este script tanto no SERVIDOR (onde suspeita de
    bloqueio) quanto na sua ESTACAO (onde funciona), contra o MESMO IP de
    destino, e compare a saida dos dois - principalmente a Etapa 2.
#>

param(
    [string]$ipAlvo = "10.198.54.142",
    [int]$portaAlvo = 9535,
    [int]$timeoutLeituraMs = 8000
)

function ConvertTo-HexDump {
    param([byte[]]$Bytes)
    ($Bytes | ForEach-Object { $_.ToString("X2") }) -join " "
}

function ConvertTo-AsciiSeguro {
    <# Troca bytes nao imprimiveis por "." pra nao bagunçar o console #>
    param([byte[]]$Bytes)
    -join ($Bytes | ForEach-Object { if ($_ -ge 32 -and $_ -le 126) { [char]$_ } else { "." } })
}

Write-Host "=== Diagnostico RCViewer (Ivanti/LANDesk Remote Control) - ${ipAlvo}:${portaAlvo} ===" -ForegroundColor Cyan
Write-Host "Executando em: $env:COMPUTERNAME (IP local abaixo)" -ForegroundColor Gray
try {
    $ipsLocais = [System.Net.Dns]::GetHostAddresses([System.Net.Dns]::GetHostName()) |
        Where-Object { $_.AddressFamily -eq 'InterNetwork' } | ForEach-Object { $_.IPAddressToString }
    Write-Host "IP(s) local(is): $($ipsLocais -join ', ')" -ForegroundColor Gray
} catch {}
Write-Host ""

# --- Etapa 1: TCP puro (handshake) ---
Write-Host "--- Etapa 1: Test-NetConnection (TCP) ---" -ForegroundColor Yellow
try {
    $tnc = Test-NetConnection -ComputerName $ipAlvo -Port $portaAlvo -WarningAction SilentlyContinue
    Write-Host "TcpTestSucceeded: $($tnc.TcpTestSucceeded)"
    Write-Host "RemoteAddress:    $($tnc.RemoteAddress)"
    Write-Host "InterfaceAlias:   $($tnc.InterfaceAlias)"
    Write-Host "SourceAddress:    $($tnc.SourceAddress)"
} catch {
    Write-Host "[ERRO] Test-NetConnection falhou: $($_.Exception.Message)" -ForegroundColor Red
}
Write-Host ""

# --- Etapa 2: socket bruto - conecta e tenta ler o que o servidor mandar ---
Write-Host "--- Etapa 2: Socket bruto - conectar e aguardar dados (protocolo proprietario, sem banner conhecido) ---" -ForegroundColor Yellow
$cliente = $null
try {
    $cronometro = [System.Diagnostics.Stopwatch]::StartNew()

    $cliente = New-Object System.Net.Sockets.TcpClient
    $resultadoConexao = $cliente.BeginConnect($ipAlvo, $portaAlvo, $null, $null)
    $conectou = $resultadoConexao.AsyncWaitHandle.WaitOne(5000, $false)

    if (-not $conectou -or -not $cliente.Connected) {
        Write-Host "[FALHA] Nao conseguiu nem completar o handshake TCP em 5s." -ForegroundColor Red
    } else {
        $cliente.EndConnect($resultadoConexao)
        Write-Host "[OK] TCP conectado em $($cronometro.ElapsedMilliseconds) ms." -ForegroundColor Green

        $stream = $cliente.GetStream()
        $stream.ReadTimeout = $timeoutLeituraMs
        $buffer = New-Object byte[] 64

        Write-Host "Aguardando ate $timeoutLeituraMs ms por dados do servidor (equivalente ao RCViewer travado logo apos conectar)..." -ForegroundColor Gray
        $cronometroLeitura = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $bytesLidos = $stream.Read($buffer, 0, $buffer.Length)
            $cronometroLeitura.Stop()
            if ($bytesLidos -gt 0) {
                $bytesRecebidos = $buffer[0..($bytesLidos - 1)]
                Write-Host "[OK] Recebeu $bytesLidos byte(s) em $($cronometroLeitura.ElapsedMilliseconds) ms." -ForegroundColor Green
                Write-Host "     HEX:   $(ConvertTo-HexDump $bytesRecebidos)" -ForegroundColor Green
                Write-Host "     ASCII: $(ConvertTo-AsciiSeguro $bytesRecebidos)" -ForegroundColor Green
                Write-Host "     => O servidor RESPONDE normalmente ate essa maquina/rede - se o RCViewer travar mesmo assim, o problema e no CLIENTE (versao do RCViewer.exe, ou algo interceptando so o trafego DELE)." -ForegroundColor Green
            } else {
                Write-Host "[FALHA] Conexao fechada pelo servidor sem enviar nada (0 bytes)." -ForegroundColor Red
            }
        } catch [System.IO.IOException] {
            $cronometroLeitura.Stop()
            Write-Host "[FALHA] TIMEOUT depois de $($cronometroLeitura.ElapsedMilliseconds) ms - TCP conectou mas NENHUM byte de dado chegou." -ForegroundColor Red
            Write-Host "     => Isso confirma: o handshake TCP passa, mas os pacotes de DADOS estao sendo bloqueados/descartados no caminho (firewall, IPS, proxy transparente, antivirus/EDR com inspecao de rede) - nao e um problema do RCViewer em si nem da maquina alvo." -ForegroundColor Red
        }
    }
} catch {
    Write-Host "[ERRO] $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if ($cliente) { $cliente.Close() }
}
Write-Host ""

# --- Etapa 3: proxy/WinHTTP configurado nesta maquina ---
Write-Host "--- Etapa 3: Proxy configurado nesta maquina (pode nao afetar RCViewer direto, mas indica politica de rede mais restritiva) ---" -ForegroundColor Yellow
try { netsh winhttp show proxy } catch {}
Write-Host ""

# --- Etapa 4: processos de seguranca/rede rodando (antivirus/EDR/firewall de terceiros) ---
# Inclui nomes de processo especificos do Trend Micro (Apex One/OfficeScan/
# Deep Security), ja que o diagnostico do VNC confirmou que e o suspeito
# principal no ambiente do TRE-MA - o padrao generico "*trend*" sozinho
# nao pega o nome real dos processos do agente.
Write-Host "--- Etapa 4: Processos de seguranca/rede conhecidos em execucao (heuristica, pode nao pegar tudo) ---" -ForegroundColor Yellow
$padroesSeguranca = @(
    "*defender*", "*mcafee*", "*kaspersky*", "*symantec*", "*crowdstrike*",
    "*sentinelone*", "*sophos*", "*fortinet*", "*forticlient*", "*paloalto*", "*checkpoint*",
    "*cyberark*", "*carbonblack*", "*cortex*", "*eset*", "*avast*", "*avg*",
    # Trend Micro (Apex One / OfficeScan / Deep Security) - nomes reais dos processos
    "*trend*", "*pccnt*", "*ntrtscan*", "*tmlisten*", "*tmccsf*", "*tmbmsrv*",
    "*tmproxy*", "*tmufender*", "*coreservice*", "*ds_agent*", "*iantimalware*"
)
$achados = Get-Process | Where-Object {
    $nome = $_.ProcessName
    $padroesSeguranca | Where-Object { $nome -like $_ }
} | Select-Object -ExpandProperty ProcessName -Unique
if ($achados) {
    Write-Host "Encontrado(s): $($achados -join ', ')" -ForegroundColor Gray
} else {
    Write-Host "Nenhum processo dos padroes conhecidos encontrado (nao decisivo - pode ser um appliance de rede, nao software local)." -ForegroundColor Gray
}
Write-Host ""

Write-Host "=== Fim do diagnostico - rode o mesmo script na sua estacao (onde funciona) e compare a Etapa 2 ===" -ForegroundColor Cyan
