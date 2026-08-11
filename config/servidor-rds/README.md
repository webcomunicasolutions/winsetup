# Perfil servidor-rds

Perfil para **Windows Server 2025** que va a hacer de **servidor RDS de un
cliente** (varios puestos entrando por Escritorio Remoto). Nacido del montaje
del servidor de FERVET (Clinica Veterinaria, Coin, 08/2026).

## Que instala (software.json)
Chrome, Firefox, WinRAR, AnyDesk, WireGuard, Java JRE 8 + AutoFirma + FNMT,
pCloud. **Todos con manualUrl**: en servidores se instala por WinRM/desatendido
y ahi winget falla (0x8a15000f) aunque este instalado. Sin Office (su licencia
en RDS es tema aparte: retail NO vale, hace falta VL o M365 con activacion
compartida).

## Que configura (tweaks.json)
- Maquina: energia alto rendimiento, WU domingos 04:00 con reinicio, telemetria
  minima, sin OOBE de privacidad, LLMNR off, NTP es.pool, red privada.
- **Perfil por defecto** (C:\Users\Default): todos los tweaks ligeros de
  usuario, para que los puestos RDS los hereden al crearse.
- Recordatorios manuales (BIOS, bloatware Gigabyte, WireGuard por GUI).

## Que NO hace (a mano en cada cliente, ver proyecto del cliente)
Conversion de licencia Evaluation, rol RDS + CAL, usuarios por puesto, carpetas
compartidas con ACL, particion de datos, backups (restic/B2), VPN, wallpaper.

## Gotchas aprendidos (FERVET 08/2026)
1. Si el paso del perfil default se interrumpe, el hive queda montado y los
   usuarios nuevos fallan al crear perfil ("No se puede cargar el perfil de
   usuario"). Arreglo: `reg unload HKU\DefUser` o reiniciar.
2. `New-LocalUser` NO mete al usuario en el grupo "Usuarios" (la GUI si):
   anadirlo a mano o no podra iniciar sesion local/SSH.
3. Las descripciones de cuentas locales tienen limite de 48 caracteres.
4. CAL RDS: comprobar en licmgr el tipo REAL (per user/per device) — el
   albaran del proveedor puede mentir. Per device es lo rastreable sin dominio.
