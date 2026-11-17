# EMISOFT · Fidelización Digital

Sistema de tarjetas de fidelización con códigos QR para varios negocios.
Versión actual: **1.3.2**

## Estructura

| Carpeta | Contenido | Dónde se usa |
|---|---|---|
| `web/` | Panel web (`index.html`, `app.js`) y tarjeta del cliente (`tarjeta.html`) | Netlify publica esta carpeta |
| `supabase/migraciones/` | Cambios de base de datos, numerados en el orden en que se ejecutaron | Supabase › SQL Editor |
| `supabase/functions/emisoft-admin/` | Edge Function para crear usuarios y restablecer contraseñas | Supabase › Edge Functions |
| `netlify.toml` | Le indica a Netlify que publique la carpeta `web` | Netlify |

## Cómo se publica

Cada cambio guardado (commit) en la rama `main` se publica solo en Netlify en 1 o 2 minutos.

Los cambios de **base de datos** y de la **Edge Function** no se publican solos: se aplican a mano en Supabase.

## Seguridad

- `web/config.js` solo contiene la clave **pública** de Supabase (`sb_publishable_…`). Es normal que esté aquí.
- **Nunca** subas a este repositorio la clave `service_role` ni la `sb_secret_…`.
- Se recomienda que el repositorio sea **privado**.

## Historial de versiones

| Versión | Cambios |
|---|---|
| 1.1.1 | Clientes, QR, sellos, canjes, historial |
| 1.2 | Superadministrador: negocios, logos, usuarios, contraseñas, auditoría |
| 1.2.1 | Usuarios visibles al elegir el negocio; mensajes de error claros |
| 1.2.2 | Tarjeta del cliente en su celular; botón +1 sello; envío por WhatsApp |
| 1.2.3 | Los sellos ganados muestran el logo del negocio |
| 1.3.0 | Política por negocio: regla del sello, varios sellos a la vez, premios intermedios |
| 1.3.1 | Rubros, íconos por premio y premios sorpresa |
| 1.3.2 | Aviso en la tarjeta: cuánto falta para el próximo premio |
