#Requires -Version 5.1
# =============================================================================
# main.ps1 - Configuracion automatica de Windows
# Instala software, aplica tweaks y remueve bloatware - TODO AUTOMATICO
#
# Ejemplos:
#   .\main.ps1                                  todo lo recomendado (como siempre)
#   .\main.ps1 -SoloTweaks                      solo tweaks, sin instalar programas
#   .\main.ps1 -SoloTweaks -Usuario ana         tweaks de usuario en la cuenta 'ana'
#   .\main.ps1 -SoloSoftware -Profile cliente   solo programas del perfil
#   .\main.ps1 -SoloTweaks -SoloBloatware       se pueden combinar
#   .\main.ps1 -Menu                            menu interactivo
#
# Desatendido (Manhattan/SYSTEM, via setup.ps1) con variables de entorno:
#   WINSETUP_UNATTENDED=1  WINSETUP_PROFILE=<perfil>
#   WINSETUP_SOLO=tweaks | software | bloatware | "tweaks,bloatware"
#   WINSETUP_USUARIO=<cuenta>   (OBLIGATORIO para tweaks de usuario como SYSTEM)
# Los parametros mandan sobre las variables de entorno.
# =============================================================================

param(
    [switch]$Menu,          # Modo interactivo con menu
    [string]$Profile,       # Perfil de cliente: carga config desde config/<Profile>/
    [switch]$SoloSoftware,  # Solo instalar el software recomendado
    [switch]$SoloTweaks,    # Solo aplicar los tweaks recomendados
    [switch]$SoloBloatware, # Solo quitar el bloatware recomendado
    [string]$Usuario        # Cuenta que recibe los tweaks de usuario (HKCU)
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
    # Aqui NO se puede usar Wait-UserAck: viene de Core.psm1 y justo ha fallado la
    # carga de modulos. Se queda Read-Host, pero solo si hay alguien delante.
    if ([Environment]::UserInteractive -and $env:WINSETUP_UNATTENDED -ne '1') {
        Read-Host "Presione Enter para salir"
    }
    exit 1
}

# --- Resolver que pasos se ejecutan ---
# Una errata en WINSETUP_SOLO NO puede acabar en "todo" (instalaria Office encima
# de un Microsoft 365): un valor desconocido para el script.
$pasosValidos = @('software', 'tweaks', 'bloatware')
$pasos = @()
if ($SoloSoftware)  { $pasos += 'software' }
if ($SoloTweaks)    { $pasos += 'tweaks' }
if ($SoloBloatware) { $pasos += 'bloatware' }
if ($pasos.Count -eq 0 -and $env:WINSETUP_SOLO) {
    foreach ($p in ($env:WINSETUP_SOLO -split '[,;\s]+' | Where-Object { $_ })) {
        $p = $p.Trim().ToLower()
        if ($pasosValidos -notcontains $p) {
            Write-Host "[ERROR] WINSETUP_SOLO='$($env:WINSETUP_SOLO)': '$p' no es valido. Validos: $($pasosValidos -join ', ')" -ForegroundColor Red
            exit 1
        }
        if ($pasos -notcontains $p) { $pasos += $p }
    }
}
$esSolo = $pasos.Count -gt 0
if (-not $esSolo) { $pasos = $pasosValidos }

if (-not $Usuario -and $env:WINSETUP_USUARIO) { $Usuario = $env:WINSETUP_USUARIO }

if ($Menu -and $esSolo) {
    Write-Host "[ERROR] -Menu no se combina con -SoloSoftware/-SoloTweaks/-SoloBloatware (el menu ya tiene esas opciones)" -ForegroundColor Red
    exit 1
}
if ($Menu -and -not (Test-InteractiveSession)) {
    Write-Host "[ERROR] -Menu necesita a alguien delante y esta sesion no es interactiva (SYSTEM/WinRM/SSH/WINSETUP_UNATTENDED)" -ForegroundColor Red
    exit 1
}

# --- Resolver perfil de configuracion ---
$configDir = Join-Path $ScriptRoot "config"
if ($Profile) {
    $profileDir = Join-Path $configDir $Profile
    if (-not (Test-Path $profileDir)) {
        Write-Host "[ERROR] Perfil '$Profile' no encontrado en $profileDir" -ForegroundColor Red
        Write-Host "Perfiles disponibles:" -ForegroundColor Yellow
        Get-ChildItem -Path $configDir -Directory | Where-Object { $_.Name -ne '_template' } | ForEach-Object {
            if (Test-Path (Join-Path $_.FullName "software.json")) {
                Write-Host "  - $($_.Name)" -ForegroundColor White
            }
        }
        Write-Host ""
        Write-Host "Para crear uno nuevo, copie config\_template\ con el nombre del cliente." -ForegroundColor Gray
        Wait-UserAck -Message "Presione Enter para salir"
        exit 1
    }
    Write-Host "[PERFIL] Usando configuracion: $Profile" -ForegroundColor Magenta
}

