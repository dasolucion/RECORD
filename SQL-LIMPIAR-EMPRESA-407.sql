-- ============================================================
-- RECORD — LIMPIAR EMPRESA 407 CREADA POR ERROR
-- Ejecutar DESPUÉS de SQL-FIX-EMPRESAS.sql
-- Proyecto: RECORD (kvlkmpvnyvudlgbqoyer)
-- ============================================================
-- Este script:
--   1) Muestra las empresas cuyo RIF empieza por 407 (con o sin J-).
--   2) Identifica la que NO es Recordplast (J-40771060-5).
--   3) Verifica que no tenga empleados/nóminas/datos asociados.
--   4) Borra su configuración y la empresa incorrecta.
--
-- Si hay más de una candidata o tiene datos asociados, NO borra nada
-- y muestra un error para revisar manualmente.

-- Diagnóstico: revise esta lista antes de continuar.
select id, nombre, rif, activo, created_at
from public.empresas
where (upper(rif) like 'J-407%' or upper(rif) like '407%')
order by id;

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
    raise exception 'Hay % empresas 407 candidatas. Borre manualmente por id después de revisar el SELECT.', v_count;
  end if;

  select id into v_id
  from public.empresas
  where (upper(rif) like 'J-407%' or upper(rif) like '407%')
    and upper(rif) <> 'J-40771060-5'
  order by id
  limit 1;

  -- Verificar que la empresa incorrecta no tenga datos de negocio.
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

  -- Borrar primero su configuración y luego la empresa.
  delete from public.parametros_config where empresa_id = v_id;
  delete from public.empresas where id = v_id;

  raise notice 'Empresa incorrecta % eliminada correctamente.', v_id;
end $$;

-- Verificación final: debe quedar Recordplast y ninguna empresa 407 incorrecta.
select id, nombre, rif, activo, created_at
from public.empresas
order by id;
