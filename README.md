# Buzón de denuncias · JBI Interiors

Canal confidencial para todo el personal de planta. **Totalmente anónimo:**
no se pide nombre, correo, teléfono ni ningún dato que identifique a quien
denuncia, y la base de datos ni siquiera tiene columnas para guardarlo.

## Archivos

- `index.html` — El buzón. El personal elige a quién va el reporte
  (RH/DO o el canal externo JAVID, con justificación) y describe los hechos.
  Al enviar recibe un folio (DEN-AAAA-NNN) para dar seguimiento sin
  identificarse.
- `tracker.html` — El seguimiento de casos. **Solo lo usan DO, RH y JAVID**,
  con correo y contraseña. Muestra KPIs, estatus SLA (vencido / en tiempo /
  cerrado), etapas, medidas y permite excusarse de un caso por conflicto
  de interés.
- `supabase/schema.sql` — El backend: tablas, seguridad (RLS) y funciones.

## Quién ve qué

- **Quien denuncia:** solo su folio. No ve casos ni listas.
- **Personal de DO/RH/JAVID:** ve el listado de folios y estatus, pero el
  contenido de una denuncia **solo lo ve quien atiende ese caso**:
  destino RH/DO → solo DO o RH; destino JAVID → solo JAVID.
  Si alguien se excusa de un caso, deja de verlo.
- Nadie puede insertar ni borrar casos a mano: solo el buzón escribe,
  a través de la función `enviar_reporte`.

## Puesta en marcha

1. En Supabase > SQL Editor, corre todo `supabase/schema.sql`.
2. En Authentication > Users crea las cuentas de DO, RH y JAVID.
3. En Table Editor > `staff`, agrega una fila por persona con su `user_id`
   (el UUID de su cuenta) y su `rol` (`DO`, `RH` o `JAVID`).
4. Publica los dos HTML (por ejemplo con GitHub Pages: Settings > Pages >
   Deploy from a branch > `main`). El buzón es `index.html` y el tracker
   es `tracker.html`.

## Notas

- El cierre meta de cada caso es de 10 días a partir de la recepción.
- Los datos de ejemplo que trae el tracker solo aparecen en modo
  demostración (cuando no hay conexión a Supabase).
