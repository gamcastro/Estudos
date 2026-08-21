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

    FASE 0 (atual): so a infraestrutura de teste de conexao. As funcoes de
    verdade (varredura, robocopy, planilhas Google, AD) sao movidas pra ca
    fase a fase, a partir do ScannerRedeZona.ps1 original - ver o plano.
#>

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
