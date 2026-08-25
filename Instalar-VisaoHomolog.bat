@echo off
rem Instalar-VisaoHomolog.bat
rem
rem Duplo-clique neste arquivo instala/atualiza a versao de HOMOLOGACAO
rem da Visao e cria o atalho "Visao Homolog" na Area de Trabalho, sem
rem afetar a instalacao de producao (modulo "Visao") ja existente na
rem mesma maquina. Chama o Instalar-VisaoHomolog.ps1 via linha de
rem comando (evita o aviso do Explorer sobre arquivo de rede).

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar-VisaoHomolog.ps1"

rem O proprio Instalar-VisaoHomolog.ps1 ja pausa e espera ENTER ao terminar.
if errorlevel 1 pause
