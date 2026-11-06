-- Pruebas manuales para 002_shared_spaces.sql.
-- Ejecute en SQL Editor como postgres tras reemplazar USER_OWNER_UUID,
-- USER_GUEST_UUID y USER_THIRD_UUID por tres usuarios de prueba existentes.
-- El script termina en ROLLBACK: no deja espacios, códigos, intentos ni membresías.

begin;

select public.bootstrap_existing_users();

-- Sin sesión, anon no puede crear espacios (ni tiene EXECUTE sobre la RPC).
set local role anon;
do $$
begin
  perform public.create_shared_space('No autorizado');
  raise exception 'anon pudo crear un espacio compartido';
exception when insufficient_privilege then
  raise notice 'OK: anon no puede ejecutar create_shared_space';
end;
$$;

-- Owner crea un espacio compartido e invitación vigente.
set local role authenticated;
select set_config('request.jwt.claim.sub', 'USER_OWNER_UUID', true);
select set_config(
  'app.shared_space_id',
  public.create_shared_space('Espacio compartido de prueba')::text,
  true
);
select set_config(
  'app.valid_code',
  public.create_space_invitation(current_setting('app.shared_space_id')::uuid),
  true
);

do $$
declare member_count bigint;
begin
  select count(*) into member_count
  from public.space_members
  where space_id = current_setting('app.shared_space_id')::uuid
    and user_id = 'USER_OWNER_UUID'
    and role = 'owner';
  if member_count <> 1 then raise exception 'El owner no recibió membresía owner'; end if;
end;
$$;

-- Un miembro que no es owner no puede generar una invitación.
select set_config('request.jwt.claim.sub', 'USER_GUEST_UUID', true);
do $$
begin
  perform public.create_space_invitation(current_setting('app.shared_space_id')::uuid);
  raise exception 'Un no-owner pudo crear una invitación';
exception when insufficient_privilege then
  raise notice 'OK: solo el owner puede crear invitaciones';
end;
$$;

-- Ni siquiera el owner puede crear invitaciones para su espacio personal.
select set_config('request.jwt.claim.sub', 'USER_OWNER_UUID', true);
select set_config(
  'app.personal_space_id',
  id::text,
  true
)
from public.spaces
where owner_id = 'USER_OWNER_UUID' and kind = 'personal';
do $$
begin
  perform public.create_space_invitation(current_setting('app.personal_space_id')::uuid);
  raise exception 'Se creó una invitación para un espacio personal';
exception when insufficient_privilege then
  raise notice 'OK: no se permiten invitaciones a espacios personales';
end;
$$;

-- El invitado consume el código vigente una sola vez y obtiene rol member.
select set_config('request.jwt.claim.sub', 'USER_GUEST_UUID', true);
do $$
declare joined_id uuid;
declare member_count bigint;
begin
  select public.join_shared_space(current_setting('app.valid_code')) into joined_id;
  if joined_id <> current_setting('app.shared_space_id')::uuid then
    raise exception 'El código vigente no unió al invitado';
  end if;

  select count(*) into member_count
  from public.space_members
  where space_id = current_setting('app.shared_space_id')::uuid
    and user_id = 'USER_GUEST_UUID'
    and role = 'member';
  if member_count <> 1 then raise exception 'El invitado no recibió membresía member'; end if;
end;
$$;

-- Un miembro existente puede introducir otro código vigente sin consumirlo.
select set_config('request.jwt.claim.sub', 'USER_OWNER_UUID', true);
select set_config(
  'app.member_code',
  public.create_space_invitation(current_setting('app.shared_space_id')::uuid),
  true
);
select set_config('request.jwt.claim.sub', 'USER_GUEST_UUID', true);
do $$
declare joined_id uuid;
begin
  select public.join_shared_space(current_setting('app.member_code')) into joined_id;
  if joined_id <> current_setting('app.shared_space_id')::uuid then
    raise exception 'Un miembro existente no recibió su espacio';
  end if;
end;
$$;

set local role postgres;
do $$
declare was_consumed boolean;
begin
  select used_at is not null into was_consumed
  from public.space_invitations
  where code_hash = extensions.digest(current_setting('app.member_code'), 'sha256');
  if was_consumed is distinct from false then
    raise exception 'El código fue consumido por un miembro existente';
  end if;
end;
$$;
set local role authenticated;

-- El tercero no puede reutilizar el código ya consumido.
select set_config('request.jwt.claim.sub', 'USER_THIRD_UUID', true);
do $$
declare joined_id uuid;
begin
  select public.join_shared_space(current_setting('app.valid_code')) into joined_id;
  if joined_id is not null then raise exception 'Se reutilizó un código de un solo uso'; end if;
end;
$$;

