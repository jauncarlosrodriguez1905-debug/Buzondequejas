-- ============================================================================
-- Buzón de denuncias · JBI Interiors — Backend en Supabase
-- ============================================================================
-- CÓMO APLICARLO (un solo paso manual):
--   1. Entra a Supabase > tu proyecto > SQL Editor > New query.
--   2. Pega TODO este archivo y dale Run.
--   3. Crea las cuentas del personal en Authentication > Users (correo y
--      contraseña) y luego inserta una fila por persona en public.staff
--      con su user_id y su rol ('DO', 'RH' o 'JAVID').
--
-- DISEÑO DE PRIVACIDAD (esto es lo que lo hace seguro, no el HTML):
--   * El buzón es TOTALMENTE ANÓNIMO: no existe ninguna columna para
--     guardar quién denuncia. El formulario nunca envía nombre, correo
--     ni teléfono, y la función enviar_reporte tampoco los recibe.
--   * El contenido de la denuncia vive SOLO en casos_detalle. Esa tabla
--     solo la puede leer quien atiende el caso: si el destino es RH/DO,
--     solo personal con rol DO o RH; si es JAVID, solo rol JAVID.
--     Además, si alguien se excusa de un caso (caso_exclusion), deja de
--     verlo para siempre.
--   * La tabla casos solo trae metadatos (folio, etapa, fechas, SLA):
--     cualquier persona activa de DO/RH/JAVID ve el listado, pero sin
--     el contenido solo ve folio y estatus, como ya hace el tracker.
--   * Nadie puede insertar ni borrar casos directamente: solo la función
--     enviar_reporte (que usa el buzón) escribe. Sin política de INSERT,
--     el INSERT directo está denegado.
-- ============================================================================

-- --------------------------------------------------------------------------
-- Tablas
-- --------------------------------------------------------------------------

create table if not exists public.staff (
  user_id uuid primary key references auth.users (id) on delete cascade,
  nombre text not null,
  rol text not null check (rol in ('DO', 'RH', 'JAVID')),
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

-- Por si la tabla staff ya existía de un intento anterior sin la columna
-- activo (o sin alguna otra): se agregan las que falten, sin borrar nada.
alter table public.staff add column if not exists nombre text not null default '';
alter table public.staff add column if not exists rol text not null default 'DO';
alter table public.staff add column if not exists activo boolean not null default true;
alter table public.staff add column if not exists created_at timestamptz not null default now();

create table if not exists public.casos (
  id uuid primary key default gen_random_uuid(),
  folio text not null unique,
  destino text not null check (destino in ('RH/DO', 'JAVID')),
  fecha_recepcion date not null default current_date,
  nivel_gravedad text check (nivel_gravedad in ('Baja', 'Media', 'Alta')),
  etapa_actual text not null default 'Recepción'
    check (etapa_actual in ('Recepción', 'Análisis', 'Investigación', 'Resolución', 'Cerrado')),
  fecha_cierre_meta date not null,
  medida_aplicada boolean not null default false,
  cerrado_en date
);

create table if not exists public.casos_detalle (
  caso_id uuid primary key references public.casos (id) on delete cascade,
  tipo_reporte text not null default 'Anónimo',
  persona_senalada text,
  fecha_suceso timestamptz,
  lugar text,
  hechos text not null,
  testigos text[] not null default '{}',
  motivo_javid text,
  justificacion_javid text,
  medida_descripcion text not null default '',
  notas_investigacion text not null default ''
);

create table if not exists public.caso_exclusion (
  caso_id uuid not null references public.casos (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (caso_id, user_id)
);

create sequence if not exists public.folio_seq;

-- --------------------------------------------------------------------------
-- Funciones de ayuda (las políticas RLS las usan)
-- --------------------------------------------------------------------------

-- ¿La persona logueada es personal activo de DO, RH o JAVID?
create or replace function public.es_personal_activo()
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1 from public.staff s
    where s.user_id = auth.uid() and s.activo
  );
$$;

-- ¿La persona logueada es quien atiende este caso?
-- RH/DO -> roles DO o RH. JAVID -> solo rol JAVID.
-- Si se excusó del caso, ya no lo ve.
create or replace function public.puede_ver_detalle(p_caso_id uuid)
returns boolean
language sql stable security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.casos c
    join public.staff s on s.user_id = auth.uid()
    where c.id = p_caso_id
      and s.activo
      and ((c.destino = 'RH/DO' and s.rol in ('DO', 'RH'))
        or (c.destino = 'JAVID' and s.rol = 'JAVID'))
      and not exists (
        select 1 from public.caso_exclusion e
        where e.caso_id = c.id and e.user_id = auth.uid()
      )
  );
