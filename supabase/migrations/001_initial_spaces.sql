-- Dinero Libre: perfiles, espacios y membresías iniciales.
-- Esta migración no crea movimientos, presupuestos ni mecanismos de invitación.

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  email text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create table public.spaces (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references auth.users (id) on delete cascade,
  name text not null check (char_length(trim(name)) between 1 and 80),
  kind text not null check (kind in ('personal', 'shared')),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

-- Un usuario puede tener muchos espacios compartidos, pero solo un espacio personal.
create unique index spaces_one_personal_space_per_owner
  on public.spaces (owner_id)
  where kind = 'personal';

create index spaces_owner_id_idx on public.spaces (owner_id);

create table public.space_members (
  space_id uuid not null references public.spaces (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role text not null default 'member' check (role in ('owner', 'member')),
  created_at timestamptz not null default now(),
  primary key (space_id, user_id)
);

create index space_members_user_id_idx on public.space_members (user_id);

revoke all on table public.profiles, public.spaces, public.space_members from public, anon, authenticated;
grant select on table public.profiles, public.spaces, public.space_members to authenticated;

alter table public.profiles enable row level security;
alter table public.spaces enable row level security;
alter table public.space_members enable row level security;

-- Consulta de membresía aislada de RLS para que las políticas no se llamen entre sí.
-- Solo authenticated puede ejecutarla porque las políticas dependen de ella.
create or replace function public.is_space_member(target_space_id uuid)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select exists (
    select 1
    from public.space_members as membership
    where membership.space_id = target_space_id
      and membership.user_id = auth.uid()
  );
$$;

revoke all on function public.is_space_member(uuid) from public, anon, authenticated;
grant execute on function public.is_space_member(uuid) to authenticated;

create policy "Users can read their own profile"
  on public.profiles for select
  to authenticated
  using ((select auth.uid()) = id);

create policy "Members can read their spaces"
  on public.spaces for select
  to authenticated
  using (
    owner_id = (select auth.uid())
    or (select public.is_space_member(id))
  );

create policy "Members can read members of their spaces"
  on public.space_members for select
  to authenticated
  using (
    user_id = (select auth.uid())
    or (select public.is_space_member(space_id))
  );

-- Intencionalmente no hay políticas INSERT, UPDATE ni DELETE para clientes.
-- Así se bloquean altas arbitrarias, cambios de owner y elevación de roles hasta
-- que exista un flujo de invitaciones/revocación expresamente autorizado.

create or replace function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  personal_space_id uuid;
begin
  insert into public.profiles (id, email)
  values (new.id, coalesce(new.email, ''))
  on conflict (id) do update
    set email = excluded.email,
        updated_at = now();

  -- El índice parcial garantiza la unicidad incluso ante ejecuciones concurrentes.
  select id into personal_space_id
  from public.spaces
  where owner_id = new.id and kind = 'personal';

  if personal_space_id is null then
    begin
      insert into public.spaces (owner_id, name, kind)
      values (new.id, 'Espacio personal', 'personal')
      returning id into personal_space_id;
    exception when unique_violation then
      select id into personal_space_id
      from public.spaces
      where owner_id = new.id and kind = 'personal';
    end;
  end if;

  insert into public.space_members (space_id, user_id, role)
  values (personal_space_id, new.id, 'owner')
  on conflict (space_id, user_id) do nothing;

  return new;
end;
$$;

-- El trigger puede invocar la función sin conceder EXECUTE a roles de aplicación.
revoke all on function public.handle_new_user() from public, anon, authenticated;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute procedure public.handle_new_user();

-- El trigger se ejecuta al INSERT de auth.users (alta inicial), no al confirmar
-- el correo. La confirmación de email no vuelve a crear perfil ni espacio.

-- Procedimiento administrativo, seguro e idempotente para usuarios existentes.
-- No se ejecuta automáticamente: ejecútelo una vez desde SQL Editor como postgres.
create or replace function public.bootstrap_existing_users()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.profiles (id, email)
  select user_record.id, coalesce(user_record.email, '')
  from auth.users as user_record
  on conflict (id) do update
    set email = excluded.email,
        updated_at = now();

  insert into public.spaces (owner_id, name, kind)
  select user_record.id, 'Espacio personal', 'personal'
  from auth.users as user_record
  where not exists (
    select 1
    from public.spaces as space_record
    where space_record.owner_id = user_record.id
      and space_record.kind = 'personal'
  )
  on conflict do nothing;

  insert into public.space_members (space_id, user_id, role)
  select space_record.id, space_record.owner_id, 'owner'
  from public.spaces as space_record
  where space_record.kind = 'personal'
  on conflict (space_id, user_id) do nothing;
end;
$$;

-- SECURITY DEFINER usa el rol propietario de la función, por ello current_user
-- no identifica al invocador. La autorización se aplica mediante EXECUTE.
revoke all on function public.bootstrap_existing_users() from public, anon, authenticated;
grant execute on function public.bootstrap_existing_users() to postgres, supabase_admin, service_role;
