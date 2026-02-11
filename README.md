# WinSetup - Configuracion Automatica de Windows

Sistema modular PowerShell para automatizar la configuracion de PCs nuevos con Windows. Instala software via winget, aplica configuraciones del sistema, y remueve bloatware. Portable (USB) y descargable desde GitHub.

## Requisitos

- Windows 10/11
- PowerShell 5.1 o superior
- Permisos de administrador (el script se auto-eleva)
- Conexion a internet (para instalar software)
- winget (el script lo instala automaticamente si no existe)

## Uso Rapido

### Desde USB o descarga local

```powershell
# Ejecutar directamente
.\main.ps1

# O usar el bootstrap
.\setup.ps1
```

### Desde GitHub (una sola linea)

```powershell
irm https://raw.githubusercontent.com/USUARIO/instalacion_software/main/setup.ps1 | iex
```

## Estructura del Proyecto

```
instalacion_software/
├── setup.ps1                    # Bootstrap: ejecutar desde USB o descarga
├── main.ps1                     # Script principal con menu interactivo
├── config/
│   ├── software.json            # Catalogo de software por categorias
│   ├── tweaks.json              # Registry tweaks organizados
│   ├── bloatware.json           # Lista de bloatware a remover
│   └── settings.json            # Configuracion del script
├── modules/
│   ├── Core.psm1                # Logging, elevacion admin, utilidades base
│   ├── UI.psm1                  # Menu interactivo con colores
│   ├── Software.psm1            # Instalacion via winget
│   ├── Tweaks.psm1              # Registry tweaks y powercfg
│   ├── Bloatware.psm1           # Remocion de apps preinstaladas
│   └── Backup.psm1              # Punto de restauracion y backups
├── logs/                        # Logs de cada ejecucion
└── backups/                     # Backups de registry
```

## Menu Principal

Al ejecutar main.ps1 se muestra un menu interactivo:

1. **Instalar Software** - Navega por categorias, selecciona con checkboxes
2. **Aplicar Configuraciones** - Tweaks de apariencia, privacidad, rendimiento
3. **Remover Bloatware** - Detecta y remueve apps preinstaladas innecesarias
4. **Configuracion Completa** - Todo automatico (solo recomendados)
5. **Ver Log** - Muestra el log de la sesion actual
6. **Salir**

## Modulos

### Core.psm1

Funciones base del sistema:
- Deteccion de privilegios y auto-elevacion
- Logging a archivo y consola
- Verificacion de internet y winget
- Deteccion de ejecucion portable (USB)

### UI.psm1

Interfaz de usuario interactiva:
- Menus con navegacion numerica
- Listas con checkboxes seleccionables
- Barra de progreso visual
- Resumen de operaciones con colores

### Software.psm1

Instalacion de software via winget:
- Catalogo configurable por categorias (software.json)
- Deteccion de software ya instalado (idempotente)
- Reintentos automaticos en fallos de red
- Instalacion silenciosa

### Tweaks.psm1

Configuraciones del sistema Windows:
- **Apariencia**: Tema oscuro, taskbar limpia, ocultar widgets
- **Privacidad**: Desactivar telemetria, Cortana, publicidad
- **Rendimiento**: Plan alto rendimiento, sin suspension
- **Explorador**: Extensiones visibles, archivos ocultos

### Bloatware.psm1

Remocion de apps preinstaladas:
- Lista de bloatware comun (Candy Crush, Bing apps, etc.)
- Proteccion de apps criticas (Store, Calculator, Photos)
- Prevencion de reinstalacion (Remove-AppxProvisionedPackage)

### Backup.psm1

Sistema de seguridad:
- Punto de restauracion automatico
- Backup de registry antes de cambios
- Exportacion del estado actual del sistema

## Configuracion

### software.json

Catalogo de software organizado en categorias:
- Esenciales (Chrome, 7-Zip, VLC, etc.)
- Desarrollo (VS Code, Git, Node.js, etc.)
- Utilidades (PowerToys, Everything, etc.)
- Multimedia (GIMP, OBS, etc.)
- Ofimatica (LibreOffice, Zoom, etc.)
- Comunicacion (Telegram, WhatsApp, etc.)

Cada paquete tiene un flag `recommended` para la instalacion automatica.

### tweaks.json

Tweaks de registry organizados por:
- Apariencia, Privacidad, Rendimiento, Explorador

Cada tweak tiene un flag `recommended` y puede ser habilitado/deshabilitado.

### bloatware.json

- `bloatware`: Lista de apps a remover con flag `recommended`
- `protected`: Lista de apps que NUNCA se removeran

## Personalizar

### Agregar software

Editar `config/software.json` y agregar paquetes con el formato:

```json
{
  "id": "Publisher.AppName",
  "name": "App Name",
  "description": "Descripcion",
  "recommended": false
}
```

El `id` debe ser un ID valido de winget. Buscar con: `winget search nombre`

### Agregar tweaks

Editar `config/tweaks.json` con el formato de registry tweak.

### Agregar/quitar bloatware

Editar `config/bloatware.json`. Buscar IDs con: `Get-AppxPackage | Select Name`

## Seguridad

- Se crea un punto de restauracion antes de cualquier cambio
- Se hace backup del registro antes de modificarlo
- Las acciones destructivas piden confirmacion
- Las apps protegidas no se pueden remover accidentalmente
- Todos los cambios se registran en logs

## Portabilidad

El script funciona desde cualquier ubicacion:
- USB: Copiar toda la carpeta y ejecutar main.ps1
- Red: Compartir carpeta y ejecutar remotamente
- GitHub: Clonar o descargar ZIP

Todas las rutas son relativas a la ubicacion del script.

## Idempotencia

El script se puede ejecutar multiples veces sin problemas:
- Software ya instalado se detecta y omite
- Tweaks ya aplicados se sobrescriben con el mismo valor
- Bloatware ya removido se detecta como ausente

## Troubleshooting

### winget no reconocido

El script intenta instalar winget automaticamente. Si falla:
1. Abrir Microsoft Store
2. Buscar "App Installer"
3. Instalar/actualizar

### Errores de permisos

El script se auto-eleva a administrador. Si no funciona:

```powershell
Start-Process powershell -Verb RunAs -ArgumentList "-File .\main.ps1"
```

### Software no se instala

1. Verificar conexion a internet
2. Verificar que el ID de winget es correcto: `winget search nombre`
3. Revisar el log en la carpeta logs/

## Licencia

Este proyecto es de uso libre. Modificar y distribuir sin restricciones.
