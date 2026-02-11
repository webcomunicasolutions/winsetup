# =============================================================================
# UI.psm1 - Modulo de Interfaz de Usuario Interactiva
# Proporciona funciones para menus, progreso, confirmaciones y formato visual
# =============================================================================

function Write-ColorText {
    <#
    .SYNOPSIS
        Escribe texto con color en la consola.
    .PARAMETER Text
        Texto a mostrar.
    .PARAMETER Color
        Color de consola a usar.
    .PARAMETER NoNewline
        Si se especifica, no agrega nueva linea al final.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Text,

        [Parameter(Mandatory = $false)]
        [System.ConsoleColor]$Color = [System.ConsoleColor]::White,

        [switch]$NoNewline
    )

    $params = @{
        Object          = $Text
        ForegroundColor = $Color
        NoNewline       = $NoNewline.IsPresent
    }
    Write-Host @params
}

function Write-Header {
    <#
    .SYNOPSIS
        Muestra un header con bordes usando caracteres ASCII.
    .PARAMETER Title
        Titulo del header.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    $width = 50
    $border = "=" * $width
    $padding = [math]::Max(0, [math]::Floor(($width - $Title.Length) / 2))
    $centeredTitle = (" " * $padding) + $Title

    Write-Host ""
    Write-Host $border -ForegroundColor Cyan
    Write-Host $centeredTitle -ForegroundColor White
    Write-Host $border -ForegroundColor Cyan
    Write-Host ""
}

function Write-Section {
    <#
    .SYNOPSIS
        Muestra un separador de seccion.
    .PARAMETER Title
        Titulo de la seccion.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Title
    )

    Write-Host ""
    Write-Host "--- $Title ---" -ForegroundColor Yellow
    Write-Host ""
}

function Show-Banner {
    <#
    .SYNOPSIS
        Muestra banner de bienvenida con ASCII art y version.
    #>
    [CmdletBinding()]
    param()

    $banner = @"

 __      __  _           _
 \ \    / / (_)  _ __   | |   ___   __ __  __
  \ \/\/ /  | | | '_ \  | |  / _ \  \ V / / _|
   \_/\_/   |_| |_.__/  |_|  \___/   \_/  \__|

"@

    Write-Host $banner -ForegroundColor Cyan
    Write-Host "  Setup v1.0 - Configuracion automatica de Windows" -ForegroundColor Green
    Write-Host ""
    Write-Host ("  " + "=" * 48) -ForegroundColor DarkGray
    Write-Host ""
}

function Show-MainMenu {
    <#
    .SYNOPSIS
        Muestra el menu principal con opciones numeradas.
    .DESCRIPTION
        Presenta las opciones principales del sistema y retorna
        el numero de opcion seleccionada por el usuario.
    .OUTPUTS
        [int] Numero de opcion seleccionada (1-6).
    #>
    [CmdletBinding()]
    param()

    do {
        Write-Header -Title "MENU PRINCIPAL"

        Write-Host "  [1] " -ForegroundColor Green -NoNewline
        Write-Host "Instalar Software"

        Write-Host "  [2] " -ForegroundColor Green -NoNewline
        Write-Host "Aplicar Configuraciones"

        Write-Host "  [3] " -ForegroundColor Green -NoNewline
        Write-Host "Remover Bloatware"

        Write-Host "  [4] " -ForegroundColor Green -NoNewline
        Write-Host "Configuracion Completa (todo recomendado)"

        Write-Host "  [5] " -ForegroundColor Green -NoNewline
        Write-Host "Ver Log"

        Write-Host "  [6] " -ForegroundColor DarkYellow -NoNewline
        Write-Host "Salir"

        Write-Host ""
        $selection = Read-Host "  Seleccione una opcion (1-6)"

        $parsed = 0
        $valid = [int]::TryParse($selection, [ref]$parsed) -and $parsed -ge 1 -and $parsed -le 6

        if (-not $valid) {
            Write-Host ""
            Write-Host "  Opcion no valida. Ingrese un numero entre 1 y 6." -ForegroundColor Red
            Write-Host ""
            Start-Sleep -Seconds 1
        }
    } while (-not $valid)

    return $parsed
}

