-- Pruebas manuales de RLS para 003_transactions.sql.
-- Ejecute como postgres en Supabase SQL Editor tras reemplazar USER_A_UUID,
-- USER_B_UUID y USER_C_UUID por tres usuarios de prueba existentes.
-- La transacción completa termina con ROLLBACK y no deja datos persistentes.

begin;

select public.bootstrap_existing_users();

-- A obtiene su espacio personal y registra un gasto. created_by enviado es falso,
-- pero el trigger debe reemplazarlo por auth.uid().
set local role authenticated;
select set_config('request.jwt.claim.sub', 'USER_A_UUID', true);
select set_config('app.personal_space_id', id::text, true)
from public.spaces
where owner_id = 'USER_A_UUID' and kind = 'personal';
select set_config('app.personal_key', gen_random_uuid()::text, true);

with inserted_transaction as (
  insert into public.transactions (
    space_id, created_by, transaction_type, amount, category_id, description, occurred_on, idempotency_key
  ) values (
    current_setting('app.personal_space_id')::uuid,
    'USER_C_UUID', 'expense', 45.50, 'alimentacion', 'Compra personal', current_date,
    current_setting('app.personal_key')::uuid
  ) returning id
)
select set_config('app.personal_transaction_id', id::text, true)
from inserted_transaction;

do $$
declare result_count bigint;
begin
  select count(*) into result_count
  from public.transactions
  where id = current_setting('app.personal_transaction_id')::uuid
    and created_by = 'USER_A_UUID';
  if result_count <> 1 then raise exception 'No se asignó el autor autenticado al gasto personal'; end if;
end;
$$;

-- Una clave idempotente del mismo usuario no puede crear un segundo movimiento.
do $$
begin
  insert into public.transactions (
    space_id, created_by, transaction_type, amount, category_id, idempotency_key
  ) values (
    current_setting('app.personal_space_id')::uuid,
    'USER_A_UUID', 'expense', 45.50, 'alimentacion', current_setting('app.personal_key')::uuid
  );
  raise exception 'La clave idempotente permitió un duplicado';
exception when unique_violation then
  raise notice 'OK: duplicado bloqueado por idempotencia';
end;
$$;

-- Montos no positivos y categorías incompatibles son rechazados.
do $$
begin
  insert into public.transactions (space_id, transaction_type, amount, category_id, idempotency_key)
  values (current_setting('app.personal_space_id')::uuid, 'expense', 0, 'alimentacion', gen_random_uuid());
  raise exception 'Se permitió monto cero';
exception when check_violation then
  raise notice 'OK: monto cero denegado';
end;
$$;

do $$
begin
  insert into public.transactions (space_id, transaction_type, amount, category_id, idempotency_key)
  values (current_setting('app.personal_space_id')::uuid, 'expense', -1, 'alimentacion', gen_random_uuid());
  raise exception 'Se permitió monto negativo';
exception when check_violation then
  raise notice 'OK: monto negativo denegado';
end;
$$;

do $$
begin
  insert into public.transactions (space_id, transaction_type, amount, category_id, idempotency_key)
  values (current_setting('app.personal_space_id')::uuid, 'expense', 1, 'sueldo', gen_random_uuid());
  raise exception 'Se permitió categoría de ingreso en gasto';
exception when check_violation then
  raise notice 'OK: categoría incompatible denegada';
end;
$$;

-- C no puede leer gastos personales de A.
select set_config('request.jwt.claim.sub', 'USER_C_UUID', true);
do $$
declare result_count bigint;
begin
  select count(*) into result_count from public.transactions
  where id = current_setting('app.personal_transaction_id')::uuid;
  if result_count <> 0 then raise exception 'C pudo leer un gasto personal ajeno'; end if;
end;
$$;

-- A crea un espacio compartido e invita a B mediante las RPC existentes.
select set_config('request.jwt.claim.sub', 'USER_A_UUID', true);
select set_config('app.shared_space_id', public.create_shared_space('Prueba movimientos')::text, true);
select set_config('app.shared_code', public.create_space_invitation(current_setting('app.shared_space_id')::uuid), true);
select set_config('request.jwt.claim.sub', 'USER_B_UUID', true);
do $$
declare joined_space_id uuid;
begin
  select public.join_shared_space(current_setting('app.shared_code')) into joined_space_id;
  if joined_space_id <> current_setting('app.shared_space_id')::uuid then
    raise exception 'B no pudo unirse al espacio compartido';
  end if;
end;
$$;

-- A almacena un solo movimiento compartido; A y B deben poder leer esa misma fila.
select set_config('request.jwt.claim.sub', 'USER_A_UUID', true);
with inserted_transaction as (
  insert into public.transactions (space_id, transaction_type, amount, category_id, description, idempotency_key)
  values (
    current_setting('app.shared_space_id')::uuid, 'expense', 20.00, 'transporte', 'Taxi compartido', gen_random_uuid()
  ) returning id
)
select set_config('app.shared_transaction_id', id::text, true)
from inserted_transaction;

