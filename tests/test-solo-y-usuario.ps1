# Pruebas de: -Solo* / WINSETUP_SOLO, destino de tweaks de usuario (-Usuario),
# omision de HKCU como SYSTEM y confirmaciones desatendidas.
# NO necesita administrador ni toca ajustes reales: escribe solo bajo
# HKCU:\Software\WinSetupPrueba (se borra al final).
$base = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$fallos = 0
function Ok($m)   { "  OK   $m" }
function Bad($m)  { $script:fallos++; "  FALLO $m" }
$sandbox = 'HKCU:\Software\WinSetupPrueba'

'== 1) Sintaxis de todos los .psm1 y .ps1'
Get-ChildItem "$base\modules\*.psm1", "$base\*.ps1", "$base\tests\*.ps1" | ForEach-Object {
    $e = $null; $t = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$t, [ref]$e) | Out-Null
    if ($e -and $e.Count) { Bad "$($_.Name): $($e[0].Message)" } else { Ok $_.Name }
}

'== 2) Modulos'
Import-Module "$base\modules\Core.psm1"   -Force -ErrorAction Stop
Import-Module "$base\modules\UI.psm1"     -Force -ErrorAction Stop
Import-Module "$base\modules\Tweaks.psm1" -Force -ErrorAction Stop -DisableNameChecking
$tw = Get-Module Tweaks
Ok 'Core + UI + Tweaks importados'

'== 3) Sin destino y sin ser SYSTEM: HKCU se queda como esta'
Clear-TweaksUserTarget
$r = Resolve-TweakRegistryPath -Path 'HKCU:\Software\A'
if ($r -eq 'HKCU:\Software\A') { Ok "HKCU intacto" } else { Bad "devolvio '$r'" }
$r = Resolve-TweakRegistryPath -Path 'HKLM:\SOFTWARE\B'
if ($r -eq 'HKLM:\SOFTWARE\B') { Ok "HKLM intacto" } else { Bad "devolvio '$r'" }

