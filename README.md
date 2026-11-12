<p align="center"><img src="img/portada.jpg" alt="LiveYou" width="100%"></p>

# LiveYou

Crea, mira y transmite videos cortos y directos en vivo, con chat y comunidad.

**Sitio:** https://juanpabloortizortuno-web.github.io/LiveYou/

## Estructura del repositorio

| Archivo / carpeta | Para qué sirve |
|---|---|
| `index.html` | La aplicación completa, dividida en bloques `CSS-xx`, `HTML-xx` y `JS-xx` |
| `404.html` | Página que se muestra si el enlace no existe |
| `manifest.webmanifest` | Permite instalar LiveYou como app en el celular |
| `favicon.ico`, `icons/` | Ícono de la pestaña, del iPhone y de la app instalada |
| `img/` | Logo, imagen de entrada y vista previa al compartir el enlace |
| `supabase-setup.sql` | Base de datos: se pega en Supabase → SQL Editor → Run |
| `_nojekyll` | Evita que GitHub Pages procese los archivos con Jekyll |

## Cómo editar `index.html`

Cada parte del código abre con `INICIO · CÓDIGO` y cierra con `FIN · CÓDIGO`.
Antes de cambiar algo, busca el código (por ejemplo `JS-16`) y modifica solo dentro de su bloque.
En CSS el orden importa: un bloque posterior puede sobrescribir a uno anterior, así que no los reordenes.

| Bloques | Contenido |
|---|---|
| `CSS-01` … `CSS-14` | Estilos (`CSS-14` es la marca nueva y va siempre al final) |
| `HTML-01` … `HTML-16` | Login, perfil, menú, vistas y ventanas |
| `JS-01` … `JS-20` | Lógica: sesión, videos, directos, chat |

## Publicar

GitHub → Settings → Pages → Branch `main` / carpeta `/ (root)`.
Después de subir cambios, espera un minuto y recarga con Ctrl + F5.

## Autoría

© 2026 **Juan Pablo Ortiz Ortuño** · Santa Cruz, Bolivia.
Todos los derechos reservados. Prohibida la copia o redistribución sin autorización escrita.
