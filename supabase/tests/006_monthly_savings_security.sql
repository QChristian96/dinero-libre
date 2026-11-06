-- Pruebas manuales para 006_monthly_savings.sql.
-- Ejecute como postgres tras reemplazar USER_A_UUID, USER_B_UUID y USER_C_UUID
-- por usuarios de prueba. Todo termina en ROLLBACK y no deja datos persistentes.

begin;

select public.bootstrap_existing_users();

-- Reserva personal válida: created_by enviado se reemplaza por auth.uid().
set local role authenticated;
select set_config('request.jwt.claim.sub', 'USER_A_UUID', true);
select set_config('app.personal_space_id', id::text, true)
from public.spaces where owner_id = 'USER_A_UUID' and kind = 'personal';
select set_config('app.transaction_count_before', count(*)::text, true)
from public.transactions where space_id = current_setting('app.personal_space_id')::uuid;

with inserted_saving as (
  insert into public.monthly_savings (space_id, year, month, amount, created_by, created_at)
  values (
    current_setting('app.personal_space_id')::uuid, 2026, 3, 350.00,
    'USER_C_UUID', '2000-01-01T00:00:00Z'
  )
  returning id
)
select set_config('app.personal_saving_id', id::text, true) from inserted_saving;

do $$
declare saving_count bigint;
declare transaction_count text;
begin
  select count(*) into saving_count from public.monthly_savings
  where id = current_setting('app.personal_saving_id')::uuid
    and created_by = 'USER_A_UUID'
    and created_at <> '2000-01-01T00:00:00Z'::timestamptz;
  if saving_count <> 1 then raise exception 'No se protegió autor o created_at de la reserva'; end if;

  select count(*)::text into transaction_count from public.transactions
  where space_id = current_setting('app.personal_space_id')::uuid;
  if transaction_count <> current_setting('app.transaction_count_before') then
    raise exception 'Crear reserva creó una transaction';
  end if;
end;
$$;

-- Duplicado del período se rechaza; otro mes se permite.
do $$
begin
  insert into public.monthly_savings (space_id, year, month, amount)
  values (current_setting('app.personal_space_id')::uuid, 2026, 3, 400.00);
  raise exception 'Se permitió una reserva duplicada';
exception when unique_violation then raise notice 'OK: duplicado mensual denegado';
end;
$$;

insert into public.monthly_savings (space_id, year, month, amount)
values (current_setting('app.personal_space_id')::uuid, 2026, 4, 400.00);

-- NULL, cero, negativos y períodos inválidos se rechazan.
do $$
begin
  insert into public.monthly_savings (space_id, year, month, amount)
  values (current_setting('app.personal_space_id')::uuid, 2026, 5, null);
  raise exception 'Se permitió importe NULL';
exception when not_null_violation then raise notice 'OK: NULL denegado';
end;
$$;

do $$
begin
  insert into public.monthly_savings (space_id, year, month, amount)
  values (current_setting('app.personal_space_id')::uuid, 2026, 5, 0);
  raise exception 'Se permitió importe cero';
exception when check_violation then raise notice 'OK: cero denegado';
end;
$$;

do $$
begin
  insert into public.monthly_savings (space_id, year, month, amount)
  values (current_setting('app.personal_space_id')::uuid, 2026, 5, -1);
  raise exception 'Se permitió importe negativo';
exception when check_violation then raise notice 'OK: negativo denegado';
end;
$$;

do $$
begin
  insert into public.monthly_savings (space_id, year, month, amount)
  values (current_setting('app.personal_space_id')::uuid, 2019, 5, 10);
  raise exception 'Se permitió año inválido';
exception when check_violation then raise notice 'OK: año inválido denegado';
end;
$$;

do $$
begin
  insert into public.monthly_savings (space_id, year, month, amount)
  values (current_setting('app.personal_space_id')::uuid, 2026, 13, 10);
  raise exception 'Se permitió mes inválido';
exception when check_violation then raise notice 'OK: mes inválido denegado';
end;
$$;

-- A modifica amount y elimina la reserva de abril.
update public.monthly_savings set amount = 375.50, updated_at = '2000-01-01T00:00:00Z'
where id = current_setting('app.personal_saving_id')::uuid;

do $$
declare saving_count bigint;
begin
  select count(*) into saving_count from public.monthly_savings
  where id = current_setting('app.personal_saving_id')::uuid
    and amount = 375.50
    and updated_at <> '2000-01-01T00:00:00Z'::timestamptz;
  if saving_count <> 1 then raise exception 'No se actualizó amount o updated_at'; end if;
end;
$$;

