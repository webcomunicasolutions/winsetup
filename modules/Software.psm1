# Software.psm1 - Modulo de instalacion de software via winget
# Funciones para catalogo, verificacion, instalacion y flujo interactivo

function Get-SoftwareCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    try {
        if (-not (Test-Path $ConfigPath)) {
            Write-Log -Message "Archivo de catalogo no encontrado: $ConfigPath" -Level Error
            return $null
        }

        $content = Get-Content -Path $ConfigPath -Raw -Encoding UTF8
        $catalog = $content | ConvertFrom-Json

        if (-not $catalog.categories) {
            Write-Log -Message "El catalogo no contiene categorias validas" -Level Error
            return $null
        }

        $totalPackages = 0
        foreach ($cat in $catalog.categories) {
            $totalPackages += $cat.packages.Count
        }

        Write-Log -Message "Catalogo cargado: $($catalog.categories.Count) categorias, $totalPackages paquetes" -Level Success
        return $catalog
    }
    catch {
        Write-Log -Message "Error al leer el catalogo de software: $_" -Level Error
        return $null
    }
}

function Test-SoftwareInstalled {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId
    )

    try {
        $output = & winget list --id $PackageId --accept-source-agreements 2>&1
        $exitCode = $LASTEXITCODE

        # winget list retorna 0 si encuentra el paquete
        if ($exitCode -eq 0 -and ($output | Out-String) -match $PackageId) {
            return $true
        }

        return $false
    }
    catch {
        Write-Log -Message "Error al verificar si $PackageId esta instalado: $_" -Level Warning
        return $false
    }
}

