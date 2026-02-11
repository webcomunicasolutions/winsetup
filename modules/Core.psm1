# Core.psm1 - Modulo base del sistema de automatizacion
# Funciones fundamentales: logging, elevacion, verificaciones de entorno

$Script:LogFile = $null

function Write-Log {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter()]
        [ValidateSet('Info', 'Warning', 'Error', 'Success')]
        [string]$Level = 'Info'
    )

    try {
        $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        $logEntry = "[$timestamp] [$Level] $Message"

        switch ($Level) {
            'Info'    { Write-Host $logEntry -ForegroundColor White }
            'Warning' { Write-Host $logEntry -ForegroundColor Yellow }
            'Error'   { Write-Host $logEntry -ForegroundColor Red }
            'Success' { Write-Host $logEntry -ForegroundColor Green }
        }

        if ($Script:LogFile -and (Test-Path (Split-Path $Script:LogFile -Parent))) {
            Add-Content -Path $Script:LogFile -Value $logEntry -Encoding UTF8
        }
    }
    catch {
        Write-Host "[LOG ERROR] No se pudo escribir al log: $_" -ForegroundColor Red
    }
}

function Test-Admin {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    }
    catch {
        Write-Log -Message "Error al verificar privilegios de administrador: $_" -Level Error
        return $false
    }
}

function Request-Elevation {
    [CmdletBinding()]
    param()

    try {
        if (Test-Admin) {
            Write-Log -Message "Ya se ejecuta como administrador" -Level Info
            return
        }

        Write-Log -Message "Solicitando elevacion de privilegios..." -Level Warning

        $scriptPath = $MyInvocation.PSCommandPath
        if (-not $scriptPath) {
            $scriptPath = $Script:MyInvocation.ScriptName
        }

        if ($scriptPath) {
            Start-Process -FilePath 'powershell.exe' `
                -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$scriptPath`"" `
                -Verb RunAs
        }
        else {
            Start-Process -FilePath 'powershell.exe' `
                -Verb RunAs
        }

        exit
    }
    catch {
        Write-Log -Message "Error al solicitar elevacion: $_" -Level Error
        throw "No se pudo elevar privilegios: $_"
    }
}

function Get-ScriptRoot {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    try {
        $root = $null

        if ($PSScriptRoot) {
            $root = Split-Path $PSScriptRoot -Parent
        }

        if (-not $root -or -not (Test-Path $root)) {
            $root = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Definition)
        }

        if (-not $root -or -not (Test-Path $root)) {
            $root = Get-Location | Select-Object -ExpandProperty Path
        }

        # Detectar si estamos en USB (letra de unidad diferente a C:)
        $drive = Split-Path $root -Qualifier
        if ($drive -and $drive -ne 'C:') {
            Write-Log -Message "Ejecutando desde unidad externa: $drive" -Level Info
        }

        return $root
    }
    catch {
        Write-Log -Message "Error al determinar la raiz del proyecto: $_" -Level Error
        return (Get-Location).Path
    }
}

function Test-Internet {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $dnsResult = Resolve-DnsName -Name 'www.microsoft.com' -Type A -DnsOnly -ErrorAction Stop
        if ($dnsResult) {
            Write-Log -Message "Conectividad a internet verificada (DNS)" -Level Success
            return $true
        }
    }
    catch {
        # DNS fallo, intentar con ping
    }

    try {
        $ping = Test-Connection -ComputerName '8.8.8.8' -Count 1 -Quiet -ErrorAction Stop
        if ($ping) {
            Write-Log -Message "Conectividad a internet verificada (ping)" -Level Success
            return $true
        }
    }
    catch {
        # Ping tambien fallo
    }

    Write-Log -Message "No se detecto conexion a internet" -Level Warning
    return $false
}

