# =============================================================================
# Tweaks.psm1 - Modulo de configuracion y optimizacion de Windows
# Aplica tweaks de registro, configuracion de energia y personalizaciones
# =============================================================================

function Get-TweaksCatalog {
    <#
    .SYNOPSIS
        Lee y parsea el catalogo de tweaks desde archivo JSON.
    .PARAMETER ConfigPath
        Ruta al archivo tweaks.json.
    .OUTPUTS
        Objeto con categorias de tweaks.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    try {
        if (-not (Test-Path $ConfigPath)) {
            Write-Log -Message "Archivo de tweaks no encontrado: $ConfigPath" -Level Error
            return $null
        }

        $content = Get-Content -Path $ConfigPath -Raw -Encoding UTF8
        $catalog = $content | ConvertFrom-Json

        if (-not $catalog.categories) {
            Write-Log -Message "Formato de tweaks.json invalido: no contiene 'categories'" -Level Error
            return $null
        }

        $totalTweaks = 0
        foreach ($cat in $catalog.categories) {
            $totalTweaks += @($cat.tweaks).Count
        }

        Write-Log -Message "Catalogo de tweaks cargado: $($catalog.categories.Count) categorias, $totalTweaks tweaks" -Level Success
        return $catalog
    }
    catch {
        Write-Log -Message "Error al cargar catalogo de tweaks: $_" -Level Error
        return $null
    }
}