function Install-ManualPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageName,

        [Parameter(Mandatory = $true)]
        [string]$ManualUrl,

        [Parameter()]
        [string]$ManualNote = ""
    )

    Write-Log -Message "Descarga directa: $PackageName" -Level Info

    $tempDir = Join-Path $env:TEMP "WinSetup_$($PackageName -replace '[^a-zA-Z0-9]', '_')"
    if (-not (Test-Path $tempDir)) { New-Item -Path $tempDir -ItemType Directory -Force | Out-Null }

    try {
        $fileName = $ManualUrl -split '/' | Select-Object -Last 1
        $downloadPath = Join-Path $tempDir $fileName

        # Descargar archivo
        Write-Log -Message "Descargando $PackageName desde $ManualUrl..." -Level Info
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $ManualUrl -OutFile $downloadPath -UseBasicParsing -ErrorAction Stop
        Write-Log -Message "Descarga completada: $fileName" -Level Success

        # Determinar tipo de archivo y actuar
        if ($fileName -match '\.zip$') {
            # Extraer ZIP y buscar instalador
            Write-Log -Message "Extrayendo $fileName..." -Level Info
            $extractDir = Join-Path $tempDir 'extracted'
            Expand-Archive -Path $downloadPath -DestinationPath $extractDir -Force

            # Buscar instalador (.exe o .msi) dentro del ZIP
            $installer = Get-ChildItem -Path $extractDir -Recurse -Include '*.exe','*.msi' |
                Where-Object { $_.Name -notmatch 'unins' } |
                Select-Object -First 1

            if ($installer) {
                Write-Log -Message "Instalador encontrado: $($installer.Name)" -Level Info
                if ($installer.Extension -eq '.msi') {
                    $proc = Start-Process -FilePath 'msiexec' -ArgumentList "/i `"$($installer.FullName)`" /passive /norestart" -Wait -PassThru
                }
                else {
                    $proc = Start-Process -FilePath $installer.FullName -ArgumentList '/S','/silent','/VERYSILENT' -Wait -PassThru -ErrorAction SilentlyContinue
                    if (-not $proc -or $proc.ExitCode -ne 0) {
                        # Intentar sin flags silenciosos
                        $proc = Start-Process -FilePath $installer.FullName -Wait -PassThru
                    }
                }
                Write-Log -Message "$PackageName instalado (codigo: $($proc.ExitCode))" -Level Success
            }
            else {
                Write-Log -Message "No se encontro instalador en el ZIP. Abriendo carpeta..." -Level Warning
                Start-Process $extractDir
                Write-Host "  Instale $PackageName manualmente desde la carpeta abierta." -ForegroundColor Yellow
                Write-Host "  Presione Enter cuando termine..." -ForegroundColor Yellow
                Read-Host | Out-Null
            }
        }
        elseif ($fileName -match '\.exe$') {
            # Ejecutar instalador directamente
            Write-Log -Message "Ejecutando instalador: $fileName" -Level Info
            $proc = Start-Process -FilePath $downloadPath -ArgumentList '/S','/silent','/VERYSILENT' -Wait -PassThru -ErrorAction SilentlyContinue
            if (-not $proc -or $proc.ExitCode -ne 0) {
                $proc = Start-Process -FilePath $downloadPath -Wait -PassThru
            }
            Write-Log -Message "$PackageName instalado (codigo: $($proc.ExitCode))" -Level Success
        }
        elseif ($fileName -match '\.(msi|msix|msixbundle|appx)$') {
            Write-Log -Message "Ejecutando instalador MSI: $fileName" -Level Info
            $proc = Start-Process -FilePath 'msiexec' -ArgumentList "/i `"$downloadPath`" /passive /norestart" -Wait -PassThru
            Write-Log -Message "$PackageName instalado (codigo: $($proc.ExitCode))" -Level Success
        }
        elseif ($fileName -match '\.img$') {
            # Montar imagen ISO/IMG
            Write-Log -Message "Montando imagen: $fileName" -Level Info
            $mountResult = Mount-DiskImage -ImagePath $downloadPath -PassThru
            $driveLetter = ($mountResult | Get-Volume).DriveLetter
            $setupPath = "${driveLetter}:\setup.exe"
            if (Test-Path $setupPath) {
                Write-Log -Message "Ejecutando setup.exe desde imagen montada" -Level Info
                $proc = Start-Process -FilePath $setupPath -Wait -PassThru
                Write-Log -Message "$PackageName instalado (codigo: $($proc.ExitCode))" -Level Success
            }
            else {
                Start-Process "${driveLetter}:\"
                Write-Host "  Imagen montada en ${driveLetter}:\ - Instale manualmente." -ForegroundColor Yellow
                Write-Host "  Presione Enter cuando termine..." -ForegroundColor Yellow
                Read-Host | Out-Null
            }
            Dismount-DiskImage -ImagePath $downloadPath -ErrorAction SilentlyContinue
        }
        else {
            # Tipo desconocido - abrir navegador
            Write-Log -Message "Tipo de archivo no reconocido, abriendo en navegador..." -Level Warning
            Start-Process $ManualUrl
            Write-Host "  Instale $PackageName manualmente." -ForegroundColor Yellow
            Write-Host "  Presione Enter cuando termine..." -ForegroundColor Yellow
            Read-Host | Out-Null
        }

        # Limpiar
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        return 'Success'
    }
    catch {
        Write-Log -Message "Error al descargar/instalar $PackageName`: $_" -Level Error
        # Fallback: abrir en navegador
        Write-Log -Message "Abriendo navegador como alternativa..." -Level Warning
        try { Start-Process $ManualUrl } catch {}
        Write-Host "  Instale $PackageName manualmente." -ForegroundColor Yellow
        Write-Host "  Presione Enter cuando termine..." -ForegroundColor Yellow
        Read-Host | Out-Null
        Remove-Item $tempDir -Recurse -Force -ErrorAction SilentlyContinue
        return 'Success'
    }
}

function Install-SoftwarePackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageId,

        [Parameter(Mandatory = $true)]
        [string]$PackageName,

        [Parameter()]
        [int]$MaxRetries = 3,

        [Parameter()]
        [int]$RetryDelay = 5,

        [Parameter()]
        [bool]$WingetUnavailable = $false,

        [Parameter()]
        [string]$ManualUrl = "",

        [Parameter()]
        [string]$ManualNote = ""
    )

    Write-Log -Message "Procesando: $PackageName ($PackageId)" -Level Info

    # Si el paquete no esta en winget, usar descarga manual
    if ($WingetUnavailable -and $ManualUrl) {
        return Install-ManualPackage -PackageName $PackageName -ManualUrl $ManualUrl -ManualNote $ManualNote
    }

    # Verificar si ya esta instalado
    if (Test-SoftwareInstalled -PackageId $PackageId) {
        Write-Log -Message "$PackageName ya esta instalado - omitiendo" -Level Info
        return 'Skipped'
    }

    # Obtener locale del sistema (ej: es-ES)
    $systemLocale = (Get-Culture).Name
    $useForce = $false

    # Intentar instalar con reintentos
    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        $attempt++
        Write-Log -Message "Instalando $PackageName (intento $attempt de $MaxRetries)..." -Level Info

        try {
            $wingetArgs = @(
                'install', '--id', $PackageId,
                '--accept-source-agreements',
                '--accept-package-agreements',
                '--silent',
                '--locale', $systemLocale
            )
            if ($useForce) {
                $wingetArgs += '--force'
                Write-Log -Message "  Usando --force para forzar instalacion" -Level Info
            }

            $output = & winget @wingetArgs 2>&1

            $exitCode = $LASTEXITCODE
            $outputText = $output | Out-String

            if ($exitCode -eq 0) {
                Write-Log -Message "$PackageName instalado correctamente" -Level Success
                return 'Success'
            }

            # Hash mismatch: reintentar con --force sin gastar mas intentos
            if ($exitCode -eq -1978335215 -and -not $useForce) {
                Write-Log -Message "Hash no coincide para $PackageName. Reintentando con --force..." -Level Warning
                $useForce = $true
                $attempt--  # No contar este intento
                continue
            }

            # Codigo de salida distinto de 0 pero no excepcion
            Write-Log -Message "winget retorno codigo $exitCode para $PackageName" -Level Warning
        }
        catch {
            Write-Log -Message "Excepcion al instalar $PackageName`: $_" -Level Error
        }

        if ($attempt -lt $MaxRetries) {
            Write-Log -Message "Reintentando en $RetryDelay segundos..." -Level Warning
            Start-Sleep -Seconds $RetryDelay
        }
    }

    Write-Log -Message "No se pudo instalar $PackageName despues de $MaxRetries intentos" -Level Error
    return 'Failed'
}

