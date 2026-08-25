#requires -Version 5.1

<#
    Instalar-VisaoHomolog.ps1

    Versao de HOMOLOGACAO do Instalar-Visao.ps1 - instala o modulo
    "VisaoHomolog" (nome diferente de "Visao" de proposito) no escopo do
    usuario atual, com atalho ("Visao Homolog.lnk") e inicializador
    proprios, pra nunca colidir com uma instalacao de producao da Visao
    ja existente na mesma maquina - os dois convivem lado a lado sem se
    atrapalhar (pastas de log/cache tambem separadas, ver
    VisaoRemoting.psm1/VisaoPlanilhas.psm1 dentro do pacote).

    Aponta pro MESMO repositorio (VisaoRepoInterno) e pro MESMO
    POLICY-SERVER/planilhas/Apps Script de producao - a ideia e testar
    uma correcao de codigo com dados reais antes de promover pra
    producao, nao simular um ambiente isolado inteiro.

    Uso pretendido (decisao do usuario, 2026-08-25): distribuir esse
    instalador pra tecnicos-chave quando houver uma mudanca sensivel a
    testar antes de ir pra todo mundo - mesmo padrao de uso do
    Instalar-Visao.ps1/.bat de producao (rodar via .bat pra nao cair no
    aviso de "arquivo baixado da internet" do Explorer).
#>

[CmdletBinding()]
param(
    [switch]$ReabrirAoTerminar
)

$ErrorActionPreference = 'Stop'

$repoNome = 'VisaoRepoInterno'
$repoCaminho = '\\POLICY-SERVER.tre-ma.gov.br\ScanZonas\PSRepo'
$nomeModulo = 'VisaoHomolog'

$pastaInicializador = Join-Path $env:LOCALAPPDATA 'SuporteTI\VisaoHomolog'
$caminhoInicializador = Join-Path $pastaInicializador 'Iniciar-VisaoHomolog.ps1'
$caminhoAtalho = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Visao Homolog.lnk'
$powershell51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Pausar-SeInterativo {
    if ($Host.Name -eq 'ConsoleHost') {
        Write-Host ''
        Read-Host 'Pressione ENTER para fechar'
    }
}

