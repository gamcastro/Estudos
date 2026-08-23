@echo off
rem Instalar-Visao.bat
rem
rem Duplo-clique neste arquivo instala/atualiza a ferramenta Visao e cria
rem o atalho na Area de Trabalho. Chama o Instalar-Visao.ps1 diretamente
rem via linha de comando (powershell.exe -File), o que evita o aviso do
rem Explorer "Nao e possivel verificar quem criou este arquivo" que
rem aparece ao usar "Executar com PowerShell" num caminho de rede.

powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Instalar-Visao.ps1"

rem O proprio Instalar-Visao.ps1 ja pausa e espera ENTER ao terminar.
rem Este pause aqui e so uma rede de seguranca, caso o PowerShell falhe
rem em iniciar (script corrompido, etc.) antes mesmo de chegar la.
if errorlevel 1 pause
