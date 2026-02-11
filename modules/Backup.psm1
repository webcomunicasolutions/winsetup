# Backup.psm1 - Modulo de respaldo y restauracion del sistema
# Puntos de restauracion, backup de registry, exportacion de configuracion

function New-SystemRestorePoint {
    <#
    .SYNOPSIS
        Crea un punto de restauracion del sistema.
    .PARAMETER Description
        Descripcion del punto de restauracion.
    .OUTPUTS
        [bool] $true si se creo correctamente, $false si fallo.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter()]
        [string]$Description = "WinSetup Backup"
    )

    try {
        Write-Log -Message "Creando punto de restauracion: '$Description'" -Level Info

        # Verificar que el servicio de restauracion esta habilitado
        $srService = Get-Service -Name 'srservice' -ErrorAction SilentlyContinue
        if (-not $srService -or $srService.Status -ne 'Running') {
            Write-Log -Message "El servicio de restauracion del sistema no esta activo" -Level Warning
            try {
                Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
                Write-Log -Message "Restauracion del sistema habilitada en $env:SystemDrive" -Level Info
            }
            catch {
                Write-Log -Message "No se pudo habilitar la restauracion del sistema: $_" -Level Error
                return $false
            }
        }

        Checkpoint-Computer -Description $Description -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log -Message "Punto de restauracion creado correctamente" -Level Success
        return $true
    }
    catch {
        $errorMsg = $_.Exception.Message

        # Windows limita a 1 punto de restauracion cada 24 horas
        if ($errorMsg -match 'frecuencia|frequency|already.*created|1410') {
            Write-Log -Message "Ya existe un punto de restauracion reciente (limite de 24h). Continuando sin crear nuevo punto." -Level Warning
            return $true
        }

        Write-Log -Message "Error al crear punto de restauracion: $_" -Level Error
        return $false
    }
}

function Backup-RegistryHive {
    <#
    .SYNOPSIS
        Exporta una rama del registro a un archivo .reg.
    .PARAMETER HivePath
        Ruta de la rama del registro (ej: "HKCU\Software\Microsoft\Windows").
    .PARAMETER BackupDir
        Directorio donde guardar el backup.
    .OUTPUTS
        [string] Ruta del archivo de backup, o $null si fallo.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$HivePath,

        [Parameter(Mandatory = $true)]
        [string]$BackupDir
    )

    try {
        # Crear directorio de backup si no existe
        if (-not (Test-Path $BackupDir)) {
            New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null
            Write-Log -Message "Directorio de backup creado: $BackupDir" -Level Info
        }

        # Generar nombre de archivo basado en timestamp y nombre del hive
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $hiveName = ($HivePath -replace '\\', '_' -replace ':', '')
        $backupFile = Join-Path $BackupDir "backup_${timestamp}_${hiveName}.reg"

        Write-Log -Message "Exportando registro: $HivePath -> $backupFile" -Level Info

        $regOutput = & reg export "$HivePath" "$backupFile" /y 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0 -and (Test-Path $backupFile)) {
            $fileSize = (Get-Item $backupFile).Length
            Write-Log -Message "Backup de registro completado ($([math]::Round($fileSize / 1KB, 1)) KB): $backupFile" -Level Success
            return $backupFile
        }

        Write-Log -Message "reg export fallo con codigo $exitCode`: $($regOutput | Out-String)" -Level Error
        return $null
    }
    catch {
        Write-Log -Message "Error al hacer backup del registro '$HivePath': $_" -Level Error
        return $null
    }
}

function New-FullBackup {
    <#
    .SYNOPSIS
        Crea backup completo de las claves de registro que el script modifica
        y exporta la lista de AppxPackage actuales.
    .PARAMETER BackupDir
        Directorio donde guardar los backups.
    .OUTPUTS
        [string[]] Array de rutas de archivos de backup creados.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupDir
    )

    $backupFiles = @()
    $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $sessionDir = Join-Path $BackupDir "backup_$timestamp"

    try {
        # Crear subdirectorio para esta sesion de backup
        if (-not (Test-Path $sessionDir)) {
            New-Item -Path $sessionDir -ItemType Directory -Force | Out-Null
        }

        Write-Log -Message "Iniciando backup completo en: $sessionDir" -Level Info

        # Claves de registro principales que el script modifica
        $registryHives = @(
            'HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced',
            'HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize',
            'HKCU\Software\Microsoft\Windows\CurrentVersion\Search',
            'HKCU\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager',
            'HKCU\Software\Microsoft\Windows\CurrentVersion\Privacy',
            'HKCU\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
        )

        foreach ($hive in $registryHives) {
            $backupFile = Backup-RegistryHive -HivePath $hive -BackupDir $sessionDir
            if ($backupFile) {
                $backupFiles += $backupFile
            }
        }

        # Exportar lista de AppxPackage actuales a JSON
        try {
            $appxFile = Join-Path $sessionDir "appx_packages_$timestamp.json"
            Write-Log -Message "Exportando lista de AppxPackage..." -Level Info

            $appxPackages = Get-AppxPackage | Select-Object Name, PackageFullName, Version, Publisher |
                ConvertTo-Json -Depth 3

            $appxPackages | Out-File -FilePath $appxFile -Encoding UTF8 -Force
            $backupFiles += $appxFile
            Write-Log -Message "Lista de AppxPackage exportada: $appxFile" -Level Success
        }
        catch {
            Write-Log -Message "Error al exportar AppxPackage: $_" -Level Warning
        }

        Write-Log -Message "Backup completo finalizado: $($backupFiles.Count) archivos creados" -Level Success
    }
    catch {
        Write-Log -Message "Error durante el backup completo: $_" -Level Error
    }

    return $backupFiles
}

