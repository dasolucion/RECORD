-- ============================================================
-- RECORD — REPARAR MULTIEMPRESA Y BORRAR EMPRESA 407 INCORRECTA
-- Ejecutar COMPLETO en Supabase → SQL Editor → proyecto RECORD
-- (kvlkmpvnyvudlgbqoyer). Es idempotente: se puede repetir.
-- ============================================================
-- Hace todo en un solo paso:
--   1) Permite que la clave pública (anon) lea y escriba public.empresas.
--   2) Asegura las columnas empresa_id.
--   3) Crea/actualiza la empresa inicial desde parametros_config (id = 1).
--   4) Vincula la configuración y rellena empresa_id en los datos existentes.
--   5) Borra la empresa 407 creada por error (si no tiene datos asociados).
--   6) Recarga la caché de PostgREST y muestra el resultado.

-- ------------------------------------------------------------
-- 0) Diagnóstico previo
-- ------------------------------------------------------------
select id, nombre, rif, activo, created_at
from public.empresas
order by id;

-- ------------------------------------------------------------
-- 1) Permisos para la clave pública usada por la app
-- ------------------------------------------------------------
alter table if exists public.empresas disable row level security;
grant select, insert, update, delete on public.empresas to anon, authenticated;

-- ------------------------------------------------------------
-- 2) Columnas empresa_id
-- ------------------------------------------------------------
alter table if exists public.parametros_config
  add column if not exists empresa_id bigint references public.empresas(id);

do $$
declare t text;
begin
  foreach t in array array[
    'departamentos','cargos','empleados','nominas','historico_salarios','vacaciones',
    'utilidades','prestaciones','antiguedad','anticipos_prestaciones','prestamos_anticipos',
    'prestamos_abonos','asistencia_registros','justificativos_faltas','expediente_documentos',
    'prenomina_borrador','firmas_recibos','tokens_portal_empleado','solicitudes_ari'
  ] loop
    if to_regclass(format('public.%I', t)) is not null then
      execute format(
        'alter table public.%I add column if not exists empresa_id bigint references public.empresas(id)',
        t
      );
    end if;
  end loop;
end $$;

-- ------------------------------------------------------------
-- 3) Empresa inicial desde la configuración real (sin RIF fijo)
-- ------------------------------------------------------------
insert into public.empresas (nombre, rif, activo)
select coalesce(nullif(pc.nombre_empresa, ''), 'EMPRESA'),
       coalesce(nullif(pc.rif_empresa, ''), 'J-00000000-0'),
       true
from public.parametros_config pc
where pc.id = 1
  and coalesce(pc.rif_empresa, '') <> ''
  and not exists (
    select 1 from public.empresas e
    where upper(e.rif) = upper(pc.rif_empresa)
  );

-- ------------------------------------------------------------
-- 4) Vincular la configuración inicial y rellenar empresa_id
-- ------------------------------------------------------------
update public.parametros_config
set empresa_id = (
  select id from public.empresas
  where upper(rif) = upper(parametros_config.rif_empresa)
  limit 1
)
where id = 1;

do $$
declare t text; id_inicial bigint;
begin
  select id into id_inicial
  from public.empresas
  where upper(rif) = (select upper(rif_empresa) from public.parametros_config where id = 1)
  limit 1;

  if id_inicial is null then return; end if;

  foreach t in array array[
    'departamentos','cargos','empleados','nominas','historico_salarios','vacaciones',
    'utilidades','prestaciones','antiguedad','anticipos_prestaciones','prestamos_anticipos',
    'prestamos_abonos','asistencia_registros','justificativos_faltas','expediente_documentos',
    'prenomina_borrador','firmas_recibos','tokens_portal_empleado','solicitudes_ari'
  ] loop
    if to_regclass(format('public.%I', t)) is not null then
      execute format('update public.%I set empresa_id = $1 where empresa_id is null', t)
        using id_inicial;
    end if;
  end loop;
end $$;

-- ------------------------------------------------------------
-- 5) Borrar la empresa 407 incorrecta (distinta de Recordplast)
--    Sólo borra si es exactamente una y no tiene datos de negocio.
-- ------------------------------------------------------------
do $$
declare
  v_id bigint;
  v_count int;
  v_tabla text;
  tablas text[] := array[
    'departamentos','cargos','empleados','nominas','historico_salarios','vacaciones',
    'utilidades','prestaciones','antiguedad','anticipos_prestaciones','prestamos_anticipos',
    'prestamos_abonos','asistencia_registros','justificativos_faltas','expediente_documentos',
    'prenomina_borrador','firmas_recibos','tokens_portal_empleado','solicitudes_ari'
  ];
begin
  select count(*) into v_count
  from public.empresas
  where (upper(rif) like 'J-407%' or upper(rif) like '407%')
    and upper(rif) <> 'J-40771060-5';

  if v_count = 0 then
    raise notice 'No hay empresa 407 distinta de Recordplast. Nada que borrar.';
    return;
  end if;

  if v_count > 1 then
    raise exception 'Hay % empresas 407 candidatas. Revise el SELECT inicial y borre manualmente por id.', v_count;
  end if;

  select id into v_id
  from public.empresas
  where (upper(rif) like 'J-407%' or upper(rif) like '407%')
    and upper(rif) <> 'J-40771060-5'
  order by id
  limit 1;

  foreach v_tabla in array tablas loop
    if to_regclass(format('public.%I', v_tabla)) is null then
      continue;
    end if;
    execute format('select count(*) from public.%I where empresa_id = $1', v_tabla)
      into v_count using v_id;
    if v_count > 0 then
      raise exception 'La empresa % tiene % fila(s) en public.%. No se borra automáticamente.', v_id, v_count, v_tabla;
    end if;
  end loop;

  delete from public.parametros_config where empresa_id = v_id;
  delete from public.empresas where id = v_id;

  raise notice 'Empresa incorrecta % eliminada correctamente.', v_id;
end $$;

-- ------------------------------------------------------------
-- 6) Recargar la caché de esquema de la API
-- ------------------------------------------------------------
notify pgrst, 'reload schema';

-- ------------------------------------------------------------
-- 7) Verificación final: debe quedar sólo Recordplast
-- ------------------------------------------------------------
select id, nombre, rif, activo, created_at
from public.empresas
order by id;
