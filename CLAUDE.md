# WinSetup (instalacion_software)

PowerShell para dejar listo un Windows: software (winget o descarga directa), tweaks
de registro y quitar bloatware. Uso, perfiles y opciones: `README.md`.

- **Repo PUBLICO**: `github.com/webcomunicasolutions/winsetup`. Nada de contraseñas ni
  datos de clientes en el repo (por eso la contraseña de AnyDesk NO esta: solo hay un
  recordatorio al final, decision de Yeye 03/10/2026).
- **Hacer push = desplegar**: Manhattan descarga `main` y lo ejecuta como SYSTEM en
  equipos de clientes. Yeye autorizo (03/10/2026) que Claude suba los commits de este repo.
- Pruebas: `tests/test-solo-y-usuario.ps1` (sin admin, no toca ajustes reales) y
  `tests/test-arreglos.ps1` (pensado para SSH; desde WSL su prueba 3 falla, es esperado).
  Desde WSL: `powershell.exe -NoProfile -ExecutionPolicy Bypass -File $(wslpath -w tests/...)`
  redirigiendo la salida a fichero (con `| grep` directo se ha llegado a colgar).

## Contrato con Manhattan (avisar ANTES a la sesion proyecto-manhatan-ca si cambia)

Manhattan (`~/proyectos/aprendizaje/proyecto_manhatan`) depende de:

1. **`config/tweaks.json` y `config/<perfil>/tweaks.json`**: `auditar-tweaks.ps1` ya no
   tiene catalogo propio, lee el nuestro. Usa `categories[].tweaks[]` con `name`,
   `recommended` y `registry[]` = `{path HKCU:\|HKLM:\, name, value, type}`; escribe con
   ese `type` (Binary = texto "90,12,..." a bytes) y audita tipo + valor. `powerConfig`
   no lo aplica (lo lista como no cubierto). Tipos en uso: DWord, String, Binary.
   Test suyo: `v3/cli/test_preparar.py::test_catalogo_del_ps1_coincide_con_winsetup`.
2. **`Test-SoftwareInstalled`** (Software.psm1, nombre y parametros `-PackageId`
   `-PackageName`, y el opcional `-Detect` desde 03/10/2026) y la estructura de
   **`config/<perfil>/software.json`** (campo opcional `detect`: patrones -like de
   DisplayName que tambien cuentan como instalado). Los usa para ver que
   `recommended` faltan (por registro, winget desactivado).
3. **Variables de entorno**: `WINSETUP_UNATTENDED=1`, `WINSETUP_PROFILE`, `WINSETUP_SOLO`,
   `WINSETUP_USUARIO` (worker `instalar-paquete-winsetup.ps1`, via `setup.ps1`).
4. **Codigo de salida** (setup.ps1 propaga el de main.ps1): 0 ok, 1 no empezo,
   2 terminado con fallos/BLOQUEADO.
5. **Textos del log** que busca su worker: `[ERROR]`, `No se pudo preparar el usuario
   destino`, `EXCEPCION`, `[Error]`, `BLOQUEADO`, `OMITIDO (es de usuario`.

## Hechos que costaron descubrir

- Win11 25H2 (LUISA, build 26200): Widgets y Noticias (HKLM\Policies Dsh / Windows Feeds)
  dan **acceso denegado siendo admin** por PowerShell Y reg.exe = filtro de registro
  (Norton 360 o UCPD, sin distinguir). .NET en español dice "operacion no valida": manda
  el HResult (0x80070005). Salen como BLOQUEADO.
- Tweaks HKCU como SYSTEM caen en la cuenta SYSTEM: sin `-Usuario` se omiten.
- Iconos de escritorio: el Explorador moderno lee `HideDesktopIcons\NewStartPanel`
  (ClassicStartMenu solo no basta).
