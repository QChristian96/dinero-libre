-- Pruebas manuales para 007_recurring_expense_payment_flow.sql.
-- Ejecute como postgres tras reemplazar USER_A_UUID, USER_B_UUID y USER_C_UUID
-- por usuarios de prueba. Todo termina en ROLLBACK.

begin;

select public.bootstrap_existing_users();

set local role authenticated;
select set_config('request.jwt.claim.sub', 'USER_A_UUID', true);
select set_config('app.personal_space_id', id::text, true)
from public.spaces where owner_id = 'USER_A_UUID' and kind = 'personal';
select set_config('app.transactions_before', count(*)::text, true)
from public.transactions where space_id = current_setting('app.personal_space_id')::uuid;

-- Pago fijo: amount_cents debe coincidir exactamente con planned_amount.
with inserted_expense as (
  insert into public.recurring_expenses (space_id, name, planned_amount, due_day, amount_mode)
  values (current_setting('app.personal_space_id')::uuid, 'Luz fija', 100.00, 15, 'fixed')
  returning id
)
select set_config('app.fixed_expense_id', id::text, true) from inserted_expense;
select set_config('app.fixed_key', gen_random_uuid()::text, true);

do $$
declare result_count bigint;
begin
  select count(*) into result_count
  from public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.fixed_expense_id'),
    'amount_cents', '10000',
    'category_id', 'servicios',
    'occurred_on', '2026-03-15',
    'idempotency_key', current_setting('app.fixed_key'),
    'description', 'Pago de luz'
  )));
  if result_count <> 1 then raise exception 'No se registró pago fijo'; end if;
end;
$$;

-- Un reintento idéntico sigue siendo válido aunque la obligación cambie luego.
update public.recurring_expenses
set planned_amount = 120.00,
    amount_mode = 'variable',
    is_active = false
where id = current_setting('app.fixed_expense_id')::uuid;

do $$
declare was_reused boolean;
begin
  select reused into was_reused
  from public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.fixed_expense_id'),
    'amount_cents', '10000',
    'category_id', 'servicios',
    'occurred_on', '2026-03-15',
    'idempotency_key', current_setting('app.fixed_key'),
    'description', 'Pago de luz'
  )));
  if was_reused is distinct from true then
    raise exception 'Reintento cambió tras editar o desactivar obligación';
  end if;
end;
$$;

-- Una clave existente no puede reutilizarse con datos distintos.
do $$
begin
  perform public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.fixed_expense_id'), 'amount_cents', '10001',
    'category_id', 'servicios', 'occurred_on', '2026-03-15',
    'idempotency_key', current_setting('app.fixed_key'), 'description', 'Pago de luz'
  )));
  raise exception 'Clave reutilizada permitió monto distinto';
exception when unique_violation then raise notice 'OK: conflicto de monto denegado';
end;
$$;

do $$
begin
  perform public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.fixed_expense_id'), 'amount_cents', '10000',
    'category_id', 'vivienda', 'occurred_on', '2026-03-15',
    'idempotency_key', current_setting('app.fixed_key'), 'description', 'Pago de luz'
  )));
  raise exception 'Clave reutilizada permitió categoría distinta';
exception when unique_violation then raise notice 'OK: conflicto de categoría denegado';
end;
$$;

do $$
begin
  perform public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.fixed_expense_id'), 'amount_cents', '10000',
    'category_id', 'servicios', 'occurred_on', '2026-03-16',
    'idempotency_key', current_setting('app.fixed_key'), 'description', 'Pago de luz'
  )));
  raise exception 'Clave reutilizada permitió fecha distinta';
exception when unique_violation then raise notice 'OK: conflicto de fecha denegado';
end;
$$;

do $$
begin
  perform public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.fixed_expense_id'), 'amount_cents', '10000',
    'category_id', 'servicios', 'occurred_on', '2026-03-15',
    'idempotency_key', current_setting('app.fixed_key'), 'description', 'Descripción distinta'
  )));
  raise exception 'Clave reutilizada permitió descripción distinta';
exception when unique_violation then raise notice 'OK: conflicto de descripción denegado';
end;
$$;

with conflicting_expense as (
  insert into public.recurring_expenses (space_id, name, planned_amount, due_day, amount_mode)
  values (current_setting('app.personal_space_id')::uuid, 'Otra obligación', 100.00, 16, 'variable')
  returning id
)
select set_config('app.conflicting_expense_id', id::text, true) from conflicting_expense;

do $$
begin
  perform public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.conflicting_expense_id'), 'amount_cents', '10000',
    'category_id', 'servicios', 'occurred_on', '2026-03-15',
    'idempotency_key', current_setting('app.fixed_key'), 'description', 'Pago de luz'
  )));
  raise exception 'Clave reutilizada permitió obligación distinta';
