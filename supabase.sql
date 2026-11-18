-- Vánoční přání – databáze pro Supabase
-- Celý soubor vložte do Supabase: SQL Editor → New query → Run.
-- Dá se spustit i opakovaně (nic nesmaže).

-- ───────────────────────── Tabulky ─────────────────────────

create table if not exists public.members (
  id           uuid primary key default gen_random_uuid(),
  name         text not null check (length(trim(name)) between 1 and 60),
  is_admin     boolean not null default false,
  -- osobní pozvánka = přístupový klíč člena; vidí ji jen správce
  invite_token text not null unique
               default replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
  created_at   timestamptz not null default now()
);

-- které přihlášené zařízení patří kterému členovi
create table if not exists public.member_sessions (
  user_id   uuid primary key references auth.users (id) on delete cascade,
  member_id uuid not null references public.members (id) on delete cascade
);

create table if not exists public.letters (
  id               uuid primary key default gen_random_uuid(),
  recipient_name   text not null check (length(trim(recipient_name)) between 1 and 60),
  body             text not null default '',
  -- vyplněno = vlastní dopis člena (ten je u něj „slepý“); prázdné = dopis dítěte
  recipient_member uuid unique references public.members (id) on delete cascade,
  created_by       uuid not null references public.members (id) on delete cascade,
  created_at       timestamptz not null default now()
);

create table if not exists public.wishes (
  id         uuid primary key default gen_random_uuid(),
  letter_id  uuid not null references public.letters (id) on delete cascade,
  title      text not null check (length(trim(title)) between 1 and 200),
  note       text not null default '',
  url        text not null default '',
  deleted_at timestamptz,          -- přání se nemažou natvrdo, aby dárce o svůj výběr nepřišel
  created_at timestamptz not null default now()
);

-- kdo si co vybral; jeden dárek = nejvýše jeden dárce
create table if not exists public.claims (
  wish_id    uuid primary key references public.wishes (id) on delete cascade,
  member_id  uuid not null references public.members (id) on delete cascade,
  created_at timestamptz not null default now()
);

-- ───────────────────── Pomocné funkce ─────────────────────

create or replace function public.me() returns uuid
language sql stable security definer set search_path = public as $$
  select member_id from member_sessions where user_id = auth.uid()
$$;

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select coalesce((select is_admin from members where id = me()), false)
$$;

create or replace function public.can_edit_letter(p_letter uuid) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from letters l
                 where l.id = p_letter and (l.created_by = me() or is_admin()))
$$;

-- Komu dopis patří a ke kterému dopisu přání patří, se nesmí dodatečně měnit.
-- Jinak by si šlo vlastní přání „přehodit“ do dětského dopisu a zjistit, jestli je zabrané.
create or replace function public.lock_columns() returns trigger
language plpgsql as $$
begin
  if tg_table_name = 'letters' then
    if new.recipient_member is distinct from old.recipient_member
       or new.created_by is distinct from old.created_by then
      raise exception 'U dopisu nelze měnit, komu patří.';
    end if;
  elsif tg_table_name = 'wishes' then
    if new.letter_id is distinct from old.letter_id then
      raise exception 'Přání nelze přesunout do jiného dopisu.';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists letters_lock on public.letters;
create trigger letters_lock before update on public.letters
  for each row execute function public.lock_columns();
drop trigger if exists wishes_lock on public.wishes;
create trigger wishes_lock before update on public.wishes
  for each row execute function public.lock_columns();

-- ─────────────────── Přístupová pravidla ───────────────────

alter table public.members         enable row level security;
alter table public.member_sessions enable row level security;
alter table public.letters         enable row level security;
alter table public.wishes          enable row level security;
alter table public.claims          enable row level security;

revoke all on public.members, public.member_sessions, public.letters,
              public.wishes, public.claims from anon, authenticated;

-- členové: jména vidí všichni členové, pozvánky nikdo (jen správce přes funkci níže)
grant select (id, name, is_admin) on public.members to authenticated;
drop policy if exists members_read on public.members;
create policy members_read on public.members for select to authenticated
  using (me() is not null);

-- dopisy: čtou všichni členové; píše autor (nebo správce)
grant select, insert, delete on public.letters to authenticated;
grant update (recipient_name, body) on public.letters to authenticated;
drop policy if exists letters_read on public.letters;
create policy letters_read on public.letters for select to authenticated
  using (me() is not null);
drop policy if exists letters_insert on public.letters;
create policy letters_insert on public.letters for insert to authenticated
  with check (created_by = me() and (recipient_member is null or recipient_member = me()));
drop policy if exists letters_update on public.letters;
create policy letters_update on public.letters for update to authenticated
  using (created_by = me() or is_admin());
drop policy if exists letters_delete on public.letters;
create policy letters_delete on public.letters for delete to authenticated
  using (is_admin());

-- přání: čtou všichni členové; píše ten, kdo smí upravovat dopis
grant select, insert on public.wishes to authenticated;
grant update (title, note, url, deleted_at) on public.wishes to authenticated;
drop policy if exists wishes_read on public.wishes;
create policy wishes_read on public.wishes for select to authenticated
  using (me() is not null);
