-- ============================================================
-- GUILDS (Herói → Guild) — Nemesy RPG v57 (nível da Guild + doações de XP). É seguro voltar a executar.
-- Criar (35 000 ouro), entrar, sair, membros, chat e recompensa diária
-- (1 000 ouro + 2 Milho a cada 24 h). Tudo passa por funções do servidor:
-- o ouro e o milho são somados/descontados no save dentro do servidor.
-- ============================================================
create table if not exists public.guilds (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  name_key text not null unique,
  icon text not null,
  owner_id uuid not null,
  created_at timestamptz not null default now()
);

alter table public.guilds add column if not exists level integer not null default 1;
alter table public.guilds add column if not exists xp bigint not null default 0;

create table if not exists public.guild_members (
  user_id uuid primary key references auth.users (id) on delete cascade,
  guild_id uuid not null references public.guilds (id) on delete cascade,
  joined_at timestamptz not null default now()
);
alter table public.guild_members add column if not exists donated bigint not null default 0;
create index if not exists guild_members_guild_idx on public.guild_members (guild_id, joined_at);

-- A última recompensa diária fica por jogador (não por Guild): sair e voltar a entrar,
-- ou mudar de Guild, não volta a dar a recompensa antes das 24 h.
create table if not exists public.guild_reward_claims (
  user_id uuid primary key references auth.users (id) on delete cascade,
  last_claim_at timestamptz not null
);

-- Jogadores expulsos: não podem voltar a entrar nessa Guild durante kick_block_hours.
create table if not exists public.guild_kicks (
  guild_id uuid not null references public.guilds (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  kicked_at timestamptz not null default now(),
  primary key (guild_id, user_id)
);

-- XP doado por jogador e por dia (limite diário).
create table if not exists public.guild_xp_donations (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  amount bigint not null default 0,
  primary key (user_id, day)
);

create table if not exists public.guild_messages (
  id bigint generated always as identity primary key,
  guild_id uuid not null references public.guilds (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  author_name text not null,
  body text not null check (char_length(body) between 1 and 200),
  created_at timestamptz not null default now()
);
create index if not exists guild_messages_guild_idx on public.guild_messages (guild_id, id desc);

alter table public.guilds enable row level security;
alter table public.guild_members enable row level security;
alter table public.guild_reward_claims enable row level security;
alter table public.guild_messages enable row level security;
alter table public.guild_kicks enable row level security;
alter table public.guild_xp_donations enable row level security;
-- Mensagens do sistema (ex.: a Guild subiu de nível) não têm autor.
alter table public.guild_messages alter column user_id drop not null;
revoke all on public.guilds, public.guild_members, public.guild_reward_claims, public.guild_messages, public.guild_kicks, public.guild_xp_donations from anon, authenticated;

-- Regras ajustáveis.
create or replace function public.guild_settings()
returns jsonb language sql immutable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'create_cost', 35000,
    'max_members', 20,
    'kick_block_hours', 24,
    'max_level', 50,
    'donate_daily_cap', 100000,
    'reward_gold', 1000,
    'reward_corn', 2,
    'reward_hours', 24
  );
$$;

-- Ícones permitidos (todos os ícones do jogo). A mesma lista está em index.html (GUILD_ICONS).
create or replace function public.guild_icon_ok(p_icon text)
returns boolean language sql immutable set search_path = public, pg_temp as $$
  select p_icon = any(array['⚔️', '🏹', '🔮', '🛡️', '✝️', '🐺', '💰', '💀', '🌀', '🐏', '💪', '🧪', '🩸', '🌧️', '🎯', '🔥', '⚡', '💚', '🌿', '👺', '🗡️', '🐀', '🟢', '👑', '🌋', '🦎', '🪨', '👿', '🐦', '🏴‍☠️', '🐉', '🗿', '❄️', '🦍', '🧌', '👻', '🐙', '⛈️', '🦅', '🦁', '🐲', '🌑', '🐻', '☠️', '👹', '🕳️', '🐍', '😇', '🌲', '🧝🏽‍♂️', '🦂', '🦬', '🌳', '🌚', '✨', '🌙', '🌕', '🦉', '⛪', '📿', '⚖️', '🏝️', '🧞', '🌪️', '🧟', '😈', '🐕‍🦺', '🪓', '🔨', '🍳', '⛏️', '🐑', '❤️', '💥', '🔴', '🔵', '🟤', '🟣', '🎁', '💠', '🦪', '🌟', '⚪', '🧅', '🥕', '🥔', '🍅', '🌽', '🍎', '⚗️', '🍀', '🟡', '🟠', '⭐', '🔺️', '🪯', '⚜️', '☣️', '🧶', '🦷', '🪶', '🖤', '🧊', '🦴', '🪽', '⚫', '🐂', '🔪', '💎', '⚒️', '🏰', '🌩️', '🎮', '🐾', '🌾', '💫', '📈', '😡', '🏆', '🪖', '👕', '🧣', '🥾', '🧤', '🔯', '🔱', '🧙', '🪄', '📜', '🧝', '🎒', '🗺', '🏙', '🧬', '💱', '📚', '🪙', '⚙', '📙', '📗', '📖', '🛒']);
$$;

-- XP para a Guild passar do nível p_level para o seguinte (curva muito exigente:
-- ~670 mil XP até ao nível 10, ~4,3 milhões até ao 20, ~49 milhões até ao 50).
create or replace function public.guild_xp_for_level(p_level integer)
returns bigint language sql immutable set search_path = public, pg_temp as $$
  select round(5000 * power(greatest(p_level, 1), 1.6))::bigint;
$$;

-- XP que o herói precisa para passar do nível p_level (igual a xpForLevel no index.html).
create or replace function public.hero_xp_for_level(p_level integer)
returns numeric language sql immutable set search_path = public, pg_temp as $$
  select round((18 + p_level * 22 + p_level * p_level * 1.1) * (1.6 + 1.0 * least(greatest(p_level, 1), 150) / 150));
$$;

-- Recompensa diária conforme o nível da Guild (cada patamar de 10 níveis soma ao anterior).
create or replace function public.guild_reward_for_level(p_level integer)
returns jsonb language sql immutable set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'gold', 1000 + 200 * least(5, greatest(p_level, 1) / 10),
    'corn', 2,
    'apple', case when p_level >= 10 then 2 else 0 end,
    'reforco', case when p_level >= 20 then 1 else 0 end,
    'feitico', case when p_level >= 30 then 1 else 0 end,
    'gem_critico', case when p_level >= 40 then 1 else 0 end,
    'gem_vida', case when p_level >= 50 then 1 else 0 end
  );
