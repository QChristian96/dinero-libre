-- Dinero Libre: presupuestos mensuales globales por espacio.
-- Configurar un presupuesto no crea movimientos financieros.

create table public.budgets (
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

create index budgets_space_updated_idx on public.budgets (space_id, updated_at desc);

revoke all on table public.budgets from public, anon, authenticated;
grant select, insert, update, delete on table public.budgets to authenticated;

alter table public.budgets enable row level security;

-- El trigger corre como invocador. No se requiere SECURITY DEFINER: la RLS
-- posterior verifica que auth.uid() siga siendo miembro del espacio.
create or replace function public.prepare_budget()
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
      raise exception 'The budget identifier cannot be changed' using errcode = '42501';
    end if;
    if new.space_id is distinct from old.space_id then
      raise exception 'The budget space cannot be changed' using errcode = '42501';
    end if;
    if new.created_by is distinct from old.created_by then
      raise exception 'The budget author cannot be changed' using errcode = '42501';
    end if;
    if new.created_at is distinct from old.created_at then
      raise exception 'The budget creation time cannot be changed' using errcode = '42501';
    end if;
  end if;

  new.updated_at := now();
  return new;
end;
$$;

revoke all on function public.prepare_budget() from public, anon, authenticated;

create trigger before_write_budget
  before insert or update on public.budgets
  for each row execute procedure public.prepare_budget();

create policy "Space members can read budgets"
  on public.budgets for select
  to authenticated
  using ((select public.is_space_member(space_id)));

create policy "Space members can create budgets as themselves"
  on public.budgets for insert
  to authenticated
  with check (
    (select public.is_space_member(space_id))
    and created_by = (select auth.uid())
  );

create policy "Space members can update budgets"
  on public.budgets for update
  to authenticated
  using ((select public.is_space_member(space_id)))
  with check ((select public.is_space_member(space_id)));

create policy "Space members can delete budgets"
  on public.budgets for delete
  to authenticated
  using ((select public.is_space_member(space_id)));
