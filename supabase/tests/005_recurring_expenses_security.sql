-- Pruebas manuales para 005_recurring_expenses.sql.
-- Ejecute como postgres tras reemplazar USER_A_UUID, USER_B_UUID y USER_C_UUID
-- por tres usuarios de prueba. Todo termina en ROLLBACK.

begin;

select public.bootstrap_existing_users();

-- A crea una obligación personal. El autor enviado no es confiable.
set local role authenticated;
select set_config('request.jwt.claim.sub', 'USER_A_UUID', true);
select set_config('app.personal_space_id', id::text, true)
from public.spaces where owner_id = 'USER_A_UUID' and kind = 'personal';
select set_config('app.personal_transaction_count', count(*)::text, true)
from public.transactions where space_id = current_setting('app.personal_space_id')::uuid;

with inserted_expense as (
  insert into public.recurring_expenses (space_id, name, planned_amount, due_day, created_by)
  values (current_setting('app.personal_space_id')::uuid, 'Internet', 99.90, 31, 'USER_C_UUID')
  returning id
)
select set_config('app.personal_expense_id', id::text, true) from inserted_expense;

do $$
declare valid_count bigint;
declare transaction_count text;
begin
  select count(*) into valid_count from public.recurring_expenses
  where id = current_setting('app.personal_expense_id')::uuid and created_by = 'USER_A_UUID';
  if valid_count <> 1 then raise exception 'No se asignó auth.uid() como autor'; end if;

  select count(*)::text into transaction_count from public.transactions
  where space_id = current_setting('app.personal_space_id')::uuid;
  if transaction_count <> current_setting('app.personal_transaction_count') then
    raise exception 'Crear obligación generó una transacción';
  end if;
end;
$$;

-- Transacción expense real del mismo espacio y período: vínculo válido.
select set_config('app.payment_key', gen_random_uuid()::text, true);
with inserted_transaction as (
  insert into public.transactions (space_id, transaction_type, amount, category_id, occurred_on, idempotency_key)
  values (
    current_setting('app.personal_space_id')::uuid, 'expense', 99.90, 'servicios',
    make_date(2026, 2, 28), current_setting('app.payment_key')::uuid
  ) returning id
)
select set_config('app.valid_transaction_id', id::text, true) from inserted_transaction;

insert into public.recurring_expense_payments (recurring_expense_id, year, month, transaction_id)
values (current_setting('app.personal_expense_id')::uuid, 2026, 2, current_setting('app.valid_transaction_id')::uuid);

-- La misma obligación no puede tener dos pagos en el mismo período.
with inserted_second_payment as (
  insert into public.transactions (space_id, transaction_type, amount, category_id, occurred_on, idempotency_key)
  values (
    current_setting('app.personal_space_id')::uuid, 'expense', 99.90, 'servicios',
    make_date(2026, 2, 27), gen_random_uuid()
  ) returning id
)
select set_config('app.second_payment_transaction_id', id::text, true) from inserted_second_payment;

do $$
begin
  insert into public.recurring_expense_payments (recurring_expense_id, year, month, transaction_id)
  values (
    current_setting('app.personal_expense_id')::uuid, 2026, 2,
    current_setting('app.second_payment_transaction_id')::uuid
  );
  raise exception 'Se permitió pago recurrente duplicado';
exception when unique_violation then raise notice 'OK: duplicado mensual denegado';
end;
$$;

-- Una transacción vinculada no puede borrarse: evita estado pagado inconsistente.
do $$
begin
  delete from public.transactions where id = current_setting('app.valid_transaction_id')::uuid;
  raise exception 'Se permitió borrar transacción vinculada';
exception when foreign_key_violation then raise notice 'OK: transacción vinculada protegida';
end;
$$;

-- Mientras está vinculada, la transacción admite edición financiera compatible
-- dentro de febrero, pero no cambio de tipo ni de período.
update public.transactions
set amount = 100.00,
    description = 'Internet actualizado',
    category_id = 'vivienda',
    occurred_on = make_date(2026, 2, 27)
