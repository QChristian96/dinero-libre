-- Pruebas manuales de RLS para 004_monthly_budgets.sql.
-- Ejecute como postgres tras reemplazar USER_A_UUID, USER_B_UUID y USER_C_UUID
-- por tres usuarios de prueba. Todo termina en ROLLBACK.

begin;

select public.bootstrap_existing_users();

-- A crea presupuesto personal. created_by recibido se sustituye por auth.uid().
set local role authenticated;
select set_config('request.jwt.claim.sub', 'USER_A_UUID', true);
select set_config('app.personal_space_id', id::text, true)
from public.spaces where owner_id = 'USER_A_UUID' and kind = 'personal';
select set_config('app.personal_transaction_count', count(*)::text, true)
from public.transactions where space_id = current_setting('app.personal_space_id')::uuid;

with inserted_budget as (
  insert into public.budgets (space_id, year, month, amount, created_by)
  values (current_setting('app.personal_space_id')::uuid, 2026, 3, 1200.00, 'USER_C_UUID')
  returning id
)
select set_config('app.personal_budget_id', id::text, true) from inserted_budget;

do $$
declare valid_count bigint;
declare transaction_count text;
begin
  select count(*) into valid_count from public.budgets
  where id = current_setting('app.personal_budget_id')::uuid
    and created_by = 'USER_A_UUID';
  if valid_count <> 1 then raise exception 'No se asignó el autor autenticado al presupuesto'; end if;

  select count(*)::text into transaction_count from public.transactions
  where space_id = current_setting('app.personal_space_id')::uuid;
  if transaction_count <> current_setting('app.personal_transaction_count') then
    raise exception 'Configurar presupuesto creó movimientos';
  end if;
end;
$$;

-- Duplicado de espacio/año/mes y valores inválidos son rechazados.
do $$
begin
  insert into public.budgets (space_id, year, month, amount)
  values (current_setting('app.personal_space_id')::uuid, 2026, 3, 1300.00);
  raise exception 'Se permitió presupuesto mensual duplicado';
exception when unique_violation then
  raise notice 'OK: duplicado mensual denegado';
end;
$$;

do $$
begin
  insert into public.budgets (space_id, year, month, amount)
  values (current_setting('app.personal_space_id')::uuid, 2026, 4, 0);
  raise exception 'Se permitió presupuesto cero';
exception when check_violation then
  raise notice 'OK: importe cero denegado';
end;
$$;

do $$
begin
  insert into public.budgets (space_id, year, month, amount)
  values (current_setting('app.personal_space_id')::uuid, 2026, 13, -1);
  raise exception 'Se permitió mes o importe inválido';
exception when check_violation then
  raise notice 'OK: mes e importe inválidos denegados';
end;
$$;

do $$
begin
  insert into public.budgets (space_id, year, month, amount)
  values (current_setting('app.personal_space_id')::uuid, 2026, 5, -1);
  raise exception 'Se permitió importe negativo';
exception when check_violation then
  raise notice 'OK: importe negativo denegado';
end;
$$;

-- C no puede leer ni escribir en el espacio personal de A.
select set_config('request.jwt.claim.sub', 'USER_C_UUID', true);
do $$
declare result_count bigint;
begin
  select count(*) into result_count from public.budgets
  where id = current_setting('app.personal_budget_id')::uuid;
  if result_count <> 0 then raise exception 'C pudo leer presupuesto personal ajeno'; end if;
end;
$$;

do $$
begin
  insert into public.budgets (space_id, year, month, amount)
  values (current_setting('app.personal_space_id')::uuid, 2026, 4, 500);
  raise exception 'C pudo insertar presupuesto ajeno';
exception when insufficient_privilege then
  raise notice 'OK: INSERT ajeno denegado por RLS';
end;
$$;

-- A crea espacio compartido y B se une mediante las RPC ya existentes.
select set_config('request.jwt.claim.sub', 'USER_A_UUID', true);
select set_config('app.shared_space_id', public.create_shared_space('Prueba presupuestos')::text, true);
select set_config('app.shared_code', public.create_space_invitation(current_setting('app.shared_space_id')::uuid), true);
select set_config('request.jwt.claim.sub', 'USER_B_UUID', true);
do $$
declare joined_id uuid;
begin
  select public.join_shared_space(current_setting('app.shared_code')) into joined_id;
  if joined_id <> current_setting('app.shared_space_id')::uuid then raise exception 'B no pudo unirse al espacio'; end if;
