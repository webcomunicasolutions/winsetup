# =============================================================================
# Tweaks.psm1 - Modulo de configuracion y optimizacion de Windows
# Aplica tweaks de registro, configuracion de energia y personalizaciones
# =============================================================================

# Cmdlets que los tweaks del JSON PUEDEN usar. Todo lo que no este aqui se
# rechaza sin ejecutarlo: el config es de confianza, pero un fichero de config no
# deberia ser una via para ejecutar cualquier cosa como administrador.
# Si un tweak nuevo necesita otro cmdlet, se anade aqui a proposito.
$script:AllowedTweakCommands = @(
    'Add-Type',
    'Disable-NetAdapterBinding', 'Enable-NetAdapterBinding',
    'Disable-ScheduledTask', 'Enable-ScheduledTask', 'Unregister-ScheduledTask',
    'ForEach-Object', 'Where-Object', 'Select-Object', 'Sort-Object',
    'Get-AppxPackage', 'Remove-AppxPackage',
    'Get-AppxProvisionedPackage', 'Remove-AppxProvisionedPackage',
    'Get-Item', 'Get-ItemProperty', 'Set-ItemProperty', 'New-ItemProperty',
    'New-Item', 'Remove-Item', 'Remove-ItemProperty', 'Test-Path',
    'Get-NetAdapter', 'Get-NetConnectionProfile', 'Set-NetConnectionProfile',
    'Get-Service', 'Set-Service', 'Start-Service', 'Stop-Service',
    'Get-WindowsOptionalFeature', 'Disable-WindowsOptionalFeature',
    'Out-Null', 'Set-TimeZone', 'Set-Culture', 'Set-WinSystemLocale',
    'Set-MpPreference', 'Set-ExecutionPolicy'
)

# =============================================================================
# Destino de los tweaks de USUARIO (HKCU)
# -----------------------------------------------------------------------------
# HKCU es la cuenta que ejecuta el script, no la persona que usa el PC. Como
# SYSTEM (tarea programada de Manhattan) o con credenciales de otro admin, HKCU
# cae en la cuenta equivocada y el tweak "funciona" sin que la usuaria vea nada.
#   - Con -Usuario <cuenta>: HKCU:\ se redirige a HKEY_USERS\<SID> de esa persona
#     (su hive ya cargado si tiene sesion abierta, o su NTUSER.DAT cargado aqui).
#   - Sin -Usuario y como SYSTEM: los tweaks HKCU se OMITEN con aviso.
#   - Sin -Usuario y con una cuenta normal: se aplican a ESA cuenta (y se dice cual).
# =============================================================================
$script:UserTarget = $null   # @{ Account; Sid; Root; RegRoot; LoadedByUs; HiveName }

# Lo pone Apply-RegistryTweak cuando una clave se rechaza con ACCESO DENEGADO por
# los dos caminos (PowerShell y reg.exe) siendo administrador: no es el metodo ni
# los permisos de la clave, es un filtro de registro (antivirus tipo Norton, o
# Windows). Visto en Win11 25H2 (build 26200, LUISA 03/10/2026) con Widgets y
# Noticias: 0x80070005 en Dsh y Windows Feeds. El texto en espanol de .NET dice
# "operacion no valida", que despista: el HResult es el que manda.
$script:LastTweakBlocked = $false
$script:BlockedSuffix = ' [BLOQUEADO por Windows/antivirus: acceso denegado siendo admin. Quitar a mano]'

function Test-AccessDeniedError {
    param($Exception)
    for ($e = $Exception; $e; $e = $e.InnerException) {
        if ($e -is [UnauthorizedAccessException] -or $e -is [System.Security.SecurityException]) { return $true }
        if ($e.HResult -eq -2147024891) { return $true }   # 0x80070005
    }
    return $false
}

function Test-RunningAsSystem {
    [CmdletBinding()]
    [OutputType([bool])]
    param()
    return ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -eq 'S-1-5-18')
}

