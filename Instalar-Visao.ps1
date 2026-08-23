<#
    Instalar-Visao.ps1

    Rode este arquivo UMA VEZ (botao direito > Executar com PowerShell)
    pra instalar a ferramenta Visao e criar o atalho na Area de
    Trabalho. Depois disso, e so clicar duas vezes no icone - nunca mais
    precisa abrir PowerShell nem digitar comando nenhum.

    Nao precisa de administrador - tudo roda no escopo do proprio
    usuario (CurrentUser).
#>

$repoNome = "VisaoRepoInterno"
$repoCaminho = "\\POLICY-SERVER.tre-ma.gov.br\ScanZonas\PSRepo"

Write-Host "Verificando o repositorio interno da Visao..." -ForegroundColor Cyan
if (-not (Get-PSRepository -Name $repoNome -ErrorAction SilentlyContinue)) {
    Register-PSRepository -Name $repoNome -SourceLocation $repoCaminho -PublishLocation $repoCaminho -InstallationPolicy Trusted
    Write-Host "Repositorio '$repoNome' registrado." -ForegroundColor Green
} else {
    Write-Host "Repositorio '$repoNome' ja estava registrado." -ForegroundColor Gray
}

Write-Host "Instalando/atualizando o modulo Visao (pode pedir pra instalar o provedor NuGet na primeira vez - confirme com Sim)..." -ForegroundColor Cyan
Install-Module -Name "Visao" -Repository $repoNome -Scope CurrentUser -Force

$moduloInfo = Get-Module -ListAvailable "Visao" | Sort-Object Version -Descending | Select-Object -First 1
if (-not $moduloInfo) {
    Write-Host "Falha ao instalar o modulo Visao - confira a mensagem de erro acima." -ForegroundColor Red
    exit 1
}
Write-Host "Modulo Visao $($moduloInfo.Version) instalado." -ForegroundColor Green

$pastaModulo = Split-Path $moduloInfo.Path -Parent
$caminhoIcone = Join-Path $pastaModulo "Visao.ico"
$caminhoAtalho = Join-Path ([Environment]::GetFolderPath("Desktop")) "Visao.lnk"

Write-Host "Criando o atalho na Area de Trabalho..." -ForegroundColor Cyan
$wshell = New-Object -ComObject WScript.Shell
$atalho = $wshell.CreateShortcut($caminhoAtalho)
$atalho.TargetPath = "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe"
$atalho.Arguments = '-NoProfile -WindowStyle Hidden -Command "Import-Module Visao; Start-Visao"'
if (Test-Path $caminhoIcone) { $atalho.IconLocation = $caminhoIcone }
$atalho.Description = "Visao - TRE-MA / SEASU-COINF-STIC"
$atalho.Save()
[void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wshell)

Write-Host ""
Write-Host "Instalacao concluida! O icone 'Visao' ja esta na Area de Trabalho." -ForegroundColor Green
Write-Host "Pra atualizar pra uma versao nova no futuro, basta rodar de novo este mesmo arquivo." -ForegroundColor Gray
