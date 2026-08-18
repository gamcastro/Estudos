<#
    Script de diagnostico avulso - NAO faz parte da ferramenta principal.
    Objetivo: descobrir se da pra listar/paginar todos os computadores do
    OCS Inventory via API (para filtrar por zona no proprio script), ja que
    /computers/search?NAME=... so aceita nome EXATO (confirmado: nem prefixo
    nem coringa % funcionam).

    Rode este arquivo e me mande a saida completa (pode apagar/mascarar
    hostnames se achar que tem algo sensivel, mas provavelmente nao tem -
    sao so nomes de maquina e IP interno).
#>

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$base = "http://inventario.tre-ma.jus.br/ocsapi/v1"

function Testar {
    param([string]$Titulo, [string]$Url)
    Write-Host "`n=== $Titulo ===" -ForegroundColor Yellow
    Write-Host $Url -ForegroundColor Gray
    try {
        $resp = Invoke-RestMethod -Uri $Url -TimeoutSec 10
        $qtd = @($resp).Count
        Write-Host "OK - $qtd item(ns) retornado(s)." -ForegroundColor Green
        if ($qtd -gt 0) {
            Write-Host "Primeiro item (bruto):" -ForegroundColor Cyan
            @($resp)[0] | ConvertTo-Json -Depth 4
        } else {
            Write-Host "Resposta bruta (pode ser objeto/erro em vez de lista):" -ForegroundColor Cyan
            $resp | ConvertTo-Json -Depth 4
        }
    } catch {
        Write-Host "ERRO: $($_.Exception.Message)" -ForegroundColor Red
        if ($_.Exception.Response) {
            try { Write-Host "HTTP Status: $([int]$_.Exception.Response.StatusCode)" -ForegroundColor Red } catch {}
        }
    }
}

# 1) /computers/search SEM nenhum filtro - existe modo "listar tudo"?
Testar "1. search sem filtro (so start/limit)" "$base/computers/search?start=0&limit=5"

# 2) /computers (sem '/search') - endpoint separado de listagem?
Testar "2. /computers sem filtro" "$base/computers?start=0&limit=5"

# 3) raiz da API - alguns frameworks devolvem rotas/ajuda em 404 ou na raiz
Testar "3. raiz da API" "$base"
Testar "3b. raiz sem versao" "http://inventario.tre-ma.jus.br/ocsapi"

# 4) sanity check - nome EXATO conhecido (deve continuar funcionando)
Testar "4. nome exato conhecido (sanity check)" "$base/computers/search?start=0&limit=5&NAME=ZMA072WKS72384"

# 5) variantes de nome de parametro/operador que outras APIs OCS usam
Testar "5a. LIKE explicito" "$base/computers/search?start=0&limit=5&NAME_LIKE=ZMA072"
Testar "5b. colchete estilo GLPI/Laravel" "$base/computers/search?start=0&limit=5&NAME[like]=ZMA072"
Testar "5c. parametro 'q' generico" "$base/computers/search?start=0&limit=5&q=ZMA072"
Testar "5d. parametro 'search' generico" "$base/computers/search?start=0&limit=5&search=ZMA072"
