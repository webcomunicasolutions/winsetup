# =============================================================================
# Bloatware.psm1 - Modulo de deteccion y remocion de bloatware de Windows
# Escanea, detecta y remueve aplicaciones preinstaladas no deseadas
# =============================================================================

function Get-BloatwareCatalog {
    <#
    .SYNOPSIS
        Lee y parsea el catalogo de bloatware desde archivo JSON.
    .PARAMETER ConfigPath
        Ruta al archivo bloatware.json.
    .OUTPUTS
        Objeto con listas de bloatware y aplicaciones protegidas.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    try {
        if (-not (Test-Path $ConfigPath)) {
            Write-Log -Message "Archivo de bloatware no encontrado: $ConfigPath" -Level Error
            return $null
        }

        $content = Get-Content -Path $ConfigPath -Raw -Encoding UTF8
        $catalog = $content | ConvertFrom-Json

        if (-not $catalog.bloatware) {
            Write-Log -Message "Formato de bloatware.json invalido: no contiene 'bloatware'" -Level Error
            return $null
        }

        $protectedCount = if ($catalog.protected) { @($catalog.protected).Count } else { 0 }
        Write-Log -Message "Catalogo de bloatware cargado: $(@($catalog.bloatware).Count) apps, $protectedCount protegidas" -Level Success
        return $catalog
    }
    catch {
        Write-Log -Message "Error al cargar catalogo de bloatware: $_" -Level Error
        return $null
    }
}

function Get-InstalledBloatware {
    <#
    .SYNOPSIS
        Escanea el sistema y retorna solo el bloatware que esta instalado.
    .PARAMETER BloatwareList
        Array de objetos con id y name del catalogo.
    .OUTPUTS
        Array de objetos de bloatware que estan instalados.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$BloatwareList
    )

    try {
        Write-Log -Message "Escaneando aplicaciones instaladas..." -Level Info

        # Obtener todos los paquetes Appx instalados una sola vez
        $installedPackages = Get-AppxPackage -ErrorAction SilentlyContinue

        $installedBloatware = @()

        foreach ($app in $BloatwareList) {
            $found = $installedPackages | Where-Object { $_.Name -like "*$($app.id)*" }

            if ($found) {
                # Agregar propiedad 'installed' al objeto
                $appCopy = $app | Select-Object *, @{ Name = 'installed'; Expression = { $true } }
                $installedBloatware += $appCopy
            }
        }

        Write-Log -Message "Bloatware detectado: $($installedBloatware.Count) de $($BloatwareList.Count) aplicaciones" -Level Info
        return $installedBloatware
    }
    catch {
        Write-Log -Message "Error al escanear bloatware instalado: $_" -Level Error
        return @()
    }
}

function Test-ProtectedApp {
    <#
    .SYNOPSIS
        Verifica si una aplicacion esta en la lista de protegidas.
    .PARAMETER AppId
        Identificador de la aplicacion.
    .PARAMETER ProtectedList
        Array de strings con IDs de apps protegidas.
    .OUTPUTS
        $true si la app esta protegida, $false si no.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [Parameter(Mandatory = $true)]
        [array]$ProtectedList
    )

    foreach ($protected in $ProtectedList) {
        if ($AppId -like "*$protected*" -or $protected -like "*$AppId*") {
            return $true
        }
    }

    return $false
}

function Remove-BloatwareApp {
    <#
    .SYNOPSIS
        Remueve una aplicacion bloatware del sistema.
    .DESCRIPTION
        Elimina el paquete Appx para el usuario actual y tambien remueve
        el paquete provisionado para prevenir reinstalacion en nuevos usuarios.
    .PARAMETER AppId
        Identificador de la aplicacion (e.g. Microsoft.BingNews).
    .PARAMETER AppName
        Nombre descriptivo de la aplicacion.
    .OUTPUTS
        'Success' o 'Failed'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$AppId,

        [Parameter(Mandatory = $true)]
        [string]$AppName
    )

    try {
        Write-Log -Message "Removiendo: $AppName ($AppId)" -Level Info
        $hasError = $false

        # Remover paquete del usuario actual
        try {
            $packages = Get-AppxPackage -Name "*$AppId*" -ErrorAction SilentlyContinue
            if ($packages) {
                $packages | Remove-AppxPackage -ErrorAction Stop
                Write-Log -Message "  Paquete de usuario removido: $AppId" -Level Info
            }
            else {
                Write-Log -Message "  Paquete de usuario no encontrado: $AppId" -Level Info
            }
        }
        catch {
            Write-Log -Message "  Error al remover paquete de usuario $AppId : $_" -Level Warning
            $hasError = $true
        }

        # Remover paquete provisionado (previene reinstalacion en nuevos usuarios)
        try {
            $provisioned = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
                Where-Object { $_.DisplayName -like "*$AppId*" }

            if ($provisioned) {
                $provisioned | Remove-AppxProvisionedPackage -Online -ErrorAction Stop
                Write-Log -Message "  Paquete provisionado removido: $AppId" -Level Info
            }
            else {
                Write-Log -Message "  Paquete provisionado no encontrado: $AppId" -Level Info
            }
        }
        catch {
            Write-Log -Message "  Error al remover paquete provisionado $AppId : $_" -Level Warning
            # No marcar como error critico si el paquete de usuario se removio
        }

        if (-not $hasError) {
            Write-Log -Message "Removido correctamente: $AppName" -Level Success
            return 'Success'
        }
        else {
            Write-Log -Message "Remocion con errores: $AppName" -Level Warning
            return 'Failed'
        }
    }
    catch {
        Write-Log -Message "Error al remover $AppName ($AppId): $_" -Level Error
        return 'Failed'
    }
}

