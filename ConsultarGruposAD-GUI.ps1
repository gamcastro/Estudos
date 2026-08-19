Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ============================================================
#  ConsultarGruposAD-GUI.ps1
#  TRE-MA | SEASU/COINF/STIC
#
#  Consulta os grupos do Active Directory aos quais um usuario
#  pertence, identificando-o pelo Titulo de Eleitor
#  (sAMAccountName no dominio tre-ma.gov.br).
#
#  Funciona com ou sem o modulo ActiveDirectory (RSAT):
#   - Se disponivel, usa Get-ADUser.
#   - Caso contrario, usa ADSI/DirectorySearcher (LDAP direto),
#     que nao depende de nenhum modulo extra.
#
#  Nao requer elevacao: e uma consulta somente leitura.
# ============================================================

$scriptVersion = "1.0"

# --- Verifica disponibilidade do modulo ActiveDirectory ---
$moduloAD = $null -ne (Get-Module -ListAvailable -Name ActiveDirectory)

# ---------------------------------------------------------------
# Form principal
# ---------------------------------------------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Consulta de Grupos AD - TRE-MA (v$scriptVersion)"
$form.Size = New-Object System.Drawing.Size(650, 560)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = "FixedDialog"
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::White

$lblTitulo = New-Object System.Windows.Forms.Label
$lblTitulo.Text = "Titulo de Eleitor (12 digitos):"
$lblTitulo.Location = New-Object System.Drawing.Point(20, 20)
$lblTitulo.Size = New-Object System.Drawing.Size(240, 20)
$lblTitulo.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$form.Controls.Add($lblTitulo)

$txtTitulo = New-Object System.Windows.Forms.TextBox
$txtTitulo.Location = New-Object System.Drawing.Point(20, 45)
$txtTitulo.Size = New-Object System.Drawing.Size(250, 25)
$txtTitulo.Font = New-Object System.Drawing.Font("Segoe UI", 11)
$txtTitulo.MaxLength = 12
$form.Controls.Add($txtTitulo)

# Aceita apenas digitos (e backspace)
$txtTitulo.Add_KeyPress({
    if (-not [char]::IsDigit($_.KeyChar) -and $_.KeyChar -ne [char]8) {
        $_.Handled = $true
    }
})

$btnConsultar = New-Object System.Windows.Forms.Button
$btnConsultar.Text = "Consultar"
$btnConsultar.Location = New-Object System.Drawing.Point(280, 43)
$btnConsultar.Size = New-Object System.Drawing.Size(110, 28)
$btnConsultar.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnConsultar.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnConsultar.ForeColor = [System.Drawing.Color]::White
$btnConsultar.FlatStyle = "Flat"
$form.Controls.Add($btnConsultar)

$btnLimpar = New-Object System.Windows.Forms.Button
$btnLimpar.Text = "Limpar"
$btnLimpar.Location = New-Object System.Drawing.Point(400, 43)
$btnLimpar.Size = New-Object System.Drawing.Size(90, 28)
$btnLimpar.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($btnLimpar)

$btnCopiar = New-Object System.Windows.Forms.Button
$btnCopiar.Text = "Copiar Resultado"
$btnCopiar.Location = New-Object System.Drawing.Point(500, 43)
$btnCopiar.Size = New-Object System.Drawing.Size(115, 28)
$btnCopiar.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Controls.Add($btnCopiar)

$rtbLog = New-Object System.Windows.Forms.RichTextBox
$rtbLog.Location = New-Object System.Drawing.Point(20, 85)
$rtbLog.Size = New-Object System.Drawing.Size(595, 415)
$rtbLog.Font = New-Object System.Drawing.Font("Consolas", 10)
$rtbLog.BackColor = [System.Drawing.Color]::Black
$rtbLog.ForeColor = [System.Drawing.Color]::White
$rtbLog.ReadOnly = $true
$rtbLog.Anchor = "Top, Bottom, Left, Right"
$form.Controls.Add($rtbLog)

# ---------------------------------------------------------------
# Log colorido no RichTextBox
# ---------------------------------------------------------------
function Write-Log {
    param(
        [string]$Message = "",
        [string]$Color = "White"
    )
    $rtbLog.SelectionStart = $rtbLog.TextLength
    $rtbLog.SelectionLength = 0
    $rtbLog.SelectionColor = [System.Drawing.Color]::$Color
    $rtbLog.AppendText("$Message`r`n")
    $rtbLog.SelectionColor = $rtbLog.ForeColor
    $rtbLog.ScrollToCaret()
}

# Extrai o nome do grupo a partir do DistinguishedName
function Get-NomeGrupo {
    param([string]$DistinguishedName)
    if ($DistinguishedName -match '^CN=([^,]+),') {
        return $Matches[1]
    }
    return $DistinguishedName
}

