#requires -Version 5.1

<#
    Instalar-Visao.ps1

    Instala/atualiza o modulo Visao no escopo do usuario atual (nao
    precisa de administrador) e cria um atalho confiavel na Area de
    Trabalho. Depois disso, e so clicar duas vezes no icone - nunca mais
    precisa abrir PowerShell nem digitar comando nenhum.

    Para rodar sem cair no aviso "Nao e possivel verificar quem criou
    este arquivo" do Explorer (mostrado quando o .ps1 e aberto direto de
    um caminho de rede fora da zona Intranet Local), use o atalho
    Instalar-Visao.bat que fica ao lado deste arquivo no repositorio -
    ele chama este script via linha de comando (powershell.exe -File),
    que nao passa pelo verbo "abrir" do Explorer e por isso nao dispara
    aquele aviso.
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$repoNome = 'VisaoRepoInterno'
$repoCaminho = '\\POLICY-SERVER.tre-ma.gov.br\ScanZonas\PSRepo'
$nomeModulo = 'Visao'

$pastaInicializador = Join-Path $env:LOCALAPPDATA 'SuporteTI\Visao'
$caminhoInicializador = Join-Path $pastaInicializador 'Iniciar-Visao.ps1'
$caminhoAtalho = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Visao.lnk'
$powershell51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'

function Pausar-SeInterativo {
    if ($Host.Name -eq 'ConsoleHost') {
        Write-Host ''
        Read-Host 'Pressione ENTER para fechar'
    }
}

try {
    Write-Host '=== Instalacao do Visao ===' -ForegroundColor Cyan
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

    Write-Host 'Instalando/atualizando o modulo Visao (pode pedir pra instalar o provedor NuGet na primeira vez - confirme com Sim)...' -ForegroundColor Cyan

    Install-Module -Name $nomeModulo -Repository $repoNome -Scope CurrentUser -Force -AllowClobber

    $moduloInfo = Get-Module -ListAvailable -Name $nomeModulo | Sort-Object Version -Descending | Select-Object -First 1

    if (-not $moduloInfo) {
        throw 'O modulo Visao nao foi localizado depois da instalacao.'
    }

    $pastaModulo = Split-Path -Path $moduloInfo.Path -Parent
    $caminhoIcone = Join-Path $pastaModulo 'Visao.ico'

    # O Install-Module as vezes preserva o "zone identifier" (marca de
    # arquivo baixado de rede) nos arquivos copiados do repositorio UNC.
    # Sem isso desbloqueado, o PowerShell pode recusar a carregar os
    # modulos silenciosamente dependendo da ExecutionPolicy da maquina.
    Write-Host 'Desbloqueando os arquivos instalados...' -ForegroundColor Cyan
    Get-ChildItem -LiteralPath $pastaModulo -Recurse -File | Unblock-File -ErrorAction SilentlyContinue

    Write-Host 'Validando o modulo...' -ForegroundColor Cyan
    Import-Module $moduloInfo.Path -Force -ErrorAction Stop

    if (-not (Get-Command -Name 'Start-Visao' -Module $nomeModulo -ErrorAction SilentlyContinue)) {
        throw 'O modulo foi carregado, mas nao exportou a funcao Start-Visao.'
    }

    Remove-Module -Name $nomeModulo -Force -ErrorAction SilentlyContinue

    Write-Host "Modulo Visao $($moduloInfo.Version) instalado." -ForegroundColor Green

    if (-not (Test-Path -LiteralPath $pastaInicializador)) {
        New-Item -Path $pastaInicializador -ItemType Directory -Force | Out-Null
    }

    # O inicializador roda de fato o Start-Visao a partir do atalho. Se
    # algo der errado (modulo corrompido, erro na interface etc.), ele
    # mostra uma mensagem amigavel em vez de so fechar a janela sem
    # explicacao, e grava os detalhes num arquivo na Area de Trabalho
    # pra facilitar o suporte remoto.
    $conteudoInicializador = @'
#requires -Version 5.1

$ErrorActionPreference = 'Stop'

try {
    Import-Module Visao -Force -ErrorAction Stop

    $comando = Get-Command Start-Visao -ErrorAction Stop
    & $comando
}
catch {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $arquivoLog = Join-Path $desktop 'Erro-Visao.txt'

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
        "Nao foi possivel iniciar o Visao.`n`nOs detalhes foram gravados em:`n$arquivoLog",
        'Erro ao iniciar o Visao',
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

        $atalho.Description = 'Visao - TRE-MA / SEASU-COINF-STIC'
        $atalho.Save()
    }
    finally {
        if ($atalho) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($atalho) }
        if ($wshell) { [void][Runtime.InteropServices.Marshal]::ReleaseComObject($wshell) }
    }

    Write-Host ''
    Write-Host "Instalacao concluida! O icone 'Visao' ja esta na Area de Trabalho." -ForegroundColor Green
    Write-Host 'Pra atualizar pra uma versao nova no futuro, basta rodar de novo o Instalar-Visao.bat.' -ForegroundColor Gray
    Write-Host 'Se ocorrer uma falha ao abrir, consulte Erro-Visao.txt na Area de Trabalho.' -ForegroundColor Gray
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