drop policy if exists wishes_insert on public.wishes;
create policy wishes_insert on public.wishes for insert to authenticated
  with check (can_edit_letter(letter_id));
drop policy if exists wishes_update on public.wishes;
create policy wishes_update on public.wishes for update to authenticated
  using (can_edit_letter(letter_id));

-- claims a member_sessions: žádný přímý přístup, jen přes funkce níže

-- ─────────────────── Funkce pro aplikaci ───────────────────

-- Úvodní stav: existuje už rodina? a kdo jsem já?
create or replace function public.app_state() returns json
language sql stable security definer set search_path = public as $$
  select json_build_object(
    'has_members', exists (select 1 from members),
    'me', (select json_build_object('id', id, 'name', name, 'is_admin', is_admin)
           from members where id = me()))
$$;

-- První spuštění: kdo aplikaci založí, stane se správcem.
create or replace function public.bootstrap(p_name text) returns void
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Nejste přihlášeni.'; end if;
  lock table members in exclusive mode;
  if exists (select 1 from members) then
    raise exception 'Rodina už je založená. Požádejte správce o pozvánku.';
  end if;
  insert into members (name, is_admin) values (trim(p_name), true) returning id into v_id;
  insert into member_sessions (user_id, member_id) values (auth.uid(), v_id);
end $$;

-- Přihlášení pozvánkou: spáruje toto zařízení se členem.
create or replace function public.redeem_invite(p_token text) returns void
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if auth.uid() is null then raise exception 'Nejste přihlášeni.'; end if;
  select id into v_id from members where invite_token = p_token;
  if v_id is null then
    raise exception 'Tato pozvánka neplatí. Požádejte o novou.';
  end if;
  insert into member_sessions (user_id, member_id) values (auth.uid(), v_id)
  on conflict (user_id) do update set member_id = excluded.member_id;
end $$;

-- Stav přání: zabrané / moje. Nikdy neříká KDO a nikdy nic nevrátí pro můj vlastní dopis.
create or replace function public.wish_states()
returns table (wish_id uuid, taken boolean, mine boolean)
language sql stable security definer set search_path = public as $$
  select w.id, c.wish_id is not null, coalesce(c.member_id = me(), false)
  from wishes w
  join letters l on l.id = w.letter_id
  left join claims c on c.wish_id = w.id
  where me() is not null
    and l.recipient_member is distinct from me()
$$;

create or replace function public.claim_wish(p_wish uuid) returns void
language plpgsql security definer set search_path = public as $$
declare v_me uuid := me(); v_recipient uuid; v_deleted timestamptz;
begin
  if v_me is null then raise exception 'Nejste přihlášeni.'; end if;
  select l.recipient_member, w.deleted_at into v_recipient, v_deleted
  from wishes w join letters l on l.id = w.letter_id where w.id = p_wish;
  if not found or v_deleted is not null then
    raise exception 'Toto přání už v dopise není.';
  end if;
  if v_recipient = v_me then
    raise exception 'Z vlastního dopisu si vybírat nemůžete.';
  end if;
  begin
    insert into claims (wish_id, member_id) values (p_wish, v_me);
  exception when unique_violation then
    raise exception 'Tenhle dárek si mezitím vybral někdo jiný.';
  end;
end $$;

create or replace function public.unclaim_wish(p_wish uuid) returns void
language sql security definer set search_path = public as $$
  delete from claims where wish_id = p_wish and member_id = me()
$$;

-- Správa rodiny (jen správce)
create or replace function public.admin_members()
returns table (id uuid, name text, is_admin boolean, invite_token text, signed_in boolean)
language plpgsql stable security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Tohle může jen správce.'; end if;
  return query
    select m.id, m.name, m.is_admin, m.invite_token,
           exists (select 1 from member_sessions s where s.member_id = m.id)
    from members m order by m.created_at;
end $$;

create or replace function public.add_member(p_name text) returns uuid
language plpgsql security definer set search_path = public as $$
declare v_id uuid;
begin
  if not is_admin() then raise exception 'Tohle může jen správce.'; end if;
  insert into members (name) values (trim(p_name)) returning id into v_id;
  return v_id;
end $$;

-- Nová pozvánka: stará přestane platit a člen je odhlášen ze všech zařízení.
create or replace function public.reset_invite(p_member uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Tohle může jen správce.'; end if;
  update members
     set invite_token = replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '')
   where id = p_member;
  delete from member_sessions where member_id = p_member and user_id <> auth.uid();
end $$;

create or replace function public.remove_member(p_member uuid) returns void
language plpgsql security definer set search_path = public as $$
begin
  if not is_admin() then raise exception 'Tohle může jen správce.'; end if;
  if p_member = me() then raise exception 'Sami sebe odebrat nemůžete.'; end if;
  delete from members where id = p_member;
end $$;

-- kdo smí které funkce volat
revoke execute on all functions in schema public from public, anon;
grant execute on all functions in schema public to authenticated;
grant execute on function public.app_state() to anon;