function Backup-RegistryKey {
    <#
    .SYNOPSIS
        Exporta una clave de registro a un archivo .reg de backup.
    .PARAMETER Path
        Ruta de registro en formato PowerShell (HKCU:\Software\...).
    .OUTPUTS
        Ruta del archivo de backup o $null si falla.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        # Determinar directorio de backups relativo al modulo
        $moduleDir = Split-Path -Parent $PSScriptRoot
        if (-not $moduleDir) {
            $moduleDir = Split-Path -Parent (Get-Location).Path
        }
        $backupDir = Join-Path $moduleDir 'backups'

        if (-not (Test-Path $backupDir)) {
            New-Item -Path $backupDir -ItemType Directory -Force | Out-Null
        }

        # Convertir path PowerShell a formato cmd para reg export
        # HKCU:\Software\... -> HKCU\Software\...
        $regPath = $Path -replace ':\\', '\'

        # Generar nombre de archivo unico
        $keyName = ($Path -split '\\')[-1] -replace '[^a-zA-Z0-9]', '_'
        $timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $backupFile = Join-Path $backupDir "backup_${timestamp}_${keyName}.reg"

        Write-Log -Message "Creando backup de registro: $Path" -Level Info

        # Verificar si la key existe antes de exportar
        if (-not (Test-Path $Path)) {
            Write-Log -Message "Clave de registro no existe (aun): $Path - No se requiere backup" -Level Info
            return $null
        }

        $process = Start-Process -FilePath 'reg' `
            -ArgumentList "export `"$regPath`" `"$backupFile`" /y" `
            -NoNewWindow -Wait -PassThru -RedirectStandardError "$env:TEMP\reg_err.txt" 2>$null

        if ($process.ExitCode -eq 0 -and (Test-Path $backupFile)) {
            Write-Log -Message "Backup creado: $backupFile" -Level Success
            return $backupFile
        }
        else {
            $errMsg = ""
            if (Test-Path "$env:TEMP\reg_err.txt") {
                $errMsg = Get-Content "$env:TEMP\reg_err.txt" -Raw -ErrorAction SilentlyContinue
                Remove-Item "$env:TEMP\reg_err.txt" -Force -ErrorAction SilentlyContinue
            }
            Write-Log -Message "No se pudo crear backup de: $Path $errMsg" -Level Warning
            return $null
        }
    }
    catch {
        Write-Log -Message "Error al hacer backup de registro: $_" -Level Error
        return $null
    }
}

function Apply-RegistryTweak {
    <#
    .SYNOPSIS
        Aplica entradas de registro para un tweak.
    .PARAMETER TweakName
        Nombre descriptivo del tweak.
    .PARAMETER RegistryEntries
        Array de objetos con path, name, value y type.
    .OUTPUTS
        'Success' o 'Failed'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$TweakName,

        [Parameter(Mandatory = $true)]
        [array]$RegistryEntries
    )

    try {
        $allOk = $true

        foreach ($entry in $RegistryEntries) {
            try {
                # Backup de la key antes de modificar
                Backup-RegistryKey -Path $entry.path | Out-Null

                # Crear la key si no existe
                if (-not (Test-Path $entry.path)) {
                    New-Item -Path $entry.path -Force | Out-Null
                    Write-Log -Message "Clave de registro creada: $($entry.path)" -Level Info
                }

                # Preparar el valor segun el tipo
                $value = $entry.value
                $propertyType = $entry.type

                if ($propertyType -eq 'Binary') {
                    # Convertir string "90,12,03,80" a byte array
                    if ($value -is [string]) {
                        $value = [byte[]]($value -split ',' | ForEach-Object { [byte]("0x$($_.Trim())") })
                    }
                }

                # Aplicar el valor
                Set-ItemProperty -Path $entry.path -Name $entry.name -Value $value -Type $propertyType -Force -ErrorAction Stop
                Write-Log -Message "  Registro aplicado: $($entry.path)\$($entry.name) = $($entry.value) ($propertyType)" -Level Info
            }
            catch {
                # Fallback: intentar con reg.exe cuando PowerShell falla (ej: claves protegidas en Win11)
                Write-Log -Message "  Set-ItemProperty fallo, intentando con reg.exe..." -Level Warning
                try {
                    $regPath = $entry.path -replace '^HKCU:\\', 'HKCU\' -replace '^HKLM:\\', 'HKLM\'
                    $regType = switch ($entry.type) {
                        'DWord'  { 'REG_DWORD' }
                        'String' { 'REG_SZ' }
                        'Binary' { 'REG_BINARY' }
                        default  { 'REG_SZ' }
                    }
                    $regValue = $entry.value
                    if ($entry.type -eq 'Binary') {
                        $regValue = ($entry.value -replace ',', '')
                    }
                    $regName = if ($entry.name -eq '(Default)') { '/ve' } else { "/v `"$($entry.name)`"" }
                    $regCmd = "reg add `"$regPath`" $regName /t $regType /d `"$regValue`" /f"
                    $regOutput = cmd /c $regCmd 2>&1
                    if ($LASTEXITCODE -eq 0) {
                        Write-Log -Message "  Registro aplicado via reg.exe: $($entry.path)\$($entry.name)" -Level Info
                    }
                    else {
                        Write-Log -Message "  Error reg.exe: $regOutput" -Level Error
                        $allOk = $false
                    }
                }
                catch {
                    Write-Log -Message "  Error al aplicar registro $($entry.path)\$($entry.name): $_" -Level Error
                    $allOk = $false
                }
            }
        }

        if ($allOk) {
            Write-Log -Message "Tweak aplicado correctamente: $TweakName" -Level Success
            return 'Success'
        }
        else {
            Write-Log -Message "Tweak aplicado con errores: $TweakName" -Level Warning
            return 'Failed'
        }
    }
    catch {
        Write-Log -Message "Error al aplicar tweak de registro '$TweakName': $_" -Level Error
        return 'Failed'
    }
}

