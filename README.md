# Estudos - Toolkit PowerShell TRE-MA (SEASU-COINF-STIC)

Coleção de ferramentas PowerShell (GUI WinForms) usadas pelo suporte técnico
do TRE-MA para dar manutenção nas estações das zonas eleitorais - varredura
de rede, controle remoto, verificação de sistemas eleitorais instalados,
campanhas de atualização, e diagnósticos pontuais.

## Ferramenta principal: Visão

`VisaoCliente.ps1` (+ módulos `Visao*.psm1`) é a ferramenta central: varre a
rede de uma zona eleitoral, identifica hosts/impressoras, cruza com o OCS
Inventory, e permite ao técnico agir em cada máquina (VNC, RC Ivanti,
ContraSenha-LAPS, Transferidor Instseg, Wake-on-LAN) e gerenciar campanhas de
atualização de sistemas eleitorais (SIS, Criptosis, GEDAI-UE, Holocron etc.).

Arquitetura cliente-servidor: o cliente roda na estação do técnico e fala com
um `VisaoServidor.ps1` carregado numa sessão PS Remoting persistente no
POLICY-SERVER (duplo-salto Kerberos pra AD e SMB). Distribuída como módulo
PowerShell publicado num repositório interno (pasta de rede), instalada nas
estações via `Instalar-Visao.ps1`/`.bat` e atualizada com `Update-Module`.

Módulos:
- `VisaoCliente.ps1` - janela principal e orquestração dos eventos da GUI
- `VisaoRemoting.psm1` - sessão persistente, chamadas remotas, keepalive, log de conexão
- `VisaoServidor.ps1` - código que roda DENTRO da sessão remota no POLICY-SERVER
- `VisaoAD.psm1` - consultas ao Active Directory
- `VisaoPacotes.psm1` / `VisaoJanelaPacotes.psm1` - pacotes de instalação (Sistemas Eleitorais)
- `VisaoPlanilhas.psm1` - leitura/gravação de dados em planilhas Google (zonas, campanhas)
- `VisaoJanelaCampanhas.psm1` - verificação e relatório de campanhas
- `VisaoJanelaAdmin.psm1` - tela de configurações
- `VisaoAcoesLocais.psm1` - ações locais na estação do técnico (VNC, RC Ivanti, LAPS, etc.)
- `VisaoOcs.psm1` - integração com a API do OCS Inventory
- `apps_script_*.gs` - Google Apps Script usados pelos WebApps de campanha/zonas/CVC

### Homologação

Mudanças arriscadas passam primeiro pelo branch `homolog` + módulo
`VisaoHomolog` (instalado lado a lado com o `Visao` de produção, sem
conflito) para validação por técnicos-chave antes de promover pra produção.
Ver `Instalar-VisaoHomolog.ps1`/`.bat`.

## Outras ferramentas standalone

- `ScannerRedeZona.ps1` - scanner de rede portátil (USB, sem dependências), predecessor mais simples da Visão
- `ConectarVNC-GUI.ps1` - abre sessão VNC numa lista de máquinas
- `ConsultarGruposAD-GUI.ps1` - consulta grupos do Active Directory
- `wol_habilitar.ps1` - habilita Wake-on-LAN numa máquina
- `ocs_diagnostico.ps1`, `rcviewer_diagnostico.ps1`, `vnc_diagnostico.ps1` - scripts de diagnóstico pontual

## Requisitos

- Windows PowerShell 5.1
- Acesso de rede ao POLICY-SERVER (WinRM) e ao repositório interno (pasta de rede)