$$;

-- --------------------------------------------------------------------------
-- Row Level Security
-- --------------------------------------------------------------------------

alter table public.staff enable row level security;
alter table public.casos enable row level security;
alter table public.casos_detalle enable row level security;
alter table public.caso_exclusion enable row level security;

drop policy if exists "staff ve su propia fila" on public.staff;
create policy "staff ve su propia fila"
  on public.staff for select
  using (user_id = auth.uid());

-- El listado de casos (folio, etapa, fechas, SLA) lo ve el personal activo.
-- El contenido NO está aquí, está en casos_detalle.
drop policy if exists "personal activo ve casos" on public.casos;
create policy "personal activo ve casos"
  on public.casos for select
  using (public.es_personal_activo());

drop policy if exists "solo el involucrado actualiza casos" on public.casos;
create policy "solo el involucrado actualiza casos"
  on public.casos for update
  using (public.puede_ver_detalle(id))
  with check (public.puede_ver_detalle(id));

-- El contenido de la denuncia: SOLO quien atiende el caso.
drop policy if exists "solo el involucrado ve el detalle" on public.casos_detalle;
create policy "solo el involucrado ve el detalle"
  on public.casos_detalle for select
  using (public.puede_ver_detalle(caso_id));

drop policy if exists "solo el involucrado actualiza el detalle" on public.casos_detalle;
create policy "solo el involucrado actualiza el detalle"
  on public.casos_detalle for update
  using (public.puede_ver_detalle(caso_id))
  with check (public.puede_ver_detalle(caso_id));

-- Excusas: cada quien ve y registra solo las suyas.
drop policy if exists "exclusiones propias" on public.caso_exclusion;
create policy "exclusiones propias"
  on public.caso_exclusion for select
  using (user_id = auth.uid());

drop policy if exists "registrar excusa propia" on public.caso_exclusion;
create policy "registrar excusa propia"
  on public.caso_exclusion for insert
  with check (user_id = auth.uid() and public.es_personal_activo());

-- Permisos de rol (RLS no sirve sin ellos).
grant select on public.staff to authenticated;
grant select, update on public.casos to authenticated;
grant select, update on public.casos_detalle to authenticated;
grant select, insert on public.caso_exclusion to authenticated;

-- --------------------------------------------------------------------------
-- RPC: enviar_reporte — lo usa el buzón (index.html)
-- Recibe SOLO los datos del reporte. No recibe ni guarda identidad.
-- Genera el folio DEN-AAAA-NNN y pone cierre meta a 10 días.
-- --------------------------------------------------------------------------

create or replace function public.enviar_reporte(p jsonb)
returns text
language plpgsql security definer
set search_path = public
as $$
declare
  v_destino text := nullif(btrim(p ->> 'destino'), '');
  v_hechos text := nullif(btrim(p ->> 'hechos'), '');
  v_motivo text := nullif(btrim(p ->> 'motivo'), '');
  v_just text := nullif(btrim(p ->> 'justificacion'), '');
  v_folio text;
  v_caso_id uuid;
  v_testigos text[] := '{}';
  v_fecha timestamptz;
  t text;
