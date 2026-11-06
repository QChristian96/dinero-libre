-- Dinero Libre: espacios compartidos mediante RPCs e invitaciones de un solo uso.
-- pgcrypto se usa únicamente para aleatoriedad criptográfica y hashes SHA-256.
create extension if not exists pgcrypto with schema extensions;

create table public.space_invitations (
  id uuid primary key default gen_random_uuid(),
  space_id uuid not null references public.spaces (id) on delete cascade,
  created_by uuid not null references auth.users (id) on delete cascade,
  code_hash bytea not null unique,
  expires_at timestamptz not null,
  used_at timestamptz,
  used_by uuid references auth.users (id) on delete set null,
  created_at timestamptz not null default now(),
  check (expires_at > created_at),
  check ((used_at is null and used_by is null) or (used_at is not null and used_by is not null))
);

create index space_invitations_active_space_idx
  on public.space_invitations (space_id, expires_at)
  where used_at is null;

-- Registro interno de intentos. No contiene códigos ni hashes de códigos.
create table public.space_invite_attempts (
  user_id uuid primary key references auth.users (id) on delete cascade,
  attempts smallint not null default 0 check (attempts >= 0),
  window_started_at timestamptz not null default now(),
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);

revoke all on table public.space_invitations, public.space_invite_attempts
  from public, anon, authenticated;

alter table public.space_invitations enable row level security;
alter table public.space_invite_attempts enable row level security;

-- Crea un espacio compartido y conserva la pertenencia owner en la misma transacción.
create or replace function public.create_shared_space(space_name text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  new_space_id uuid;
  normalized_name text := trim(space_name);
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '42501';
  end if;

  if normalized_name is null or char_length(normalized_name) not between 1 and 80 then
    raise exception 'Space name must contain between 1 and 80 characters' using errcode = '22023';
  end if;

  insert into public.spaces (owner_id, name, kind)
  values (current_user_id, normalized_name, 'shared')
  returning id into new_space_id;

  insert into public.space_members (space_id, user_id, role)
  values (new_space_id, current_user_id, 'owner');

  return new_space_id;
end;
$$;

-- Devuelve el código una única vez. En la tabla solo queda su hash SHA-256.
create or replace function public.create_space_invitation(target_space_id uuid)
returns text
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  invitation_code text;
  random_bytes bytea;
  character_position integer;
  generation_attempt integer;
  alphabet constant text := 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '42501';
  end if;

  -- owner_id es la autoridad exclusiva; no basta con ser miembro.
  perform 1
  from public.spaces
  where id = target_space_id
    and kind = 'shared'
    and owner_id = current_user_id
  for update;

  if not found then
    raise exception 'Only the owner of a shared space can create invitations' using errcode = '42501';
  end if;

  -- Ocho caracteres aleatorios alfanuméricos. El índice unique del hash cubre
  -- la improbable colisión y el bucle vuelve a intentar sin exponerla.
  for generation_attempt in 1..10 loop
    invitation_code := '';
    random_bytes := extensions.gen_random_bytes(8);
    for character_position in 0..7 loop
      invitation_code := invitation_code || substr(
        alphabet,
        (get_byte(random_bytes, character_position) % char_length(alphabet)) + 1,
        1
      );
    end loop;

    begin
      insert into public.space_invitations (space_id, created_by, code_hash, expires_at)
      values (
        target_space_id,
        current_user_id,
        extensions.digest(invitation_code, 'sha256'),
        now() + interval '24 hours'
      );
      return invitation_code;
    exception when unique_violation then
      -- Solo se puede deber al índice único de code_hash; se genera otro código.
      null;
    end;
  end loop;

  raise exception 'Could not generate a unique invitation code' using errcode = 'P0001';
end;
$$;

-- Une al usuario autenticado. Un resultado NULL cubre código inválido, vencido,
-- usado o bloqueo temporal para no revelar el motivo ni la existencia del código.
create or replace function public.join_shared_space(invitation_code text)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  current_user_id uuid := auth.uid();
  attempt_record public.space_invite_attempts%rowtype;
  invitation_record public.space_invitations%rowtype;
  joined_space_id uuid;
begin
  if current_user_id is null then
    raise exception 'Authentication is required' using errcode = '42501';
  end if;

  -- Ventana deslizante: cinco fallos bloquean nuevos intentos durante 15 minutos.
  insert into public.space_invite_attempts (user_id, attempts, window_started_at, locked_until)
  values (current_user_id, 0, now(), null)
  on conflict (user_id) do update
    set attempts = case
          when public.space_invite_attempts.window_started_at <= now() - interval '15 minutes' then 0
          else public.space_invite_attempts.attempts
        end,
        window_started_at = case
          when public.space_invite_attempts.window_started_at <= now() - interval '15 minutes' then now()
          else public.space_invite_attempts.window_started_at
        end,
        locked_until = case
          when public.space_invite_attempts.locked_until <= now() then null
          else public.space_invite_attempts.locked_until
        end,
        updated_at = now()
  returning * into attempt_record;

  if attempt_record.locked_until is not null and attempt_record.locked_until > now() then
    return null;
  end if;

  select * into invitation_record
  from public.space_invitations
  where code_hash = extensions.digest(upper(trim(coalesce(invitation_code, ''))), 'sha256')
    and used_at is null
    and expires_at > now()
  for update;

  if not found then
    update public.space_invite_attempts
    set attempts = attempts + 1,
        locked_until = case when attempts + 1 >= 5 then now() + interval '15 minutes' else null end,
        updated_at = now()
    where user_id = current_user_id;
    return null;
  end if;

  -- Defensa adicional ante datos administrativos inválidos: nunca une a personales.
  select id into joined_space_id
  from public.spaces
  where id = invitation_record.space_id and kind = 'shared';

  if not found then
    return null;
  end if;

  -- Una membresía existente recibe el mismo espacio, pero no consume el código:
  -- así un miembro que lo introduce por error no invalida la invitación destinada
  -- a otra persona. Los códigos inválidos, vencidos o usados siguen devolviendo NULL.
  if exists (
    select 1 from public.space_members
    where space_id = joined_space_id and user_id = current_user_id
  ) then
    delete from public.space_invite_attempts where user_id = current_user_id;
    return joined_space_id;
  end if;

  insert into public.space_members (space_id, user_id, role)
  values (joined_space_id, current_user_id, 'member')
  on conflict (space_id, user_id) do nothing;

  update public.space_invitations
  set used_at = now(), used_by = current_user_id
  where id = invitation_record.id;

  delete from public.space_invite_attempts where user_id = current_user_id;
  return joined_space_id;
end;
$$;

revoke all on function public.create_shared_space(text) from public, anon, authenticated;
revoke all on function public.create_space_invitation(uuid) from public, anon, authenticated;
revoke all on function public.join_shared_space(text) from public, anon, authenticated;

grant execute on function public.create_shared_space(text) to authenticated;
grant execute on function public.create_space_invitation(uuid) to authenticated;
grant execute on function public.join_shared_space(text) to authenticated;
