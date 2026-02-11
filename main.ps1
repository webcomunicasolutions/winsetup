#Requires -Version 5.1
# =============================================================================
# main.ps1 - Configuracion automatica de Windows
# Instala software, aplica tweaks y remueve bloatware - TODO AUTOMATICO
# =============================================================================

param(
    [switch]$Menu  # Usar -Menu para modo interactivo con menu
)

# --- Determinar raiz del script ---
$ScriptRoot = $PSScriptRoot
if (-not $ScriptRoot) {
    $ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
}

# --- Cargar modulos ---
try {
    Import-Module "$ScriptRoot\modules\Core.psm1" -Force -ErrorAction Stop
    Import-Module "$ScriptRoot\modules\UI.psm1" -Force -ErrorAction Stop
    Import-Module "$ScriptRoot\modules\Software.psm1" -Force -ErrorAction Stop
    Import-Module "$ScriptRoot\modules\Tweaks.psm1" -Force -ErrorAction Stop -DisableNameChecking
    Import-Module "$ScriptRoot\modules\Bloatware.psm1" -Force -ErrorAction Stop
    Import-Module "$ScriptRoot\modules\Backup.psm1" -Force -ErrorAction Stop
}
catch {
    Write-Host "[ERROR] No se pudo cargar un modulo requerido: $_" -ForegroundColor Red
    Write-Host "Verifique que todos los archivos .psm1 existen en $ScriptRoot\modules\" -ForegroundColor Yellow
    Read-Host "Presione Enter para salir"
    exit 1
}

# --- Verificar permisos de administrador ---
if (-not (Test-Admin)) {
    Write-ColorText "Se requieren permisos de administrador." -Color Yellow
    Write-ColorText "Elevando permisos..." -Color Yellow
    Request-Elevation
    exit
}

# --- Inicializar entorno ---
try {
    $env = Initialize-Environment
    if (-not $env.Initialized) {
        Write-ColorText "Error critico al inicializar el entorno." -Color Red
        Read-Host "Presione Enter para salir"
        exit 1
    }
}
catch {
    Write-Host "[ERROR] Fallo la inicializacion: $_" -ForegroundColor Red
    Read-Host "Presione Enter para salir"
    exit 1
}

# --- Mostrar banner ---
Show-Banner

# --- Verificar conectividad ---
if (-not $env.HasInternet) {
    Write-ColorText "Sin conexion a internet. La instalacion de software no funcionara." -Color Yellow
}

if (-not $env.HasWinget) {
    Write-ColorText "winget no disponible. La instalacion de software via winget no funcionara." -Color Red
}

# --- Cargar settings ---
$settingsPath = Join-Path $ScriptRoot "config\settings.json"
$settings = $null
try {
    if (Test-Path $settingsPath) {
        $settings = Get-Content -Path $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
        Write-Log -Message "Configuracion cargada desde $settingsPath" -Level Info
    }
    else {
        Write-Log -Message "Archivo settings.json no encontrado, usando valores por defecto" -Level Warning
    }
}
catch {
    Write-Log -Message "Error al leer settings.json: $_" -Level Warning
}

# --- Definir rutas de configuracion ---
$configPaths = @{
    Software  = Join-Path $ScriptRoot "config\software.json"
    Tweaks    = Join-Path $ScriptRoot "config\tweaks.json"
    Bloatware = Join-Path $ScriptRoot "config\bloatware.json"
    Backups   = Join-Path $ScriptRoot "backups"
}

# Crear directorio de backups si no existe
if (-not (Test-Path $configPaths.Backups)) {
    New-Item -Path $configPaths.Backups -ItemType Directory -Force | Out-Null
}

# =============================================================================
# MODO AUTOMATICO (por defecto) o MODO MENU (con -Menu)
# =============================================================================