function Install-SoftwareList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Packages,

        [Parameter(Mandatory = $true)]
        [string]$CategoryName
    )

    $results = @{
        Success = @()
        Failed  = @()
        Skipped = @()
    }

    $total = $Packages.Count
    Write-Log -Message "Iniciando instalacion de $total paquetes en '$CategoryName'" -Level Info

    for ($i = 0; $i -lt $total; $i++) {
        $pkg = $Packages[$i]
        $current = $i + 1

        Show-Progress -Current $current -Total $total -Activity "Instalando $CategoryName" -Status $pkg.name

        $installParams = @{
            PackageId   = $pkg.id
            PackageName = $pkg.name
        }
        if ($pkg.wingetUnavailable -eq $true) {
            $installParams.WingetUnavailable = $true
            $installParams.ManualUrl = $pkg.manualUrl
            $installParams.ManualNote = $pkg.manualNote
        }
        $status = Install-SoftwarePackage @installParams

        switch ($status) {
            'Success' { $results.Success += $pkg.name }
            'Failed'  { $results.Failed += $pkg.name }
            'Skipped' { $results.Skipped += $pkg.name }
        }
    }

    Write-Log -Message "Categoria '$CategoryName' completada: $($results.Success.Count) instalados, $($results.Failed.Count) fallidos, $($results.Skipped.Count) omitidos" -Level Info
    return $results
}