# --- Verificar permisos de administrador ---
if (-not (Test-Admin)) {
    Write-ColorText "Se requieren permisos de administrador." -Color Yellow
    Write-ColorText "Elevando permisos..." -Color Yellow
    $relanzar = @()
    if ($Menu)          { $relanzar += '-Menu' }
    if ($Profile)       { $relanzar += "-Profile `"$Profile`"" }
    if ($SoloSoftware)  { $relanzar += '-SoloSoftware' }
    if ($SoloTweaks)    { $relanzar += '-SoloTweaks' }
    if ($SoloBloatware) { $relanzar += '-SoloBloatware' }
    if ($Usuario)       { $relanzar += "-Usuario `"$Usuario`"" }
    Request-Elevation -ExtraArguments ($relanzar -join ' ')
    exit
}

# --- Inicializar entorno ---
try {
    $env = Initialize-Environment
    if (-not $env.Initialized) {
        Write-ColorText "Error critico al inicializar el entorno." -Color Red
        Wait-UserAck -Message "Presione Enter para salir"
        exit 1
    }
}
catch {
    Write-Host "[ERROR] Fallo la inicializacion: $_" -ForegroundColor Red
    Wait-UserAck -Message "Presione Enter para salir"
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

# --- Definir rutas de configuracion (perfil con fallback a default) ---
function Resolve-ConfigPath {
    param([string]$FileName)
    if ($Profile) {
        $profilePath = Join-Path $ScriptRoot "config\$Profile\$FileName"
        if (Test-Path $profilePath) { return $profilePath }
    }
    return Join-Path $ScriptRoot "config\$FileName"
}

$configPaths = @{
    Software  = Resolve-ConfigPath "software.json"
    Tweaks    = Resolve-ConfigPath "tweaks.json"
    Bloatware = Resolve-ConfigPath "bloatware.json"
    Backups   = Join-Path $ScriptRoot "backups"
}

if ($Profile) {
    Write-Log -Message "Config software: $($configPaths.Software)" -Level Info
    Write-Log -Message "Config tweaks: $($configPaths.Tweaks)" -Level Info
    Write-Log -Message "Config bloatware: $($configPaths.Bloatware)" -Level Info
}

# Crear directorio de backups si no existe
if (-not (Test-Path $configPaths.Backups)) {
    New-Item -Path $configPaths.Backups -ItemType Directory -Force | Out-Null
}

# --- Destino de los tweaks de usuario (HKCU) ---
# Se fija aqui, una vez, y se libera en el finally del final (un NTUSER.DAT que
# se queda cargado impide a esa persona entrar con su perfil).
$necesitaTweaks = $Menu -or ($pasos -contains 'tweaks')
if ($Usuario -and $necesitaTweaks) {
    if (-not (Set-TweaksUserTarget -Usuario $Usuario)) {
        Write-ColorText "No se pudo preparar el usuario destino '$Usuario'. No se aplica nada para no escribir en otra cuenta." -Color Red
        Wait-UserAck -Message "Presione Enter para salir"
        exit 1
    }
}
if ($necesitaTweaks) {
    $destino = Get-TweaksUserTargetDescription
    Write-Log -Message "Tweaks de usuario (HKCU) se aplican a: $destino" -Level Info
    Write-ColorText "Tweaks de usuario para: $destino" -Color Magenta
}

# =============================================================================
# Ejecucion de los pasos recomendados (todo, o solo los pedidos)
# =============================================================================
function Invoke-PasosRecomendados {
    param([string[]]$Pasos)

    $vacio = @{ Success = @(); Failed = @(); Skipped = @() }
    $resultados = @()
    $total = $Pasos.Count + 1
    $n = 1

    $headerTitle = if ($Pasos.Count -eq 3) { "CONFIGURACION AUTOMATICA DE WINDOWS" } else { "SOLO: $(($Pasos -join ' + ').ToUpper())" }
    if ($Profile) { $headerTitle += " - PERFIL: $($Profile.ToUpper())" }
    Write-Header -Title $headerTitle
    Write-Log -Message "Pasos a ejecutar: $($Pasos -join ', ')" -Level Info

    # --- Backup y punto de restauracion (solo si se toca el sistema) ---
    if ($Pasos -contains 'tweaks' -or $Pasos -contains 'bloatware') {
        Write-Section -Title "Paso $n/$($total): Backup y punto de restauracion"
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
    }
    else { $total-- ; $n-- }
    $n++

    if ($Pasos -contains 'software') {
        Write-Section -Title "Paso $n/$($total): Instalando software"
        $n++
        if ($env.HasWinget) {
            try {
                $r = Install-RecommendedSoftware -ConfigPath $configPaths.Software
                $resultados += ,$(if ($r) { $r } else { $vacio })
            }
            catch { Write-Log -Message "Error en instalacion de software: $_" -Level Error }
        }
        else {
            Write-Host ""
            Write-Host "  !! WINGET NO DISPONIBLE !!" -ForegroundColor Red
            Write-Host "  No se puede instalar software automaticamente." -ForegroundColor Yellow
            Write-Host "  Instale 'App Installer' desde Microsoft Store y vuelva a ejecutar." -ForegroundColor Yellow
            Write-Host ""
            Write-Log -Message "winget no disponible, omitiendo instalacion de software" -Level Warning
            Start-Sleep -Seconds 3
        }
    }

    if ($Pasos -contains 'tweaks') {
        Write-Section -Title "Paso $n/$($total): Aplicando configuraciones"
        $n++
        try {
            $r = Apply-RecommendedTweaks -ConfigPath $configPaths.Tweaks
            $resultados += ,$(if ($r) { $r } else { $vacio })
        }
        catch { Write-Log -Message "Error en tweaks: $_" -Level Error }
    }

    if ($Pasos -contains 'bloatware') {
        Write-Section -Title "Paso $n/$($total): Removiendo bloatware"
        $n++
        try {
            $r = Remove-RecommendedBloatware -ConfigPath $configPaths.Bloatware
            $resultados += ,$(if ($r) { $r } else { $vacio })
        }
        catch { Write-Log -Message "Error en remocion de bloatware: $_" -Level Error }
    }

    # --- Resumen final ---
    Write-Host ""
    $combined = @{ Success = @(); Failed = @(); Skipped = @() }
    foreach ($r in $resultados) {
        $combined.Success += @($r.Success)
        $combined.Failed  += @($r.Failed)
        $combined.Skipped += @($r.Skipped)
    }
    Show-Summary -Results $combined
    Write-Log -Message "Configuracion finalizada ($($Pasos -join ', '))" -Level Success
}

# =============================================================================
# MODO AUTOMATICO (por defecto) o MODO MENU (con -Menu)
# =============================================================================

try {
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
                    { $_ -in 4, 5, 6, 7 } {
                        $elegidos = switch ($choice) {
                            4 { @('software', 'tweaks', 'bloatware') }
                            5 { @('tweaks') }
                            6 { @('software') }
                            7 { @('bloatware') }
                        }
                        if (Show-Confirmation -Message "Se aplicara lo recomendado de: $($elegidos -join ', '). Continuar?") {
                            Invoke-PasosRecomendados -Pasos $elegidos
                            Wait-UserAck -Message "Presione Enter para volver al menu"
                        }
                    }
                    8 {
                        $logDir = Join-Path $ScriptRoot "logs"
                        $latestLog = Get-ChildItem -Path $logDir -Filter "*.log" -ErrorAction SilentlyContinue |
                            Sort-Object LastWriteTime -Descending |
                            Select-Object -First 1

                        if ($latestLog) {
                            Write-Header -Title "LOG ACTUAL"
                            Get-Content $latestLog.FullName | Out-Host
                            Wait-UserAck -Message "Presione Enter para continuar"
                        }
                        else {
                            Write-ColorText "No hay logs disponibles." -Color Yellow
                            Start-Sleep -Seconds 2
                        }
                    }
                    9 {
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
        # --- MODO AUTOMATICO (todo por defecto, o solo lo pedido) ---
        Invoke-PasosRecomendados -Pasos $pasos
    }
}
finally {
    # Descargar el NTUSER.DAT del usuario destino si lo cargamos (tambien con Ctrl+C)
    Clear-TweaksUserTarget
}

# --- Despedida ---
Write-Host ""
Write-Host ""
Write-Header -Title "PROCESO COMPLETADO"
Write-ColorText "Toda la configuracion ha finalizado." -Color Green
Write-Host ""
Write-Host "  Revise el resumen de arriba para ver que se instalo/configuro." -ForegroundColor White
Write-Host ""
Write-Host ""
Write-Host "  ============================================" -ForegroundColor Red
Write-Host "    ATENCION: La siguiente pregunta reinicia" -ForegroundColor Red
Write-Host "    el equipo. Responda N si no esta seguro." -ForegroundColor Red
Write-Host "  ============================================" -ForegroundColor Red
Write-Host ""

if (Show-Confirmation -Message "Desea REINICIAR el equipo ahora?") {
    Write-Host ""
    for ($countdown = 10; $countdown -ge 1; $countdown--) {
        Write-Host "`r  Reiniciando en $countdown segundos... (Ctrl+C para cancelar)   " -ForegroundColor Yellow -NoNewline
        Start-Sleep -Seconds 1
    }
    Write-Host ""
    Restart-Computer -Force
}
else {
    Write-ColorText "Puede reiniciar manualmente mas tarde para aplicar todos los cambios." -Color Cyan
}

Write-Host ""
Wait-UserAck -Message "Presione Enter para cerrar esta ventana"
