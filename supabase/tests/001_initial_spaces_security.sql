-- Pruebas manuales de RLS para 001_initial_spaces.sql.
-- Ejecute en Supabase SQL Editor como postgres, tras reemplazar USER_A_UUID,
-- USER_B_UUID y USER_C_UUID por tres usuarios de prueba existentes de auth.users.
-- No use usuarios reales. Todo el script corre dentro de una transacción y termina
-- en ROLLBACK, por lo que no deja espacios ni membresías persistentes.
--
-- Obtenga los UUID con:
-- select id, email from auth.users order by created_at limit 3;

begin;

-- Preparación administrativa e idempotente de perfiles/espacios personales.
select public.bootstrap_existing_users();

-- Crea un espacio compartido temporal y asigna A (owner) y B (member).
with shared_space as (
  insert into public.spaces (owner_id, name, kind)
  values ('USER_A_UUID', 'Prueba de seguridad temporal', 'shared')
  returning id
), saved_id as (
  select set_config('app.test_shared_space_id', id::text, true)
  from shared_space
)
insert into public.space_members (space_id, user_id, role)
select current_setting('app.test_shared_space_id')::uuid, 'USER_A_UUID', 'owner'
from saved_id
union all
select current_setting('app.test_shared_space_id')::uuid, 'USER_B_UUID', 'member'
from saved_id;

-- A: lectura de perfil propio y espacio compartido autorizada; perfil de B denegado.
set local role authenticated;
select set_config('request.jwt.claim.sub', 'USER_A_UUID', true);
do $$
declare actual_count bigint;
begin
  select count(*) into actual_count from public.profiles where id = 'USER_A_UUID';
  if actual_count <> 1 then raise exception 'A no pudo leer su propio perfil'; end if;

  select count(*) into actual_count
  from public.spaces
  where id = current_setting('app.test_shared_space_id')::uuid;
  if actual_count <> 1 then raise exception 'A no pudo leer el espacio compartido'; end if;

  select count(*) into actual_count from public.profiles where id = 'USER_B_UUID';
  if actual_count <> 0 then raise exception 'A pudo leer el perfil privado de B'; end if;
end;
$$;

-- B: puede consultar el espacio compartido y toda su membresía.
select set_config('request.jwt.claim.sub', 'USER_B_UUID', true);
do $$
declare actual_count bigint;
begin
  select count(*) into actual_count
  from public.spaces
  where id = current_setting('app.test_shared_space_id')::uuid;
  if actual_count <> 1 then raise exception 'B no pudo leer el espacio compartido'; end if;

  select count(*) into actual_count
  from public.space_members
  where space_id = current_setting('app.test_shared_space_id')::uuid;
  if actual_count <> 2 then raise exception 'B no pudo leer la membresía del espacio compartido'; end if;
end;
$$;

-- C: no pertenece al espacio y no puede verlo ni consultar sus miembros.
select set_config('request.jwt.claim.sub', 'USER_C_UUID', true);
do $$
declare actual_count bigint;
begin
  select count(*) into actual_count
  from public.spaces
  where id = current_setting('app.test_shared_space_id')::uuid;
  if actual_count <> 0 then raise exception 'C pudo leer un espacio compartido ajeno'; end if;

  select count(*) into actual_count
  from public.space_members
  where space_id = current_setting('app.test_shared_space_id')::uuid;
  if actual_count <> 0 then raise exception 'C pudo leer miembros de un espacio ajeno'; end if;
end;
$$;

-- C no puede llamar a la función administrativa, ni insertar espacios o miembros.
do $$
declare function_is_executable boolean;
begin
  select has_function_privilege(
    current_user,
    'public.handle_new_user()'::regprocedure,
    'EXECUTE'
  ) into function_is_executable;
  if function_is_executable then
    raise exception 'C recibió EXECUTE sobre handle_new_user';
  end if;

  perform public.bootstrap_existing_users();
  raise exception 'C pudo ejecutar bootstrap_existing_users';
exception when insufficient_privilege then
  raise notice 'OK: EXECUTE de bootstrap_existing_users denegado a authenticated';
end;
$$;

do $$
begin
  insert into public.spaces (owner_id, name, kind)
  values ('USER_C_UUID', 'Espacio no autorizado', 'shared');
  raise exception 'C pudo insertar un espacio';
exception when insufficient_privilege then
  raise notice 'OK: INSERT de spaces denegado';
end;
$$;

do $$
begin
  insert into public.space_members (space_id, user_id, role)
  values (current_setting('app.test_shared_space_id')::uuid, 'USER_C_UUID', 'owner');
  raise exception 'C pudo insertar una membresía';
exception when insufficient_privilege then
  raise notice 'OK: INSERT de space_members denegado';
end;
$$;

-- Sin políticas de escritura, UPDATE y DELETE no deben afectar filas ajenas.
do $$
declare affected_rows integer;
begin
  begin
    update public.spaces
    set owner_id = 'USER_C_UUID'
    where id = current_setting('app.test_shared_space_id')::uuid;
    get diagnostics affected_rows = row_count;
    if affected_rows <> 0 then raise exception 'C pudo cambiar el propietario'; end if;
  exception when insufficient_privilege then
    raise notice 'OK: UPDATE de spaces denegado';
  end;

  begin
    delete from public.space_members
    where space_id = current_setting('app.test_shared_space_id')::uuid
      and user_id = 'USER_B_UUID';
    get diagnostics affected_rows = row_count;
    if affected_rows <> 0 then raise exception 'C pudo eliminar una membresía'; end if;
  exception when insufficient_privilege then
    raise notice 'OK: DELETE de space_members denegado';
  end;
end;
$$;

rollback;
