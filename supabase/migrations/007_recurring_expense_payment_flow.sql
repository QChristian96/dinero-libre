-- Dinero Libre: registro atómico de pagos de obligaciones recurrentes.
-- No altera el flujo existente de vincular un gasto ya registrado.

alter table public.recurring_expenses
  add column amount_mode text not null default 'fixed'
  check (amount_mode in ('fixed', 'variable'));

-- Recibe un arreglo JSON de pagos:
-- [{ recurring_expense_id, amount_cents, category_id, occurred_on,
--    idempotency_key, description? }].
-- amount_cents siempre es un entero de céntimos; nunca un importe decimal.
create or replace function public.record_recurring_expense_payments(p_payments jsonb)
returns table (
  recurring_expense_id uuid,
  transaction_id uuid,
  payment_id uuid,
  reused boolean
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  payment_item jsonb;
  input_expense_id uuid;
  input_category_id text;
  input_occurred_on date;
  input_idempotency_key uuid;
  input_description text;
  input_amount_cents bigint;
  input_amount_cents_text text;
  input_amount numeric(14,2);
  payment_year integer;
  payment_month smallint;
  expense_record public.recurring_expenses%rowtype;
  existing_payment_id uuid;
  existing_payment_transaction_id uuid;
  existing_transaction_payment_id uuid;
  existing_transaction_payment_expense_id uuid;
  existing_transaction_payment_year integer;
  existing_transaction_payment_month smallint;
  existing_transaction_id uuid;
  existing_transaction_space_id uuid;
  existing_transaction_type text;
  existing_transaction_amount numeric(14,2);
  existing_transaction_category_id text;
  existing_transaction_description text;
  existing_transaction_date date;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '42501';
  end if;

  -- SQL NULL no entra en jsonb_typeof y JSON null tampoco es un arreglo.
  -- La longitud se valida por separado para no aplicarla a valores no-array.
  if p_payments is null or jsonb_typeof(p_payments) is distinct from 'array' then
    raise exception 'payments must be a non-empty JSON array' using errcode = '22023';
  end if;

  if jsonb_array_length(p_payments) = 0 then
    raise exception 'payments must be a non-empty JSON array' using errcode = '22023';
  end if;

  if exists (
    select 1
    from (
      select nullif(item.value ->> 'recurring_expense_id', '')::uuid as recurring_expense_id
      from jsonb_array_elements(p_payments) as item(value)
    ) as items
    group by recurring_expense_id
    having count(*) > 1
  ) then
    raise exception 'An obligation can only be paid once per batch' using errcode = '22023';
  end if;

  if exists (
    select 1
    from (
      select nullif(item.value ->> 'idempotency_key', '')::uuid as idempotency_key
      from jsonb_array_elements(p_payments) as item(value)
    ) as items
    group by idempotency_key
    having count(*) > 1
  ) then
    raise exception 'Each payment requires a unique idempotency key' using errcode = '22023';
  end if;

  -- Todas las obligaciones autorizadas se bloquean antes de procesar el lote y
  -- siempre en orden UUID. La respuesta se identifica por recurring_expense_id;
  -- el contrato no depende de un orden posicional de filas.
  perform expense.id
  from public.recurring_expenses as expense
  join public.space_members as membership
    on membership.space_id = expense.space_id
   and membership.user_id = current_user_id
  join (
    select nullif(item.value ->> 'recurring_expense_id', '')::uuid as recurring_expense_id
    from jsonb_array_elements(p_payments) as item(value)
  ) as input on input.recurring_expense_id = expense.id
  order by expense.id
  for update of expense;

  for payment_item in select item.value from jsonb_array_elements(p_payments) as item(value)
  loop
    if jsonb_typeof(payment_item) <> 'object' then
      raise exception 'Each payment must be a JSON object' using errcode = '22023';
    end if;

    input_amount_cents_text := payment_item ->> 'amount_cents';
    if coalesce(input_amount_cents_text, '') !~ '^[0-9]+$' then
      raise exception 'amount_cents must be a positive integer' using errcode = '22023';
    end if;

    input_expense_id := nullif(payment_item ->> 'recurring_expense_id', '')::uuid;
    input_category_id := nullif(payment_item ->> 'category_id', '');
    input_occurred_on := nullif(payment_item ->> 'occurred_on', '')::date;
    input_idempotency_key := nullif(payment_item ->> 'idempotency_key', '')::uuid;
    input_description := nullif(trim(coalesce(payment_item ->> 'description', '')), '');
    input_amount_cents := input_amount_cents_text::bigint;

    if input_expense_id is null or input_category_id is null
      or input_occurred_on is null or input_idempotency_key is null
      or input_amount_cents < 1 or input_amount_cents > 99999999999999 then
      raise exception 'Payment payload is incomplete or amount is out of range' using errcode = '22023';
    end if;

    input_amount := input_amount_cents::numeric / 100;
    payment_year := extract(year from input_occurred_on)::integer;
    payment_month := extract(month from input_occurred_on)::smallint;

    -- El bloqueo se adquirió para todo el lote en orden determinista.
    select expense.* into expense_record
    from public.recurring_expenses as expense
    where expense.id = input_expense_id;

    if not found then
      raise exception 'Recurring expense does not exist' using errcode = '23514';
    end if;

    if not exists (
      select 1
      from public.space_members as membership
      where membership.space_id = expense_record.space_id
        and membership.user_id = current_user_id
    ) then
      raise exception 'Not authorized for this recurring expense' using errcode = '42501';
    end if;

    select transaction_record.id,
           transaction_record.space_id,
           transaction_record.transaction_type,
           transaction_record.amount,
           transaction_record.category_id,
           transaction_record.description,
           transaction_record.occurred_on
    into existing_transaction_id,
         existing_transaction_space_id,
         existing_transaction_type,
         existing_transaction_amount,
         existing_transaction_category_id,
         existing_transaction_description,
         existing_transaction_date
    from public.transactions as transaction_record
    where transaction_record.created_by = current_user_id
      and transaction_record.idempotency_key = input_idempotency_key
    for update;

    if found then
      select payment.id,
             payment.recurring_expense_id,
             payment.year,
             payment.month
      into existing_transaction_payment_id,
           existing_transaction_payment_expense_id,
           existing_transaction_payment_year,
           existing_transaction_payment_month
      from public.recurring_expense_payments as payment
      where payment.transaction_id = existing_transaction_id
      for update;

      if existing_transaction_payment_id is null
        or existing_transaction_payment_expense_id <> input_expense_id
        or existing_transaction_payment_year <> payment_year
        or existing_transaction_payment_month <> payment_month
        or existing_transaction_space_id <> expense_record.space_id
        or existing_transaction_type <> 'expense'
        or existing_transaction_amount <> input_amount
        or existing_transaction_category_id <> input_category_id
        or existing_transaction_description is distinct from input_description
        or existing_transaction_date <> input_occurred_on then
        raise exception 'Idempotency key conflicts with an existing transaction' using errcode = '23505';
      end if;

      recurring_expense_id := input_expense_id;
      transaction_id := existing_transaction_id;
      payment_id := existing_transaction_payment_id;
      reused := true;
      return next;
      continue;
    end if;

    -- Solo los pagos nuevos dependen del estado y configuración actuales.
    if not expense_record.is_active then
      raise exception 'Recurring expense is not active' using errcode = '23514';
    end if;

    if expense_record.amount_mode = 'fixed'
      and input_amount_cents <> (expense_record.planned_amount * 100)::bigint then
      raise exception 'Fixed recurring expense amount must match its planned amount' using errcode = '23514';
    end if;

    if not exists (
      select 1
      from public.categories as category
      where category.id = input_category_id
        and category.transaction_type = 'expense'
    ) then
      raise exception 'Payment category must be an expense category' using errcode = '23514';
    end if;

    select payment.id, payment.transaction_id
    into existing_payment_id, existing_payment_transaction_id
    from public.recurring_expense_payments as payment
    where payment.recurring_expense_id = input_expense_id
      and payment.year = payment_year
      and payment.month = payment_month
    for update;

    if existing_payment_id is not null then
      raise exception 'Recurring expense is already paid for this period' using errcode = '23505';
    end if;

    insert into public.transactions (
      space_id,
      transaction_type,
      amount,
      category_id,
      description,
      occurred_on,
      idempotency_key
    ) values (
      expense_record.space_id,
      'expense',
      input_amount,
      input_category_id,
      input_description,
      input_occurred_on,
      input_idempotency_key
    )
    returning id into transaction_id;

    insert into public.recurring_expense_payments (
      recurring_expense_id,
      year,
      month,
      transaction_id
    ) values (
      input_expense_id,
      payment_year,
      payment_month,
      transaction_id
    )
    returning id into payment_id;

    recurring_expense_id := input_expense_id;
    reused := false;
    return next;
  end loop;
end;
$$;

revoke all on function public.record_recurring_expense_payments(jsonb) from public, anon, authenticated;
grant execute on function public.record_recurring_expense_payments(jsonb) to authenticated;
