-- Dinero Libre: reservas mensuales de ahorro por espacio.
-- Una reserva no crea ni modifica transactions, budgets ni recurring_expenses.

create table public.monthly_savings (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces (id) on delete cascade,
  year integer not null check (year between 2020 and 2100),
  month smallint not null check (month between 1 and 12),
  amount numeric(14,2) not null check (amount > 0),
  created_by uuid not null references auth.users (id) on delete restrict,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (space_id, year, month)
);

create index monthly_savings_space_updated_idx
  on public.monthly_savings (space_id, updated_at desc);

revoke all on table public.monthly_savings from public, anon, authenticated;
grant select, insert, update, delete on table public.monthly_savings to authenticated;

alter table public.monthly_savings enable row level security;

-- UPDATE permite modificar únicamente amount. El trigger controla updated_at y
-- asigna created_by desde auth.uid() al crear, sin confiar en el cliente.
create or replace function public.prepare_monthly_saving()
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
    new.created_at := now();
  else
    if new.id is distinct from old.id then
      raise exception 'The saving identifier cannot be changed' using errcode = '42501';
    end if;
    if new.space_id is distinct from old.space_id then
      raise exception 'The saving space cannot be changed' using errcode = '42501';
    end if;
    if new.year is distinct from old.year or new.month is distinct from old.month then
      raise exception 'The saving period cannot be changed' using errcode = '42501';
    end if;
    if new.created_by is distinct from old.created_by then
      raise exception 'The saving author cannot be changed' using errcode = '42501';
    end if;
    if new.created_at is distinct from old.created_at then
      raise exception 'The saving creation time cannot be changed' using errcode = '42501';
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.prepare_monthly_saving() from public, anon, authenticated;

create trigger before_write_monthly_saving
  before insert or update on public.monthly_savings
  for each row execute procedure public.prepare_monthly_saving();

create policy "Space members can read monthly savings"
  on public.monthly_savings for select
  to authenticated
  using ((select public.is_space_member(space_id)));

create policy "Space members can create monthly savings as themselves"
  on public.monthly_savings for insert
  to authenticated
  with check (
    (select public.is_space_member(space_id))
    and created_by = (select auth.uid())
  );

create policy "Space members can update monthly savings"
  on public.monthly_savings for update
  to authenticated
  using ((select public.is_space_member(space_id)))
  with check ((select public.is_space_member(space_id)));

create policy "Space members can delete monthly savings"
  on public.monthly_savings for delete
  to authenticated
  using ((select public.is_space_member(space_id)));
