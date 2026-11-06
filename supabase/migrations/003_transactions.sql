-- Dinero Libre: catálogo común y movimientos financieros por espacio.

create table public.categories (
  id text primary key,
  name text not null unique,
  transaction_type text not null check (transaction_type in ('income', 'expense')),
  created_at timestamptz not null default now(),
  check (id ~ '^[a-z0-9_]+$')
);

insert into public.categories (id, name, transaction_type) values
  ('alimentacion', 'Alimentación', 'expense'),
  ('transporte', 'Transporte', 'expense'),
  ('vivienda', 'Vivienda', 'expense'),
  ('servicios', 'Servicios', 'expense'),
  ('salud', 'Salud', 'expense'),
  ('educacion', 'Educación', 'expense'),
  ('entretenimiento', 'Entretenimiento', 'expense'),
  ('compras', 'Compras', 'expense'),
  ('otros_gastos', 'Otros gastos', 'expense'),
  ('sueldo', 'Sueldo', 'income'),
  ('trabajo_independiente', 'Trabajo independiente', 'income'),
  ('ventas', 'Ventas', 'income'),
  ('otros_ingresos', 'Otros ingresos', 'income');

create table public.transactions (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces (id) on delete cascade,
  created_by uuid not null references auth.users (id) on delete restrict,
  transaction_type text not null check (transaction_type in ('income', 'expense')),
  amount numeric(14,2) not null check (amount > 0),
  category_id text not null references public.categories (id) on delete restrict,
  description text check (description is null or char_length(trim(description)) <= 500),
  occurred_on date not null default current_date,
  idempotency_key uuid not null,
  created_at timestamptz not null default now(),
  -- El frontend debe crear con INSERT. No use UPSERT para sobrescribir un
  -- movimiento existente: la clave solo evita duplicados accidentales por autor.
  unique (created_by, idempotency_key)
);

create index transactions_space_occurred_on_idx
  on public.transactions (space_id, occurred_on desc, created_at desc);
create index transactions_space_category_idx
  on public.transactions (space_id, category_id, occurred_on desc);
create index transactions_category_id_idx on public.transactions (category_id);

revoke all on table public.categories, public.transactions from public, anon, authenticated;
grant select on table public.categories to authenticated;
grant select, insert, update, delete on table public.transactions to authenticated;

alter table public.categories enable row level security;
alter table public.transactions enable row level security;

-- El catálogo es común y solo se expone para lectura a usuarios autenticados.
create policy "Authenticated users can read categories"
  on public.categories for select
  to authenticated
  using ((select auth.uid()) is not null);

-- No se usa SECURITY DEFINER: el trigger corre como invocador y la categoría es
-- legible por authenticated. El autor siempre se reemplaza por auth.uid().
create or replace function public.prepare_transaction()
returns trigger
language plpgsql
set search_path = ''
as $$
declare
  category_transaction_type text;
begin
  if tg_op = 'INSERT' then
    if auth.uid() is null then
      raise exception 'Authentication is required' using errcode = '42501';
    end if;
    new.created_by := auth.uid();
  else
    if new.created_by is distinct from old.created_by then
      raise exception 'The transaction author cannot be changed' using errcode = '42501';
    end if;
    if new.space_id is distinct from old.space_id then
      raise exception 'The transaction space cannot be changed' using errcode = '42501';
    end if;
    if new.id is distinct from old.id then
      raise exception 'The transaction identifier cannot be changed' using errcode = '42501';
    end if;
    if new.created_at is distinct from old.created_at then
      raise exception 'The transaction creation time cannot be changed' using errcode = '42501';
    end if;
    if new.idempotency_key is distinct from old.idempotency_key then
      raise exception 'The transaction idempotency key cannot be changed' using errcode = '42501';
    end if;
  end if;

  select transaction_type into category_transaction_type
  from public.categories
  where id = new.category_id;

  if not found or category_transaction_type <> new.transaction_type then
    raise exception 'The category does not match the transaction type' using errcode = '23514';
  end if;

  return new;
end;
$$;

revoke all on function public.prepare_transaction() from public, anon, authenticated;

create trigger before_write_transaction
  before insert or update on public.transactions
  for each row execute procedure public.prepare_transaction();

create policy "Space members can read transactions"
  on public.transactions for select
  to authenticated
  using ((select public.is_space_member(space_id)));

create policy "Space members can create transactions as themselves"
  on public.transactions for insert
  to authenticated
  with check (
    (select public.is_space_member(space_id))
    and created_by = (select auth.uid())
  );

create policy "Authors can update their authorized transactions"
  on public.transactions for update
  to authenticated
  using (
    created_by = (select auth.uid())
    and (select public.is_space_member(space_id))
  )
  with check (
    created_by = (select auth.uid())
    and (select public.is_space_member(space_id))
  );

create policy "Authors can delete their authorized transactions"
  on public.transactions for delete
  to authenticated
  using (
    created_by = (select auth.uid())
    and (select public.is_space_member(space_id))
  );
