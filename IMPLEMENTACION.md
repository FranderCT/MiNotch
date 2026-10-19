# Terminal, actividad de agentes e integración de proyectos

Primera implementación a partir del informe local de Warp del 19 de octubre de 2026.
El código es propio; el informe se utilizó como referencia de organización.

## Comandos y terminal

La terminal visible recibe señales de `preexec` y `precmd` de zsh mediante un OSC
específico de MiNotch y un identificador por sesión. El parser de SwiftTerm ensambla
los fragmentos del PTY. Una pausa de salida no se interpreta como finalización.
La interfaz y las herramientas del asistente distinguen ejecución, prompt listo,
entrada pendiente y estado desconocido, e informan el código del último comando.

Los archivos de inicio se cargan mediante un ZDOTDIR temporal; se conservan los
archivos del usuario y se restaura su ZDOTDIR antes del primer prompt. No se editan
archivos del shell. Las sesiones auxiliares siguen informando si su proceso está
vivo cuando devuelven una lectura parcial.

El estado describe el shell local: SSH, REPLs, shells hijos y aplicaciones a pantalla
completa siguen siendo un comando en ejecución hasta regresar al prompt local.
Si la configuración desactiva los archivos de inicio o elimina los hooks, no se
puede confirmar el fin del comando por esta vía. Un trabajo lanzado con `&` puede
seguir vivo cuando el shell ya vuelve al prompt.

Referencia: [hooks de zsh](https://zsh.sourceforge.io/Doc/Release/Functions.html).

## Agentes externos

Claude y Cursor usan `stream-json`; Codex y OpenCode conservan sus formatos de
eventos. La salida se decodifica por líneas completas, incluyendo UTF-8 cortado
entre lecturas. Se muestran hasta 40 eventos recientes por trabajo, con actividad,
herramientas, errores y un botón para detenerlo. El asistente también recibe los
eventos recientes al consultar el trabajo.

Se conservan la sesión, el resultado y el costo entre los eventos. Se espera EOF
en stdout y stderr antes de finalizar, y un identificador por corrida impide que
un callback viejo sobrescriba una continuación. Los buffers están limitados.
Grok conserva su respuesta JSON final; su interfaz indica que no entrega progreso
incremental en esta integración. No se muestran bloques de razonamiento.

Los argumentos se verificaron con la ayuda de los CLIs instalados. Las pruebas
de ejecución usan procesos locales simulados, sin llamadas facturadas a agentes.

## Finder y enlaces

El bundle declara el servicio **Abrir carpeta en MiNotch** y el esquema:

```
minotch://open?path=/ruta/absoluta
```

El menú de carpeta permite copiar el enlace con la ruta codificada. Solo se aceptan
carpetas existentes; los enlaces no admiten comandos ni prompts. Se reutiliza una
pestaña de esa carpeta si existe y se comprueba el límite antes de abrir varias.
El servicio requiere que macOS registre la nueva versión del bundle; puede ser
necesario habilitarlo en los ajustes de Servicios de macOS.

Referencia: [propiedades de servicios de macOS](https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/properties.html).

## Preferencias y diagnóstico

Configuración se divide en Cuenta, Apariencia, Terminal, Agentes, Atajos y Privacidad.
El tamaño de fuente de la terminal se aplica a las vistas abiertas.

El diagnóstico está desactivado por defecto. Conserva hasta 200 eventos en memoria
y permite copiarlos o borrarlos. Incluye duración y resultado de agentes, códigos
de salida del shell y tiempo hasta el siguiente turno de la cola principal al abrir
el notch. Esta última métrica no es el tiempo total de animación ni una medición de
renderizado. No mide CPU/RAM ni sustituye Instruments. No registra contenido,
comandos, rutas o credenciales, ni envía telemetría.

## Verificación

```sh
zsh Tests/run-runtime-tests.sh
zsh Tests/run-billing-tests.sh
swift build
zsh build-app.sh
```

Las pruebas cubren archivos de inicio y códigos reales de zsh, estado del comando,
fragmentación y límites de eventos, formatos de agentes, entrega de progreso antes
del final, continuación después de detener un trabajo, enlaces y facturación.

La app compilada queda en `MiNotch.app`. Reiniciar una instancia anterior carga los
cambios; las conversaciones actuales viven en memoria y deben terminarse antes.