function Show-CategoryMenu {
    <#
    .SYNOPSIS
        Muestra una lista de categorias numeradas.
    .PARAMETER Categories
        Array de objetos con propiedades 'name' y 'description'.
    .OUTPUTS
        [int] Indice seleccionado (base 0) o -1 para volver.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Categories
    )

    do {
        Write-Section -Title "CATEGORIAS DISPONIBLES"

        for ($i = 0; $i -lt $Categories.Count; $i++) {
            $cat = $Categories[$i]
            $num = $i + 1
            Write-Host "  [$num] " -ForegroundColor Green -NoNewline
            Write-Host "$($cat.name)" -ForegroundColor White -NoNewline
            if ($cat.description) {
                Write-Host " - $($cat.description)" -ForegroundColor Gray
            }
            else {
                Write-Host ""
            }
        }

        Write-Host ""
        Write-Host "  [0] " -ForegroundColor DarkYellow -NoNewline
        Write-Host "Volver"
        Write-Host ""

        $selection = Read-Host "  Seleccione una opcion"

        $parsed = -1
        $valid = [int]::TryParse($selection, [ref]$parsed) -and $parsed -ge 0 -and $parsed -le $Categories.Count

        if (-not $valid) {
            Write-Host ""
            Write-Host "  Opcion no valida." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    } while (-not $valid)

    if ($parsed -eq 0) {
        return -1
    }

    return ($parsed - 1)
}

function Show-CheckboxList {
    <#
    .SYNOPSIS
        Muestra lista interactiva con checkboxes para seleccion multiple.
    .PARAMETER Items
        Array de objetos con propiedades 'name', 'description', y 'recommended' (bool).
    .PARAMETER Title
        Titulo de la lista.
    .OUTPUTS
        Array de items seleccionados, o array vacio si el usuario vuelve sin seleccionar.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [array]$Items,

        [Parameter(Mandatory = $false)]
        [string]$Title = "SELECCION DE ELEMENTOS"
    )

    # Inicializar estado de seleccion: recomendados inician marcados
    $selected = [bool[]]::new($Items.Count)
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($Items[$i].recommended -eq $true) {
            $selected[$i] = $true
        }
    }

    $done = $false
    $cancelled = $false

    do {
        Clear-Host
        Write-Header -Title $Title

        $selectedCount = ($selected | Where-Object { $_ }).Count

        for ($i = 0; $i -lt $Items.Count; $i++) {
            $item = $Items[$i]
            $num = $i + 1
            $check = if ($selected[$i]) { "X" } else { " " }
            $checkColor = if ($selected[$i]) { "Green" } else { "DarkGray" }

            Write-Host "  " -NoNewline
            Write-Host "[$check]" -ForegroundColor $checkColor -NoNewline
            Write-Host " $num. " -ForegroundColor DarkCyan -NoNewline
            Write-Host "$($item.name)" -ForegroundColor White -NoNewline

            if ($item.description) {
                Write-Host " - $($item.description)" -ForegroundColor Gray -NoNewline
            }

            if ($item.recommended -eq $true) {
                Write-Host " (recomendado)" -ForegroundColor Yellow
            }
            else {
                Write-Host ""
            }
        }

        Write-Host ""
        Write-Host "  Seleccionados: $selectedCount / $($Items.Count)" -ForegroundColor Cyan
        Write-Host ""
        Write-Host "  Comandos:" -ForegroundColor DarkGray
        Write-Host "    <numero>  Toggle individual    " -ForegroundColor DarkGray -NoNewline
        Write-Host "A" -ForegroundColor Green -NoNewline
        Write-Host " = Seleccionar todos" -ForegroundColor DarkGray
        Write-Host "    " -NoNewline
        Write-Host "N" -ForegroundColor Red -NoNewline
        Write-Host " = Deseleccionar todos   " -ForegroundColor DarkGray -NoNewline
        Write-Host "R" -ForegroundColor Yellow -NoNewline
        Write-Host " = Solo recomendados" -ForegroundColor DarkGray
        Write-Host "    " -NoNewline
        Write-Host "C" -ForegroundColor Cyan -NoNewline
        Write-Host " = Confirmar seleccion   " -ForegroundColor DarkGray -NoNewline
        Write-Host "V" -ForegroundColor DarkYellow -NoNewline
        Write-Host " = Volver sin seleccionar" -ForegroundColor DarkGray
        Write-Host ""

        $input = Read-Host "  Accion"
        $inputUpper = $input.Trim().ToUpper()

        switch ($inputUpper) {
            "A" {
                for ($i = 0; $i -lt $selected.Count; $i++) { $selected[$i] = $true }
            }
            "N" {
                for ($i = 0; $i -lt $selected.Count; $i++) { $selected[$i] = $false }
            }
            "R" {
                for ($i = 0; $i -lt $Items.Count; $i++) {
                    $selected[$i] = ($Items[$i].recommended -eq $true)
                }
            }
            "C" {
                $done = $true
            }
            "V" {
                $done = $true
                $cancelled = $true
            }
            default {
                $num = 0
                if ([int]::TryParse($inputUpper, [ref]$num) -and $num -ge 1 -and $num -le $Items.Count) {
                    $idx = $num - 1
                    $selected[$idx] = -not $selected[$idx]
                }
                else {
                    Write-Host "  Entrada no valida." -ForegroundColor Red
                    Start-Sleep -Milliseconds 800
                }
            }
        }
    } while (-not $done)

    if ($cancelled) {
        return @()
    }

    $result = @()
    for ($i = 0; $i -lt $Items.Count; $i++) {
        if ($selected[$i]) {
            $result += $Items[$i]
        }
    }

    return $result
}