where id = current_setting('app.valid_transaction_id')::uuid;

do $$
declare valid_count bigint;
begin
  select count(*) into valid_count from public.transactions
  where id = current_setting('app.valid_transaction_id')::uuid
    and amount = 100.00
    and description = 'Internet actualizado'
    and category_id = 'vivienda'
    and occurred_on = make_date(2026, 2, 27);
  if valid_count <> 1 then raise exception 'Edición compatible de pago vinculado falló'; end if;
end;
$$;

do $$
begin
  update public.transactions
  set transaction_type = 'income', category_id = 'sueldo'
  where id = current_setting('app.valid_transaction_id')::uuid;
  raise exception 'Se permitió cambiar payment expense a income';
exception when check_violation then raise notice 'OK: tipo de pago vinculado protegido';
end;
$$;

do $$
begin
  update public.transactions
  set occurred_on = make_date(2026, 3, 1)
  where id = current_setting('app.valid_transaction_id')::uuid;
  raise exception 'Se permitió cambiar período de pago vinculado';
exception when check_violation then raise notice 'OK: período de pago vinculado protegido';
end;
$$;

-- Un gasto de otro espacio visible para A tampoco puede pagar obligación personal.
select set_config('app.shared_space_id', public.create_shared_space('Prueba recurrentes')::text, true);
with inserted_other_space as (
  insert into public.transactions (space_id, transaction_type, amount, category_id, occurred_on, idempotency_key)
  values (current_setting('app.shared_space_id')::uuid, 'expense', 10, 'servicios', make_date(2026, 2, 20), gen_random_uuid())
  returning id
)
select set_config('app.other_space_transaction_id', id::text, true) from inserted_other_space;

do $$
begin
  insert into public.recurring_expense_payments (recurring_expense_id, year, month, transaction_id)
  values (current_setting('app.personal_expense_id')::uuid, 2026, 2, current_setting('app.other_space_transaction_id')::uuid);
  raise exception 'Se permitió pago de otro espacio';
exception when check_violation then raise notice 'OK: espacio distinto denegado';
end;
$$;

-- Income, período distinto y espacio distinto son rechazados.
with inserted_income as (
  insert into public.transactions (space_id, transaction_type, amount, category_id, occurred_on, idempotency_key)
  values (current_setting('app.personal_space_id')::uuid, 'income', 100, 'sueldo', make_date(2026, 2, 28), gen_random_uuid())
  returning id
)
select set_config('app.income_transaction_id', id::text, true) from inserted_income;

do $$
begin
  insert into public.recurring_expense_payments (recurring_expense_id, year, month, transaction_id)
  values (current_setting('app.personal_expense_id')::uuid, 2026, 3, current_setting('app.income_transaction_id')::uuid);
  raise exception 'Se permitió income como pago';
exception when check_violation then raise notice 'OK: income denegado';
end;
$$;

with inserted_other_period as (
  insert into public.transactions (space_id, transaction_type, amount, category_id, occurred_on, idempotency_key)
  values (current_setting('app.personal_space_id')::uuid, 'expense', 10, 'servicios', make_date(2026, 3, 1), gen_random_uuid())
  returning id
)
select set_config('app.other_period_transaction_id', id::text, true) from inserted_other_period;

do $$
begin
  insert into public.recurring_expense_payments (recurring_expense_id, year, month, transaction_id)
  values (current_setting('app.personal_expense_id')::uuid, 2026, 2, current_setting('app.other_period_transaction_id')::uuid);
  raise exception 'Se permitió pago de otro período';
exception when check_violation then raise notice 'OK: período distinto denegado';
end;
$$;

-- Otro gasto no puede reutilizar la transaction ya asociada a otra obligación.
select set_config('app.second_expense_id', gen_random_uuid()::text, true);
insert into public.recurring_expenses (id, space_id, name, planned_amount, due_day)
values (current_setting('app.second_expense_id')::uuid, current_setting('app.personal_space_id')::uuid, 'Seguro', 50, 15);
do $$
begin
  insert into public.recurring_expense_payments (recurring_expense_id, year, month, transaction_id)
  values (current_setting('app.second_expense_id')::uuid, 2026, 2, current_setting('app.valid_transaction_id')::uuid);
  raise exception 'Se reutilizó transaction_id para otra obligación';