try {
    Write-Host '=== Instalacao do Visao HOMOLOG ===' -ForegroundColor Cyan
    Write-Host ''

    if (-not (Test-Path -LiteralPath $repoCaminho)) {
        throw "O repositorio interno nao esta acessivel: $repoCaminho"
    }

    Write-Host 'Verificando o repositorio interno...' -ForegroundColor Cyan

    $repositorio = Get-PSRepository -Name $repoNome -ErrorAction SilentlyContinue

    if ($repositorio) {
        $caminhoRegistrado = [string]$repositorio.SourceLocation

        if (-not $caminhoRegistrado.Equals($repoCaminho, [StringComparison]::OrdinalIgnoreCase)) {
            Write-Host 'Caminho do repositorio mudou, atualizando registro...' -ForegroundColor Yellow
            Unregister-PSRepository -Name $repoNome
            $repositorio = $null
        }
    }

    if (-not $repositorio) {
        Register-PSRepository -Name $repoNome -SourceLocation $repoCaminho -PublishLocation $repoCaminho -InstallationPolicy Trusted
        Write-Host "Repositorio '$repoNome' registrado." -ForegroundColor Green
    }
    else {
        Set-PSRepository -Name $repoNome -InstallationPolicy Trusted
        Write-Host "Repositorio '$repoNome' ja estava registrado." -ForegroundColor Gray
    }

    Write-Host 'Instalando/atualizando o modulo VisaoHomolog (pode pedir pra instalar o provedor NuGet na primeira vez - confirme com Sim)...' -ForegroundColor Cyan

    Install-Module -Name $nomeModulo -Repository $repoNome -Scope CurrentUser -Force -AllowClobber

    $moduloInfo = Get-Module -ListAvailable -Name $nomeModulo | Sort-Object Version -Descending | Select-Object -First 1

    if (-not $moduloInfo) {
        throw 'O modulo VisaoHomolog nao foi localizado depois da instalacao.'
    }

    $pastaModulo = Split-Path -Path $moduloInfo.Path -Parent
    $caminhoIcone = Join-Path $pastaModulo 'Visao.ico'

    Write-Host 'Desbloqueando os arquivos instalados...' -ForegroundColor Cyan
    Get-ChildItem -LiteralPath $pastaModulo -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    Write-Host 'Validando o modulo...' -ForegroundColor Cyan
    Import-Module $moduloInfo.Path -Force -ErrorAction Stop

    if (-not (Get-Command -Name 'Start-VisaoHomolog' -Module $nomeModulo -ErrorAction SilentlyContinue)) {
        throw 'O modulo foi carregado, mas nao exportou a funcao Start-VisaoHomolog.'
    }

    Remove-Module -Name $nomeModulo -Force -ErrorAction SilentlyContinue

    Write-Host "Modulo VisaoHomolog $($moduloInfo.Version) instalado." -ForegroundColor Green

    if (-not (Test-Path -LiteralPath $pastaInicializador)) {
        New-Item -Path $pastaInicializador -ItemType Directory -Force | Out-Null
    }

    $conteudoInicializador = @'
#requires -Version 5.1

$ErrorActionPreference = 'Stop'

function Registrar-LogAutoAtualizacao {
    param([string]$Linha)
    try {
        $arquivoLog = Join-Path $PSScriptRoot 'AutoAtualizacao.log'
        $linhaComData = "$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') - $Linha"
        $linhasExistentes = @()
        if (Test-Path -LiteralPath $arquivoLog) {
            $linhasExistentes = @(Get-Content -LiteralPath $arquivoLog -ErrorAction SilentlyContinue)
        }
        $linhasFinais = @($linhasExistentes + $linhaComData) | Select-Object -Last 50
        Set-Content -LiteralPath $arquivoLog -Value $linhasFinais -Encoding utf8 -Force
    } catch {}
}

$arquivoDesativarAutoAtualizacao = Join-Path $PSScriptRoot 'SemAutoAtualizacao.txt'

if (Test-Path -LiteralPath $arquivoDesativarAutoAtualizacao) {
    Registrar-LogAutoAtualizacao 'Pulado - SemAutoAtualizacao.txt presente'
}
else {
    try {
        $job = Start-Job -ScriptBlock {
            param($NomeModulo, $NomeRepo, $CaminhoRepo)
            $instalado = Get-Module -ListAvailable -Name $NomeModulo | Sort-Object Version -Descending | Select-Object -First 1
            if (-not $instalado) { return "Modulo nao encontrado localmente - pulando checagem" }

            $pacotes = Get-ChildItem -LiteralPath $CaminhoRepo -Filter "$NomeModulo.*.nupkg" -ErrorAction Stop
            $versaoDisponivel = $pacotes | ForEach-Object {
                if ($_.BaseName -match "^$([regex]::Escape($NomeModulo))\.(\d+(?:\.\d+){1,3})$") { [version]$Matches[1] }
            } | Sort-Object -Descending | Select-Object -First 1

            if (-not $versaoDisponivel -or $versaoDisponivel -le [version]$instalado.Version) {
                return "Ja estava na versao mais recente ($($instalado.Version))"
            }

            Update-Module -Name $NomeModulo -Force -ErrorAction Stop
            $verificacao = Get-Module -ListAvailable -Name $NomeModulo | Sort-Object Version -Descending | Select-Object -First 1
            if ($verificacao.Version -lt $versaoDisponivel) {
                throw "Update-Module nao lancou erro, mas a versao instalada continua $($verificacao.Version) (esperada $versaoDisponivel)"
            }
            return "Atualizado de $($instalado.Version) para $($verificacao.Version)"
        } -ArgumentList 'VisaoHomolog', 'VisaoRepoInterno', '\\POLICY-SERVER.tre-ma.gov.br\ScanZonas\PSRepo'

        if (Wait-Job -Job $job -Timeout 20) {
            $resultado = Receive-Job -Job $job -ErrorAction SilentlyContinue
            Registrar-LogAutoAtualizacao $resultado
        }
        else {
            Stop-Job -Job $job -ErrorAction SilentlyContinue
            Registrar-LogAutoAtualizacao 'Pulado - checagem excedeu o prazo (servidor lento ou fora do ar)'
        }
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
    }
    catch {
        Registrar-LogAutoAtualizacao "Pulado - erro na checagem: $($_.Exception.Message)"
    }
}

try {
    Import-Module VisaoHomolog -Force -ErrorAction Stop

    $comando = Get-Command Start-VisaoHomolog -ErrorAction Stop
    & $comando
}
catch {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $arquivoLog = Join-Path $desktop 'Erro-VisaoHomolog.txt'

    $detalhes = @(
        "Data: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "Computador: $env:COMPUTERNAME"
        "Usuario: $env:USERDOMAIN\$env:USERNAME"
        "PowerShell: $($PSVersionTable.PSVersion)"
        ''
        'Erro:'
        ($_ | Out-String)
        ''
        'Detalhes:'
        ($_.Exception | Format-List * -Force | Out-String)
        ''
        'Pilha:'
        ($_.ScriptStackTrace | Out-String)
    ) -join [Environment]::NewLine

    $detalhes | Out-File -LiteralPath $arquivoLog -Encoding utf8 -Force

    Add-Type -AssemblyName PresentationFramework
    [System.Windows.MessageBox]::Show(
        "Nao foi possivel iniciar o Visao Homolog.`n`nOs detalhes foram gravados em:`n$arquivoLog",
        'Erro ao iniciar o Visao Homolog',
        [System.Windows.MessageBoxButton]::OK,
        [System.Windows.MessageBoxImage]::Error
    ) | Out-Null

    exit 1
}
'@

    Set-Content -LiteralPath $caminhoInicializador -Value $conteudoInicializador -Encoding UTF8 -Force
    Unblock-File -LiteralPath $caminhoInicializador -ErrorAction SilentlyContinue

    Write-Host 'Criando o atalho na Area de Trabalho...' -ForegroundColor Cyan

    $wshell = New-Object -ComObject WScript.Shell

    try {
        $atalho = $wshell.CreateShortcut($caminhoAtalho)
        $atalho.TargetPath = $powershell51
        $atalho.Arguments = '-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File "{0}"' -f $caminhoInicializador
        $atalho.WorkingDirectory = $pastaModulo

        if (Test-Path -LiteralPath $caminhoIcone) {
            $atalho.IconLocation = "$caminhoIcone,0"
        }

        $atalho.Description = 'Visao HOMOLOG - TRE-MA / SEASU-COINF-STIC'
        $atalho.Save()
    }
    finally {
        if ($atalho) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($atalho) }
        if ($wshell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wshell) }
    }

    Write-Host ''
    Write-Host "Instalacao concluida! O icone 'Visao Homolog' ja esta na Area de Trabalho." -ForegroundColor Green
    Write-Host 'Pra atualizar pra uma versao nova no futuro, basta rodar de novo o Instalar-VisaoHomolog.bat.' -ForegroundColor Gray
    Write-Host 'Se ocorrer uma falha ao abrir, consulte Erro-VisaoHomolog.txt na Area de Trabalho.' -ForegroundColor Gray

    if ($ReabrirAoTerminar) {
        Write-Host ''
        Write-Host 'Reabrindo o Visao Homolog...' -ForegroundColor Cyan
        Start-Process -FilePath $powershell51 -ArgumentList @('-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$caminhoInicializador`"")
        Start-Sleep -Seconds 2
        exit 0
    }
}
catch {
    Write-Host ''
    Write-Host 'A instalacao nao foi concluida.' -ForegroundColor Red
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ''
    Write-Host ($_ | Out-String) -ForegroundColor DarkGray
    Pausar-SeInterativo
    exit 1
}

Pausar-SeInterativo
