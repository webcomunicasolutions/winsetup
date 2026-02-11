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

    Write-Log -Message "DESCARGA MANUAL: $PackageName" -Level Warning
    Write-Host ""
    Write-Host "  $PackageName requiere descarga manual:" -ForegroundColor Yellow
    Write-Host "  URL: $ManualUrl" -ForegroundColor Cyan
    if ($ManualNote) {
        Write-Host "  Nota: $ManualNote" -ForegroundColor Gray
    }
    Write-Host ""

    try {
        Start-Process $ManualUrl
        Write-Log -Message "Se abrio el navegador para descargar $PackageName" -Level Info
    }
    catch {
        Write-Log -Message "No se pudo abrir la URL automaticamente. Copie la URL manualmente." -Level Warning
    }

    Write-Host "  Presione Enter cuando haya completado la instalacion de $PackageName..." -ForegroundColor Yellow
    Read-Host | Out-Null

    return 'Success'
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

    # Intentar instalar con reintentos
    $attempt = 0
    while ($attempt -lt $MaxRetries) {
        $attempt++
        Write-Log -Message "Instalando $PackageName (intento $attempt de $MaxRetries)..." -Level Info

        try {
            # Obtener locale del sistema (ej: es-ES)
            $systemLocale = (Get-Culture).Name

            $output = & winget install --id $PackageId `
                --accept-source-agreements `
                --accept-package-agreements `
                --silent `
                --locale $systemLocale 2>&1

            $exitCode = $LASTEXITCODE
            $outputText = $output | Out-String

            if ($exitCode -eq 0) {
                Write-Log -Message "$PackageName instalado correctamente" -Level Success
                return 'Success'
            }

            # Codigo de salida distinto de 0 pero no excepcion
            Write-Log -Message "winget retorno codigo $exitCode para $PackageName" -Level Warning
            if ($outputText.Trim()) {
                Write-Log -Message "Salida de winget: $($outputText.Trim())" -Level Warning
            }
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
