# =============================================================================
# setup.ps1 - Configuracion automatica de Windows
#
# USO: Abrir PowerShell como Administrador y ejecutar:
#   irm https://raw.githubusercontent.com/webcomunicasolutions/winsetup/main/setup.ps1 | iex
#
# Tambien funciona desde USB/local: .\setup.ps1
# =============================================================================

# --- Auto-elevar a administrador si no lo es ---
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Se necesitan permisos de administrador. Elevando..." -ForegroundColor Yellow
    $cmdLine = "irm https://raw.githubusercontent.com/webcomunicasolutions/winsetup/main/setup.ps1 | iex"
    Start-Process powershell -Verb RunAs -ArgumentList "-NoProfile -ExecutionPolicy Bypass -Command `"$cmdLine`""
    return
}

# --- Si estamos en local (USB), ejecutar directamente ---
if ($PSScriptRoot -and (Test-Path (Join-Path $PSScriptRoot "main.ps1"))) {
    Write-Host "Ejecutando desde directorio local..." -ForegroundColor Green
    & (Join-Path $PSScriptRoot "main.ps1")
    return
}

# --- Descarga online desde GitHub ---
$repoOwner = "webcomunicasolutions"
$repoName = "winsetup"
$branch = "main"
$repoUrl = "https://github.com/$repoOwner/$repoName/archive/refs/heads/$branch.zip"
$installDir = "$env:TEMP\WinSetup"
$zipPath = "$env:TEMP\WinSetup.zip"

Clear-Host
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host "    WinSetup - Configuracion automatica" -ForegroundColor Cyan
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Descargando desde GitHub..." -ForegroundColor White
Write-Host "  Repo: $repoOwner/$repoName" -ForegroundColor Gray
Write-Host ""

try {
    # TLS 1.2 necesario para GitHub
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Descargar ZIP del repositorio
    Invoke-WebRequest -Uri $repoUrl -OutFile $zipPath -UseBasicParsing -ErrorAction Stop
    Write-Host "  [OK] Descarga completada" -ForegroundColor Green

    # Limpiar directorio previo si existe
    if (Test-Path $installDir) {
        Remove-Item $installDir -Recurse -Force
    }

    # Extraer ZIP
    Write-Host "  [..] Extrayendo archivos..." -ForegroundColor White
    Expand-Archive -Path $zipPath -DestinationPath $installDir -Force
    Write-Host "  [OK] Archivos extraidos" -ForegroundColor Green

    # Buscar main.ps1 dentro de la carpeta extraida
    # GitHub crea una subcarpeta: winsetup-main/
    $mainScript = Get-ChildItem -Path $installDir -Recurse -Filter "main.ps1" |
        Select-Object -First 1

    if ($mainScript) {
        Write-Host "  [OK] Script encontrado" -ForegroundColor Green
        Write-Host ""
        Write-Host "  Iniciando configuracion..." -ForegroundColor Cyan
        Write-Host ""
        Start-Sleep -Seconds 1

        # Ejecutar main.ps1
        & $mainScript.FullName
    }
    else {
        Write-Host "  [ERROR] No se encontro main.ps1 en la descarga" -ForegroundColor Red
        Write-Host "  Verifique que el repositorio $repoOwner/$repoName existe" -ForegroundColor Yellow
    }
}
catch {
    Write-Host ""
    Write-Host "  [ERROR] Fallo la descarga: $_" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Posibles causas:" -ForegroundColor Yellow
    Write-Host "    - Sin conexion a internet" -ForegroundColor Gray
    Write-Host "    - El repositorio no existe o es privado" -ForegroundColor Gray
    Write-Host "    - GitHub no accesible desde esta red" -ForegroundColor Gray
    Write-Host ""
    Write-Host "  Alternativa: Descarga el ZIP manualmente desde:" -ForegroundColor White
    Write-Host "  https://github.com/$repoOwner/$repoName/archive/refs/heads/$branch.zip" -ForegroundColor Cyan
}
finally {
    # Limpiar ZIP descargado
    if (Test-Path $zipPath) {
        Remove-Item $zipPath -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Read-Host "Presione Enter para cerrar"
