# Claude Panel

Widget flotante para macOS que muestra los MCP de Claude Code, el consumo de tokens y la adopción de esta Mac.

## Requisitos

- macOS 14 o posterior
- [Xcode Command Line Tools](https://developer.apple.com/xcode/resources/), para tener `swiftc` y `codesign`
- Claude Code instalado en esta Mac

Comprueba las herramientas con:

```bash
xcode-select -p
swiftc --version
```

Si `swiftc` no existe:

```bash
xcode-select --install
```

## Instalación

```bash
git clone https://github.com/devrabit/claude-panel.git
cd claude-panel
./build.sh
open "Claude Panel.app"
```

`build.sh` compila la app, la firma en local y deja `Claude Panel.app` en esta carpeta. La app no aparece en el Dock: queda el icono flotante y un acceso en la barra de menú.

Para tenerla con el resto de las aplicaciones:

```bash
mv "Claude Panel.app" /Applications/
open -a "Claude Panel"
```

Si macOS bloquea la apertura por la firma local, ábrela desde el Finder con clic derecho y **Abrir**, o permite la app en **Ajustes del Sistema → Privacidad y seguridad**.

## Uso

- Clic en el icono: abre o cierra el panel.
- Arrastrar el icono: lo mueve. La posición se guarda.
- Clic derecho: actualizar o salir.
- La lista de MCP se actualiza sola cada 3 minutos. Tokens y adopción se leen de las sesiones locales en `~/.claude/projects`.

## Volver a compilar

Después de cambiar el código:

```bash
./build.sh
open "Claude Panel.app"
```