-- Código inválido: no une al tercero. Cinco fallos activan bloqueo temporal.
set local role postgres;
delete from public.space_invite_attempts where user_id = 'USER_THIRD_UUID';
set local role authenticated;
select set_config('request.jwt.claim.sub', 'USER_OWNER_UUID', true);
select set_config(
  'app.locked_valid_code',
  public.create_space_invitation(current_setting('app.shared_space_id')::uuid),
  true
);
select set_config('request.jwt.claim.sub', 'USER_THIRD_UUID', true);
do $$
declare joined_id uuid;
declare attempt_count integer;
begin
  for attempt_count in 1..5 loop
    select public.join_shared_space('INVALIDO') into joined_id;
    if joined_id is not null then raise exception 'Un código inválido produjo una membresía'; end if;
  end loop;
end;
$$;

set local role postgres;
do $$
declare is_locked boolean;
begin
  select locked_until > now() into is_locked
  from public.space_invite_attempts
  where user_id = 'USER_THIRD_UUID';
  if is_locked is distinct from true then raise exception 'No se bloqueó fuerza bruta tras cinco intentos'; end if;
end;
$$;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'USER_THIRD_UUID', true);
do $$
declare joined_id uuid;
begin
  select public.join_shared_space(current_setting('app.locked_valid_code')) into joined_id;
  if joined_id is not null then raise exception 'Un usuario bloqueado consumió un código vigente'; end if;
end;
$$;
set local role postgres;
do $$
declare was_consumed boolean;
begin
  select used_at is not null into was_consumed
  from public.space_invitations
  where code_hash = extensions.digest(current_setting('app.locked_valid_code'), 'sha256');
  if was_consumed is distinct from false then
    raise exception 'El código vigente fue consumido durante el bloqueo';
  end if;
end;
$$;

-- Crea un código y lo vence administrativamente; debe ser rechazado sin revelar motivo.
set local role authenticated;
select set_config('request.jwt.claim.sub', 'USER_OWNER_UUID', true);
select set_config(
  'app.expired_code',
  public.create_space_invitation(current_setting('app.shared_space_id')::uuid),
  true
);
set local role postgres;
update public.space_invitations
set created_at = now() - interval '48 hours',
    expires_at = now() - interval '24 hours'
where code_hash = extensions.digest(current_setting('app.expired_code'), 'sha256');
delete from public.space_invite_attempts where user_id = 'USER_THIRD_UUID';
set local role authenticated;
select set_config('request.jwt.claim.sub', 'USER_THIRD_UUID', true);
do $$
declare joined_id uuid;
begin
  select public.join_shared_space(current_setting('app.expired_code')) into joined_id;
  if joined_id is not null then raise exception 'Se aceptó un código vencido'; end if;
end;
$$;

-- A y B pueden leer el espacio; C no. Las tablas privadas no admiten escritura directa.
select set_config('request.jwt.claim.sub', 'USER_OWNER_UUID', true);
do $$
declare result_count bigint;
begin
  select count(*) into result_count from public.spaces where id = current_setting('app.shared_space_id')::uuid;
  if result_count <> 1 then raise exception 'Owner no puede leer su espacio compartido'; end if;
end;
$$;

select set_config('request.jwt.claim.sub', 'USER_GUEST_UUID', true);
do $$
declare result_count bigint;
begin
  select count(*) into result_count from public.spaces where id = current_setting('app.shared_space_id')::uuid;
  if result_count <> 1 then raise exception 'Invitado no puede leer el espacio compartido'; end if;
end;
$$;

select set_config('request.jwt.claim.sub', 'USER_THIRD_UUID', true);
do $$
declare result_count bigint;
begin
  select count(*) into result_count from public.spaces where id = current_setting('app.shared_space_id')::uuid;
  if result_count <> 0 then raise exception 'Tercero pudo leer espacio ajeno'; end if;
end;
$$;

do $$
begin
  insert into public.space_members (space_id, user_id, role)
  values (current_setting('app.shared_space_id')::uuid, 'USER_THIRD_UUID', 'owner');
  raise exception 'Escritura directa de membresía permitida';
exception when insufficient_privilege then
  raise notice 'OK: INSERT directo de membresía denegado';
end;
$$;

do $$
begin
  insert into public.space_invitations (space_id, created_by, code_hash, expires_at)
  values (
    current_setting('app.shared_space_id')::uuid,
    'USER_THIRD_UUID',
    extensions.digest('ABCDEFGH', 'sha256'),
    now() + interval '24 hours'
  );
  raise exception 'Escritura directa de invitación permitida';
exception when insufficient_privilege then
  raise notice 'OK: INSERT directo de invitación denegado';
end;
$$;

do $$
begin
  update public.space_members
  set role = 'owner'
  where space_id = current_setting('app.shared_space_id')::uuid
    and user_id = 'USER_GUEST_UUID';
  raise exception 'Escalamiento directo de rol permitido';
exception when insufficient_privilege then
  raise notice 'OK: UPDATE directo de membresía denegado';
end;
$$;

do $$
begin
  delete from public.space_invitations
  where space_id = current_setting('app.shared_space_id')::uuid;
  raise exception 'DELETE directo de invitación permitido';
exception when insufficient_privilege then
  raise notice 'OK: DELETE directo de invitación denegado';
end;
$$;

rollback;