function Show-Progress {
    <#
    .SYNOPSIS
        Muestra barra de progreso visual y nativa de PowerShell.
    .PARAMETER Activity
        Nombre de la actividad en curso.
    .PARAMETER Status
        Estado actual de la operacion.
    .PARAMETER Current
        Numero de item actual.
    .PARAMETER Total
        Numero total de items.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Activity,

        [Parameter(Mandatory = $true)]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [int]$Current,

        [Parameter(Mandatory = $true)]
        [int]$Total
    )

    if ($Total -le 0) { $Total = 1 }
    $percent = [math]::Min(100, [math]::Floor(($Current / $Total) * 100))

    # Barra visual con caracteres ASCII
    $barWidth = 30
    $filled = [math]::Floor($barWidth * $percent / 100)
    $empty = $barWidth - $filled
    $bar = ("#" * $filled) + ("-" * $empty)

    Write-Host "`r  [$bar] $percent% ($Current/$Total) - $Status    " -ForegroundColor Cyan -NoNewline

    # Tambien usar Write-Progress nativo de PowerShell
    Write-Progress -Activity $Activity -Status "$Status ($Current/$Total)" -PercentComplete $percent
}

function Show-Summary {
    <#
    .SYNOPSIS
        Muestra resumen final de operaciones realizadas.
    .PARAMETER Results
        Hashtable con claves 'Success', 'Failed', 'Skipped', cada una conteniendo un array de nombres.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Results
    )

    $successItems = if ($Results.Success) { @($Results.Success) } else { @() }
    $failedItems = if ($Results.Failed) { @($Results.Failed) } else { @() }
    $skippedItems = if ($Results.Skipped) { @($Results.Skipped) } else { @() }

    Write-Host ""
    Write-Header -Title "RESUMEN DE OPERACIONES"

    # Exitosos
    Write-Host "  [OK] Exitosos: $($successItems.Count)" -ForegroundColor Green
    foreach ($item in $successItems) {
        Write-Host "       - $item" -ForegroundColor Gray
    }

    if ($successItems.Count -gt 0) { Write-Host "" }

    # Fallidos
    Write-Host "  [!!] Fallidos: $($failedItems.Count)" -ForegroundColor Red
    foreach ($item in $failedItems) {
        Write-Host "       - $item" -ForegroundColor Gray
    }

    if ($failedItems.Count -gt 0) { Write-Host "" }

    # Omitidos
    Write-Host "  [--] Omitidos: $($skippedItems.Count)" -ForegroundColor Yellow
    foreach ($item in $skippedItems) {
        Write-Host "       - $item" -ForegroundColor Gray
    }

    Write-Host ""
    $totalWidth = 50
    Write-Host ("=" * $totalWidth) -ForegroundColor Cyan
    Write-Host ""
}

function Show-Confirmation {
    <#
    .SYNOPSIS
        Pregunta de confirmacion Si/No.
    .PARAMETER Message
        Mensaje a mostrar.
    .PARAMETER DefaultYes
        Si se especifica, la opcion por defecto es Si.
    .OUTPUTS
        [bool] $true si el usuario confirma, $false si no.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [switch]$DefaultYes
    )

    $options = if ($DefaultYes) { "(S/n)" } else { "(s/N)" }

    do {
        Write-Host ""
        Write-Host "  $Message $options " -ForegroundColor Yellow -NoNewline
        $response = Read-Host

        if ([string]::IsNullOrWhiteSpace($response)) {
            return $DefaultYes.IsPresent
        }

        $responseUpper = $response.Trim().ToUpper()

        switch ($responseUpper) {
            "S" { return $true }
            "SI" { return $true }
            "Y" { return $true }
            "YES" { return $true }
            "N" { return $false }
            "NO" { return $false }
            default {
                Write-Host "  Respuesta no valida. Ingrese S o N." -ForegroundColor Red
            }
        }
    } while ($true)
}

# =============================================================================
# Exportar funciones publicas
# =============================================================================
Export-ModuleMember -Function @(
    'Write-ColorText',
    'Write-Header',
    'Write-Section',
    'Show-Banner',
    'Show-MainMenu',
    'Show-CategoryMenu',
    'Show-CheckboxList',
    'Show-Progress',
    'Show-Summary',
    'Show-Confirmation'
)
