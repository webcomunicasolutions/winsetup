# Plantilla de Perfil de Cliente

## Uso rapido

```powershell
# 1. Copiar plantilla (en Windows)
Copy-Item -Recurse config\_template config\mi-cliente

# 2. Editar software.json con los paquetes del cliente

# 3. Ejecutar con perfil
.\main.ps1 -Profile mi-cliente

# 4. Modo menu con perfil
.\main.ps1 -Profile mi-cliente -Menu

# 5. Ejecucion remota con perfil (tras push a GitHub)
irm https://raw.githubusercontent.com/webcomunicasolutions/winsetup/main/setup.ps1 | iex
# Luego: .\main.ps1 -Profile mi-cliente
```

## Archivos del perfil

| Archivo | Obligatorio | Descripcion |
|---------|-------------|-------------|
| `software.json` | Si | Lista de software a instalar |
| `tweaks.json` | No | Si no existe, usa el default de `config/` |
| `bloatware.json` | No | Si no existe, usa el default de `config/` |
| `settings.json` | No | Si no existe, usa el default de `config/` |

Solo necesitas crear los archivos que sean diferentes al default.

## Paquetes comunes para copiar/pegar

### Acceso remoto
```json
{ "id": "AnyDeskSoftwareGmbH.AnyDesk", "name": "AnyDesk", "recommended": true, "wingetUnavailable": true, "manualUrl": "https://download.anydesk.com/AnyDesk.exe", "silentArgs": "--install \"C:\\Program Files (x86)\\AnyDesk\" --silent --start-with-win --create-shortcuts --create-desktop-icon" }
```

### VPN
```json
{ "id": "WireGuard.WireGuard", "name": "WireGuard", "recommended": true, "wingetUnavailable": true, "manualUrl": "https://download.wireguard.com/windows-client/wireguard-installer.exe" }
```

### Ofimatica
```json
{ "id": "TheDocumentFoundation.LibreOffice", "name": "LibreOffice", "recommended": true }
{ "id": "Microsoft.Office", "name": "Office 2021 Pro Plus", "recommended": true, "wingetUnavailable": true, "manualUrl": "https://officecdn.microsoft.com/db/492350f6-3a01-4f97-b9c0-c7c6ddf67d60/media/es-es/ProPlus2021Retail.img" }
```

### Firma digital (Espana)
```json
{ "id": "EclipseAdoptium.Temurin.8.JRE", "name": "Java JRE 8", "recommended": true, "wingetUnavailable": true, "manualUrl": "https://api.adoptium.net/v3/installer/latest/8/ga/windows/x64/jre/hotspot/normal/eclipse" }
{ "id": "Gobierno.AutoFirma", "name": "AutoFirma", "recommended": true, "wingetUnavailable": true, "manualUrl": "https://firmaelectronica.gob.es/content/dam/firmaelectronica/descargas-software/autofirma19/Autofirma64.zip" }
{ "id": "FNMT.Configurador", "name": "Configurador FNMT", "recommended": true, "wingetUnavailable": true, "manualUrl": "https://descargas.cert.fnmt.es/Windows/Configurador_FNMT_5.1.0_64bits.exe" }
```

### Comunicacion
```json
{ "id": "Zoom.Zoom", "name": "Zoom", "recommended": true }
{ "id": "SlackTechnologies.Slack", "name": "Slack", "recommended": true }
{ "id": "Microsoft.Teams", "name": "Microsoft Teams", "recommended": true }
```