do $$
declare result_count bigint;
begin
  select count(*) into result_count from public.transactions
  where id = current_setting('app.shared_transaction_id')::uuid;
  if result_count <> 1 then raise exception 'A no pudo leer el movimiento compartido único'; end if;
end;
$$;

select set_config('request.jwt.claim.sub', 'USER_B_UUID', true);
do $$
declare result_count bigint;
begin
  select count(*) into result_count from public.transactions
  where id = current_setting('app.shared_transaction_id')::uuid;
  if result_count <> 1 then raise exception 'B no pudo leer el movimiento compartido'; end if;
end;
$$;

-- C no puede insertar en el espacio compartido ajeno.
select set_config('request.jwt.claim.sub', 'USER_C_UUID', true);
do $$
begin
  insert into public.transactions (space_id, transaction_type, amount, category_id, idempotency_key)
  values (current_setting('app.shared_space_id')::uuid, 'expense', 10, 'transporte', gen_random_uuid());
  raise exception 'C pudo insertar en un espacio ajeno';
exception when insufficient_privilege then
  raise notice 'OK: INSERT ajeno denegado por RLS';
end;
$$;

-- B puede leer, pero no editar ni eliminar el movimiento creado por A.
select set_config('request.jwt.claim.sub', 'USER_B_UUID', true);
do $$
declare affected_rows integer;
begin
  begin
    update public.transactions set description = 'Edición no autorizada'
    where id = current_setting('app.shared_transaction_id')::uuid;
    get diagnostics affected_rows = row_count;
    if affected_rows <> 0 then raise exception 'B pudo editar movimiento de A'; end if;
  exception when insufficient_privilege then
    raise notice 'OK: UPDATE ajeno denegado';
  end;

  begin
    delete from public.transactions where id = current_setting('app.shared_transaction_id')::uuid;
    get diagnostics affected_rows = row_count;
    if affected_rows <> 0 then raise exception 'B pudo eliminar movimiento de A'; end if;
  exception when insufficient_privilege then
    raise notice 'OK: DELETE ajeno denegado';
  end;
end;
$$;

-- A puede editar y luego eliminar su movimiento. No puede falsificar autor ni moverlo de espacio.
select set_config('request.jwt.claim.sub', 'USER_A_UUID', true);
do $$
declare affected_rows integer;
begin
  update public.transactions
  set amount = 21.50,
      description = 'Taxi actualizado',
      category_id = 'servicios',
      occurred_on = current_date - 1
  where id = current_setting('app.shared_transaction_id')::uuid;
  get diagnostics affected_rows = row_count;
  if affected_rows <> 1 then raise exception 'A no pudo editar su propio movimiento'; end if;
end;
$$;

do $$
declare result_count bigint;
begin
  select count(*) into result_count
  from public.transactions
  where id = current_setting('app.shared_transaction_id')::uuid
    and amount = 21.50
    and description = 'Taxi actualizado'
    and category_id = 'servicios'
    and occurred_on = current_date - 1;
  if result_count <> 1 then raise exception 'La edición legítima de monto, descripción o categoría falló'; end if;
end;
$$;

do $$
begin
  update public.transactions set created_by = 'USER_B_UUID'
  where id = current_setting('app.shared_transaction_id')::uuid;
  raise exception 'A pudo cambiar el autor';
exception when insufficient_privilege then
  raise notice 'OK: cambio de autor denegado';
end;
$$;

do $$
begin
  update public.transactions set id = gen_random_uuid()
  where id = current_setting('app.shared_transaction_id')::uuid;
  raise exception 'A pudo cambiar el identificador';
exception when insufficient_privilege then
  raise notice 'OK: cambio de id denegado';
end;
$$;

do $$
begin
  update public.transactions set created_at = now() - interval '1 day'
  where id = current_setting('app.shared_transaction_id')::uuid;
  raise exception 'A pudo cambiar created_at';
exception when insufficient_privilege then
  raise notice 'OK: cambio de created_at denegado';
end;
$$;

do $$
begin
  update public.transactions set idempotency_key = gen_random_uuid()
  where id = current_setting('app.shared_transaction_id')::uuid;
  raise exception 'A pudo cambiar la clave de idempotencia';
exception when insufficient_privilege then
  raise notice 'OK: cambio de clave de idempotencia denegado';
end;
$$;

do $$
begin
  update public.transactions set space_id = current_setting('app.personal_space_id')::uuid
  where id = current_setting('app.shared_transaction_id')::uuid;
  raise exception 'A pudo transferir el movimiento a otro espacio';
exception when insufficient_privilege then
  raise notice 'OK: cambio de espacio denegado';
end;
$$;

do $$
declare affected_rows integer;
begin
  delete from public.transactions where id = current_setting('app.shared_transaction_id')::uuid;
  get diagnostics affected_rows = row_count;
  if affected_rows <> 1 then raise exception 'A no pudo eliminar su propio movimiento'; end if;
end;
$$;

rollback;