begin
  if v_destino is null or v_destino not in ('RH/DO', 'JAVID') then
    raise exception 'destino inválido';
  end if;
  if v_hechos is null or char_length(v_hechos) < 20 then
    raise exception 'la descripción debe tener al menos 20 caracteres';
  end if;
  if v_destino = 'JAVID' then
    if v_motivo is null or v_just is null or char_length(v_just) < 20 then
      raise exception 'el canal externo requiere motivo y justificación';
    end if;
  end if;

  foreach t in array array[p ->> 'testigo1', p ->> 'testigo2', p ->> 'testigo3'] loop
    if nullif(btrim(coalesce(t, '')), '') is not null then
      v_testigos := array_append(v_testigos, btrim(t));
    end if;
  end loop;

  if nullif(btrim(p ->> 'fecha'), '') is not null then
    v_fecha := (p ->> 'fecha')::timestamptz;
  end if;

  v_folio := 'DEN-' || extract(year from current_date)::text
    || '-' || lpad(nextval('public.folio_seq')::text, 3, '0');

  insert into public.casos (folio, destino, fecha_cierre_meta)
  values (v_folio, v_destino, current_date + interval '10 days')
  returning id into v_caso_id;

  insert into public.casos_detalle
    (caso_id, tipo_reporte, persona_senalada, fecha_suceso, lugar, hechos,
     testigos, motivo_javid, justificacion_javid)
  values
    (v_caso_id, 'Anónimo',
     nullif(btrim(p ->> 'senalada'), ''),
     v_fecha,
     nullif(btrim(p ->> 'lugar'), ''),
     v_hechos,
     v_testigos,
     case when v_destino = 'JAVID' then v_motivo end,
     case when v_destino = 'JAVID' then v_just end);

  return v_folio;
end;
$$;

grant execute on function public.enviar_reporte(jsonb) to anon, authenticated;

-- --------------------------------------------------------------------------
-- RPC: excluir_de_caso — lo usa el tracker ("Excusarme del caso")
-- --------------------------------------------------------------------------

create or replace function public.excluir_de_caso(p_folio text)
returns void
language plpgsql security definer
set search_path = public
as $$
declare
  v_caso_id uuid;
begin
  if auth.uid() is null then
    raise exception 'no autenticado';
  end if;
  select id into v_caso_id
  from public.casos
  where folio = btrim(p_folio);
  if v_caso_id is null then
    raise exception 'folio no encontrado';
  end if;
  insert into public.caso_exclusion (caso_id, user_id)
  values (v_caso_id, auth.uid())
  on conflict do nothing;
end;
$$;

grant execute on function public.excluir_de_caso(text) to authenticated;

-- --------------------------------------------------------------------------
-- Personal delegado — dar de alta DESPUÉS de crear sus cuentas
-- en Authentication > Users (correo y contraseña).
-- Por cada uno, copia su UUID de Authentication > Users y corre su insert.
-- --------------------------------------------------------------------------
-- JAVID: Ruby Arriola <rarriola@javidmexico.com> — rol 'JAVID'
--   insert into public.staff (user_id, nombre, rol)
--   values ('<UUID de Ruby>', 'Ruby Arriola', 'JAVID');
-- DO (Desarrollo Organizacional): Alejandro Castro <AlejandroCastro@JBI-Interiors.com> — rol 'DO'
--   insert into public.staff (user_id, nombre, rol)
--   values ('<UUID de Alejandro>', 'Alejandro Castro', 'DO');
-- RH: Berenice Higuera <berenice.higuera@javidmexico.com> — rol 'RH'
--   insert into public.staff (user_id, nombre, rol)
--   values ('<UUID de Berenice>', 'Berenice Higuera', 'RH');
--
-- Con eso cada uno entra al tracker con su correo y contraseña, y solo ve
-- el contenido de los casos de su destino: Ruby solo JAVID; Alejandro y
-- Berenice solo RH/DO.