function Set-TweaksUserTarget {
    <#
    .SYNOPSIS
        Fija la cuenta cuyo HKCU recibira los tweaks de usuario.
    .PARAMETER Usuario
        Cuenta local o de dominio ('ana', 'EQUIPO\ana', 'DOMINIO\ana').
    .PARAMETER RegistryRoot
        SOLO PARA PRUEBAS: usa esta ruta como raiz de HKCU en vez del hive real.
    .OUTPUTS
        $true si el destino queda listo, $false si no (y lo registra en el log).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Usuario,

        [string]$RegistryRoot
    )

    Clear-TweaksUserTarget

    if ($RegistryRoot) {
        $script:UserTarget = @{
            Account = $Usuario; Sid = '(prueba)'; Root = $RegistryRoot.TrimEnd('\')
            RegRoot = ($RegistryRoot.TrimEnd('\') -replace '^HKCU:\\', 'HKCU\' -replace '^Registry::HKEY_USERS\\', 'HKU\')
            LoadedByUs = $false; HiveName = $null
        }
        return $true
    }

    try {
        $sid = ([Security.Principal.NTAccount]$Usuario).Translate([Security.Principal.SecurityIdentifier]).Value
    }
    catch {
        Write-Log -Message "Usuario destino '$Usuario' no existe en este equipo: $_" -Level Error
        return $false
    }

    $profileKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$sid"
    $profilePath = (Get-ItemProperty -Path $profileKey -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
    if (-not $profilePath) {
        Write-Log -Message "El usuario '$Usuario' ($sid) no tiene perfil creado todavia: que inicie sesion una vez y repetir" -Level Error
        return $false
    }

    $target = @{ Account = $Usuario; Sid = $sid; LoadedByUs = $false; HiveName = $null }

    if (Test-Path "Registry::HKEY_USERS\$sid") {
        # Tiene sesion abierta: su hive ya esta montado (y su NTUSER.DAT bloqueado)
        $target.Root = "Registry::HKEY_USERS\$sid"
        $target.RegRoot = "HKU\$sid"
        Write-Log -Message "Usuario destino '$Usuario' con sesion abierta: se escribe en HKU\$sid" -Level Info
    }
    else {
        $ntuser = Join-Path $profilePath 'NTUSER.DAT'
        $hiveName = "WinSetup_$($sid -replace '[^0-9]', '')"
        $out = & reg.exe load "HKU\$hiveName" "$ntuser" 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Log -Message "No se pudo cargar $ntuser : $out" -Level Error
            return $false
        }
        $target.Root = "Registry::HKEY_USERS\$hiveName"
        $target.RegRoot = "HKU\$hiveName"
        $target.LoadedByUs = $true
        $target.HiveName = $hiveName
        Write-Log -Message "Usuario destino '$Usuario' sin sesion: cargado $ntuser en HKU\$hiveName" -Level Info
    }

    $script:UserTarget = $target
    return $true
}

function Clear-TweaksUserTarget {
    <#
    .SYNOPSIS
        Quita el destino de usuario y descarga su NTUSER.DAT si lo cargamos nosotros.
    .DESCRIPTION
        Un hive que se queda montado impide a esa persona iniciar sesion con su
        perfil (visto en FERVET 08/2026 con el perfil Default). Por eso se llama
        siempre en un finally y se reintenta la descarga.
    #>
    [CmdletBinding()]
    param()

    $t = $script:UserTarget
    $script:UserTarget = $null
    if (-not $t -or -not $t.LoadedByUs) { return }

    for ($i = 1; $i -le 5; $i++) {
        [GC]::Collect()
        [GC]::WaitForPendingFinalizers()
        $out = & reg.exe unload "HKU\$($t.HiveName)" 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log -Message "Perfil de '$($t.Account)' descargado (HKU\$($t.HiveName))" -Level Info
            return
        }
        Start-Sleep -Seconds 2
    }
    Write-Log -Message "NO se pudo descargar HKU\$($t.HiveName): $out. Ejecutar 'reg unload HKU\$($t.HiveName)' o reiniciar ANTES de que '$($t.Account)' inicie sesion" -Level Error
}

function Get-TweaksUserTargetDescription {
    <#
    .SYNOPSIS
        Texto para el log/pantalla: a quien van los tweaks de usuario.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param()

    if ($script:UserTarget) { return "$($script:UserTarget.Account) ($($script:UserTarget.Sid))" }
    if (Test-RunningAsSystem) { return 'NINGUNO (se ejecuta como SYSTEM sin -Usuario: se omiten)' }
    return "$([Security.Principal.WindowsIdentity]::GetCurrent().Name) (la cuenta que ejecuta el script)"
}

function Resolve-TweakRegistryPath {
    <#
    .SYNOPSIS
        Traduce una ruta del JSON al destino real. $null = hay que omitirla.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    if ($Path -notmatch '^HKCU:\\') { return $Path }
    if ($script:UserTarget) { return ($Path -replace '^HKCU:', $script:UserTarget.Root) }
    if (Test-RunningAsSystem) { return $null }
    return $Path
}

function Resolve-TweakCommandText {
    <#
    .SYNOPSIS
        Redirige HKCU en un comando del JSON. $null = hay que omitirlo.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandText
    )

    $usesHkcu = $CommandText -match 'HKCU:\\|HKCU\\|HKEY_CURRENT_USER'
    if (-not $usesHkcu) { return $CommandText }
    if ($script:UserTarget) {
        # Una sola pasada: con -replace encadenados, lo ya sustituido volvia a
        # casar con el patron siguiente y la ruta se duplicaba.
        $root = $script:UserTarget.Root
        $regRoot = $script:UserTarget.RegRoot
        return [regex]::Replace($CommandText, 'HKCU:\\|HKEY_CURRENT_USER\\|(?<![A-Za-z])HKCU\\', {
            param($m)
            if ($m.Value -eq 'HKCU:\') { return $root + '\' }
            return $regRoot + '\'
        }.GetNewClosure())
    }
    if (Test-RunningAsSystem) { return $null }
    return $CommandText
}

function ConvertTo-RegExePath {
    # Ruta de PowerShell -> ruta de reg.exe (HKCU:\x, HKLM:\x, Registry::HKEY_USERS\x)
    param([string]$Path)
    return ($Path `
        -replace '^Registry::HKEY_USERS\\', 'HKU\' `
        -replace '^Registry::HKEY_LOCAL_MACHINE\\', 'HKLM\' `
        -replace '^Registry::HKEY_CURRENT_USER\\', 'HKCU\' `
        -replace '^(HKCU|HKLM|HKU):\\', '$1\')
}

function Get-DisallowedCommands {
    <#
    .SYNOPSIS
        Devuelve los comandos de un texto de PowerShell que NO estan en la allowlist.
    .DESCRIPTION
        Usa el parser de PowerShell (no expresiones regulares) para sacar todos los
        comandos del texto, incluidos los de dentro de pipelines, bloques y
        subexpresiones. Devuelve un array vacio si todo esta permitido.
    .PARAMETER CommandText
        Texto del comando tal y como viene del JSON de tweaks.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory = $true)]
        [string]$CommandText
    )

    $errs = $null
    $tokens = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $CommandText, [ref]$tokens, [ref]$errs)

    if ($errs -and $errs.Count -gt 0) {
        return @("<error de sintaxis: $($errs[0].Message)>")
    }

    $comandos = $ast.FindAll(
        { param($n) $n -is [System.Management.Automation.Language.CommandAst] }, $true)

    $malos = New-Object System.Collections.Generic.List[string]
    foreach ($c in $comandos) {
        $nombre = $c.GetCommandName()
        if (-not $nombre) {
            $malos.Add('<comando dinamico>')   # p.ej. & $var: no se puede validar
            continue
        }
        if ($script:AllowedTweakCommands -notcontains $nombre) { $malos.Add($nombre) }
    }
    return $malos.ToArray()
}

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
        # HKCU:\Software\... -> HKCU\Software\... ; Registry::HKEY_USERS\x -> HKU\x
        $regPath = ConvertTo-RegExePath -Path $Path

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
        $applied = 0
        $omitted = 0
        $script:LastTweakBlocked = $false

        foreach ($original in $RegistryEntries) {
            $realPath = Resolve-TweakRegistryPath -Path $original.path
            if (-not $realPath) {
                Write-Log -Message "  OMITIDO (es de usuario y se ejecuta como SYSTEM sin -Usuario): $($original.path)\$($original.name)" -Level Warning
                $omitted++
                continue
            }
            # Copia con la ruta real; el resto del bloque no cambia
            $entry = [pscustomobject]@{ path = $realPath; name = $original.name; value = $original.value; type = $original.type }
            try {
                # Backup de la key antes de modificar
                Backup-RegistryKey -Path $entry.path | Out-Null

                # Crear la key si no existe
                if (-not (Test-Path -LiteralPath $entry.path)) {
                    # -ErrorAction Stop: sin el, un acceso denegado no cortaba, se
                    # registraba "creada" y el error que llegaba era "no existe"
                    New-Item -Path $entry.path -Force -ErrorAction Stop | Out-Null
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
                $applied++
            }
            catch {
                # Fallback: intentar con reg.exe cuando PowerShell falla (ej: claves protegidas en Win11)
                $psDenegado = Test-AccessDeniedError -Exception $_.Exception
                Write-Log -Message "  Set-ItemProperty fallo [$($_.Exception.GetType().Name) 0x$('{0:X8}' -f $_.Exception.HResult)], intentando con reg.exe..." -Level Warning
                try {
                    $regPath = ConvertTo-RegExePath -Path $entry.path
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
                        $applied++
                    }
                    else {
                        if ($psDenegado) {
                            $script:LastTweakBlocked = $true
                            Write-Log -Message "  BLOQUEADO: acceso denegado por PowerShell Y por reg.exe en $($entry.path)\$($entry.name). Lo impide un filtro de registro (antivirus o Windows), no el script. reg.exe: $regOutput" -Level Error
                        }
                        else {
                            Write-Log -Message "  Error reg.exe: $regOutput" -Level Error
                        }
                        $allOk = $false
                    }
                }
                catch {
                    Write-Log -Message "  Error al aplicar registro $($entry.path)\$($entry.name): $_" -Level Error
                    $allOk = $false
                }
            }
        }

        if ($allOk -and $applied -eq 0 -and $omitted -gt 0) {
            Write-Log -Message "Tweak omitido (solo tiene claves de usuario): $TweakName" -Level Warning
            return 'Skipped'
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
        $executed = 0

        foreach ($rawCmd in $Commands) {
            try {
                $cmd = Resolve-TweakCommandText -CommandText $rawCmd
                if (-not $cmd) {
                    Write-Log -Message "  OMITIDO (es de usuario y se ejecuta como SYSTEM sin -Usuario): $rawCmd" -Level Warning
                    continue
                }
                Write-Log -Message "Ejecutando: $cmd" -Level Info
                $executed++

                # Si es un cmdlet de PowerShell (contiene - como Set-NetConnectionProfile)
                if ($cmd -match '^\w+-\w+') {
                    # Antes de ejecutar un string venido del JSON se comprueba con el
                    # parser que TODOS los comandos del pipeline estan en la allowlist,
                    # para que un config manipulado no pueda ejecutar cualquier cosa
                    # como administrador. Ver $script:AllowedTweakCommands.
                    $noPermitidos = Get-DisallowedCommands -CommandText $cmd
                    if ($noPermitidos.Count -gt 0) {
                        Write-Log -Message "  RECHAZADO por seguridad (comando no permitido: $($noPermitidos -join ', ')): $cmd" -Level Error
                        $allOk = $false
                        continue
                    }

                    $errores = @()
                    & ([scriptblock]::Create($cmd)) -ErrorVariable errores -ErrorAction SilentlyContinue | Out-Null
                    if ($errores.Count -gt 0) {
                        Write-Log -Message "  Comando devolvio errores: $cmd :: $($errores[0])" -Level Warning
                        $allOk = $false
                    }
                    else {
                        Write-Log -Message "  Comando ejecutado correctamente: $cmd" -Level Info
                    }
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
                Write-Log -Message "  Error al ejecutar '$rawCmd': $_" -Level Error
                $allOk = $false
            }
        }

        if ($allOk -and $executed -eq 0) { return 'Skipped' }
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

            $script:LastTweakBlocked = $false
            $result = Apply-TweakItem -Tweak $tweak

            switch ($result) {
                'Success' { $results.Success += $tweak.name }
                'Failed'  { $results.Failed += $(if ($script:LastTweakBlocked) { $tweak.name + $script:BlockedSuffix } else { $tweak.name }) }
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

            $script:LastTweakBlocked = $false
            $result = Apply-TweakItem -Tweak $tweak

            switch ($result) {
                'Success' { $results.Success += $tweak.name }
                'Failed'  { $results.Failed += $(if ($script:LastTweakBlocked) { $tweak.name + $script:BlockedSuffix } else { $tweak.name }) }
                'Skipped' { $results.Skipped += $tweak.name }
            }
        }

        Write-Progress -Activity "Aplicando tweaks recomendados" -Completed
        Write-Host ""

        # Reiniciar explorer.exe para que los cambios de registro surtan efecto.
        # SOLO si el script corre en la sesion de la propia persona: como SYSTEM
        # mataria el Explorador de todos y lo relanzaria en la sesion 0 (invisible),
        # y con -Usuario el Explorador que importa es el de otra cuenta.
        $explorerPropio = (Test-InteractiveSession) -and -not $script:UserTarget -and -not (Test-RunningAsSystem)
        if ($results.Success.Count -gt 0 -and -not $explorerPropio) {
            Write-Log -Message "No se reinicia el Explorador (no es la sesion de la persona): los cambios de usuario se veran al cerrar y abrir sesion" -Level Warning
        }
        if ($results.Success.Count -gt 0 -and $explorerPropio) {
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
    'Test-RunningAsSystem',
    'Set-TweaksUserTarget',
    'Clear-TweaksUserTarget',
    'Get-TweaksUserTargetDescription',
    'Resolve-TweakRegistryPath',
    'Resolve-TweakCommandText',
    'Get-DisallowedCommands',
    'Get-TweaksCatalog',
    'Backup-RegistryKey',
    'Apply-RegistryTweak',
    'Apply-PowerConfiguration',
    'Apply-TweakItem',
    'Start-TweaksConfiguration',
    'Apply-RecommendedTweaks'
)
