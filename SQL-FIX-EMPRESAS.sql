-- ============================================================
-- RECORD — REPARO RÁPIDO DE MULTIEMPRESA
-- Ejecutar COMPLETO en Supabase → SQL Editor → proyecto RECORD
-- ============================================================
-- Este script es idempotente: se puede volver a ejecutar sin duplicar datos.

-- 1) El frontend usa la anon key, por lo que debe poder registrar empresas.
alter table public.empresas disable row level security;
grant select, insert, update, delete on public.empresas to anon, authenticated;

-- 2) Asegurar las columnas empresa_id (si el script anterior se cortó a mitad).
alter table public.parametros_config
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
    execute format(
      'alter table if exists public.%I add column if not exists empresa_id bigint references public.empresas(id)',
      t
    );
  end loop;
end $$;

-- 3) Crear la empresa inicial desde la configuración real (sin RIF hardcodeado).
insert into public.empresas (nombre, rif, activo)
select coalesce(nullif(nombre_empresa, ''), 'EMPRESA'),
       coalesce(nullif(rif_empresa, ''), 'J-00000000-0'),
       true
from public.parametros_config where id = 1
on conflict (rif) do update set nombre = excluded.nombre, activo = excluded.activo;

-- 4) Vincular la config inicial y backfill de datos existentes.
update public.parametros_config
set empresa_id = (
  select id from public.empresas
  where rif = parametros_config.rif_empresa
  limit 1
)
where id = 1;

do $$
declare t text; id_inicial bigint;
begin
  select id into id_inicial
  from public.empresas
  where rif = (select rif_empresa from public.parametros_config where id = 1)
  limit 1;

  if id_inicial is null then return; end if;

  foreach t in array array[
    'departamentos','cargos','empleados','nominas','historico_salarios','vacaciones',
    'utilidades','prestaciones','antiguedad','anticipos_prestaciones','prestamos_anticipos',
    'prestamos_abonos','asistencia_registros','justificativos_faltas','expediente_documentos',
    'prenomina_borrador','firmas_recibos','tokens_portal_empleado','solicitudes_ari'
  ] loop
    execute format('update public.%I set empresa_id = $1 where empresa_id is null', t) using id_inicial;
  end loop;
end $$;

-- 5) Verificación rápida (debe devolver al menos 1 fila).
select id, nombre, rif, activo from public.empresas order by id;