$$;

create or replace function public.guild_name_key(p_name text)
returns text language sql immutable set search_path = public, pg_temp as $$
  select lower(regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g'));
$$;

-- Tira um jogador da Guild. Se era o líder, a liderança passa para o membro mais antigo;
-- se não sobrar ninguém, a Guild é apagada (com o chat).
create or replace function public.guild_remove_member(p_user uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_guild uuid;
  v_owner uuid;
  v_next uuid;
begin
  select guild_id into v_guild from public.guild_members where user_id = p_user;
  if not found then return; end if;
  select owner_id into v_owner from public.guilds where id = v_guild for update;
  delete from public.guild_members where user_id = p_user;
  if v_owner = p_user then
    select user_id into v_next from public.guild_members
    where guild_id = v_guild order by joined_at, user_id limit 1;
    if v_next is null then
      delete from public.guilds where id = v_guild;
    else
      update public.guilds set owner_id = v_next where id = v_guild;
    end if;
  end if;
end;
$$;

-- Recomeçar a aventura (apagar o save) também tira o jogador da Guild.
create or replace function public.guild_on_save_deleted()
returns trigger language plpgsql security definer set search_path = public, pg_temp as $$
begin
  perform public.guild_remove_member(old.user_id);
  return old;
end;
$$;
drop trigger if exists guild_on_save_deleted on public.game_saves;
create trigger guild_on_save_deleted after delete on public.game_saves
  for each row execute function public.guild_on_save_deleted();

create or replace function public.get_my_guild()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := auth.uid();
  v_guild public.guilds%rowtype;
  v_last timestamptz;
  v_count integer;
  v_owner_name text;
  v_today bigint := 0;
  v_mine bigint := 0;
  v_cfg jsonb := public.guild_settings();
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  select last_claim_at into v_last from public.guild_reward_claims where user_id = v_user;
  select g.* into v_guild from public.guilds g join public.guild_members m on m.guild_id = g.id where m.user_id = v_user;
  if not found then
    return jsonb_build_object('guild', null, 'server_now', floor(extract(epoch from clock_timestamp()) * 1000)::bigint, 'settings', v_cfg);
  end if;
  select count(*) into v_count from public.guild_members where guild_id = v_guild.id;
  select coalesce((select amount from public.guild_xp_donations where user_id = v_user and day = (clock_timestamp() at time zone 'utc')::date), 0) into v_today;
  select donated into v_mine from public.guild_members where user_id = v_user;
  select left(coalesce(nullif(btrim(save_data->>'name'), ''), 'Herói'), 16) into v_owner_name from public.game_saves where user_id = v_guild.owner_id;
  return jsonb_build_object(
    'guild', jsonb_build_object(
      'id', v_guild.id, 'name', v_guild.name, 'icon', v_guild.icon,
      'is_owner', v_guild.owner_id = v_user, 'owner_name', coalesce(v_owner_name, 'Herói'),
      'member_count', v_count, 'created_at', v_guild.created_at,
      'level', v_guild.level, 'xp', v_guild.xp,
      'xp_needed', case when v_guild.level >= (v_cfg->>'max_level')::int then 0 else public.guild_xp_for_level(v_guild.level) end,
      'reward', public.guild_reward_for_level(v_guild.level)
    ),
    'donated_today', v_today,
    'my_donated', coalesce(v_mine, 0),
    'reward_next_at', case when v_last is null then null
      else floor(extract(epoch from v_last + make_interval(hours => (v_cfg->>'reward_hours')::int)) * 1000)::bigint end,
    'server_now', floor(extract(epoch from clock_timestamp()) * 1000)::bigint,
    'settings', v_cfg
  );
end;
$$;

create or replace function public.list_guilds(p_search text default null)
returns jsonb language sql stable security definer set search_path = public, pg_temp as $$
  select coalesce(jsonb_agg(row_to_json(t)::jsonb order by t.level desc, t.member_count desc, t.name), '[]'::jsonb)
  from (
    select g.id, g.name, g.icon, g.level,
      (select count(*) from public.guild_members m where m.guild_id = g.id) as member_count,
      (select left(coalesce(nullif(btrim(s.save_data->>'name'), ''), 'Herói'), 16) from public.game_saves s where s.user_id = g.owner_id) as owner_name
    from public.guilds g
    where p_search is null or btrim(p_search) = '' or g.name_key like '%' || public.guild_name_key(p_search) || '%'
    order by g.level desc, (select count(*) from public.guild_members m where m.guild_id = g.id) desc, g.name
    limit 50
  ) t;
$$;

create or replace function public.create_guild(p_name text, p_icon text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := auth.uid();
  v_cfg jsonb := public.guild_settings();
  v_cost bigint := (public.guild_settings()->>'create_cost')::bigint;
  v_name text := btrim(regexp_replace(coalesce(p_name, ''), '\s+', ' ', 'g'));
  v_save jsonb;
  v_gold bigint;
  v_guild uuid;
  v_revision bigint;
  v_now timestamptz := clock_timestamp();
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  if char_length(v_name) < 3 or char_length(v_name) > 20 then raise exception 'O nome da Guild tem de ter entre 3 e 20 letras.'; end if;
  if v_name ~ '[<>"''`&\\]' or v_name ~ '[[:cntrl:]]' then raise exception 'O nome da Guild tem símbolos que não são permitidos.'; end if;
  if not public.guild_icon_ok(p_icon) then raise exception 'Escolhe um ícone da lista.'; end if;

  select save_data into v_save from public.game_saves where user_id = v_user for update;
  if not found then raise exception 'Não foi encontrado o teu save.'; end if;
  if exists (select 1 from public.guild_members where user_id = v_user) then raise exception 'Já pertences a uma Guild. Sai dela primeiro.'; end if;
  if exists (select 1 from public.guilds where name_key = public.guild_name_key(v_name)) then raise exception 'Já existe uma Guild com esse nome.'; end if;
  if coalesce(v_save->>'gold', '') !~ '^[0-9]+$' then raise exception 'O teu saldo de ouro não é válido.'; end if;
  v_gold := (v_save->>'gold')::bigint;
  if v_gold < v_cost then raise exception 'Precisas de % de ouro para criar uma Guild.', v_cost; end if;

  insert into public.guilds (name, name_key, icon, owner_id) values (v_name, public.guild_name_key(v_name), p_icon, v_user) returning id into v_guild;
  insert into public.guild_members (user_id, guild_id, joined_at) values (v_user, v_guild, v_now);

  v_save := jsonb_set(v_save, '{gold}', to_jsonb(v_gold - v_cost), true);
  update public.game_saves set save_data = v_save, updated_at = v_now, revision = revision + 1
  where user_id = v_user returning revision into v_revision;
  return jsonb_build_object('save_data', v_save, 'revision', v_revision, 'updated_at', v_now, 'guild_id', v_guild);
exception when unique_violation then
  raise exception 'Já existe uma Guild com esse nome.';
end;
$$;

create or replace function public.join_guild(p_guild_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := auth.uid();
  v_count integer;
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  if not exists (select 1 from public.game_saves where user_id = v_user) then raise exception 'Não foi encontrado o teu save.'; end if;
  perform 1 from public.guilds where id = p_guild_id for update;
  if not found then raise exception 'Esta Guild já não existe.'; end if;
  if exists (select 1 from public.guild_members where user_id = v_user) then raise exception 'Já pertences a uma Guild. Sai dela primeiro.'; end if;
  if exists (select 1 from public.guild_kicks where guild_id = p_guild_id and user_id = v_user
             and kicked_at > clock_timestamp() - make_interval(hours => (public.guild_settings()->>'kick_block_hours')::int)) then
    raise exception 'Foste expulso desta Guild. Só podes voltar a pedir para entrar daqui a 24 horas.';
  end if;
  select count(*) into v_count from public.guild_members where guild_id = p_guild_id;
  if v_count >= (public.guild_settings()->>'max_members')::int then raise exception 'Esta Guild está cheia.'; end if;
  insert into public.guild_members (user_id, guild_id) values (v_user, p_guild_id);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.leave_guild()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  if not exists (select 1 from public.guild_members where user_id = v_user) then raise exception 'Não pertences a nenhuma Guild.'; end if;
  perform public.guild_remove_member(v_user);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.get_guild_members()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := auth.uid();
  v_guild public.guilds%rowtype;
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  select g.* into v_guild from public.guilds g join public.guild_members m on m.guild_id = g.id where m.user_id = v_user;
  if not found then raise exception 'Não pertences a nenhuma Guild.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', m.user_id,
      'name', left(coalesce(nullif(btrim(s.save_data->>'name'), ''), 'Herói'), 16),
      'class', case when s.save_data->>'class' in ('guerreiro', 'arqueiro', 'mago') then s.save_data->>'class' else 'guerreiro' end,
      'evolution', case when s.save_data->>'evolution' in ('paladino', 'cruzado', 'cacador', 'mercenario', 'necromante', 'feiticeiro') then s.save_data->>'evolution' else null end,
      'level', case when s.save_data->>'level' ~ '^[1-9][0-9]{0,6}$' then (s.save_data->>'level')::bigint else 1 end,
      'is_owner', m.user_id = v_guild.owner_id,
      'is_me', m.user_id = v_user,
      'donated', m.donated
    ) order by (m.user_id = v_guild.owner_id) desc,
             case when s.save_data->>'level' ~ '^[1-9][0-9]{0,6}$' then (s.save_data->>'level')::bigint else 1 end desc, m.joined_at)
    from public.guild_members m
    left join public.game_saves s on s.user_id = m.user_id
    where m.guild_id = v_guild.id
  ), '[]'::jsonb);