exception when unique_violation then raise notice 'OK: conflicto de obligación denegado';
end;
$$;

do $$
declare transaction_count bigint;
        link_count bigint;
begin
  select count(*) into transaction_count
  from public.transactions as transaction_record
  where transaction_record.created_by = 'USER_A_UUID'
    and transaction_record.idempotency_key = current_setting('app.fixed_key')::uuid
    and transaction_record.amount = 100.00;
  if transaction_count <> 1 then raise exception 'Pago fijo no creó transaction exacta'; end if;

  select count(*) into link_count
  from public.recurring_expense_payments as payment
  join public.transactions as transaction_record on transaction_record.id = payment.transaction_id
  where payment.recurring_expense_id = current_setting('app.fixed_expense_id')::uuid
    and payment.year = 2026 and payment.month = 3
    and transaction_record.idempotency_key = current_setting('app.fixed_key')::uuid;
  if link_count <> 1 then raise exception 'Pago fijo no quedó vinculado'; end if;
end;
$$;

-- Reintento con la misma clave: devuelve el pago ya creado sin duplicar gastos.
do $$
declare was_reused boolean;
        transaction_count bigint;
begin
  select reused into was_reused
  from public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.fixed_expense_id'),
    'amount_cents', '10000',
    'category_id', 'servicios',
    'occurred_on', '2026-03-15',
    'idempotency_key', current_setting('app.fixed_key'),
    'description', 'Pago de luz'
  )));
  if was_reused is distinct from true then raise exception 'Reintento no fue idempotente'; end if;

  select count(*) into transaction_count
  from public.transactions where created_by = 'USER_A_UUID'
    and idempotency_key = current_setting('app.fixed_key')::uuid;
  if transaction_count <> 1 then raise exception 'Reintento duplicó transaction'; end if;
end;
$$;

-- Pago variable: importe real puede diferir del previsto.
with inserted_expense as (
  insert into public.recurring_expenses (space_id, name, planned_amount, due_day, amount_mode)
  values (current_setting('app.personal_space_id')::uuid, 'Luz variable', 100.00, 15, 'variable')
  returning id
)
select set_config('app.variable_expense_id', id::text, true) from inserted_expense;
select set_config('app.variable_key', gen_random_uuid()::text, true);

do $$
declare real_amount numeric(14,2);
begin
  select transaction_record.amount into real_amount
  from public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.variable_expense_id'),
    'amount_cents', '11500',
    'category_id', 'servicios',
    'occurred_on', '2026-03-16',
    'idempotency_key', current_setting('app.variable_key')
  )) as result
  join public.transactions as transaction_record on transaction_record.id = result.transaction_id;
  if real_amount <> 115.00 then raise exception 'Pago variable no conservó importe real'; end if;
end;
$$;

-- SQL NULL, JSON null, valores no-array y arreglo vacío se rechazan sin escribir.
do $$
declare
  transactions_before bigint;
  payments_before bigint;
  scenario text;
  payload jsonb;
  rejected boolean;
begin
  select count(*) into transactions_before
  from public.transactions where created_by = 'USER_A_UUID';
  select count(*) into payments_before
  from public.recurring_expense_payments where linked_by = 'USER_A_UUID';

  foreach scenario in array array['sql-null', 'json-null', 'json-string', 'json-object', 'empty-array'] loop
    payload := case scenario
      when 'sql-null' then null::jsonb
      when 'json-null' then 'null'::jsonb
      when 'json-string' then '"texto"'::jsonb
      when 'json-object' then '{}'::jsonb
      when 'empty-array' then '[]'::jsonb
    end;

    rejected := false;
    begin
      perform public.record_recurring_expense_payments(payload);
    exception when invalid_parameter_value then
      if sqlerrm <> 'payments must be a non-empty JSON array' then
        raise exception 'Validación inesperada para %: %', scenario, sqlerrm;
      end if;
      rejected := true;
    end;

    if not rejected then
      raise exception 'Se aceptó payload inválido: %', scenario;
    end if;
  end loop;

  if (select count(*) from public.transactions where created_by = 'USER_A_UUID') <> transactions_before then
    raise exception 'Payload inválido creó transactions';
  end if;
  if (select count(*) from public.recurring_expense_payments where linked_by = 'USER_A_UUID') <> payments_before then
    raise exception 'Payload inválido creó vínculos';
  end if;
end;
$$;

