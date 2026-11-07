-- Prueba de regresión manual para
-- 008_fix_recurring_expense_payment_flow_ambiguity.sql.
--
-- Reproduce el caso reportado: obligación variable con previsto S/100.00 e
-- importe real S/115.00. Si la función vuelve a tener una referencia ambigua,
-- la primera llamada falla con SQLSTATE 42702 y esta prueba se detiene.
--
-- Ejecute como postgres tras reemplazar USER_A_UUID por un usuario de prueba.
-- Todo termina en ROLLBACK; no deja datos.

begin;

select public.bootstrap_existing_users();

set local role authenticated;
select set_config('request.jwt.claim.sub', 'USER_A_UUID', true);
select set_config('app.personal_space_id', id::text, true)
from public.spaces where owner_id = 'USER_A_UUID' and kind = 'personal';

with inserted_expense as (
  insert into public.recurring_expenses (space_id, name, planned_amount, due_day, amount_mode)
  values (current_setting('app.personal_space_id')::uuid, 'Regresión ambigüedad', 100.00, 15, 'variable')
  returning id
)
select set_config('app.regression_expense_id', id::text, true) from inserted_expense;

select set_config('app.regression_key', gen_random_uuid()::text, true);

do $$
declare
  first_result record;
  retry_result record;
  transaction_amount numeric(14,2);
  transaction_count bigint;
  payment_count bigint;
begin
  -- Camino nuevo: debe devolver las cuatro columnas del contrato sin 42702.
  select * into first_result
  from public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.regression_expense_id'),
    'amount_cents', '11500',
    'category_id', 'servicios',
    'occurred_on', '2026-03-15',
    'idempotency_key', current_setting('app.regression_key')
  )));

  if first_result.recurring_expense_id is distinct from current_setting('app.regression_expense_id')::uuid then
    raise exception 'La RPC devolvió recurring_expense_id incorrecto';
  end if;
  if first_result.transaction_id is null then
    raise exception 'La RPC no devolvió transaction_id';
  end if;
  if first_result.payment_id is null then
    raise exception 'La RPC no devolvió payment_id';
  end if;
  if first_result.reused is distinct from false then
    raise exception 'La RPC marcó reused incorrectamente en el primer pago';
  end if;

  select transaction_record.amount into transaction_amount
  from public.transactions as transaction_record
  where transaction_record.id = first_result.transaction_id;

  if transaction_amount is distinct from 115.00::numeric then
    raise exception 'La RPC no conservó el importe real de S/115.00';
  end if;

  select count(*) into payment_count
  from public.recurring_expense_payments as payment
  where payment.id = first_result.payment_id
    and payment.recurring_expense_id = first_result.recurring_expense_id
    and payment.transaction_id = first_result.transaction_id
    and payment.year = 2026
    and payment.month = 3;

  if payment_count <> 1 then
    raise exception 'El pago no quedó vinculado correctamente a la transacción';
  end if;

  -- Camino idempotente: misma clave, mismos IDs y reused = true.
  select * into retry_result
  from public.record_recurring_expense_payments(jsonb_build_array(jsonb_build_object(
    'recurring_expense_id', current_setting('app.regression_expense_id'),
    'amount_cents', '11500',
    'category_id', 'servicios',
    'occurred_on', '2026-03-15',
    'idempotency_key', current_setting('app.regression_key')
  )));

  if retry_result.reused is distinct from true then
    raise exception 'El reintento no fue idempotente';
  end if;
  if retry_result.recurring_expense_id is distinct from first_result.recurring_expense_id
    or retry_result.transaction_id is distinct from first_result.transaction_id
    or retry_result.payment_id is distinct from first_result.payment_id then
    raise exception 'El reintento no devolvió los mismos identificadores';
  end if;

  select count(*) into transaction_count
  from public.transactions as transaction_record
  where transaction_record.created_by = 'USER_A_UUID'
    and transaction_record.idempotency_key = current_setting('app.regression_key')::uuid;
  if transaction_count <> 1 then
    raise exception 'El reintento duplicó la transacción';
  end if;

  select count(*) into payment_count
  from public.recurring_expense_payments as payment
  where payment.recurring_expense_id = current_setting('app.regression_expense_id')::uuid
    and payment.year = 2026
    and payment.month = 3;
  if payment_count <> 1 then
    raise exception 'El reintento duplicó el vínculo del pago';
  end if;
end;
$$;

rollback;