function Start-SoftwareInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    $catalog = Get-SoftwareCatalog -ConfigPath $ConfigPath
    if (-not $catalog) {
        Write-Log -Message "No se pudo cargar el catalogo de software" -Level Error
        return
    }

    $allResults = @{
        Success = @()
        Failed  = @()
        Skipped = @()
    }

    $continueLoop = $true
    while ($continueLoop) {
        # Preparar opciones de categorias
        $categoryNames = @()
        $categoryDescriptions = @()
        foreach ($cat in $catalog.categories) {
            $categoryNames += $cat.name
            $categoryDescriptions += "$($cat.name) - $($cat.description) ($($cat.packages.Count) paquetes)"
        }

        Write-Section -Title "Instalacion de Software"
        $selectedCategory = Show-CategoryMenu -Categories $categoryDescriptions -Title "Seleccione una categoria"

        if ($null -eq $selectedCategory -or $selectedCategory -lt 0) {
            $continueLoop = $false
            continue
        }

        $category = $catalog.categories[$selectedCategory]
        Write-Log -Message "Categoria seleccionada: $($category.name)" -Level Info

        # Preparar lista de paquetes para checkboxes
        $packageItems = @()
        $preSelected = @()
        for ($i = 0; $i -lt $category.packages.Count; $i++) {
            $pkg = $category.packages[$i]
            $packageItems += "$($pkg.name) - $($pkg.description)"
            if ($pkg.recommended) {
                $preSelected += $i
            }
        }

        $selectedIndexes = Show-CheckboxList -Items $packageItems -Title "Paquetes en '$($category.name)'" -PreSelected $preSelected

        if (-not $selectedIndexes -or $selectedIndexes.Count -eq 0) {
            Write-Log -Message "No se seleccionaron paquetes en '$($category.name)'" -Level Info
            continue
        }

        # Construir lista de paquetes seleccionados
        $selectedPackages = @()
        foreach ($idx in $selectedIndexes) {
            $selectedPackages += $category.packages[$idx]
        }

        Write-Log -Message "Se seleccionaron $($selectedPackages.Count) paquetes para instalar" -Level Info

        $confirm = Show-Confirmation -Message "Instalar $($selectedPackages.Count) paquetes de '$($category.name)'?"
        if (-not $confirm) {
            Write-Log -Message "Instalacion cancelada por el usuario" -Level Warning
            continue
        }

        # Instalar paquetes seleccionados
        $categoryResults = Install-SoftwareList -Packages $selectedPackages -CategoryName $category.name

        # Acumular resultados globales
        $allResults.Success += $categoryResults.Success
        $allResults.Failed += $categoryResults.Failed
        $allResults.Skipped += $categoryResults.Skipped

        # Mostrar resumen parcial
        Show-Summary -Results $categoryResults -Title "Resumen: $($category.name)"

        # Preguntar si continuar con otra categoria
        $continueLoop = Show-Confirmation -Message "Desea instalar software de otra categoria?"
    }

    # Mostrar resumen global si hubo instalaciones
    if (($allResults.Success.Count + $allResults.Failed.Count + $allResults.Skipped.Count) -gt 0) {
        Show-Summary -Results $allResults -Title "Resumen General de Instalacion"
    }

    Write-Log -Message "Proceso de instalacion de software finalizado" -Level Info
}

function Install-RecommendedSoftware {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    $catalog = Get-SoftwareCatalog -ConfigPath $ConfigPath
    if (-not $catalog) {
        Write-Log -Message "No se pudo cargar el catalogo de software" -Level Error
        return $null
    }

    # Recopilar todos los paquetes recomendados
    $recommendedPackages = @()
    foreach ($cat in $catalog.categories) {
        foreach ($pkg in $cat.packages) {
            if ($pkg.recommended -eq $true) {
                $recommendedPackages += $pkg
            }
        }
    }

    if ($recommendedPackages.Count -eq 0) {
        Write-Log -Message "No se encontraron paquetes recomendados en el catalogo" -Level Warning
        return @{ Success = @(); Failed = @(); Skipped = @() }
    }

    Write-Log -Message "Instalando $($recommendedPackages.Count) paquetes recomendados..." -Level Info

    $results = Install-SoftwareList -Packages $recommendedPackages -CategoryName "Recomendados"

    Show-Summary -Results $results -Title "Resumen: Software Recomendado"

    return $results
}

Export-ModuleMember -Function @(
    'Get-SoftwareCatalog',
    'Test-SoftwareInstalled',
    'Install-ManualPackage',
    'Install-SoftwarePackage',
    'Install-SoftwareList',
    'Start-SoftwareInstallation',
    'Install-RecommendedSoftware'
)