if ($Menu) {
    # --- MODO MENU INTERACTIVO ---
    $running = $true
    while ($running) {
        try {
            $choice = Show-MainMenu

            switch ($choice) {
                1 {
                    if (-not $env.HasWinget) {
                        Write-ColorText "winget no esta disponible. No se puede instalar software." -Color Red
                        Start-Sleep -Seconds 2
                    }
                    else {
                        Start-SoftwareInstallation -ConfigPath $configPaths.Software
                    }
                }
                2 {
                    Start-TweaksConfiguration -ConfigPath $configPaths.Tweaks
                }
                3 {
                    Start-BloatwareRemoval -ConfigPath $configPaths.Bloatware
                }
                4 {
                    # Ejecutar todo automatico desde menu
                    Write-Header -Title "CONFIGURACION COMPLETA"
                    if (Show-Confirmation -Message "Esto instalara software, aplicara tweaks y removera bloatware. Continuar?") {
                        & $ScriptRoot\main.ps1  # Re-ejecutar sin -Menu
                    }
                }
                5 {
                    $logDir = Join-Path $ScriptRoot "logs"
                    $latestLog = Get-ChildItem -Path $logDir -Filter "*.log" -ErrorAction SilentlyContinue |
                        Sort-Object LastWriteTime -Descending |
                        Select-Object -First 1

                    if ($latestLog) {
                        Write-Header -Title "LOG ACTUAL"
                        Get-Content $latestLog.FullName | Out-Host
                        Read-Host "Presione Enter para continuar"
                    }
                    else {
                        Write-ColorText "No hay logs disponibles." -Color Yellow
                        Start-Sleep -Seconds 2
                    }
                }
                6 {
                    $running = $false
                }
                default {
                    Write-ColorText "Opcion no valida." -Color Red
                    Start-Sleep -Seconds 1
                }
            }
        }
        catch {
            Write-Log -Message "Error inesperado en el menu principal: $_" -Level Error
            Write-ColorText "Ocurrio un error inesperado. Revise el log para mas detalles." -Color Red
            Start-Sleep -Seconds 2
        }
    }
}
else {
    # --- MODO AUTOMATICO (por defecto) ---
    Write-Header -Title "CONFIGURACION AUTOMATICA DE WINDOWS"
    Write-Host ""
    Write-ColorText "Se ejecutara la configuracion completa:" -Color Cyan
    Write-Host "  1. Crear punto de restauracion y backup" -ForegroundColor White
    Write-Host "  2. Instalar software recomendado" -ForegroundColor White
    Write-Host "  3. Aplicar configuraciones del sistema" -ForegroundColor White
    Write-Host "  4. Remover bloatware" -ForegroundColor White
    Write-Host ""

    # --- Paso 1: Backup y punto de restauracion ---
    Write-Section -Title "Paso 1/4: Backup y punto de restauracion"
    try {
        if ($settings -and $settings.options.createRestorePoint) {
            New-SystemRestorePoint -Description "WinSetup - Pre configuracion"
        }
        New-FullBackup -BackupDir $configPaths.Backups
        Write-Log -Message "Backup completado" -Level Success
    }
    catch {
        Write-Log -Message "Error al crear backup: $_" -Level Warning
        Write-ColorText "No se pudo crear backup completo, pero se continua..." -Color Yellow
    }

    # --- Paso 2: Instalar software recomendado ---
    $swResults = @{ Success = @(); Failed = @(); Skipped = @() }
    Write-Section -Title "Paso 2/4: Instalando software"
    if ($env.HasWinget) {
        try {
            $swResults = Install-RecommendedSoftware -ConfigPath $configPaths.Software
            if (-not $swResults) {
                $swResults = @{ Success = @(); Failed = @(); Skipped = @() }
            }
        }
        catch {
            Write-Log -Message "Error en instalacion de software: $_" -Level Error
        }
    }
    else {
        Write-Log -Message "winget no disponible, omitiendo instalacion via winget" -Level Warning
    }

    # --- Paso 3: Aplicar tweaks recomendados ---
    $twResults = @{ Success = @(); Failed = @(); Skipped = @() }
    Write-Section -Title "Paso 3/4: Aplicando configuraciones"
    try {
        $twResults = Apply-RecommendedTweaks -ConfigPath $configPaths.Tweaks
        if (-not $twResults) {
            $twResults = @{ Success = @(); Failed = @(); Skipped = @() }
        }
    }
    catch {
        Write-Log -Message "Error en tweaks: $_" -Level Error
    }

    # --- Paso 4: Remover bloatware recomendado ---
    $blResults = @{ Success = @(); Failed = @(); Skipped = @() }
    Write-Section -Title "Paso 4/4: Removiendo bloatware"
    try {
        $blResults = Remove-RecommendedBloatware -ConfigPath $configPaths.Bloatware
        if (-not $blResults) {
            $blResults = @{ Success = @(); Failed = @(); Skipped = @() }
        }
    }
    catch {
        Write-Log -Message "Error en remocion de bloatware: $_" -Level Error
    }

    # --- Resumen final ---
    Write-Host ""
    $combined = @{
        Success = @($swResults.Success) + @($twResults.Success) + @($blResults.Success)
        Failed  = @($swResults.Failed) + @($twResults.Failed) + @($blResults.Failed)
        Skipped = @($swResults.Skipped) + @($twResults.Skipped) + @($blResults.Skipped)
    }
    Show-Summary -Results $combined

    Write-Log -Message "Configuracion completa finalizada" -Level Success
}

# --- Despedida ---
Write-Host ""
Write-ColorText "Configuracion finalizada." -Color Green
Write-Host ""

if (Show-Confirmation -Message "Desea reiniciar el equipo ahora?") {
    Write-ColorText "Reiniciando en 5 segundos..." -Color Yellow
    Start-Sleep -Seconds 5
    Restart-Computer -Force
}
else {
    Write-ColorText "Puede reiniciar manualmente mas tarde para aplicar todos los cambios." -Color Cyan
}