function Start-BloatwareRemoval {
    <#
    .SYNOPSIS
        Funcion principal interactiva para seleccionar y remover bloatware.
    .PARAMETER ConfigPath
        Ruta al archivo bloatware.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    try {
        # Cargar catalogo
        $catalog = Get-BloatwareCatalog -ConfigPath $ConfigPath
        if (-not $catalog) {
            Write-Log -Message "No se pudo cargar el catalogo de bloatware" -Level Error
            return
        }

        # Escanear bloatware instalado
        $installedBloatware = Get-InstalledBloatware -BloatwareList $catalog.bloatware

        if ($installedBloatware.Count -eq 0) {
            Write-Log -Message "No se detecto bloatware instalado en el sistema" -Level Success
            return
        }

        # Mostrar solo los detectados con checkboxes (recomendados marcados)
        $selectedApps = Show-CheckboxList -Items $installedBloatware -Title "BLOATWARE DETECTADO ($($installedBloatware.Count) apps)"

        if ($selectedApps.Count -eq 0) {
            Write-Log -Message "No se selecciono bloatware para remover" -Level Info
            return
        }

        # Confirmar antes de remover (accion destructiva)
        Write-Section -Title "ADVERTENCIA"
        Write-Log -Message "Se removeran $($selectedApps.Count) aplicacion(es). Esta accion no se puede deshacer facilmente." -Level Warning

        $confirm = Show-Confirmation -Message "Confirmar remocion de $($selectedApps.Count) aplicacion(es)?"
        if (-not $confirm) {
            Write-Log -Message "Remocion de bloatware cancelada por el usuario" -Level Info
            return
        }

        # Remover seleccionados con progreso
        $results = @{
            Success = @()
            Failed  = @()
            Skipped = @()
        }

        $protectedList = if ($catalog.protected) { @($catalog.protected) } else { @() }

        for ($i = 0; $i -lt $selectedApps.Count; $i++) {
            $app = $selectedApps[$i]
            Show-Progress -Activity "Removiendo bloatware" -Status $app.name -Current ($i + 1) -Total $selectedApps.Count

            # Verificar si es una app protegida
            if (Test-ProtectedApp -AppId $app.id -ProtectedList $protectedList) {
                Write-Log -Message "App protegida, omitiendo: $($app.name)" -Level Warning
                $results.Skipped += $app.name
                continue
            }

            $result = Remove-BloatwareApp -AppId $app.id -AppName $app.name

            switch ($result) {
                'Success' { $results.Success += $app.name }
                'Failed'  { $results.Failed += $app.name }
            }
        }

        Write-Progress -Activity "Removiendo bloatware" -Completed
        Write-Host ""

        # Mostrar resumen
        Show-Summary -Results $results
    }
    catch {
        Write-Log -Message "Error en remocion de bloatware: $_" -Level Error
    }
}

function Remove-RecommendedBloatware {
    <#
    .SYNOPSIS
        Remueve automaticamente todo el bloatware marcado como recomendado.
    .DESCRIPTION
        Solo remueve aplicaciones que estan instaladas y marcadas como recomendadas.
        No requiere interaccion del usuario.
    .PARAMETER ConfigPath
        Ruta al archivo bloatware.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    try {
        # Cargar catalogo
        $catalog = Get-BloatwareCatalog -ConfigPath $ConfigPath
        if (-not $catalog) {
            Write-Log -Message "No se pudo cargar el catalogo de bloatware" -Level Error
            return
        }

        # Filtrar solo los recomendados
        $recommendedApps = @($catalog.bloatware | Where-Object { $_.recommended -eq $true })

        if ($recommendedApps.Count -eq 0) {
            Write-Log -Message "No hay bloatware recomendado para remover" -Level Info
            return
        }

        # Escanear cuales estan instalados
        $installedRecommended = Get-InstalledBloatware -BloatwareList $recommendedApps

        if ($installedRecommended.Count -eq 0) {
            Write-Log -Message "Ninguno de los $($recommendedApps.Count) bloatware recomendados esta instalado" -Level Success
            return
        }

        Write-Log -Message "Removiendo $($installedRecommended.Count) aplicaciones de bloatware recomendadas..." -Level Info

        $results = @{
            Success = @()
            Failed  = @()
            Skipped = @()
        }

        $protectedList = if ($catalog.protected) { @($catalog.protected) } else { @() }

        for ($i = 0; $i -lt $installedRecommended.Count; $i++) {
            $app = $installedRecommended[$i]
            Show-Progress -Activity "Removiendo bloatware recomendado" -Status $app.name -Current ($i + 1) -Total $installedRecommended.Count

            # Verificar si es una app protegida
            if (Test-ProtectedApp -AppId $app.id -ProtectedList $protectedList) {
                Write-Log -Message "App protegida, omitiendo: $($app.name)" -Level Warning
                $results.Skipped += $app.name
                continue
            }

            $result = Remove-BloatwareApp -AppId $app.id -AppName $app.name

            switch ($result) {
                'Success' { $results.Success += $app.name }
                'Failed'  { $results.Failed += $app.name }
            }
        }

        Write-Progress -Activity "Removiendo bloatware recomendado" -Completed
        Write-Host ""

        Show-Summary -Results $results
    }
    catch {
        Write-Log -Message "Error al remover bloatware recomendado: $_" -Level Error
    }
}

# =============================================================================
# Exportar funciones publicas
# =============================================================================
Export-ModuleMember -Function @(
    'Get-BloatwareCatalog',
    'Get-InstalledBloatware',
    'Test-ProtectedApp',
    'Remove-BloatwareApp',
    'Start-BloatwareRemoval',
    'Remove-RecommendedBloatware'
)