exception when unique_violation then raise notice 'OK: transaction_id único';
end;
$$;

-- Desactivar conserva el historial de pagos.
update public.recurring_expenses set is_active = false
where id = current_setting('app.personal_expense_id')::uuid;
do $$
declare payment_count bigint;
begin
  select count(*) into payment_count from public.recurring_expense_payments
  where recurring_expense_id = current_setting('app.personal_expense_id')::uuid;
  if payment_count <> 1 then raise exception 'Desactivar eliminó historial de pagos'; end if;
end;
$$;

-- Tras desvincular, la transacción vuelve a poder cambiar de tipo y período.
delete from public.recurring_expense_payments
where recurring_expense_id = current_setting('app.personal_expense_id')::uuid
  and year = 2026 and month = 2;

update public.transactions
set transaction_type = 'income',
    category_id = 'sueldo',
    occurred_on = make_date(2026, 3, 1)
where id = current_setting('app.valid_transaction_id')::uuid;

do $$
declare valid_count bigint;
begin
  select count(*) into valid_count from public.transactions
  where id = current_setting('app.valid_transaction_id')::uuid
    and transaction_type = 'income'
    and category_id = 'sueldo'
    and occurred_on = make_date(2026, 3, 1);
  if valid_count <> 1 then raise exception 'Cambio permitido tras desvincular falló'; end if;
end;
$$;

-- Fechas de vencimiento: día 31 se ajusta a fin de mes.
do $$
begin
  if public.recurring_due_date(2026, 2, 29) <> date '2026-02-28' then raise exception '29 de febrero no ajustado'; end if;
  if public.recurring_due_date(2026, 2, 30) <> date '2026-02-28' then raise exception '30 de febrero no ajustado'; end if;
  if public.recurring_due_date(2026, 2, 31) <> date '2026-02-28' then raise exception '31 de febrero no ajustado'; end if;
  if public.recurring_due_date(2024, 2, 31) <> date '2024-02-29' then raise exception '31 en febrero bisiesto no ajustado'; end if;
end;
$$;

-- Espacio compartido: A ya creó el espacio y B puede unirse y ver obligaciones.
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
with inserted_expense as (
  insert into public.recurring_expenses (space_id, name, planned_amount, due_day)
  values (current_setting('app.shared_space_id')::uuid, 'Alquiler', 1500, 1)
  returning id
)
select set_config('app.shared_expense_id', id::text, true) from inserted_expense;

-- A registra el gasto; B puede vincularlo como pago sin ser su autor.
with inserted_transaction as (
  insert into public.transactions (space_id, transaction_type, amount, category_id, occurred_on, idempotency_key)
  values (
    current_setting('app.shared_space_id')::uuid, 'expense', 1500, 'vivienda',
    make_date(2026, 2, 1), gen_random_uuid()
  ) returning id
)
select set_config('app.shared_transaction_id', id::text, true) from inserted_transaction;

select set_config('request.jwt.claim.sub', 'USER_B_UUID', true);
do $$
declare result_count bigint;
begin
  select count(*) into result_count from public.recurring_expenses
  where id = current_setting('app.shared_expense_id')::uuid;
  if result_count <> 1 then raise exception 'B no pudo leer obligación compartida'; end if;
end;
$$;

insert into public.recurring_expense_payments (recurring_expense_id, year, month, transaction_id)
values (
  current_setting('app.shared_expense_id')::uuid,
  2026,
  2,
  current_setting('app.shared_transaction_id')::uuid
);

do $$
declare link_count bigint;
begin
  select count(*) into link_count from public.recurring_expense_payments
  where recurring_expense_id = current_setting('app.shared_expense_id')::uuid
    and transaction_id = current_setting('app.shared_transaction_id')::uuid
    and linked_by = 'USER_B_UUID';
  if link_count <> 1 then
    raise exception 'B no pudo vincular gasto compartido creado por A';
  end if;
