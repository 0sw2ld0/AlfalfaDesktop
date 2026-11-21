# AlfalfaDesktop

[English](README.md)

AlfalfaDesktop es el controlador nativo de macOS extraído de AlfalfaCode y empaquetado en Swift. Enumera apps
abiertas, lee sus árboles de accesibilidad y ejecuta acciones con aprobación explícita. El cursor virtual dirige
las acciones en segundo plano a la aplicación elegida.

## Descargas

Requiere macOS 14 o posterior. Descarga el ejecutable correspondiente y comprueba su suma SHA-256 antes de abrirlo.

| Mac | Descarga |
| --- | --- |
| Apple Silicon | [alfalfa-desktop-macos-arm64](https://github.com/0sw2ld0/AlfalfaDesktop/releases/latest/download/alfalfa-desktop-macos-arm64) |
| Intel | [alfalfa-desktop-macos-x64](https://github.com/0sw2ld0/AlfalfaDesktop/releases/latest/download/alfalfa-desktop-macos-x64) |

[SHA256SUMS](https://github.com/0sw2ld0/AlfalfaDesktop/releases/latest/download/SHA256SUMS)

Por ejemplo, después de descargar el binario para Apple Silicon y el manifiesto de la misma versión:

```sh
grep '  alfalfa-desktop-macos-arm64$' SHA256SUMS | shasum -a 256 -c
chmod +x alfalfa-desktop-macos-arm64
./alfalfa-desktop-macos-arm64 --version
```

## Compilar y usar la CLI

Compila con Swift 5.10 o posterior.

```sh
swift build
swift test

desktop=.build/debug/alfalfa-desktop
"$desktop" --version
"$desktop" list
"$desktop" permissions
"$desktop" inspect --pid=12345 --window=0 --approve
"$desktop" action --pid=12345 --window=0 --kind=click --path=1 --role=AXButton --approve
```

Usa el PID de `list` y la ruta y el rol del elemento que devuelve `inspect`. El índice de ventana predeterminado
es `0`. Con `inspect --capture --approve` puedes obtener la ruta de una imagen cuando macOS permite capturar la
ventana. Las imágenes se guardan en un directorio temporal privado y puedes retirarlas cuando termines.

El comando `permissions --request --approve` pide los permisos del sistema. macOS concede por separado
Accesibilidad y Grabación de pantalla a la aplicación responsable. Una app firmada ofrece una identidad estable
para esos permisos. El parámetro `--approve` autoriza una sola invocación dentro de la CLI.

La CLI admite clics, desplazamientos, arrastres, movimiento del cursor, texto, teclas, cambios de valores de
accesibilidad, selección de menús y cambios explícitos de foco. La CLI y PACAI aplican las mismas restricciones por
app y vuelven a comprobar la ventana después de la aprobación.

Para compilar un ejecutable optimizado desde un clon local de AlfalfaDesktop, ejecuta lo siguiente en
la raíz del repositorio. SwiftPM compila para el Mac que estás usando.

```sh
swift build -c release
desktop="$(swift build -c release --show-bin-path)/alfalfa-desktop"
printf '%s\n' "$desktop"
"$desktop" --version
```

Dale la ruta absoluta resultante al agente de VS Code para que use esa compilación.

## Usar la CLI desde un agente de VS Code

1. Descarga y verifica el ejecutable para tu Mac. En la terminal de VS Code, indica su ruta completa y
   ejecuta estos comandos desde un espacio de trabajo local en macOS:

   ```sh
   desktop="$HOME/Downloads/alfalfa-desktop-macos-arm64" # Usa alfalfa-desktop-macos-x64 en Intel.
   chmod +x "$desktop"
   "$desktop" --version
   "$desktop" permissions
   "$desktop" list
   ```

2. Abre un documento vacío nuevo en TextEdit y deja VS Code en primer plano. Si falta Accesibilidad,
   ejecuta tú `"$desktop" permissions --request --approve` y concede el permiso a la app responsable que
   indica macOS. Grabación de pantalla se necesita para obtener imágenes con `inspect --capture`.

3. Abre un chat de agente local con acceso a la terminal y dale este encargo. Sustituye la ruta por la que
   verificaste. Revisa cada comando cuando VS Code te pida aprobarlo.

   > Usa `/ruta/absoluta/alfalfa-desktop-macos-arm64` para comprobar mi documento vacío de TextEdit.
   > Ejecuta `list` para localizar el PID de TextEdit. Pregúntame antes de ejecutar
   > `inspect --pid=PID --window=0 --approve` y dime
   > el título. Si encuentras el documento de prueba vacío, elige un punto dentro del área de edición a
   > partir del árbol de accesibilidad. Pregúntame antes de ejecutar
   > `action --pid=PID --window=0 --kind=click --x=X --y=Y --approve`. Deja VS Code en primer plano y
   > termina después del clic.

VS Code también puede cargar el [skill `alfalfadesktop-cli` del proyecto](.github/skills/alfalfadesktop-cli/SKILL.md).
En un chat local de Copilot, escribe `/alfalfadesktop-cli` seguido de la app y lo que quieres comprobar.

El agente local invoca el ejecutable mediante su herramienta de terminal. Usa `--approve` para la inspección o
acción concreta que revisaste. Consulta las [herramientas para agentes de VS Code](https://code.visualstudio.com/docs/agents/run/tools).

## PACAI sobre stdio

Ejecuta `alfalfa-desktop pacai` para intercambiar mensajes PACAI 0.3 en formato JSONL. El cliente comienza enviando
`hello`. Cada `input` lleva un bloque estructurado con este formato:

```json
{
  "type": "structured",
  "schema": "urn:alfalfadesktop:command:v1",
  "data": {
    "command": "inspect",
    "options": { "pid": "12345", "window": "0", "capture": "true" }
  }
}
```

Los comandos admitidos son `list`, `inspect`, `action` y `permissions`. Las opciones se nombran como en la CLI,
sin los guiones iniciales. Una operación que requiere permiso emite `approval_request` con el digest de sus
argumentos. El cliente responde mediante `approval_result.reply_to` y puede aprobar con alcance `once`.

Una interrupción válida cancela la aprobación pendiente y cierra la ejecución. Las operaciones nativas también
son síncronas una vez aprobadas. El resultado llega en un bloque estructurado de `tool_end`, seguido de
`run_finished`. Al desconectar, se descartan las aprobaciones pendientes. El adaptador actual ofrece transporte
local por stdio. El adaptador MCP, el transporte en red y la reanudación de sesiones quedan fuera de esta versión.

## Prueba con una app real

`Tests/Fixtures/DesktopFixture.swift` abre un contador AppKit y registra qué app conserva el foco. El script
`Scripts/test-desktop.mjs` inspecciona esa ventana, hace un clic por CLI y otro por PACAI, y comprueba que denegar o
interrumpir una aprobación deja el contador intacto.

```sh
fixture_dir=$(mktemp -d)
swiftc Tests/Fixtures/DesktopFixture.swift -o "$fixture_dir/AlfalfaDesktopFixture"
touch "$fixture_dir/focus.jsonl"
"$fixture_dir/AlfalfaDesktopFixture" "$fixture_dir/focus.jsonl" &
fixture_pid=$!
# Espera a que aparezca la ventana y continúa con otra app en primer plano.
node Scripts/test-desktop.mjs "$PWD/.build/debug/alfalfa-desktop" "$fixture_pid" "$fixture_dir/focus.jsonl"
kill "$fixture_pid"
```

Usa `--capture` para comprobar que la imagen cambia al incrementar el contador. Usa `--list-only` para verificar
el descubrimiento de apps, la negociación PACAI, la denegación y la cancelación sin emitir clics ni teclas.

## Referencias

- [AlfalfaCode](https://github.com/0sw2ld0/AlfalfaCode)
- [PACAI](https://github.com/0sw2ld0/PACAI)
- [CuyBrowser](https://github.com/0sw2ld0/cuybrowser)