function Export-CurrentConfiguration {
    <#
    .SYNOPSIS
        Exporta el estado actual del sistema a un archivo JSON.
    .PARAMETER ConfigPath
        Ruta al directorio de configuracion del proyecto.
    .PARAMETER BackupDir
        Directorio donde guardar la exportacion.
    .OUTPUTS
        [string] Ruta del archivo de exportacion, o $null si fallo.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath,

        [Parameter(Mandatory = $true)]
        [string]$BackupDir
    )

    try {
        if (-not (Test-Path $BackupDir)) {
            New-Item -Path $BackupDir -ItemType Directory -Force | Out-Null
        }

        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $exportFile = Join-Path $BackupDir "export_$timestamp.json"

        Write-Log -Message "Exportando configuracion actual del sistema..." -Level Info

        $export = @{
            timestamp     = $timestamp
            computerName  = $env:COMPUTERNAME
            userName      = $env:USERNAME
            osVersion     = (Get-CimInstance Win32_OperatingSystem -ErrorAction SilentlyContinue).Caption
        }

        # Lista de software instalado via winget
        try {
            Write-Log -Message "Obteniendo lista de software instalado (winget)..." -Level Info
            $wingetOutput = & winget list --accept-source-agreements 2>&1 | Out-String
            $export.installedSoftware = $wingetOutput
        }
        catch {
            Write-Log -Message "No se pudo obtener lista de winget: $_" -Level Warning
            $export.installedSoftware = "Error: no disponible"
        }

        # Lista de AppxPackage
        try {
            Write-Log -Message "Obteniendo lista de AppxPackage..." -Level Info
            $appxList = Get-AppxPackage | Select-Object Name, Version, PackageFullName
            $export.appxPackages = $appxList
        }
        catch {
            Write-Log -Message "No se pudo obtener lista de AppxPackage: $_" -Level Warning
            $export.appxPackages = @()
        }

        # Valores actuales de registry keys relevantes
        try {
            Write-Log -Message "Leyendo valores de registro relevantes..." -Level Info
            $registryValues = @{}

            $keysToRead = @{
                'Explorer'             = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced'
                'Personalize'          = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize'
                'Search'               = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Search'
                'ContentDelivery'      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager'
                'Privacy'              = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Privacy'
                'AdvertisingInfo'      = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo'
            }

            foreach ($keyName in $keysToRead.Keys) {
                $keyPath = $keysToRead[$keyName]
                if (Test-Path $keyPath) {
                    $props = Get-ItemProperty -Path $keyPath -ErrorAction SilentlyContinue
                    $registryValues[$keyName] = $props | Select-Object * -ExcludeProperty PS*
                }
                else {
                    $registryValues[$keyName] = "Clave no existe"
                }
            }

            $export.registryValues = $registryValues
        }
        catch {
            Write-Log -Message "Error al leer valores de registro: $_" -Level Warning
            $export.registryValues = @{}
        }

        # Plan de energia activo
        try {
            Write-Log -Message "Obteniendo plan de energia activo..." -Level Info
            $powerPlan = & powercfg /getactivescheme 2>&1 | Out-String
            $export.activePowerPlan = $powerPlan.Trim()
        }
        catch {
            Write-Log -Message "No se pudo obtener el plan de energia: $_" -Level Warning
            $export.activePowerPlan = "No disponible"
        }

        # Guardar exportacion
        $export | ConvertTo-Json -Depth 5 | Out-File -FilePath $exportFile -Encoding UTF8 -Force

        $fileSize = (Get-Item $exportFile).Length
        Write-Log -Message "Configuracion exportada ($([math]::Round($fileSize / 1KB, 1)) KB): $exportFile" -Level Success
        return $exportFile
    }
    catch {
        Write-Log -Message "Error al exportar configuracion: $_" -Level Error
        return $null
    }
}

function Restore-RegistryBackup {
    <#
    .SYNOPSIS
        Restaura un archivo de backup del registro (.reg).
    .PARAMETER BackupFile
        Ruta al archivo .reg a importar.
    .OUTPUTS
        [bool] $true si se restauro correctamente, $false si fallo.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$BackupFile
    )

    try {
        if (-not (Test-Path $BackupFile)) {
            Write-Log -Message "Archivo de backup no encontrado: $BackupFile" -Level Error
            return $false
        }

        if (-not $BackupFile.EndsWith('.reg')) {
            Write-Log -Message "El archivo no es un archivo .reg valido: $BackupFile" -Level Error
            return $false
        }

        $fileName = Split-Path $BackupFile -Leaf
        Write-Log -Message "Restaurando registro desde: $fileName" -Level Info
        Write-Log -Message "Ruta completa: $BackupFile" -Level Info

        $regOutput = & reg import "$BackupFile" 2>&1
        $exitCode = $LASTEXITCODE

        if ($exitCode -eq 0) {
            Write-Log -Message "Registro restaurado correctamente desde $fileName" -Level Success
            return $true
        }

        Write-Log -Message "reg import fallo con codigo $exitCode`: $($regOutput | Out-String)" -Level Error
        return $false
    }
    catch {
        Write-Log -Message "Error al restaurar registro desde '$BackupFile': $_" -Level Error
        return $false
    }
}

Export-ModuleMember -Function @(
    'New-SystemRestorePoint',
    'Backup-RegistryHive',
    'New-FullBackup',
    'Export-CurrentConfiguration',
    'Restore-RegistryBackup'
)