-- Duplicados dentro del lote y payloads inválidos se rechazan antes de escribir.
do $$
begin
  perform public.record_recurring_expense_payments(jsonb_build_array(
    jsonb_build_object('recurring_expense_id', current_setting('app.variable_expense_id'), 'amount_cents', '11500', 'category_id', 'servicios', 'occurred_on', '2026-04-16', 'idempotency_key', gen_random_uuid()::text),
    jsonb_build_object('recurring_expense_id', current_setting('app.variable_expense_id'), 'amount_cents', '11500', 'category_id', 'servicios', 'occurred_on', '2026-04-16', 'idempotency_key', gen_random_uuid()::text)
  ));
  raise exception 'Lote permitió obligación duplicada';
exception when invalid_parameter_value then raise notice 'OK: obligación duplicada denegada';
end;
$$;

do $$
begin
  perform public.record_recurring_expense_payments(jsonb_build_array(
    jsonb_build_object('recurring_expense_id', current_setting('app.variable_expense_id'), 'amount_cents', '11500', 'category_id', 'servicios', 'occurred_on', '2026-04-16', 'idempotency_key', current_setting('app.variable_key')),
    jsonb_build_object('recurring_expense_id', current_setting('app.fixed_expense_id'), 'amount_cents', '10000', 'category_id', 'servicios', 'occurred_on', '2026-04-16', 'idempotency_key', current_setting('app.variable_key'))
  ));
  raise exception 'Lote permitió clave idempotente duplicada';
exception when invalid_parameter_value then raise notice 'OK: clave duplicada denegada';
end;
$$;

do $$
declare invalid_amount text;
begin
  foreach invalid_amount in array array['100.5', '0', '-1', '100000000000000'] loop
    begin
      perform public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
        'recurring_expense_id', current_setting('app.variable_expense_id'), 'amount_cents', invalid_amount,
        'category_id', 'servicios', 'occurred_on', '2026-04-16', 'idempotency_key', gen_random_uuid()::text
      )));
      raise exception 'Se permitió amount_cents inválido: %', invalid_amount;
    exception when invalid_parameter_value then
      raise notice 'OK: amount_cents inválido denegado: %', invalid_amount;
    end;
  end loop;
end;
$$;

do $$
begin
  perform public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', 'uuid-invalido', 'amount_cents', '11500',
    'category_id', 'servicios', 'occurred_on', '2026-04-16', 'idempotency_key', gen_random_uuid()::text
  )));
  raise exception 'Se permitió UUID inválido';
exception when data_exception then raise notice 'OK: UUID inválido denegado';
end;
$$;

do $$
begin
  perform public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.variable_expense_id'), 'amount_cents', '11500',
    'category_id', 'servicios', 'occurred_on', 'fecha-invalida', 'idempotency_key', gen_random_uuid()::text
  )));
  raise exception 'Se permitió fecha inválida';
exception when data_exception then raise notice 'OK: fecha inválida denegada';
end;
$$;

do $$
begin
  perform public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.variable_expense_id'), 'amount_cents', '11500',
    'category_id', 'categoria_inexistente', 'occurred_on', '2026-04-16', 'idempotency_key', gen_random_uuid()::text
  )));
  raise exception 'Se permitió categoría inexistente';
exception when check_violation then raise notice 'OK: categoría inexistente denegada';
end;
$$;

-- Un lote de dos obligaciones persiste completo o falla completo.
with first_expense as (
  insert into public.recurring_expenses (space_id, name, planned_amount, due_day, amount_mode)
  values (current_setting('app.personal_space_id')::uuid, 'Internet', 80.00, 10, 'fixed')
  returning id
), second_expense as (
  insert into public.recurring_expenses (space_id, name, planned_amount, due_day, amount_mode)
  values (current_setting('app.personal_space_id')::uuid, 'Seguro', 50.00, 20, 'fixed')
  returning id
)
select set_config('app.batch_expense_a', (select id::text from first_expense), true),
       set_config('app.batch_expense_b', (select id::text from second_expense), true);
select set_config('app.batch_key_a', gen_random_uuid()::text, true),
       set_config('app.batch_key_b', gen_random_uuid()::text, true);

do $$
declare result_count bigint;
begin
  select count(*) into result_count
  from public.record_recurring_expense_payments(jsonb_build_array(
    jsonb_build_object('recurring_expense_id', current_setting('app.batch_expense_a'), 'amount_cents', '8000', 'category_id', 'servicios', 'occurred_on', '2026-03-10', 'idempotency_key', current_setting('app.batch_key_a')),
    jsonb_build_object('recurring_expense_id', current_setting('app.batch_expense_b'), 'amount_cents', '5000', 'category_id', 'servicios', 'occurred_on', '2026-03-20', 'idempotency_key', current_setting('app.batch_key_b'))
  ));
  if result_count <> 2 then raise exception 'Lote válido no registró ambos pagos'; end if;
end;
$$;

