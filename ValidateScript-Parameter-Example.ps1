[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
         [ValidateScript( {(Get-Content -Path $_ | Select-String -Pattern 'SISBB' -SimpleMatch -Quiet) -and (Test-Path -Path $_ -PathType Leaf)},ErrorMessage = "O arquivo não existe ou não é")]
       <#   [ValidateScript( {(Get-Content -Pat $_ | Select-String -Pattern 'SISBB' -SimpleMatch -Quiet)},ErrorMessage = "Não é um arquivo válido")] #>
        [string]$SourcePath
)
BEGIN {}
PROCESS {
    Write-Host $SourcePath
}