end;
$$;

do $$
declare affected_rows integer;
begin
  update public.recurring_expenses set planned_amount = 1600
  where id = current_setting('app.shared_expense_id')::uuid;
  get diagnostics affected_rows = row_count;
  if affected_rows <> 1 then raise exception 'B no pudo administrar obligación compartida'; end if;
end;
$$;

-- La vista de estado actual respeta el mismo aislamiento RLS.
do $$
declare
  status_count bigint;
  peru_today date := timezone('America/Lima', now())::date;
  status_year integer;
  status_month smallint;
  due_date date;
  status_value text;
  expected_status text;
begin
  select year, month, due_date, status
  into status_year, status_month, due_date, status_value
  from public.recurring_expense_current_status
  where recurring_expense_id = current_setting('app.shared_expense_id')::uuid;

  select count(*) into status_count from public.recurring_expense_current_status
  where recurring_expense_id = current_setting('app.shared_expense_id')::uuid;
  if status_count <> 1 then raise exception 'B no pudo consultar estado compartido'; end if;
  if status_year <> extract(year from peru_today)::integer
    or status_month <> extract(month from peru_today)::smallint then
    raise exception 'La vista no usó el mes local de America/Lima';
  end if;

  expected_status := case when due_date < peru_today then 'vencido' else 'pendiente' end;
  if status_value <> expected_status then
    raise exception 'Estado derivado no coincide con la fecha local de Perú';
  end if;
end;
$$;

select set_config('request.jwt.claim.sub', 'USER_C_UUID', true);
do $$
declare result_count bigint;
begin
  select count(*) into result_count from public.recurring_expenses
  where id = current_setting('app.shared_expense_id')::uuid;
  if result_count <> 0 then raise exception 'C pudo leer obligación ajena'; end if;
end;
$$;

do $$
declare status_count bigint;
begin
  select count(*) into status_count from public.recurring_expense_current_status
  where recurring_expense_id = current_setting('app.shared_expense_id')::uuid;
  if status_count <> 0 then raise exception 'C pudo consultar estado recurrente ajeno'; end if;
end;
$$;

do $$
begin
  insert into public.recurring_expenses (space_id, name, planned_amount, due_day)
  values (current_setting('app.shared_space_id')::uuid, 'No autorizado', 1, 1);
  raise exception 'C pudo crear obligación en espacio ajeno';
exception when insufficient_privilege then raise notice 'OK: acceso ajeno denegado';
end;
$$;

do $$
begin
  insert into public.recurring_expense_payments (recurring_expense_id, year, month, transaction_id)
  values (
    current_setting('app.shared_expense_id')::uuid,
    2026,
    2,
    current_setting('app.shared_transaction_id')::uuid
  );
  raise exception 'C pudo vincular un pago ajeno';
exception when insufficient_privilege then raise notice 'OK: vínculo ajeno denegado';
end;
$$;

-- Prueba manual de concurrencia (ejecutar fuera de este script, en dos sesiones
-- autenticadas como el mismo miembro y con los IDs creados por una preparación
-- persistente de prueba):
--
-- Sesión A:
--   begin;
--   insert into public.recurring_expense_payments (..., transaction_id = '<TX_ID>');
--   -- Mantener la transacción abierta para conservar SELECT FOR UPDATE
--   -- ejecutado por el trigger SECURITY DEFINER.
--
-- Sesión B:
--   begin;
--   update public.transactions set occurred_on = date '<OTRO_MES>' where id = '<TX_ID>';
--   -- Debe esperar a A. Tras COMMIT de A debe fallar por el trigger de protección.
--
-- Como variante, intentar INSERT de un segundo recurring_expense_payment con el
-- mismo transaction_id en B: debe esperar y luego fallar por UNIQUE(transaction_id).
-- Finalizar ambas sesiones con ROLLBACK. Esta comprobación no se ejecuta aquí.

rollback;