with rollback_expense_a as (
  insert into public.recurring_expenses (space_id, name, planned_amount, due_day, amount_mode)
  values (current_setting('app.personal_space_id')::uuid, 'Lote rollback A', 10.00, 5, 'fixed')
  returning id
), rollback_expense_b as (
  insert into public.recurring_expenses (space_id, name, planned_amount, due_day, amount_mode)
  values (current_setting('app.personal_space_id')::uuid, 'Lote rollback B', 20.00, 6, 'fixed')
  returning id
)
select set_config('app.rollback_expense_a', (select id::text from rollback_expense_a), true),
       set_config('app.rollback_expense_b', (select id::text from rollback_expense_b), true);
select set_config('app.rollback_key_a', gen_random_uuid()::text, true),
       set_config('app.rollback_key_b', gen_random_uuid()::text, true);

do $$
begin
  perform public.record_recurring_expense_payments(jsonb_build_array(
    jsonb_build_object('recurring_expense_id', current_setting('app.rollback_expense_a'), 'amount_cents', '1000', 'category_id', 'servicios', 'occurred_on', '2026-03-05', 'idempotency_key', current_setting('app.rollback_key_a')),
    jsonb_build_object('recurring_expense_id', current_setting('app.rollback_expense_b'), 'amount_cents', '2000', 'category_id', 'sueldo', 'occurred_on', '2026-03-06', 'idempotency_key', current_setting('app.rollback_key_b'))
  ));
  raise exception 'Lote inválido no falló';
exception when check_violation then
  raise notice 'OK: lote inválido revertido';
end;
$$;

do $$
declare transaction_count bigint;
        payment_count bigint;
begin
  select count(*) into transaction_count from public.transactions
  where created_by = 'USER_A_UUID'
    and idempotency_key in (current_setting('app.rollback_key_a')::uuid, current_setting('app.rollback_key_b')::uuid);
  if transaction_count <> 0 then raise exception 'Lote inválido dejó transactions parciales'; end if;

  select count(*) into payment_count from public.recurring_expense_payments
  where recurring_expense_id in (
    current_setting('app.rollback_expense_a')::uuid,
    current_setting('app.rollback_expense_b')::uuid
  );
  if payment_count <> 0 then raise exception 'Lote inválido dejó vínculos parciales'; end if;
end;
$$;

-- Un importe distinto para obligación fija y un tercero ajeno se rechazan.
with invalid_fixed_expense as (
  insert into public.recurring_expenses (space_id, name, planned_amount, due_day, amount_mode)
  values (current_setting('app.personal_space_id')::uuid, 'Fija inválida', 30.00, 7, 'fixed')
  returning id
)
select set_config('app.invalid_fixed_expense', id::text, true) from invalid_fixed_expense;

do $$
begin
  perform public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.invalid_fixed_expense'),
    'amount_cents', '2900',
    'category_id', 'servicios',
    'occurred_on', '2026-03-07',
    'idempotency_key', gen_random_uuid()::text
  )));
  raise exception 'Se permitió importe distinto en obligación fija';
exception when check_violation then raise notice 'OK: fijo protegido';
end;
$$;

select set_config('app.shared_space_id', public.create_shared_space('Prueba lote recurrente')::text, true);
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
with shared_expense as (
  insert into public.recurring_expenses (space_id, name, planned_amount, due_day, amount_mode)
  values (current_setting('app.shared_space_id')::uuid, 'Alquiler', 1500.00, 1, 'fixed')
  returning id
)
select set_config('app.shared_expense_id', id::text, true) from shared_expense;

-- B, miembro autorizado, registra y vincula un pago compartido creado por la RPC.
select set_config('request.jwt.claim.sub', 'USER_B_UUID', true);
select set_config('app.shared_key', gen_random_uuid()::text, true);
do $$
declare linked_by_id uuid;
begin
  select payment.linked_by into linked_by_id
  from public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.shared_expense_id'),
    'amount_cents', '150000',
    'category_id', 'vivienda',
    'occurred_on', '2026-03-01',
    'idempotency_key', current_setting('app.shared_key')
  )) as result
  join public.recurring_expense_payments as payment on payment.id = result.payment_id;
  if linked_by_id <> 'USER_B_UUID'::uuid then raise exception 'B no fue registrado como quien vinculó el pago'; end if;
end;
$$;

select set_config('request.jwt.claim.sub', 'USER_C_UUID', true);
do $$
begin
  perform public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.shared_expense_id'),
    'amount_cents', '150000',
    'category_id', 'vivienda',
    'occurred_on', '2026-04-01',
    'idempotency_key', gen_random_uuid()::text
  )));
  raise exception 'C pudo registrar pago en espacio ajeno';
exception when insufficient_privilege then raise notice 'OK: tercero denegado';
end;
$$;

rollback;