'== 4) Con destino: HKCU se redirige (registro y comandos)'
Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
New-Item "$sandbox\Destino" -Force | Out-Null
if (Set-TweaksUserTarget -Usuario 'prueba' -RegistryRoot "$sandbox\Destino") { Ok 'destino de prueba fijado' } else { Bad 'no se fijo el destino' }
$r = Resolve-TweakRegistryPath -Path 'HKCU:\Software\X'
if ($r -eq "$sandbox\Destino\Software\X") { Ok "ruta -> $r" } else { Bad "ruta -> '$r'" }
$casos = @(
    @{ in = 'Set-ItemProperty -Path "HKCU:\Software\X" -Name a -Value 1'; out = "Set-ItemProperty -Path `"$sandbox\Destino\Software\X`" -Name a -Value 1" },
    @{ in = 'reg add "HKCU\Software\X" /v a /d 1 /f'; out = 'reg add "HKCU\Software\WinSetupPrueba\Destino\Software\X" /v a /d 1 /f' },
    @{ in = 'reg add "HKEY_CURRENT_USER\Software\X" /f'; out = 'reg add "HKCU\Software\WinSetupPrueba\Destino\Software\X" /f' },
    @{ in = 'reg add "HKU\DefUser\Software\X" /f'; out = 'reg add "HKU\DefUser\Software\X" /f' },
    @{ in = 'powercfg /change standby-timeout-ac 0'; out = 'powercfg /change standby-timeout-ac 0' }
)
foreach ($c in $casos) {
    $r = Resolve-TweakCommandText -CommandText $c.in
    if ($r -eq $c.out) { Ok "cmd: $($c.in.Substring(0,[Math]::Min(40,$c.in.Length)))" } else { Bad "cmd '$($c.in)' -> '$r' (esperado '$($c.out)')" }
}

'== 5) Apply-RegistryTweak escribe en el DESTINO y no en el HKCU real'
$entrada = @([pscustomobject]@{ path = 'HKCU:\Software\WinSetupPrueba\Real\Explorer'; name = 'Valor'; value = 1; type = 'DWord' })
$res = Apply-RegistryTweak -TweakName 'prueba destino' -RegistryEntries $entrada
$enDestino = (Get-ItemProperty "$sandbox\Destino\Software\WinSetupPrueba\Real\Explorer" -Name Valor -ErrorAction SilentlyContinue).Valor
$enReal = Test-Path "$sandbox\Real"
if ($res -eq 'Success' -and $enDestino -eq 1) { Ok "escrito en destino (resultado $res)" } else { Bad "resultado $res, valor en destino '$enDestino'" }
if (-not $enReal) { Ok 'el HKCU real NO se ha tocado' } else { Bad 'se escribio en el HKCU real' }

'== 6) Rutas para reg.exe'
$conv = & $tw { param($p) ConvertTo-RegExePath -Path $p }
$casos = @(
    @{ in = 'Registry::HKEY_USERS\S-1-5-21-1\Software\X'; out = 'HKU\S-1-5-21-1\Software\X' },
    @{ in = 'HKCU:\Software\X'; out = 'HKCU\Software\X' },
    @{ in = 'HKLM:\SOFTWARE\X'; out = 'HKLM\SOFTWARE\X' }
)
foreach ($c in $casos) {
    $r = & $tw { param($p) ConvertTo-RegExePath -Path $p } $c.in
    if ($r -eq $c.out) { Ok "$($c.in) -> $r" } else { Bad "$($c.in) -> '$r'" }
}
Clear-TweaksUserTarget

'== 7) Como SYSTEM sin -Usuario: HKCU se OMITE (simulado)'
& $tw { function script:Test-RunningAsSystem { $true } }
$r = Resolve-TweakRegistryPath -Path 'HKCU:\Software\A'
if ($null -eq $r) { Ok 'ruta HKCU -> omitida' } else { Bad "ruta HKCU -> '$r'" }
$r = Resolve-TweakRegistryPath -Path 'HKLM:\SOFTWARE\B'
if ($r -eq 'HKLM:\SOFTWARE\B') { Ok 'HKLM se sigue aplicando' } else { Bad "HKLM -> '$r'" }
$res = Apply-RegistryTweak -TweakName 'solo usuario' -RegistryEntries $entrada
if ($res -eq 'Skipped') { Ok 'tweak solo-HKCU -> Skipped (no Success mentiroso)' } else { Bad "tweak solo-HKCU -> $res" }
$res = Apply-PowerConfiguration -Commands @('Set-ItemProperty -Path "HKCU:\Software\WinSetupPrueba\Cmd" -Name a -Value 1')
if ($res -eq 'Skipped' -and -not (Test-Path "$sandbox\Cmd")) { Ok 'comando HKCU -> Skipped y no ejecutado' } else { Bad "comando HKCU -> $res" }
$d = Get-TweaksUserTargetDescription
if ($d -match 'SYSTEM') { Ok "descripcion: $d" } else { Bad "descripcion: $d" }
Import-Module "$base\modules\Tweaks.psm1" -Force -DisableNameChecking   # quita el simulacro

'== 8) Show-Confirmation desatendida responde el valor por defecto sin esperar'
$env:WINSETUP_UNATTENDED = '1'
$sw = [Diagnostics.Stopwatch]::StartNew()
$no = Show-Confirmation -Message 'reiniciar?'
$si = Show-Confirmation -Message 'seguir?' -DefaultYes
$sw.Stop()
if ($no -eq $false -and $si -eq $true -and $sw.Elapsed.TotalSeconds -lt 3) { Ok "NO/SI por defecto en $([math]::Round($sw.Elapsed.TotalSeconds,2))s" } else { Bad "no=$no si=$si t=$($sw.Elapsed.TotalSeconds)" }

'== 9) main.ps1 rechaza combinaciones malas ANTES de tocar nada'
$ps = (Get-Process -Id $PID).Path
$env:WINSETUP_SOLO = 'twaeks'
$o = & $ps -NoProfile -ExecutionPolicy Bypass -File "$base\main.ps1" 2>&1 | Out-String
$code = $LASTEXITCODE
if ($code -eq 1 -and $o -match 'no es valido') { Ok 'WINSETUP_SOLO con errata -> exit 1 (no hace "todo")' } else { Bad "errata -> exit $code :: $o" }
Remove-Item Env:\WINSETUP_SOLO
$o = & $ps -NoProfile -ExecutionPolicy Bypass -File "$base\main.ps1" -Menu -SoloTweaks 2>&1 | Out-String
if ($LASTEXITCODE -eq 1 -and $o -match 'no se combina') { Ok '-Menu -SoloTweaks -> exit 1' } else { Bad "-Menu -SoloTweaks -> exit $LASTEXITCODE :: $o" }
$o = & $ps -NoProfile -ExecutionPolicy Bypass -File "$base\main.ps1" -Menu 2>&1 | Out-String
if ($LASTEXITCODE -eq 1 -and $o -match 'no es interactiva') { Ok '-Menu desatendido -> exit 1 (no se cuelga)' } else { Bad "-Menu desatendido -> exit $LASTEXITCODE :: $o" }
Remove-Item Env:\WINSETUP_UNATTENDED

'== 10) "Mostrar iconos de escritorio" recomendado en todos los tweaks que se usan'
$clsids = '20D04FE0-3AEA-1069-A2D8-08002B30309D', '59031a47-3f72-44a7-89c5-5595fe6b30ee', 'F02C1A0D-BE21-4350-88B0-7367FC96EF3C'
Get-ChildItem "$base\config" -Directory | Where-Object { $_.Name -ne '_template' } | ForEach-Object {
    $f = Join-Path $_.FullName 'tweaks.json'
    $origen = $_.Name
    if (-not (Test-Path $f)) { $f = "$base\config\tweaks.json"; $origen = "$($_.Name) (usa el base)" }
    $j = Get-Content $f -Raw -Encoding UTF8 | ConvertFrom-Json
    $rec = foreach ($cat in $j.categories) { foreach ($t in $cat.tweaks) { if ($t.recommended) { $t } } }
    $texto = ($rec | ConvertTo-Json -Depth 10)
    $faltan = $clsids | Where-Object { $texto -notmatch [regex]::Escape($_) }
    $newsp = $texto -match 'NewStartPanel'
    if (-not $faltan -and $newsp) { Ok "$origen : 3 iconos, en NewStartPanel" } else { Bad "$origen : faltan [$($faltan -join ',')] NewStartPanel=$newsp" }
}

'== 11) Acceso denegado por los dos caminos -> BLOQUEADO en el resumen (caso LUISA 25H2)'
# Sin admin, HKLM\SOFTWARE\Policies da 0x80070005 en PowerShell Y en reg.exe:
# el mismo sintoma que el filtro de registro de Win11 25H2. Con admin se salta
# (escribiria de verdad en HKLM).
if (Test-Admin) {
    '  (se omite: ejecutar SIN administrador para provocar el acceso denegado)'
}
else {
    $clave = 'HKLM:\SOFTWARE\Policies\WinSetupPruebaBloqueo'
    $json = Join-Path $env:TEMP 'winsetup_prueba_bloqueo.json'
    @{ categories = @(@{ name = 'Prueba'; tweaks = @(@{ name = 'Tweak de prueba'; recommended = $true;
        registry = @(@{ path = $clave; name = 'Valor'; value = 0; type = 'DWord' }) }) }) } |
        ConvertTo-Json -Depth 10 | Set-Content -Path $json -Encoding UTF8
    $res = Apply-RecommendedTweaks -ConfigPath $json
    $fallo = @($res.Failed)
    if ($fallo.Count -eq 1 -and $fallo[0] -cmatch '\[BLOQUEADO por') { Ok "resumen: $($fallo[0])" } else { Bad "resumen Failed = [$($fallo -join ' | ')]" }
    if (-not (Test-Path $clave)) { Ok 'no se ha creado nada en HKLM' } else { Bad "se creo $clave" }
    $falsoPositivo = & $tw { Test-AccessDeniedError -Exception ([InvalidOperationException]::new('x')) }
    if ($falsoPositivo -eq $false) { Ok 'otro tipo de error NO se marca como bloqueado' } else { Bad 'InvalidOperation se tomo como bloqueo' }
    Move-Item $json "$json.usado" -Force   # se queda en %TEMP%, no se borra
}

'== 12) setup.ps1 devuelve el codigo de salida de main.ps1 (sin colgarse en Read-Host)'
# Copia de setup.ps1 SIN el bloque de auto-elevacion (si no, saltaria UAC) junto
# a un main.ps1 falso. Se deja en %TEMP%\winsetup_prueba_setup (no se borra).
$dir = Join-Path $env:TEMP 'winsetup_prueba_setup'
New-Item $dir -ItemType Directory -Force | Out-Null
$setup = Get-Content "$base\setup.ps1" -Raw -Encoding UTF8
$sinElevar = [regex]::Replace($setup, '(?s)# --- Auto-elevar.*?\n\}\r?\n', '')
if ($sinElevar -eq $setup) { Bad 'no se encontro el bloque de auto-elevacion para quitarlo' }
Set-Content "$dir\setup.ps1" $sinElevar -Encoding UTF8
$env:WINSETUP_UNATTENDED = '1'
$casos = @(
    @{ main = 'exit 7'; esperado = 7; txt = 'main sale con 7' },
    @{ main = 'cmd /c exit 3; exit 0'; esperado = 0; txt = 'main OK tras un programa que fallo' },
    @{ main = 'cmd /c exit 3; exit 1'; esperado = 1; txt = 'main sale con 1 (errata, usuario inexistente)' }
)
foreach ($c in $casos) {
    Set-Content "$dir\main.ps1" $c.main -Encoding UTF8
    $sw = [Diagnostics.Stopwatch]::StartNew()
    & $ps -NoProfile -ExecutionPolicy Bypass -File "$dir\setup.ps1" *> $null
    $code = $LASTEXITCODE
    $sw.Stop()
    if ($code -eq $c.esperado -and $sw.Elapsed.TotalSeconds -lt 20) { Ok "$($c.txt) -> setup.ps1 exit $code" }
    else { Bad "$($c.txt) -> setup.ps1 exit $code (esperado $($c.esperado)), $([math]::Round($sw.Elapsed.TotalSeconds,1))s" }
}
Remove-Item Env:\WINSETUP_UNATTENDED

'== 13) main.ps1 sale con 2 si algo fallo o salio BLOQUEADO, 0 si no'
# El main.ps1 real necesita admin: se extrae Invoke-PasosRecomendados con el
# parser y se ejecuta con los pasos de verdad simulados.
$e = $null; $t = $null
$astMain = [System.Management.Automation.Language.Parser]::ParseFile("$base\main.ps1", [ref]$t, [ref]$e)
$fn = $astMain.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-PasosRecomendados' }, $true)
. ([scriptblock]::Create($fn.Extent.Text))
function Write-Header { }  function Write-Section { }  function Show-Summary { }
$settings = $null; $Profile = $null; $configPaths = @{ Tweaks = 'x' }
foreach ($c in @(@{ falla = @('Ocultar Widgets [BLOQUEADO por Windows/antivirus]'); esperado = $true },
                 @{ falla = @(); esperado = $false })) {
    $script:HuboAvisos = $false
    $simFalla = $c.falla
    function Apply-RecommendedTweaks { param($ConfigPath) @{ Success = @('a'); Failed = $simFalla; Skipped = @() } }
    function New-FullBackup { param($BackupDir) }
    Invoke-PasosRecomendados -Pasos @('tweaks') *> $null
    if ($script:HuboAvisos -eq $c.esperado) { Ok "fallidos=$($simFalla.Count) -> HuboAvisos=$($script:HuboAvisos)" } else { Bad "fallidos=$($simFalla.Count) -> HuboAvisos=$($script:HuboAvisos)" }
}
$finMain = (Get-Content "$base\main.ps1" -Raw)
if ($finMain -match '(?s)if \(\$script:HuboAvisos\) \{.*?exit 2\s*\}\s*exit 0\s*$') { Ok 'main.ps1 termina con: HuboAvisos -> exit 2, si no exit 0' } else { Bad 'el final de main.ps1 no es el esperado' }

'== 14) Recordatorio de la contraseña de AnyDesk'
$fn = $astMain.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Show-RecordatorioAnyDesk' }, $true)
. ([scriptblock]::Create($fn.Extent.Text))
$falso = Join-Path $env:TEMP 'winsetup_prueba_anydesk.exe'
Set-Content $falso 'x'
$si = Show-RecordatorioAnyDesk -Rutas @('C:\no\existe\AnyDesk.exe', $falso) 6> $null
$no = Show-RecordatorioAnyDesk -Rutas @('C:\no\existe\AnyDesk.exe') 6> $null
if ($si -eq $true -and $no -eq $false) { Ok 'avisa si AnyDesk esta, calla si no' } else { Bad "con AnyDesk=$si sin AnyDesk=$no" }
Move-Item $falso "$falso.usado" -Force
if ((Get-Content "$base\main.ps1" -Raw) -match '(?m)^Show-RecordatorioAnyDesk') { Ok 'main.ps1 llama al recordatorio' } else { Bad 'main.ps1 no llama al recordatorio' }

'== 15) Test-SoftwareInstalled -Detect (patrones de software.json contra el registro)'
Import-Module "$base\modules\Software.psm1" -Force -ErrorAction Stop
$cat = Get-Content "$base\config\software.json" -Raw -Encoding UTF8 | ConvertFrom-Json
$pk = @{}; foreach ($c in $cat.categories) { foreach ($p in $c.packages) { $pk[$p.id] = $p } }
$nombres = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*' -ErrorAction SilentlyContinue |
    Where-Object { $_.DisplayName } | ForEach-Object { $_.DisplayName }
foreach ($id in 'Adobe.Acrobat.Reader.64-bit', 'EclipseAdoptium.Temurin.8.JRE') {
    $p = $pk[$id]
    $hay = $nombres | Where-Object { $n = $_; @($p.detect | Where-Object { $n -like $_ }).Count -gt 0 } | Select-Object -First 1
    if (-not $hay) { "  (se omite $id : este equipo no tiene nada que case con $($p.detect -join ', '))"; continue }
    # PackageName vacio y un Id que no existe: solo puede acertar por -Detect
    $r = Test-SoftwareInstalled -PackageId 'Prueba.NoExiste.WinSetup' -Detect @($p.detect) 6> $null
    if ($r) { Ok "$id detectado por 'detect' ($hay)" } else { Bad "$id NO detectado y el equipo tiene '$hay'" }
}
$r = Test-SoftwareInstalled -PackageId 'Prueba.NoExiste.WinSetup' -Detect @('Programa Que No Existe*') 6> $null
if (-not $r) { Ok 'un patron que no casa no da falso positivo' } else { Bad 'falso positivo con patron inexistente' }
$r = Test-SoftwareInstalled -PackageId 'Prueba.NoExiste.WinSetup' 6> $null
if (-not $r) { Ok 'sin -Detect sigue funcionando como antes (firma compatible)' } else { Bad 'sin -Detect da positivo' }

Remove-Item $sandbox -Recurse -Force -ErrorAction SilentlyContinue
''
if ($fallos -eq 0) { "RESULTADO: TODO OK" } else { "RESULTADO: $fallos FALLO(S)" }
exit $fallos
