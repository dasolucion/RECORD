-- ============================================================
-- RECORD — CONSOLIDAR EMPRESA EN ID = 1
-- Ejecutar COMPLETO en Supabase → SQL Editor → proyecto RECORD
-- (kvlkmpvnyvudlgbqoyer). Es idempotente.
-- ============================================================
-- Situación actual:
--   id = 1  → "Recordplast" con RIF viejo J-50685235-7  (datos: 5 empleados, 5 nóminas)
--   id = 7  → "Recordplast, C.A." con RIF correcto J-40771060-5 (sin datos)
--
-- Este script aplica la OPCIÓN 1:
--   1) Deja la empresa canónica en id = 1 (donde ya están los datos).
--   2) Le corrige nombre y RIF a Recordplast, C.A. — J-40771060-5.
--   3) Apunta parametros_config a empresa_id = 1.
--   4) Borra la fila duplicada id = 7 (sólo si no tiene datos propios).
--   5) Rellena empresa_id nulo en los datos existentes.
--   6) Recarga la caché de PostgREST y muestra la verificación.

-- ------------------------------------------------------------
-- 0) Diagnóstico previo
-- ------------------------------------------------------------
select id, nombre, rif, activo, created_at
from public.empresas
order by id;

select id, nombre_empresa, rif_empresa, empresa_id
from public.parametros_config
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
-- 3) Consolidar en id = 1
-- ------------------------------------------------------------
do $$
declare
  v_rif_correcto text;
  v_nombre_correcto text;
  v_id_correcto bigint;
  v_datos int;
  v_tabla text;
  tablas text[] := array[
    'departamentos','cargos','empleados','nominas','historico_salarios','vacaciones',
    'utilidades','prestaciones','antiguedad','anticipos_prestaciones','prestamos_anticipos',
    'prestamos_abonos','asistencia_registros','justificativos_faltas','expediente_documentos',
    'prenomina_borrador','firmas_recibos','tokens_portal_empleado','solicitudes_ari'
  ];
begin
  -- El nombre y RIF correctos salen de la configuración real (parametros_config id = 1).
  select nullif(rif_empresa, ''), nullif(nombre_empresa, '')
    into v_rif_correcto, v_nombre_correcto
  from public.parametros_config
  where id = 1;

  if v_rif_correcto is null then
    raise notice 'parametros_config id = 1 no tiene RIF. No se consolida automáticamente.';
    return;
  end if;

  -- Empresa que hoy tiene ese RIF correcto (normalmente id = 7).
  select id into v_id_correcto
  from public.empresas
  where upper(rif) = upper(v_rif_correcto)
  order by id
  limit 1;

  -- Si la empresa correcta no es id = 1, verificar que no tenga datos propios.
  -- Los datos reales deben estar bajo empresa_id = 1.
  if v_id_correcto is not null and v_id_correcto <> 1 then
    foreach v_tabla in array tablas loop
      if to_regclass(format('public.%I', v_tabla)) is null then
        continue;
      end if;
      execute format('select count(*) from public.%I where empresa_id = $1', v_tabla)
        into v_datos using v_id_correcto;
      if v_datos > 0 then
        raise notice 'La empresa % (RIF %) tiene % fila(s) en public.%. No se consolida automáticamente.', v_id_correcto, v_rif_correcto, v_datos, v_tabla;
        return;
      end if;
    end loop;
  end if;

  -- 1) Mover cualquier configuración que apunte a la empresa duplicada hacia id = 1.
  if v_id_correcto is not null and v_id_correcto <> 1 then
    update public.parametros_config
    set empresa_id = 1
    where empresa_id = v_id_correcto;
  end if;

  -- 2) Borrar la empresa duplicada (id = 7) si no es id = 1.
  if v_id_correcto is not null and v_id_correcto <> 1 then
    begin
      delete from public.empresas where id = v_id_correcto;
      raise notice 'Empresa duplicada % eliminada. Los datos quedan en id = 1.', v_id_correcto;
    exception when others then
      raise notice 'No se pudo borrar la empresa %: %', v_id_correcto, SQLERRM;
      return;
    end;
  end if;

  -- 3) Corregir (o crear) la empresa id = 1 con el nombre/RIF reales.
  if exists (select 1 from public.empresas where id = 1) then
    update public.empresas
    set nombre = coalesce(v_nombre_correcto, 'Recordplast, C.A.'),
        rif = v_rif_correcto,
        activo = true
    where id = 1;
  else
    insert into public.empresas (id, nombre, rif, activo)
    values (1, coalesce(v_nombre_correcto, 'Recordplast, C.A.'), v_rif_correcto, true);
  end if;

  -- 4) Configuración id = 1 apuntando a la empresa 1.
  update public.parametros_config
  set empresa_id = 1,
      nombre_empresa = coalesce(v_nombre_correcto, 'Recordplast, C.A.'),
      rif_empresa = v_rif_correcto
  where id = 1;

  -- 5) Rellenar empresa_id nulo en los datos existentes.
  foreach v_tabla in array tablas loop
    if to_regclass(format('public.%I', v_tabla)) is null then
      continue;
    end if;
    execute format('update public.%I set empresa_id = 1 where empresa_id is null', v_tabla);
  end loop;

  raise notice 'Consolidado en id = 1: % (%).', v_nombre_correcto, v_rif_correcto;
end $$;

-- ------------------------------------------------------------
-- 4) Recargar la caché de esquema de la API
-- ------------------------------------------------------------
notify pgrst, 'reload schema';

-- ------------------------------------------------------------
-- 5) Verificación final
-- ------------------------------------------------------------
select id, nombre, rif, activo, created_at
from public.empresas
order by id;

select id, nombre_empresa, rif_empresa, empresa_id
from public.parametros_config
order by id;

-- Conteos por empresa: los datos deben seguir en empresa_id = 1
select 'empleados' as tabla, empresa_id, count(*) as filas
from public.empleados group by empresa_id
union all
select 'nominas', empresa_id, count(*)
from public.nominas group by empresa_id
union all
select 'departamentos', empresa_id, count(*)
from public.departamentos group by empresa_id
union all
select 'cargos', empresa_id, count(*)
from public.cargos group by empresa_id
order by tabla, empresa_id;