end;
$$;

-- Só o líder pode expulsar, e não se pode expulsar a si próprio.
create or replace function public.kick_guild_member(p_user_id uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := auth.uid();
  v_guild public.guilds%rowtype;
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  select g.* into v_guild from public.guilds g join public.guild_members m on m.guild_id = g.id where m.user_id = v_user for update of g;
  if not found then raise exception 'Não pertences a nenhuma Guild.'; end if;
  if v_guild.owner_id <> v_user then raise exception 'Só o líder da Guild pode expulsar guerreiros.'; end if;
  if p_user_id is null or p_user_id = v_user then raise exception 'Não te podes expulsar a ti próprio. Usa "Sair da Guild".'; end if;
  if not exists (select 1 from public.guild_members where user_id = p_user_id and guild_id = v_guild.id) then
    raise exception 'Esse guerreiro já não pertence à Guild.';
  end if;
  delete from public.guild_members where user_id = p_user_id and guild_id = v_guild.id;
  insert into public.guild_kicks (guild_id, user_id, kicked_at) values (v_guild.id, p_user_id, clock_timestamp())
  on conflict (guild_id, user_id) do update set kicked_at = excluded.kicked_at;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.send_guild_message(p_body text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := auth.uid();
  v_guild uuid;
  v_body text := btrim(regexp_replace(coalesce(p_body, ''), '[[:cntrl:]]+', ' ', 'g'));
  v_name text;
  v_id bigint;
  v_cut bigint;
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  select guild_id into v_guild from public.guild_members where user_id = v_user;
  if not found then raise exception 'Não pertences a nenhuma Guild.'; end if;
  if char_length(v_body) < 1 then raise exception 'Escreve uma mensagem.'; end if;
  if char_length(v_body) > 200 then raise exception 'A mensagem pode ter no máximo 200 letras.'; end if;
  if exists (select 1 from public.guild_messages where user_id = v_user and created_at > clock_timestamp() - interval '2 seconds') then
    raise exception 'Estás a escrever depressa demais. Espera um segundo.';
  end if;
  select left(coalesce(nullif(btrim(save_data->>'name'), ''), 'Herói'), 16) into v_name from public.game_saves where user_id = v_user;
  insert into public.guild_messages (guild_id, user_id, author_name, body)
  values (v_guild, v_user, coalesce(v_name, 'Herói'), v_body) returning id into v_id;
  -- Só se guardam as últimas 200 mensagens de cada Guild.
  select id into v_cut from public.guild_messages where guild_id = v_guild order by id desc offset 200 limit 1;
  if v_cut is not null then delete from public.guild_messages where guild_id = v_guild and id <= v_cut; end if;
  return jsonb_build_object('id', v_id);
end;
$$;

-- p_after_id = 0 → últimas 50 mensagens; senão, só as mais recentes que esse id.
create or replace function public.get_guild_messages(p_after_id bigint default 0)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := auth.uid();
  v_guild uuid;
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  select guild_id into v_guild from public.guild_members where user_id = v_user;
  if not found then raise exception 'Não pertences a nenhuma Guild.'; end if;
  return coalesce((
    select jsonb_agg(jsonb_build_object(
      'id', t.id, 'author', t.author_name, 'body', t.body,
      'at', floor(extract(epoch from t.created_at) * 1000)::bigint, 'is_me', coalesce(t.user_id = v_user, false), 'system', t.user_id is null
    ) order by t.id)
    from (
      select * from public.guild_messages
      where guild_id = v_guild and id > coalesce(p_after_id, 0)
      order by id desc limit 50
    ) t
  ), '[]'::jsonb);
end;
$$;

-- Doar XP: sai da barra de XP do herói (nunca baixa de nível) e entra na Guild.
create or replace function public.donate_guild_xp(p_amount bigint)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := auth.uid();
  v_cfg jsonb := public.guild_settings();
  v_max integer := (public.guild_settings()->>'max_level')::int;
  v_cap bigint := (public.guild_settings()->>'donate_daily_cap')::bigint;
  v_day date := (clock_timestamp() at time zone 'utc')::date;
  v_now timestamptz := clock_timestamp();
  v_guild public.guilds%rowtype;
  v_save jsonb;
  v_hero_level integer;
  v_hero_xp numeric;
  v_today bigint;
  v_amount bigint := p_amount;
  v_left bigint;
  v_level integer;
  v_xp bigint;
  v_gained integer := 0;
  v_revision bigint;
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  if v_amount is null or v_amount < 1 then raise exception 'Escolhe quanto XP queres doar.'; end if;
  select g.* into v_guild from public.guilds g join public.guild_members m on m.guild_id = g.id where m.user_id = v_user for update of g;
  if not found then raise exception 'Não pertences a nenhuma Guild.'; end if;
  if v_guild.level >= v_max then raise exception 'A Guild já está no nível máximo.'; end if;

  select save_data into v_save from public.game_saves where user_id = v_user for update;
  if not found then raise exception 'Não foi encontrado o teu save.'; end if;
  if coalesce(v_save->>'level', '') !~ '^[1-9][0-9]{0,3}$' or coalesce(v_save->>'xp', '') !~ '^[0-9]{1,15}$' then
    raise exception 'O XP do teu herói não é válido.';
  end if;
  v_hero_level := (v_save->>'level')::int;
  v_hero_xp := (v_save->>'xp')::numeric;
  -- Antes do nível 150, a barra de XP nunca pode passar do que o nível pede.
  if v_hero_level < 150 and v_hero_xp > public.hero_xp_for_level(v_hero_level) + 1 then
    raise exception 'O XP do teu herói não é válido.';
  end if;
  if v_amount > v_hero_xp then raise exception 'Não tens esse XP para doar (tens %).', v_hero_xp; end if;

  select coalesce((select amount from public.guild_xp_donations where user_id = v_user and day = v_day for update), 0) into v_today;
  if v_today + v_amount > v_cap then
    raise exception 'Só podes doar % XP por dia. Hoje ainda podes doar %.', v_cap, greatest(v_cap - v_today, 0);
  end if;

  -- Não aceita mais do que falta para o nível máximo.
  v_left := public.guild_xp_for_level(v_guild.level) - v_guild.xp;
  if v_guild.level + 1 < v_max then
    select v_left + coalesce(sum(public.guild_xp_for_level(l)), 0) into v_left from generate_series(v_guild.level + 1, v_max - 1) l;
  end if;
  v_amount := least(v_amount, v_left);

  v_level := v_guild.level;
  v_xp := v_guild.xp + v_amount;
  while v_level < v_max and v_xp >= public.guild_xp_for_level(v_level) loop
    v_xp := v_xp - public.guild_xp_for_level(v_level);
    v_level := v_level + 1;
    v_gained := v_gained + 1;
  end loop;
  if v_level >= v_max then v_xp := 0; end if;

  update public.guilds set level = v_level, xp = v_xp where id = v_guild.id;
  update public.guild_members set donated = donated + v_amount where user_id = v_user;
  insert into public.guild_xp_donations (user_id, day, amount) values (v_user, v_day, v_amount)
  on conflict (user_id, day) do update set amount = public.guild_xp_donations.amount + excluded.amount;

  v_save := jsonb_set(v_save, '{xp}', to_jsonb(v_hero_xp - v_amount), true);
  update public.game_saves set save_data = v_save, updated_at = v_now, revision = revision + 1
  where user_id = v_user returning revision into v_revision;

  if v_gained > 0 then
    insert into public.guild_messages (guild_id, user_id, author_name, body)
    values (v_guild.id, null, 'Guild', format('🎉 A Guild subiu para o nível %s graças a %s!', v_level,
      left(coalesce(nullif(btrim(v_save->>'name'), ''), 'Herói'), 16)));
  end if;

  return jsonb_build_object('save_data', v_save, 'revision', v_revision, 'updated_at', v_now,
    'donated', v_amount, 'level', v_level, 'xp', v_xp, 'levels_gained', v_gained);
end;
$$;

create or replace function public.claim_guild_reward()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_user uuid := auth.uid();
  v_cfg jsonb := public.guild_settings();
  v_now timestamptz := clock_timestamp();
  v_last timestamptz;
  v_save jsonb;
  v_gold numeric;
  v_corn numeric;
  v_revision bigint;
  v_glevel integer;
  v_r jsonb;
  v_n numeric;
  v_path text[];
  v_key text;
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  select g.level into v_glevel from public.guilds g join public.guild_members m on m.guild_id = g.id where m.user_id = v_user;
  if not found then raise exception 'Precisas de pertencer a uma Guild.'; end if;
  v_r := public.guild_reward_for_level(v_glevel);

  select save_data into v_save from public.game_saves where user_id = v_user for update;
  if not found then raise exception 'Não foi encontrado o teu save.'; end if;
  select last_claim_at into v_last from public.guild_reward_claims where user_id = v_user for update;
  if v_last is not null and v_now < v_last + make_interval(hours => (v_cfg->>'reward_hours')::int) then
    raise exception 'A recompensa ainda não está disponível.';
  end if;
  if coalesce(v_save->>'gold', '') !~ '^[0-9]+$' then raise exception 'O teu saldo de ouro não é válido.'; end if;

  v_gold := (v_save->>'gold')::numeric + (v_r->>'gold')::numeric;
  v_save := jsonb_set(v_save, '{gold}', to_jsonb(v_gold), true);
  if jsonb_typeof(v_save->'farm') is distinct from 'object' then v_save := jsonb_set(v_save, '{farm}', '{}'::jsonb, true); end if;
  if jsonb_typeof(v_save->'farm'->'crops') is distinct from 'object' then v_save := jsonb_set(v_save, '{farm,crops}', '{}'::jsonb, true); end if;
  if jsonb_typeof(v_save->'scrolls') is distinct from 'object' then v_save := jsonb_set(v_save, '{scrolls}', '{}'::jsonb, true); end if;
  if jsonb_typeof(v_save->'gems') is distinct from 'object' then v_save := jsonb_set(v_save, '{gems}', '{}'::jsonb, true); end if;
  foreach v_key in array array['critico', 'vida'] loop
    if jsonb_typeof(v_save->'gems'->v_key) is distinct from 'array' then
      v_save := jsonb_set(v_save, array['gems', v_key], '[0,0,0]'::jsonb, true);
    end if;
  end loop;
  -- Soma cada parte da recompensa ao sítio certo do save (só as que forem > 0).
  foreach v_key in array array['corn', 'apple', 'reforco', 'feitico', 'gem_critico', 'gem_vida'] loop
    v_n := (v_r->>v_key)::numeric;
    if v_n > 0 then
      v_path := case v_key
        when 'corn' then array['farm', 'crops', 'corn'] when 'apple' then array['farm', 'crops', 'apple']
        when 'reforco' then array['scrolls', 'reforco'] when 'feitico' then array['scrolls', 'feitico']
        when 'gem_critico' then array['gems', 'critico', '0'] else array['gems', 'vida', '0'] end;
      v_save := jsonb_set(v_save, v_path, to_jsonb(
        case when coalesce(v_save #>> v_path, '') ~ '^[0-9]+$' then (v_save #>> v_path)::numeric else 0 end + v_n), true);
    end if;
  end loop;

  insert into public.guild_reward_claims (user_id, last_claim_at) values (v_user, v_now)
  on conflict (user_id) do update set last_claim_at = excluded.last_claim_at;
  update public.game_saves set save_data = v_save, updated_at = v_now, revision = revision + 1
  where user_id = v_user returning revision into v_revision;

  return jsonb_build_object('save_data', v_save, 'revision', v_revision, 'updated_at', v_now, 'reward', v_r,
    'reward_next_at', floor(extract(epoch from v_now + make_interval(hours => (v_cfg->>'reward_hours')::int)) * 1000)::bigint,
    'server_now', floor(extract(epoch from v_now) * 1000)::bigint);
end;
$$;

revoke all on function public.guild_settings() from public, anon;
revoke all on function public.guild_icon_ok(text) from public, anon;
revoke all on function public.guild_name_key(text) from public, anon;
revoke all on function public.guild_remove_member(uuid) from public, anon, authenticated;
revoke all on function public.guild_on_save_deleted() from public, anon, authenticated;
revoke all on function public.get_my_guild() from public, anon;
revoke all on function public.list_guilds(text) from public, anon;
revoke all on function public.create_guild(text, text) from public, anon;
revoke all on function public.join_guild(uuid) from public, anon;
revoke all on function public.leave_guild() from public, anon;
revoke all on function public.get_guild_members() from public, anon;
revoke all on function public.send_guild_message(text) from public, anon;
revoke all on function public.kick_guild_member(uuid) from public, anon;
revoke all on function public.donate_guild_xp(bigint) from public, anon;
revoke all on function public.guild_xp_for_level(integer) from public, anon;
revoke all on function public.hero_xp_for_level(integer) from public, anon;
revoke all on function public.guild_reward_for_level(integer) from public, anon;
revoke all on function public.get_guild_messages(bigint) from public, anon;
revoke all on function public.claim_guild_reward() from public, anon;
grant execute on function public.get_my_guild() to authenticated;
grant execute on function public.list_guilds(text) to authenticated;
grant execute on function public.create_guild(text, text) to authenticated;
grant execute on function public.join_guild(uuid) to authenticated;
grant execute on function public.leave_guild() to authenticated;
grant execute on function public.get_guild_members() to authenticated;
grant execute on function public.send_guild_message(text) to authenticated;
grant execute on function public.kick_guild_member(uuid) to authenticated;
grant execute on function public.donate_guild_xp(bigint) to authenticated;
grant execute on function public.get_guild_messages(bigint) to authenticated;
grant execute on function public.claim_guild_reward() to authenticated;
