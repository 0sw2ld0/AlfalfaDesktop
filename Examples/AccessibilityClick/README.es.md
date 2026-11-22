# Reproducir un clic sin grabación de pantalla

El ejemplo compila una app temporal de macOS, pulsa su único botón con AlfalfaDesktop y verifica el cambio
por el árbol de Accesibilidad. El guion se limita al PID que acaba de abrir.

## Ejecutar la prueba

Necesitas macOS 14 o posterior, Node.js 20 o posterior, las herramientas de línea de comandos de Xcode y
AlfalfaDesktop 0.1.1 o posterior. Desde la raíz del repositorio, pide a AlfalfaCode o a un agente de VS Code
que ejecute este comando. También puedes ejecutarlo desde una terminal.

```sh
ALFALFA_DESKTOP="$HOME/.local/bin/alfalfa-desktop" node Examples/AccessibilityClick/test-click.mjs
```

Ajusta la ruta al binario que tienes instalado. Si falta Accesibilidad, consulta
`"$ALFALFA_DESKTOP" permissions` desde el mismo entorno que va a ejecutar el guion. La prueba solo necesita
Accesibilidad. Si el agente pide permiso para ejecutar el comando, aprueba esa ejecución puntual.

El guion verifica «Pendiente», pulsa «Verificar control» una sola vez mediante `AXPress` en segundo plano y
reinspecciona la ventana para comprobar «Control confirmado». Cierra la app temporal al terminar.

## Resultados registrados

Ambos agentes usaron AlfalfaDesktop 0.1.1. Confirmaron el clic con `accessibility: true` y
`screenRecording: false`. El guion nunca solicitó una captura.

- [JSON de AlfalfaCode](results/alfalfacode-desktop.json)
- [JSON de VS Code](results/vscode-desktop.json)