end;
$$;

-- A crea un presupuesto compartido, visible una sola vez para A y B.
select set_config('request.jwt.claim.sub', 'USER_A_UUID', true);
with inserted_budget as (
  insert into public.budgets (space_id, year, month, amount)
  values (current_setting('app.shared_space_id')::uuid, 2026, 3, 2000.00)
  returning id
)
select set_config('app.shared_budget_id', id::text, true) from inserted_budget;

select set_config('request.jwt.claim.sub', 'USER_B_UUID', true);
do $$
declare result_count bigint;
begin
  select count(*) into result_count from public.budgets
  where id = current_setting('app.shared_budget_id')::uuid;
  if result_count <> 1 then raise exception 'B no pudo leer presupuesto compartido'; end if;
end;
$$;

-- B, como miembro, puede actualizar y eliminar sin duplicar el presupuesto.
do $$
declare affected_rows integer;
declare automatic_timestamp boolean;
begin
  update public.budgets
  set amount = 2200.00, updated_at = '2000-01-01T00:00:00Z'
  where id = current_setting('app.shared_budget_id')::uuid;
  get diagnostics affected_rows = row_count;
  if affected_rows <> 1 then raise exception 'B no pudo actualizar presupuesto compartido'; end if;

  select updated_at <> '2000-01-01T00:00:00Z'::timestamptz into automatic_timestamp
  from public.budgets where id = current_setting('app.shared_budget_id')::uuid;
  if automatic_timestamp is distinct from true then raise exception 'updated_at no fue automático'; end if;
end;
$$;

-- Campos inmutables no se pueden alterar ni siquiera por un miembro autorizado.
do $$
begin
  update public.budgets set id = gen_random_uuid()
  where id = current_setting('app.shared_budget_id')::uuid;
  raise exception 'Se permitió cambiar id';
exception when insufficient_privilege then raise notice 'OK: id inmutable';
end;
$$;

do $$
begin
  update public.budgets set created_at = now() - interval '1 day'
  where id = current_setting('app.shared_budget_id')::uuid;
  raise exception 'Se permitió cambiar created_at';
exception when insufficient_privilege then raise notice 'OK: created_at inmutable';
end;
$$;

do $$
begin
  update public.budgets set created_by = 'USER_B_UUID'
  where id = current_setting('app.shared_budget_id')::uuid;
  raise exception 'Se permitió cambiar created_by';
exception when insufficient_privilege then raise notice 'OK: created_by inmutable';
end;
$$;

do $$
begin
  update public.budgets set space_id = current_setting('app.personal_space_id')::uuid
  where id = current_setting('app.shared_budget_id')::uuid;
  raise exception 'Se permitió cambiar space_id';
exception when insufficient_privilege then raise notice 'OK: space_id inmutable';
end;
$$;

-- C no puede leer ni escribir el espacio compartido de A/B.
select set_config('request.jwt.claim.sub', 'USER_C_UUID', true);
do $$
declare result_count bigint;
begin
  select count(*) into result_count from public.budgets
  where space_id = current_setting('app.shared_space_id')::uuid;
  if result_count <> 0 then raise exception 'C pudo leer presupuesto compartido ajeno'; end if;
end;
$$;

do $$
begin
  insert into public.budgets (space_id, year, month, amount)
  values (current_setting('app.shared_space_id')::uuid, 2026, 4, 500);
  raise exception 'C pudo insertar presupuesto compartido ajeno';
exception when insufficient_privilege then
  raise notice 'OK: INSERT compartido ajeno denegado por RLS';
end;
$$;

-- B puede eliminar el presupuesto compartido mientras conserve la membresía.
select set_config('request.jwt.claim.sub', 'USER_B_UUID', true);
do $$
declare affected_rows integer;
begin
  delete from public.budgets where id = current_setting('app.shared_budget_id')::uuid;
  get diagnostics affected_rows = row_count;
  if affected_rows <> 1 then raise exception 'B no pudo eliminar presupuesto compartido'; end if;
end;
$$;

rollback;