function Apply-PowerConfiguration {
    <#
    .SYNOPSIS
        Ejecuta comandos de configuracion de energia (powercfg).
    .PARAMETER Commands
        Array de strings con comandos powercfg a ejecutar.
    .OUTPUTS
        'Success' o 'Failed'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Commands
    )

    try {
        $allOk = $true

        foreach ($cmd in $Commands) {
            try {
                Write-Log -Message "Ejecutando: $cmd" -Level Info

                # Si es un cmdlet de PowerShell (contiene - como Set-NetConnectionProfile)
                if ($cmd -match '^\w+-\w+') {
                    Invoke-Expression $cmd
                    Write-Log -Message "  Comando ejecutado correctamente: $cmd" -Level Info
                }
                else {
                    # Comando externo (powercfg, etc.)
                    $parts = $cmd -split ' ', 2
                    $exe = $parts[0]
                    $cmdArgs = if ($parts.Count -gt 1) { $parts[1] } else { "" }

                    $process = Start-Process -FilePath $exe -ArgumentList $cmdArgs `
                        -NoNewWindow -Wait -PassThru 2>$null

                    if ($process.ExitCode -eq 0) {
                        Write-Log -Message "  Comando ejecutado correctamente: $cmd" -Level Info
                    }
                    else {
                        Write-Log -Message "  Comando termino con codigo $($process.ExitCode): $cmd" -Level Warning
                        $allOk = $false
                    }
                }
            }
            catch {
                Write-Log -Message "  Error al ejecutar '$cmd': $_" -Level Error
                $allOk = $false
            }
        }

        if ($allOk) {
            return 'Success'
        }
        else {
            return 'Failed'
        }
    }
    catch {
        Write-Log -Message "Error en configuracion de energia: $_" -Level Error
        return 'Failed'
    }
}

function Apply-TweakItem {
    <#
    .SYNOPSIS
        Aplica un tweak individual segun su tipo (registry, powerConfig o info).
    .PARAMETER Tweak
        Objeto de tweak del catalogo JSON.
    .OUTPUTS
        'Success', 'Failed' o 'Skipped'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [object]$Tweak
    )

    try {
        Write-Log -Message "Procesando tweak: $($Tweak.name)" -Level Info

        # Tweak informativo - solo mostrar
        if ($Tweak.info -eq $true) {
            Write-Log -Message "  [INFO] $($Tweak.name): $($Tweak.description)" -Level Info
            return 'Skipped'
        }

        $overallResult = 'Skipped'
        $hasAction = $false

        # Tweak de registro
        if ($Tweak.registry) {
            $hasAction = $true
            $regResult = Apply-RegistryTweak -TweakName $Tweak.name -RegistryEntries $Tweak.registry
            $overallResult = $regResult
        }

        # Tweak de configuracion de energia / comandos
        if ($Tweak.powerConfig) {
            $hasAction = $true
            $cmdResult = Apply-PowerConfiguration -Commands $Tweak.powerConfig
            if ($cmdResult -eq 'Success') {
                Write-Log -Message "Comandos ejecutados: $($Tweak.name)" -Level Success
            }
            # Si registry fue Success pero powerConfig fallo, marcar como Failed
            if ($cmdResult -eq 'Failed') { $overallResult = 'Failed' }
            elseif ($overallResult -eq 'Skipped') { $overallResult = $cmdResult }
        }

        if (-not $hasAction) {
            Write-Log -Message "Tweak sin accion definida: $($Tweak.name)" -Level Warning
            return 'Skipped'
        }

        return $overallResult
    }
    catch {
        Write-Log -Message "Error al procesar tweak '$($Tweak.name)': $_" -Level Error
        return 'Failed'
    }
}

function Start-TweaksConfiguration {
    <#
    .SYNOPSIS
        Funcion principal interactiva para seleccionar y aplicar tweaks.
    .PARAMETER ConfigPath
        Ruta al archivo tweaks.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    try {
        # Cargar catalogo
        $catalog = Get-TweaksCatalog -ConfigPath $ConfigPath
        if (-not $catalog) {
            Write-Log -Message "No se pudo cargar el catalogo de tweaks" -Level Error
            return
        }

        # Mostrar categorias
        $categoryIndex = Show-CategoryMenu -Categories $catalog.categories
        if ($categoryIndex -eq -1) {
            Write-Log -Message "Operacion de tweaks cancelada por el usuario" -Level Info
            return
        }

        $category = $catalog.categories[$categoryIndex]
        Write-Log -Message "Categoria seleccionada: $($category.name)" -Level Info

        # Mostrar tweaks con checkboxes
        $selectedTweaks = Show-CheckboxList -Items $category.tweaks -Title "TWEAKS: $($category.name)"

        if ($selectedTweaks.Count -eq 0) {
            Write-Log -Message "No se seleccionaron tweaks" -Level Info
            return
        }

        # Confirmar antes de aplicar
        $confirm = Show-Confirmation -Message "Aplicar $($selectedTweaks.Count) tweak(s) de '$($category.name)'?"
        if (-not $confirm) {
            Write-Log -Message "Aplicacion de tweaks cancelada por el usuario" -Level Info
            return
        }

        # Aplicar tweaks seleccionados con progreso
        $results = @{
            Success = @()
            Failed  = @()
            Skipped = @()
        }

        for ($i = 0; $i -lt $selectedTweaks.Count; $i++) {
            $tweak = $selectedTweaks[$i]
            Show-Progress -Activity "Aplicando tweaks" -Status $tweak.name -Current ($i + 1) -Total $selectedTweaks.Count

            $result = Apply-TweakItem -Tweak $tweak

            switch ($result) {
                'Success' { $results.Success += $tweak.name }
                'Failed'  { $results.Failed += $tweak.name }
                'Skipped' { $results.Skipped += $tweak.name }
            }
        }

        Write-Progress -Activity "Aplicando tweaks" -Completed
        Write-Host ""

        # Mostrar resumen
        Show-Summary -Results $results
    }
    catch {
        Write-Log -Message "Error en configuracion de tweaks: $_" -Level Error
    }
}

function Apply-RecommendedTweaks {
    <#
    .SYNOPSIS
        Aplica automaticamente todos los tweaks marcados como recomendados.
    .PARAMETER ConfigPath
        Ruta al archivo tweaks.json.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ConfigPath
    )

    try {
        $emptyResults = @{ Success = @(); Failed = @(); Skipped = @() }

        # Cargar catalogo
        $catalog = Get-TweaksCatalog -ConfigPath $ConfigPath
        if (-not $catalog) {
            Write-Log -Message "No se pudo cargar el catalogo de tweaks" -Level Error
            return $emptyResults
        }

        # Recolectar todos los tweaks recomendados
        $recommendedTweaks = @()
        foreach ($category in $catalog.categories) {
            foreach ($tweak in $category.tweaks) {
                if ($tweak.recommended -eq $true) {
                    $recommendedTweaks += $tweak
                }
            }
        }

        if ($recommendedTweaks.Count -eq 0) {
            Write-Log -Message "No hay tweaks recomendados para aplicar" -Level Info
            return $emptyResults
        }

        Write-Log -Message "Aplicando $($recommendedTweaks.Count) tweaks recomendados..." -Level Info

        $results = @{
            Success = @()
            Failed  = @()
            Skipped = @()
        }

        for ($i = 0; $i -lt $recommendedTweaks.Count; $i++) {
            $tweak = $recommendedTweaks[$i]
            Show-Progress -Activity "Aplicando tweaks recomendados" -Status $tweak.name -Current ($i + 1) -Total $recommendedTweaks.Count

            $result = Apply-TweakItem -Tweak $tweak

            switch ($result) {
                'Success' { $results.Success += $tweak.name }
                'Failed'  { $results.Failed += $tweak.name }
                'Skipped' { $results.Skipped += $tweak.name }
            }
        }

        Write-Progress -Activity "Aplicando tweaks recomendados" -Completed
        Write-Host ""

        # Reiniciar explorer.exe para que los cambios de registro surtan efecto
        if ($results.Success.Count -gt 0) {
            Write-Log -Message "Reiniciando explorer.exe para aplicar cambios visuales..." -Level Info
            try {
                Stop-Process -Name explorer -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
                Start-Process explorer.exe
                Write-Log -Message "Explorer reiniciado correctamente" -Level Success
            }
            catch {
                Write-Log -Message "No se pudo reiniciar explorer: $_" -Level Warning
            }
        }

        Show-Summary -Results $results

        return $results
    }
    catch {
        Write-Log -Message "Error al aplicar tweaks recomendados: $_" -Level Error
        return @{ Success = @(); Failed = @(); Skipped = @() }
    }
}

# =============================================================================
# Exportar funciones publicas
# =============================================================================
Export-ModuleMember -Function @(
    'Get-TweaksCatalog',
    'Backup-RegistryKey',
    'Apply-RegistryTweak',
    'Apply-PowerConfiguration',
    'Apply-TweakItem',
    'Start-TweaksConfiguration',
    'Apply-RecommendedTweaks'
)
