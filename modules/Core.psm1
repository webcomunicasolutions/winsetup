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

    # Intentar instalar winget via App Installer
    try {
        $progressPreference = 'SilentlyContinue'
        $latestUrl = 'https://aka.ms/getwinget'
        $installerPath = Join-Path $env:TEMP 'Microsoft.DesktopAppInstaller.msixbundle'

        Write-Log -Message "Descargando winget desde $latestUrl..." -Level Info
        Invoke-WebRequest -Uri $latestUrl -OutFile $installerPath -UseBasicParsing -ErrorAction Stop

        Write-Log -Message "Instalando winget..." -Level Info
        Add-AppxPackage -Path $installerPath -ErrorAction Stop

        Remove-Item $installerPath -Force -ErrorAction SilentlyContinue

        # Verificar que se instalo correctamente
        $wingetCheck = Get-Command winget -ErrorAction Stop
        if ($wingetCheck) {
            Write-Log -Message "Winget instalado correctamente" -Level Success
            return $true
        }
    }
    catch {
        Write-Log -Message "No se pudo instalar winget: $_" -Level Error
        Write-Log -Message "Instale manualmente desde: https://aka.ms/getwinget" -Level Warning
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
