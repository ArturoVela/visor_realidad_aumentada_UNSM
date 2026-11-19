# Nexus AR

## Interfaz de este proyecto

- Lee `.agents/skills/apple-design/SKILL.md` antes de diseñar, revisar o modificar la interfaz de Nexus AR. Esta copia de `apple-design` pertenece a este repositorio.
- Adapta la guía a SwiftUI, UIKit y RealityKit. Prioriza manipulación directa, respuesta inmediata, transiciones breves que se puedan interrumpir y capas de controles que dejen visible la escena.
- Conserva la tipografía del sistema, los colores semánticos de iOS y el acento azul de Nexus AR. Usa texto e iconos para comunicar estados. Respeta Dynamic Type, Reducir movimiento, Reducir transparencia y Aumentar contraste.
- Al cambiar el visor, revisa la orientación vertical y horizontal en el simulador. Los controles de RA se superponen a la cámara y mantienen su encuadre. Verifica el seguimiento espacial con un iPhone compatible cuando el cambio lo requiera.

Ejecuta este comando desde la raíz del repositorio para reinstalar la habilidad.

```sh
npx skills add https://github.com/emilkowalski/skills --skill apple-design --agent codex --copy
```
