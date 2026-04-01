# TheWave Agent — Informe de Debugging

**Fecha**: 31 marzo 2026
**App**: TheWave Agent (`com.andresmallada.the-wave-agent`)
**Dispositivo**: iPhone 15 Pro Max (iOS, 5G celular + WiFi)

---

## Resumen

Se depuró la app iOS para Meta Ray-Ban smart glasses que integra:
- **Gemini Live API** (WebSocket bidireccional con audio/video)
- **MCP Server** (herramientas: `web_search`, `send_message`, `add_reminder`)
- **WebRTC** (streaming de video desde las gafas)

La app se renombró de "VisionClaw" a "TheWave Agent" con nuevo bundle ID.

---

## Problema 1: UI de Settings mostraba campos antiguos de "VisionClaw"

**Síntoma**: La pantalla de Settings seguía mostrando campos y referencias a "VisionClaw" en lugar de los campos MCP/WebRTC actualizados.

**Causa raíz**: La app anterior (`com.xiaoanliu.VisionClaw`) permanecía instalada en el iPhone. iOS mostraba la versión antigua porque el bundle ID había cambiado.

**Solución**: Desinstalar la app antigua manualmente del iPhone antes de instalar la nueva.

**Lección**: Cuando se cambia el bundle ID de una app, la versión anterior NO se reemplaza automáticamente. Hay que desinstalarla manualmente.

---

## Problema 2: Sin acceso a logs de la app

**Síntoma**: No se podían ver los logs de la app. Xcode GUI no mostraba logs de forma accesible, y el acceso por línea de comandos era problemático.

**Causa raíz**: Las llamadas `NSLog()` solo son visibles en la consola de Xcode, que es difícil de usar si no se tiene experiencia con el IDE.

**Solución**: Se implementó un **Debug Console in-app** accesible con un botón 🐞:

### Archivos creados/modificados:
- **`MCP/DebugLogger.swift`** — Singleton thread-safe con:
  - `AppLog("Tag", "message")` — función global de conveniencia
  - `DebugConsoleView` — vista SwiftUI con scroll, copy, clear
  - `logStartupDiagnostics()` — log de configuración al arrancar
  - Máximo 500 entradas con rotación automática
  - Thread-safe: `DispatchQueue` + `@MainActor` para UI

- **Vistas modificadas**:
  - `StreamView.swift` — botón 🐞 (ladybug) arriba a la izquierda
  - `NonStreamView.swift` — opción "Debug Console" en menú ⚙️
  - `HomeScreenView.swift` — botón 🐞 junto al ⚙️

- **Logging añadido** (reemplazando `NSLog` con `AppLog`):
  - `GeminiLiveService.swift` — WebSocket open/close/error, setup, tool calls
  - `GeminiSessionViewModel.swift` — MCP connection, tool declarations
  - `MCPBridge.swift` — HTTP requests, tool call timing
  - `MCPToolCallRouter.swift` — tool call routing, circuit breaker

**Lección**: Para apps iOS donde Xcode no es práctico, un debug console in-app es esencial. Colocar el logger en una carpeta con `fileSystemSynchronizedRootGroup` (como `MCP/`) lo añade automáticamente al proyecto sin editar `project.pbxproj`.

---

## Problema 3: Gemini WebSocket — "Socket is not connected"

**Síntoma**: Al pulsar "AI", la conexión fallaba con el error "Socket is not connected". El alert mostraba "Connection lost" o "Failed to connect to Gemini".

**Logs iniciales** (sin debug console):
```
nw_flow_add_write_request [C7 216.58.205.106:443 failed parent-flow ...] cannot accept write requests
nw_write_request_report [C7] Send failed with error "Socket is not connected"
```

**Diagnóstico inicial erróneo**: Se pensó que era un problema de QUIC/HTTP3 en red celular, porque los logs del sistema mostraban `quic_conn_process_inbound [...] unable to parse packet` y `sec_framer_open_aesgcm failed`. Se probó `config.assumesHTTP3Capable = false` pero el usuario indicó que no tenía sentido porque antes funcionaba.

**Diagnóstico correcto** (tras añadir logging detallado):
```
[Gemini] WebSocket closed: code=1007, reason=Invalid JSON payload received.
Unknown name "additionalProperties" at 'setup.tools[0].function_declarations[0].parameters':
```

**Causa raíz**: El MCP server devuelve schemas JSON estándar para las herramientas que incluyen `"additionalProperties": false`. La API de Gemini Live (BidiGenerateContent) **no soporta** ese campo en `function_declarations`. El WebSocket se abría correctamente, pero al enviar el `setup` message con los schemas inválidos, Gemini cerraba la conexión con código 1007.

**Solución**: En `MCPModels.swift`, función `toGeminiFunctionDeclaration()`:

```swift
// Recursively strip JSON Schema keys that Gemini does not support
private static let unsupportedKeys: Set<String> = [
    "additionalProperties", "$schema", "$id", "$ref",
    "definitions", "$defs", "default", "examples",
    "patternProperties", "if", "then", "else",
    "allOf", "anyOf", "oneOf", "not", "title"
]

private static func stripUnsupportedKeys(_ schema: [String: Any]) -> [String: Any] {
    var cleaned = [String: Any]()
    for (key, value) in schema {
        if unsupportedKeys.contains(key) { continue }
        if let dict = value as? [String: Any] {
            cleaned[key] = stripUnsupportedKeys(dict)
        } else if let array = value as? [[String: Any]] {
            cleaned[key] = array.map { stripUnsupportedKeys($0) }
        } else {
            cleaned[key] = value
        }
    }
    return cleaned
}
```

**Lección clave**: Gemini Live API solo soporta un subconjunto de JSON Schema en `function_declarations`. Cualquier herramienta MCP debe tener su schema limpiado antes de enviarse a Gemini. Los campos no soportados causan que Gemini cierre el WebSocket con código 1007 sin establecer la sesión.

---

## Mejora adicional: Auto-retry en WebSocket

**Cambio**: Se añadió lógica de reintentos en `GeminiLiveService.swift`:

- **URLSession fresca por intento** — evita reutilizar pool de conexiones corrupto
- **Hasta 3 intentos** (1 + 2 retries) con 1 segundo de delay
- **Limpieza de delegate callbacks** antes de invalidar session (evita race conditions)
- **`onDisconnected` solo se dispara si `connectionState == .ready`** — evita que un retry fallido mate toda la sesión

```swift
func connect() async -> Bool {
    for attempt in 0...maxRetries {
        if attempt > 0 {
            AppLog("Gemini", "Retry \(attempt)/\(maxRetries) after 1s delay...")
            try? await Task.sleep(nanoseconds: 1_000_000_000)
        }
        let success = await attemptConnect(url: url)
        if success { return true }
    }
    return false
}
```

---

## Verificación de API

Se verificó desde la línea de comandos que la API key y el modelo funcionan:

```bash
# Verificar que la API key funciona
curl -s "https://generativelanguage.googleapis.com/v1beta/models?key=API_KEY"

# Verificar modelos con BidiGenerateContent
python3 -c "..." # Filtrar por 'bidiGenerateContent' en supportedGenerationMethods

# Test de WebSocket directo
python3 -c "
import asyncio, websockets, json
async def test():
    url = 'wss://generativelanguage.googleapis.com/ws/...?key=API_KEY'
    async with websockets.connect(url) as ws:
        await ws.send(json.dumps({'setup': {'model': 'models/gemini-2.5-flash-native-audio-preview-12-2025', ...}}))
        resp = await ws.recv()
        print(json.loads(resp))  # {'setupComplete': ...}
asyncio.run(test())
"
# Resultado: SUCCESS: ['setupComplete']
```

**Modelos disponibles con BidiGenerateContent** (marzo 2026):
- `models/gemini-2.5-flash-native-audio-latest`
- `models/gemini-2.5-flash-native-audio-preview-09-2025`
- `models/gemini-2.5-flash-native-audio-preview-12-2025` ← actualmente usado
- `models/gemini-3.1-flash-live-preview`

---

## Archivos modificados (resumen)

| Archivo | Cambio |
|---------|--------|
| `MCP/DebugLogger.swift` | **Nuevo** — Logger in-app + UI |
| `MCP/MCPModels.swift` | Strip `additionalProperties` y otros campos no soportados por Gemini |
| `Gemini/GeminiLiveService.swift` | Auto-retry, URLSession fresca, logging detallado en WebSocket |
| `Gemini/GeminiSessionViewModel.swift` | `NSLog` → `AppLog` |
| `MCP/MCPBridge.swift` | `NSLog` → `AppLog` |
| `MCP/MCPToolCallRouter.swift` | `NSLog` → `AppLog` |
| `Views/StreamView.swift` | Botón 🐞 debug console |
| `Views/NonStreamView.swift` | Opción debug console en menú |
| `Views/HomeScreenView.swift` | Botón 🐞 debug console |
| `CameraAccessApp.swift` | Startup diagnostics |

---

## Estado final

| Componente | Estado |
|-----------|--------|
| App rename + bundle ID | ✅ Funcionando |
| Settings UI (MCP/WebRTC) | ✅ Funcionando |
| MCP Server connection | ✅ Conecta, 3 tools |
| WebRTC streaming | ✅ Funcionando |
| Gemini Live WebSocket | ✅ Conecta, setupComplete |
| Tool calling (MCP via Gemini) | ✅ Verificado: send_message (152ms), add_reminder (154ms) |
| Debug Console in-app | ✅ Funcionando |
