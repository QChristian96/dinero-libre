-- Dinero Libre: obligaciones recurrentes y vínculos explícitos a pagos reales.
-- Esta migración no crea transactions automáticamente ni usa cron jobs.

create table public.recurring_expenses (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces (id) on delete cascade,
  name text not null check (char_length(trim(name)) between 1 and 120),
  planned_amount numeric(14,2) not null check (planned_amount > 0),
  due_day smallint not null check (due_day between 1 and 31),
  is_active boolean not null default true,
  created_by uuid not null references auth.users (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.recurring_expense_payments (
  id uuid primary key default gen_random_uuid(),
  recurring_expense_id uuid not null references public.recurring_expenses (id) on delete restrict,
  year integer not null check (year between 2020 and 2100),
  month smallint not null check (month between 1 and 12),
  transaction_id uuid not null unique references public.transactions (id) on delete restrict,
  linked_by uuid not null references auth.users (id) on delete restrict,
  linked_at timestamptz not null default now(),
  unique (recurring_expense_id, year, month)
);

create index recurring_expenses_space_active_idx
  on public.recurring_expenses (space_id, is_active, due_day);
create index recurring_expense_payments_expense_period_idx
  on public.recurring_expense_payments (recurring_expense_id, year, month);

revoke all on table public.recurring_expenses, public.recurring_expense_payments
  from public, anon, authenticated;
grant select, insert, update, delete on table public.recurring_expenses to authenticated;
grant select, insert, delete on table public.recurring_expense_payments to authenticated;

alter table public.recurring_expenses enable row level security;
alter table public.recurring_expense_payments enable row level security;

-- Día efectivo: el 29/30/31 se ajusta al último día si el mes es más corto.
create or replace function public.recurring_due_date(target_year integer, target_month smallint, target_day smallint)
returns date
language sql
immutable
set search_path = ''
as $$
  select make_date(
    target_year,
    target_month,
    least(
      target_day::integer,
      extract(day from (make_date(target_year, target_month, 1) + interval '1 month - 1 day'))::integer
    )
  );
$$;

revoke all on function public.recurring_due_date(integer, smallint, smallint) from public, anon, authenticated;
grant execute on function public.recurring_due_date(integer, smallint, smallint) to authenticated;

create or replace function public.prepare_recurring_expense()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if auth.uid() is null then
      raise exception 'Authentication is required' using errcode = '42501';
    end if;
    new.created_by := auth.uid();
  else
    if new.id is distinct from old.id then
      raise exception 'The recurring expense identifier cannot be changed' using errcode = '42501';
    end if;
    if new.space_id is distinct from old.space_id then
      raise exception 'The recurring expense space cannot be changed' using errcode = '42501';
    end if;
    if new.created_by is distinct from old.created_by then
      raise exception 'The recurring expense author cannot be changed' using errcode = '42501';
    end if;
    if new.created_at is distinct from old.created_at then
      raise exception 'The recurring expense creation time cannot be changed' using errcode = '42501';
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.prepare_recurring_expense_payment()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  expense_space_id uuid;
  payment_space_id uuid;
  payment_type text;
  payment_date date;
begin
  if tg_op = 'UPDATE' then
    raise exception 'Recurring expense payments are immutable' using errcode = '42501';
  end if;

  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '42501';
  end if;

  new.linked_by := current_user_id;
  new.linked_at := now();

  -- SECURITY DEFINER permite bloquear una transaction creada por otro miembro,
  -- pero la autorización se comprueba explícitamente con el usuario de JWT.
  select space_id into expense_space_id
  from public.recurring_expenses
  where id = new.recurring_expense_id;
  if not found or not exists (
    select 1
    from public.space_members as membership
    where membership.space_id = expense_space_id
      and membership.user_id = current_user_id
  ) then
    raise exception 'Recurring expense not found or not authorized' using errcode = '42501';
  end if;

  -- Se bloquea la fila bajo privilegios del propietario de la función. Esto
  -- serializa el vínculo frente a UPDATE/DELETE y evita que RLS de autoría de
  -- transactions impida a otro miembro vincular un gasto compartido.
  select space_id, transaction_type, occurred_on
  into payment_space_id, payment_type, payment_date
  from public.transactions
  where id = new.transaction_id
  for update;
  if not found then
    raise exception 'Transaction not found or not authorized' using errcode = '42501';
  end if;

  -- Revalidación tras adquirir el bloqueo: si la membresía cambió mientras se
  -- esperaba la fila, no se puede crear el vínculo.
  if not exists (
    select 1
    from public.space_members as membership
    where membership.space_id = expense_space_id
      and membership.user_id = current_user_id
  ) then
    raise exception 'Membership is no longer authorized' using errcode = '42501';
  end if;

  if payment_type <> 'expense'
    or payment_space_id <> expense_space_id
    or extract(year from payment_date)::integer <> new.year
    or extract(month from payment_date)::smallint <> new.month then
    raise exception 'The payment transaction must be an expense from the same space and period' using errcode = '23514';
  end if;

  return new;
end;
$$;

-- Una transacción ya vinculada conserva tipo expense y el mismo período del
-- pago. El vínculo debe eliminarse explícitamente antes de cambiar esos campos.
-- No usa SECURITY DEFINER: el autor que puede UPDATE la transacción solo puede
-- consultar vínculos del mismo espacio mediante las políticas existentes.
create or replace function public.protect_linked_payment_transaction()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.recurring_expense_payments as payment
    where payment.transaction_id = new.id
      and (
        new.transaction_type <> 'expense'
        or payment.year <> extract(year from new.occurred_on)::integer
        or payment.month <> extract(month from new.occurred_on)::smallint
      )
  ) then
    raise exception 'Unlink the recurring payment before changing its type or period' using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function public.prepare_recurring_expense() from public, anon, authenticated;
revoke all on function public.prepare_recurring_expense_payment() from public, anon, authenticated;
revoke all on function public.protect_linked_payment_transaction() from public, anon, authenticated;

create trigger before_write_recurring_expense
  before insert or update on public.recurring_expenses
  for each row execute procedure public.prepare_recurring_expense();

create trigger before_write_recurring_expense_payment
  before insert or update on public.recurring_expense_payments
  for each row execute procedure public.prepare_recurring_expense_payment();

create trigger after_change_linked_payment_transaction
  after update of transaction_type, occurred_on on public.transactions
  for each row execute procedure public.protect_linked_payment_transaction();

create policy "Space members can read recurring expenses"
  on public.recurring_expenses for select
  to authenticated
  using ((select public.is_space_member(space_id)));

create policy "Space members can create recurring expenses"
  on public.recurring_expenses for insert
  to authenticated
  with check (
    (select public.is_space_member(space_id))
    and created_by = (select auth.uid())
  );

create policy "Space members can update recurring expenses"
  on public.recurring_expenses for update
  to authenticated
  using ((select public.is_space_member(space_id)))
  with check ((select public.is_space_member(space_id)));

create policy "Space members can delete recurring expenses"
  on public.recurring_expenses for delete
  to authenticated
  using ((select public.is_space_member(space_id)));

-- La comprobación de membresía se deriva del espacio de la obligación. La
-- política de recurring_expenses usa is_space_member(), no esta tabla, por lo
-- que no existe recursión RLS.
create policy "Space members can read recurring expense payments"
  on public.recurring_expense_payments for select
  to authenticated
  using (
    exists (
      select 1 from public.recurring_expenses as expense
      where expense.id = recurring_expense_id
        and (select public.is_space_member(expense.space_id))
    )
  );

create policy "Space members can link recurring expense payments"
  on public.recurring_expense_payments for insert
  to authenticated
  with check (
    exists (
      select 1 from public.recurring_expenses as expense
      where expense.id = recurring_expense_id
        and (select public.is_space_member(expense.space_id))
    )
  );

create policy "Space members can unlink recurring expense payments"
  on public.recurring_expense_payments for delete
  to authenticated
  using (
    exists (
      select 1 from public.recurring_expenses as expense
      where expense.id = recurring_expense_id
        and (select public.is_space_member(expense.space_id))
    )
  );

-- Estados del mes actual, derivados al consultar; no se almacenan ni requieren cron.
create view public.recurring_expense_current_status
with (security_invoker = true)
as
with peru_today as (
  select timezone('America/Lima', now())::date as value
)
select
  expense.id as recurring_expense_id,
  expense.space_id,
  extract(year from peru_today.value)::integer as year,
  extract(month from peru_today.value)::smallint as month,
  public.recurring_due_date(
    extract(year from peru_today.value)::integer,
    extract(month from peru_today.value)::smallint,
    expense.due_day
  ) as due_date,
  case
    when payment.id is not null then 'pagado'
    when public.recurring_due_date(
      extract(year from peru_today.value)::integer,
      extract(month from peru_today.value)::smallint,
      expense.due_day
    ) < peru_today.value then 'vencido'
    else 'pendiente'
  end as status
from public.recurring_expenses as expense
cross join peru_today
left join public.recurring_expense_payments as payment
  on payment.recurring_expense_id = expense.id
  and payment.year = extract(year from peru_today.value)::integer
  and payment.month = extract(month from peru_today.value)::smallint
where expense.is_active;

revoke all on table public.recurring_expense_current_status from public, anon, authenticated;
grant select on table public.recurring_expense_current_status to authenticated;