# ---------------------------------------------------------------
# Consulta via modulo ActiveDirectory
# ---------------------------------------------------------------
function Consultar-ViaModuloAD {
    param([string]$Titulo)
    return Get-ADUser -Identity $Titulo -Properties MemberOf, DisplayName, Enabled -ErrorAction Stop
}

# ---------------------------------------------------------------
# Consulta via ADSI (sem depender do modulo ActiveDirectory)
# ---------------------------------------------------------------
function Consultar-ViaADSI {
    param([string]$Titulo)

    $searcher = New-Object System.DirectoryServices.DirectorySearcher
    $searcher.Filter = "(sAMAccountName=$Titulo)"
    $searcher.PropertiesToLoad.AddRange(@("memberOf", "displayName", "userAccountControl")) | Out-Null
    $resultado = $searcher.FindOne()

    if ($null -eq $resultado) {
        return $null
    }

    [PSCustomObject]@{
        DisplayName = if ($resultado.Properties["displayname"].Count -gt 0) { $resultado.Properties["displayname"][0] } else { $Titulo }
        MemberOf    = $resultado.Properties["memberof"]
        UAC         = if ($resultado.Properties["useraccountcontrol"].Count -gt 0) { $resultado.Properties["useraccountcontrol"][0] } else { $null }
    }
}

# ---------------------------------------------------------------
# Acao principal
# ---------------------------------------------------------------
function Executar-Consulta {
    $titulo = $txtTitulo.Text.Trim()

    if ($titulo -notmatch '^\d{12}$') {
        Write-Log "[ERRO] O titulo de eleitor deve conter exatamente 12 digitos." "Red"
        return
    }

    $rtbLog.Clear()
    Write-Log "Consultando titulo $titulo no Active Directory..." "Cyan"
    Write-Log "Metodo: $(if ($moduloAD) { 'Modulo ActiveDirectory' } else { 'ADSI (LDAP direto)' })" "Gray"
    Write-Log "" "White"

    try {
        if ($moduloAD) {
            Import-Module ActiveDirectory -ErrorAction Stop
            $usuario = Consultar-ViaModuloAD -Titulo $titulo
            $nome    = $usuario.DisplayName
            $grupos  = $usuario.MemberOf
            $ativo   = $usuario.Enabled
        }
        else {
            $usuario = Consultar-ViaADSI -Titulo $titulo
            if ($null -eq $usuario) {
                Write-Log "[ERRO] Usuario nao encontrado no AD." "Red"
                return
            }
            $nome   = $usuario.DisplayName
            $grupos = $usuario.MemberOf
            $ativo  = if ($null -ne $usuario.UAC) { -not ([int]$usuario.UAC -band 2) } else { $null }
        }

        Write-Log "Usuario: $nome" "White"
        if ($null -ne $ativo) {
            if ($ativo) { Write-Log "Status: Ativo" "Green" }
            else { Write-Log "Status: DESABILITADO" "Yellow" }
        }
        Write-Log "" "White"

        if ($null -eq $grupos -or $grupos.Count -eq 0) {
            Write-Log "Nenhum grupo encontrado para este usuario." "Yellow"
        }
        else {
            $nomesGrupos = $grupos | ForEach-Object { Get-NomeGrupo $_ } | Sort-Object
            Write-Log "Grupos ($($nomesGrupos.Count)):" "Cyan"
            Write-Log "----------------------------------------" "DarkGray"
            foreach ($g in $nomesGrupos) {
                Write-Log "  - $g" "White"
            }
        }

        Write-Log "" "White"
        Write-Log "Consulta concluida." "Green"
    }
    catch [Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException] {
        Write-Log "[ERRO] Usuario nao encontrado no AD (titulo: $titulo)." "Red"
    }
    catch {
        Write-Log "[ERRO] Falha na consulta: $($_.Exception.Message)" "Red"
    }
}

$btnConsultar.Add_Click({ Executar-Consulta })

$btnLimpar.Add_Click({
    $txtTitulo.Clear()
    $rtbLog.Clear()
    $txtTitulo.Focus()
})

$btnCopiar.Add_Click({
    if ($rtbLog.Text.Length -gt 0) {
        [System.Windows.Forms.Clipboard]::SetText($rtbLog.Text)
        Write-Log "" "White"
        Write-Log "[Resultado copiado para a area de transferencia]" "DarkGray"
    }
})

# Enter no campo de titulo dispara a consulta
$txtTitulo.Add_KeyDown({
    if ($_.KeyCode -eq "Enter") {
        Executar-Consulta
        $_.SuppressKeyPress = $true
    }
})

$txtTitulo.Focus()
Write-Log "Consulta de Grupos AD - TRE-MA" "Cyan"
Write-Log "Digite o titulo de eleitor e clique em Consultar (ou pressione Enter)." "Gray"
Write-Log "" "White"

[void]$form.ShowDialog()