function Test-WingetAvailable {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    try {
        $winget = Get-Command winget -ErrorAction Stop
        if ($winget) {
            $version = & winget --version 2>$null
            Write-Log -Message "Winget disponible: $version" -Level Success
            return $true
        }
    }
    catch {
        Write-Log -Message "Winget no encontrado. Intentando instalar..." -Level Warning
    }

    # Intentar instalar winget desde GitHub releases oficial
    try {
        $ProgressPreference = 'SilentlyContinue'
        $tempDir = Join-Path $env:TEMP 'WingetInstall'
        if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }

        $wingetVersion = 'v1.12.470'
        $baseUrl = "https://github.com/microsoft/winget-cli/releases/download/$wingetVersion"

        # 1. Descargar dependencias oficiales (VCLibs + UI.Xaml incluidas)
        Write-Log -Message "Descargando dependencias de winget (esto puede tardar)..." -Level Info
        $depsUrl = "$baseUrl/DesktopAppInstaller_Dependencies.zip"
        $depsPath = Join-Path $tempDir 'deps.zip'
        Invoke-WebRequest -Uri $depsUrl -OutFile $depsPath -UseBasicParsing -ErrorAction Stop
        Write-Log -Message "Dependencias descargadas" -Level Info

        # 2. Descargar winget
        Write-Log -Message "Descargando winget $wingetVersion..." -Level Info
        $wingetUrl = "$baseUrl/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
        $wingetPath = Join-Path $tempDir 'winget.msixbundle'
        Invoke-WebRequest -Uri $wingetUrl -OutFile $wingetPath -UseBasicParsing -ErrorAction Stop
        Write-Log -Message "Winget descargado" -Level Info

        # 3. Instalar dependencias x64
        Write-Log -Message "Instalando dependencias..." -Level Info
        $depsDir = Join-Path $tempDir 'deps'
        Expand-Archive -Path $depsPath -DestinationPath $depsDir -Force

        $depsX64 = Join-Path $depsDir 'x64'
        if (Test-Path $depsX64) {
            Get-ChildItem "$depsX64\*.appx" | ForEach-Object {
                Write-Log -Message "  Instalando dependencia: $($_.Name)" -Level Info
                Add-AppxPackage -Path $_.FullName -ErrorAction SilentlyContinue
            }
        }

        # 4. Instalar winget
        Write-Log -Message "Instalando winget..." -Level Info
        Add-AppxPackage -Path $wingetPath -ForceApplicationShutdown -ErrorAction Stop

        # Limpiar
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue

        # Refrescar PATH
        $env:Path = [System.Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [System.Environment]::GetEnvironmentVariable("Path", "User")

        # Verificar
        $wingetCheck = Get-Command winget -ErrorAction SilentlyContinue
        if ($wingetCheck) {
            $version = & winget --version 2>$null
            Write-Log -Message "Winget instalado correctamente: $version" -Level Success
            return $true
        }

        # Ultimo intento: buscar directamente en WindowsApps
        $wingetExe = Resolve-Path "C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe" -ErrorAction SilentlyContinue | Select-Object -Last 1
        if ($wingetExe) {
            Write-Log -Message "Winget encontrado en: $($wingetExe.Path)" -Level Success
            $wingetDir = Split-Path $wingetExe.Path -Parent
            $env:Path += ";$wingetDir"
            return $true
        }
    }
    catch {
        Write-Log -Message "No se pudo instalar winget: $_" -Level Error
        Write-Log -Message "Instale manualmente: Abra Microsoft Store y busque 'App Installer'" -Level Warning
    }

    return $false
}

function Initialize-Environment {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $result = @{
        IsAdmin          = $false
        HasInternet      = $false
        HasWinget        = $false
        ProjectRoot      = $null
        LogFile          = $null
        SettingsLoaded   = $false
        Settings         = $null
        Initialized      = $false
    }

    try {
        # Determinar raiz del proyecto
        $result.ProjectRoot = Get-ScriptRoot
        Write-Log -Message "Raiz del proyecto: $($result.ProjectRoot)" -Level Info

        # Configurar logging
        $logsDir = Join-Path $result.ProjectRoot 'logs'
        if (-not (Test-Path $logsDir)) {
            New-Item -Path $logsDir -ItemType Directory -Force | Out-Null
        }

        $logFileName = "setup_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
        $Script:LogFile = Join-Path $logsDir $logFileName
        $result.LogFile = $Script:LogFile

        # Crear archivo de log
        New-Item -Path $Script:LogFile -ItemType File -Force | Out-Null
        Write-Log -Message "=== Inicio de sesion ===" -Level Info
        Write-Log -Message "Archivo de log: $Script:LogFile" -Level Info

        # Cargar configuracion
        $settingsPath = Join-Path (Join-Path $result.ProjectRoot 'config') 'settings.json'
        if (Test-Path $settingsPath) {
            $settingsContent = Get-Content -Path $settingsPath -Raw -Encoding UTF8
            $result.Settings = $settingsContent | ConvertFrom-Json
            $result.SettingsLoaded = $true
            Write-Log -Message "Configuracion cargada desde $settingsPath" -Level Success
        }
        else {
            Write-Log -Message "Archivo de configuracion no encontrado: $settingsPath" -Level Warning
        }

        # Verificar privilegios de administrador
        $result.IsAdmin = Test-Admin
        if ($result.IsAdmin) {
            Write-Log -Message "Ejecutando como administrador" -Level Success
        }
        else {
            Write-Log -Message "Ejecutando sin privilegios de administrador" -Level Warning
        }

        # Verificar conectividad a internet
        $result.HasInternet = Test-Internet

        # Verificar winget
        $result.HasWinget = Test-WingetAvailable

        $result.Initialized = $true
        Write-Log -Message "Entorno inicializado correctamente" -Level Success
    }
    catch {
        Write-Log -Message "Error durante la inicializacion del entorno: $_" -Level Error
        $result.Initialized = $false
    }

    return $result
}

Export-ModuleMember -Function @(
    'Write-Log',
    'Test-Admin',
    'Request-Elevation',
    'Get-ScriptRoot',
    'Test-Internet',
    'Test-WingetAvailable',
    'Initialize-Environment'
)
