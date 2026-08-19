<#
    Diagnostico de conexao VNC (RFB) a nivel de socket bruto, sem depender
    do UltraVNC Viewer - serve pra descobrir em qual camada a conexao esta
    travando quando o vncviewer.exe fica parado em "Negotiate Protocol
    Version...".

    COMO USAR: rode este script tanto no SERVIDOR (onde trava) quanto na
    sua ESTACAO (onde funciona), contra o MESMO IP de destino, e compare
    a saida dos dois. Ajuste $ipAlvo abaixo se precisar testar outro IP.
#>

param(
    [string]$ipAlvo = "10.198.54.142",
    [int]$portaAlvo = 5900,
    [int]$timeoutLeituraMs = 8000
)

Write-Host "=== Diagnostico VNC (RFB) - ${ipAlvo}:${portaAlvo} ===" -ForegroundColor Cyan
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

# --- Etapa 2: socket bruto - conecta e tenta ler o banner RFB ---
Write-Host "--- Etapa 2: Socket bruto - conectar e ler banner RFB (12 bytes esperados: 'RFB 003.00X') ---" -ForegroundColor Yellow
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
        $buffer = New-Object byte[] 32

        Write-Host "Aguardando ate $timeoutLeituraMs ms por dados do servidor (isso e exatamente o que o vncviewer faz na tela 'Negotiate Protocol Version...')..." -ForegroundColor Gray
        $cronometroLeitura = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            $bytesLidos = $stream.Read($buffer, 0, $buffer.Length)
            $cronometroLeitura.Stop()
            if ($bytesLidos -gt 0) {
                $textoRecebido = [System.Text.Encoding]::ASCII.GetString($buffer, 0, $bytesLidos)
                Write-Host "[OK] Recebeu $bytesLidos byte(s) em $($cronometroLeitura.ElapsedMilliseconds) ms: '$($textoRecebido.Trim())'" -ForegroundColor Green
                Write-Host "     => O servidor RESPONDE normalmente ate essa maquina/rede - se o vncviewer trava mesmo assim, o problema e no CLIENTE (versao do UltraVNC, ou algo interceptando so o trafego DELE)." -ForegroundColor Green
            } else {
                Write-Host "[FALHA] Conexao fechada pelo servidor sem enviar nada (0 bytes)." -ForegroundColor Red
            }
        } catch [System.IO.IOException] {
            $cronometroLeitura.Stop()
            Write-Host "[FALHA] TIMEOUT depois de $($cronometroLeitura.ElapsedMilliseconds) ms - TCP conectou mas NENHUM byte de dado chegou." -ForegroundColor Red
            Write-Host "     => Isso confirma: o handshake TCP passa, mas os pacotes de DADOS estao sendo bloqueados/descartados no caminho (firewall, IPS, proxy transparente, antivirus/EDR com inspecao de rede) - nao e um problema do VNC em si nem da maquina alvo." -ForegroundColor Red
        }
    }
} catch {
    Write-Host "[ERRO] $($_.Exception.Message)" -ForegroundColor Red
} finally {
    if ($cliente) { $cliente.Close() }
}
Write-Host ""

# --- Etapa 3: proxy/WinHTTP configurado nesta maquina ---
Write-Host "--- Etapa 3: Proxy configurado nesta maquina (pode nao afetar VNC direto, mas indica politica de rede mais restritiva) ---" -ForegroundColor Yellow
try { netsh winhttp show proxy } catch {}
Write-Host ""

# --- Etapa 4: processos de seguranca/rede rodando (antivirus/EDR/firewall de terceiros) ---
# Inclui nomes de processo especificos do Trend Micro (Apex One/OfficeScan/
# Deep Security), ja que e o suspeito principal confirmado no ambiente do
# TRE-MA - o padrao generico "*trend*" sozinho nao pega o nome real dos
# processos do agente.
Write-Host "--- Etapa 4: Processos de seguranca/rede conhecidos em execucao (heuristica, pode nao pegar tudo) ---" -ForegroundColor Yellow
$padroesSeguranca = @(
    "*defender*", "*mcafee*", "*kaspersky*", "*symantec*", "*crowdstrike*",
    "*sentinelone*", "*sophos*", "*fortinet*", "*forticlient*", "*paloalto*", "*checkpoint*",
    "*cyberark*", "*carbonblack*", "*cortex*", "*eset*", "*avast*", "*avg*",
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