delete from public.monthly_savings
where space_id = current_setting('app.personal_space_id')::uuid
  and year = 2026 and month = 4;

-- Espacio compartido: B puede administrar la misma reserva creada por A.
select set_config('app.shared_space_id', public.create_shared_space('Prueba reservas')::text, true);
select set_config('app.shared_code', public.create_space_invitation(current_setting('app.shared_space_id')::uuid), true);
select set_config('request.jwt.claim.sub', 'USER_B_UUID', true);
do $$
declare joined_id uuid;
begin
  select public.join_shared_space(current_setting('app.shared_code')) into joined_id;
  if joined_id <> current_setting('app.shared_space_id')::uuid then raise exception 'B no pudo unirse'; end if;
end;
$$;

select set_config('request.jwt.claim.sub', 'USER_A_UUID', true);
with inserted_saving as (
  insert into public.monthly_savings (space_id, year, month, amount)
  values (current_setting('app.shared_space_id')::uuid, 2026, 3, 500.00)
  returning id
)
select set_config('app.shared_saving_id', id::text, true) from inserted_saving;

select set_config('request.jwt.claim.sub', 'USER_B_UUID', true);
do $$
declare saving_count bigint;
begin
  select count(*) into saving_count from public.monthly_savings
  where id = current_setting('app.shared_saving_id')::uuid;
  if saving_count <> 1 then raise exception 'B no pudo leer reserva compartida'; end if;
end;
$$;

do $$
declare affected_rows integer;
begin
  update public.monthly_savings set amount = 550.00
  where id = current_setting('app.shared_saving_id')::uuid;
  get diagnostics affected_rows = row_count;
  if affected_rows <> 1 then raise exception 'B no pudo actualizar reserva compartida'; end if;
end;
$$;

-- Identidad, período, espacio y auditoría son inmutables incluso para B.
do $$
begin
  update public.monthly_savings set id = gen_random_uuid()
  where id = current_setting('app.shared_saving_id')::uuid;
  raise exception 'Se permitió cambiar id';
exception when insufficient_privilege then raise notice 'OK: id inmutable';
end;
$$;

do $$
begin
  update public.monthly_savings set month = 4
  where id = current_setting('app.shared_saving_id')::uuid;
  raise exception 'Se permitió cambiar período';
exception when insufficient_privilege then raise notice 'OK: período inmutable';
end;
$$;

do $$
begin
  update public.monthly_savings set created_by = 'USER_B_UUID'
  where id = current_setting('app.shared_saving_id')::uuid;
  raise exception 'Se permitió cambiar created_by';
exception when insufficient_privilege then raise notice 'OK: created_by inmutable';
end;
$$;

-- C no puede leer ni escribir en el espacio compartido ajeno.
select set_config('request.jwt.claim.sub', 'USER_C_UUID', true);
do $$
declare saving_count bigint;
begin
  select count(*) into saving_count from public.monthly_savings
  where id = current_setting('app.shared_saving_id')::uuid;
  if saving_count <> 0 then raise exception 'C pudo leer reserva ajena'; end if;
end;
$$;

do $$
begin
  insert into public.monthly_savings (space_id, year, month, amount)
  values (current_setting('app.shared_space_id')::uuid, 2026, 4, 100.00);
  raise exception 'C pudo crear reserva ajena';
exception when insufficient_privilege then raise notice 'OK: escritura ajena denegada';
end;
$$;

do $$
declare affected_rows integer;
begin
  begin
    update public.monthly_savings set amount = 1.00
    where id = current_setting('app.shared_saving_id')::uuid;
    get diagnostics affected_rows = row_count;
    if affected_rows <> 0 then raise exception 'C pudo actualizar reserva ajena'; end if;
  exception when insufficient_privilege then
    raise notice 'OK: UPDATE ajeno denegado';
  end;

  begin
    delete from public.monthly_savings
    where id = current_setting('app.shared_saving_id')::uuid;
    get diagnostics affected_rows = row_count;
    if affected_rows <> 0 then raise exception 'C pudo eliminar reserva ajena'; end if;
  exception when insufficient_privilege then
    raise notice 'OK: DELETE ajeno denegado';
  end;
end;
$$;

-- B elimina la reserva compartida antes de finalizar la transacción de prueba.
select set_config('request.jwt.claim.sub', 'USER_B_UUID', true);
do $$
declare affected_rows integer;
begin
  delete from public.monthly_savings where id = current_setting('app.shared_saving_id')::uuid;
  get diagnostics affected_rows = row_count;
  if affected_rows <> 1 then raise exception 'B no pudo eliminar reserva compartida'; end if;
end;
$$;

rollback;
