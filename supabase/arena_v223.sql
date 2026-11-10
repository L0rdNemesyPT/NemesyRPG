-- =====================================================================
-- v223: ARENA — lutas contra cópias dos heróis de outros jogadores.
-- Tudo o que conta (pontos, lutas por dia, Fichas, loja, prémios semanais)
-- é decidido aqui no servidor. O jogo só envia a "cópia" do herói
-- (estatísticas niveladas ao Nv. 100) e o resultado da luta.
-- =====================================================================

create table if not exists public.arena_players (
  user_id uuid primary key references auth.users(id) on delete cascade,
  name text not null default '',
  cls text not null default '',
  level integer not null default 1,
  paragon integer not null default 0,
  snapshot jsonb not null default '{}'::jsonb,
  points integer not null default 1000,
  wins integer not null default 0,
  losses integer not null default 0,
  def_wins integer not null default 0,
  def_losses integer not null default 0,
  fichas integer not null default 0,
  week date not null,
  week_fights integer not null default 0,
  day date not null,
  fights_today integer not null default 0,
  offers jsonb not null default '[]'::jsonb,
  offers_at timestamptz,
  buys jsonb not null default '{}'::jsonb,
  title text,
  updated_at timestamptz not null default now()
);
create index if not exists arena_players_points_idx on public.arena_players (points desc);

create table if not exists public.arena_matches (
  id bigserial primary key,
  attacker uuid not null,
  defender uuid,
  attacker_name text not null default '',
  defender_name text not null default '',
  win boolean not null,
  d_att integer not null default 0,
  d_def integer not null default 0,
  created_at timestamptz not null default now()
);
create index if not exists arena_matches_att_idx on public.arena_matches (attacker, created_at desc);
create index if not exists arena_matches_def_idx on public.arena_matches (defender, created_at desc);

create table if not exists public.arena_results (
  week date not null,
  user_id uuid not null references auth.users(id) on delete cascade,
  name text not null default '',
  points integer not null,
  rank integer not null,
  league text not null,
  fichas integer not null,
  top3 boolean not null default false,
  claimed boolean not null default false,
  primary key (week, user_id)
);

create table if not exists public.arena_meta (
  id boolean primary key default true check (id),
  week date not null
);

alter table public.arena_players enable row level security;
alter table public.arena_matches enable row level security;
alter table public.arena_results enable row level security;
alter table public.arena_meta enable row level security;
-- Sem políticas: só as funções abaixo (security definer) leem e escrevem.

-- ---------- Ajudantes ----------
create or replace function public.arena_today() returns date language sql stable
set search_path = public, pg_temp as $$ select (now() at time zone 'Europe/Lisbon')::date $$;

create or replace function public.arena_week_of(p_day date) returns date language sql immutable
set search_path = public, pg_temp as $$ select (date_trunc('week', p_day::timestamp))::date $$;

create or replace function public.arena_league(p_points integer) returns text language sql immutable
set search_path = public, pg_temp as $$
  select case when p_points >= 2200 then 'lenda' when p_points >= 1900 then 'diamante'
              when p_points >= 1600 then 'platina' when p_points >= 1200 then 'ouro'
              when p_points >= 800 then 'prata' else 'bronze' end $$;

create or replace function public.arena_reset_points(p_points integer) returns integer language sql immutable
set search_path = public, pg_temp as $$
  select case public.arena_league(p_points) when 'lenda' then 1900 when 'diamante' then 1600
              when 'platina' then 1200 when 'ouro' then 800 when 'prata' then 600 else p_points end $$;

create or replace function public.arena_league_fichas(p_league text) returns integer language sql immutable
set search_path = public, pg_temp as $$
  select case p_league when 'lenda' then 100 when 'diamante' then 75 when 'platina' then 50
              when 'ouro' then 35 when 'prata' then 20 else 10 end $$;

-- Pontos: ganhar a alguém mais forte dá mais e perder custa menos.
create or replace function public.arena_gain(p_my integer, p_opp integer) returns integer language sql immutable
set search_path = public, pg_temp as $$ select greatest(12, least(30, round(20 + (p_opp - p_my) / 10.0)::int)) $$;
create or replace function public.arena_loss(p_my integer, p_opp integer) returns integer language sql immutable
set search_path = public, pg_temp as $$ select greatest(4, least(14, round(9 - (p_opp - p_my) / 25.0)::int)) $$;

-- Fecha a semana anterior (uma vez): guarda o ranking e os prémios, e baixa os pontos uma liga.
create or replace function public.arena_rollover() returns void language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_cur date := public.arena_week_of(public.arena_today()); v_old date;
begin
  insert into public.arena_meta (id, week) values (true, v_cur) on conflict (id) do nothing;
  select week into v_old from public.arena_meta where id for update;
  if v_old >= v_cur then return; end if;
  insert into public.arena_results (week, user_id, name, points, rank, league, fichas, top3)
  select v_old, user_id, name, points, rk, public.arena_league(points),
         public.arena_league_fichas(public.arena_league(points)) + case when rk <= 3 then 50 else 0 end, rk <= 3
  from (select user_id, name, points, row_number() over (order by points desc, wins desc, user_id) rk
        from public.arena_players where week = v_old and week_fights > 0) t
  on conflict do nothing;
  update public.arena_players set points = public.arena_reset_points(points), week = v_cur, week_fights = 0
  where week < v_cur;
  update public.arena_meta set week = v_cur where id;
end $$;

create or replace function public.arena_me_json(r public.arena_players) returns jsonb language sql stable
set search_path = public, pg_temp as $$
  select jsonb_build_object(
    'points', r.points, 'league', public.arena_league(r.points), 'wins', r.wins, 'losses', r.losses,
    'def_wins', r.def_wins, 'def_losses', r.def_losses, 'fichas', r.fichas,
    'fights_left', greatest(0, 5 - case when r.day = public.arena_today() then r.fights_today else 0 end),
    'rank', (select count(*) + 1 from public.arena_players o where o.week = r.week and o.points > r.points),
    'title', r.title, 'buys', r.buys,
    'week_end', floor(extract(epoch from ((public.arena_week_of(public.arena_today()) + 7)::timestamp at time zone 'Europe/Lisbon')) * 1000)::bigint,
    'day_end', floor(extract(epoch from ((public.arena_today() + 1)::timestamp at time zone 'Europe/Lisbon')) * 1000)::bigint,
    'server_now', floor(extract(epoch from now()) * 1000)::bigint) $$;

-- Lê o meu registo da Arena, já com o dia e a semana em dia (bloqueado para escrita).
create or replace function public.arena_lock_me(p_user uuid) returns public.arena_players language plpgsql security definer
set search_path = public, pg_temp as $$
declare r public.arena_players; v_today date := public.arena_today(); v_week date := public.arena_week_of(public.arena_today());
begin
  perform public.arena_rollover();
  select * into r from public.arena_players where user_id = p_user for update;
  if not found then raise exception 'Abre a Arena primeiro.'; end if;
  if r.week < v_week then
    update public.arena_players set points = public.arena_reset_points(points), week = v_week, week_fights = 0
    where user_id = p_user returning * into r;
  end if;
  if r.day < v_today then
    update public.arena_players set day = v_today, fights_today = 0 where user_id = p_user returning * into r;
  end if;
  return r;
end $$;

-- ---------- 1) Entrar na Arena / atualizar a minha cópia ----------
create or replace function public.arena_sync(p_snapshot jsonb) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_user uuid := auth.uid(); v_save jsonb; v_lv integer; v_snap jsonb; r public.arena_players;
  v_rewards jsonb := '[]'::jsonb; x record; v_today date := public.arena_today();
  num_ok text := '^[0-9]+(\.[0-9]+)?$';
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  select save_data into v_save from public.game_saves where user_id = v_user;
  if not found then raise exception 'Não foi encontrado o teu save.'; end if;
  v_lv := case when coalesce(v_save->>'level', '') ~ '^[0-9]+$' then (v_save->>'level')::int else 1 end;
  if v_lv < 50 then raise exception 'A Arena abre no Nv. 50.'; end if;
  if coalesce(p_snapshot->>'hp', '') !~ num_ok or coalesce(p_snapshot->>'dmg', '') !~ num_ok
     or coalesce(p_snapshot->>'def', '') !~ num_ok or coalesce(p_snapshot->>'crit', '') !~ num_ok then
    raise exception 'Cópia do herói inválida.';
  end if;
  v_snap := jsonb_build_object(
    'hp', greatest(1, least(400000, round((p_snapshot->>'hp')::numeric))),
    'dmg', greatest(1, least(40000, round((p_snapshot->>'dmg')::numeric))),
    'def', greatest(0, least(20000, round((p_snapshot->>'def')::numeric))),
    'crit', greatest(0, least(0.6, round((p_snapshot->>'crit')::numeric, 3))));
  perform public.arena_rollover();
  insert into public.arena_players (user_id, name, cls, level, paragon, snapshot, week, day)
  values (v_user, left(coalesce(v_save->>'name', 'Herói'), 24), coalesce(v_save->>'class', ''), v_lv,
          case when coalesce(v_save->>'paragon', '') ~ '^[0-9]+$' then (v_save->>'paragon')::int else 0 end,
          v_snap, public.arena_week_of(v_today), v_today)
  on conflict (user_id) do update set name = excluded.name, cls = excluded.cls, level = excluded.level,
    paragon = excluded.paragon, snapshot = excluded.snapshot, updated_at = now();
  r := public.arena_lock_me(v_user);
  for x in select * from public.arena_results where user_id = v_user and not claimed order by week loop
    update public.arena_results set claimed = true where week = x.week and user_id = v_user;
    update public.arena_players set fichas = fichas + x.fichas,
      title = case when x.top3 then 'Campeão da Arena' else title end where user_id = v_user;
    v_rewards := v_rewards || jsonb_build_object('week', x.week, 'rank', x.rank, 'league', x.league, 'fichas', x.fichas, 'top3', x.top3);
  end loop;
  select * into r from public.arena_players where user_id = v_user;
  return jsonb_build_object('me', public.arena_me_json(r), 'rewards', v_rewards);
end $$;

-- ---------- 2) Adversários (1 mais fraco, 1 equilibrado, 1 mais forte) ----------
-- Se ainda não houver jogadores suficientes, o servidor junta "Sombras" (cópias treinadas).
create or replace function public.arena_opponents(p_refresh boolean default false) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_user uuid := auth.uid(); r public.arena_players; v_list jsonb := '[]'::jsonb; v_ids uuid[] := '{}';
  v_pick record; v_tier text; v_save jsonb; v_gold numeric; v_rev bigint; v_now timestamptz := clock_timestamp();
  v_ret jsonb := null; i integer; v_f numeric; v_bp integer;
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  r := public.arena_lock_me(v_user);
  if not p_refresh and r.offers_at is not null and r.offers_at > v_now - interval '5 minutes'
     and jsonb_array_length(r.offers) > 0 then
    v_list := r.offers;
  else
    if p_refresh then
      select save_data into v_save from public.game_saves where user_id = v_user for update;
      if coalesce(v_save->>'gold', '') !~ '^[0-9]+$' or (v_save->>'gold')::numeric < 500 then
        raise exception 'Precisas de 500 de ouro para trocar de adversários.';
      end if;
      v_gold := (v_save->>'gold')::numeric - 500;
      v_save := jsonb_set(v_save, '{gold}', to_jsonb(v_gold), true);
      update public.game_saves set save_data = v_save, updated_at = v_now, revision = revision + 1
      where user_id = v_user returning revision into v_rev;
      v_ret := jsonb_build_object('save_data', v_save, 'revision', v_rev, 'updated_at', v_now);
    end if;
    foreach v_tier in array array['fraco', 'igual', 'forte'] loop
      select o.* into v_pick from (
        select p.* from public.arena_players p
        where p.user_id <> v_user and p.snapshot <> '{}'::jsonb and p.updated_at > v_now - interval '30 days'
          and not (p.user_id = any (v_ids))
          and case v_tier when 'fraco' then p.points < r.points - 25 when 'forte' then p.points > r.points + 25 else true end
        order by case v_tier when 'fraco' then r.points - p.points when 'forte' then p.points - r.points else abs(p.points - r.points) end
        limit 6) o
      order by random() limit 1;
      if found then
        v_ids := v_ids || v_pick.user_id;
        v_list := v_list || jsonb_build_object('id', v_pick.user_id::text, 'name', v_pick.name, 'cls', v_pick.cls,
          'level', v_pick.level, 'paragon', v_pick.paragon, 'points', v_pick.points, 'league', public.arena_league(v_pick.points),
          'snapshot', v_pick.snapshot, 'title', v_pick.title, 'bot', false,
          'gain', public.arena_gain(r.points, v_pick.points), 'loss', public.arena_loss(r.points, v_pick.points));
      end if;
    end loop;
    -- Sombras para completar 3 adversários.
    i := 0;
    while jsonb_array_length(v_list) < 3 and i < 3 loop
      i := i + 1;
      v_f := case i when 1 then 0.9 when 2 then 1.0 else 1.1 end;
      v_bp := r.points + case i when 1 then -60 when 2 then 0 else 60 end;
      v_list := v_list || jsonb_build_object('id', 'sombra:' || i, 'name', 'Sombra ' || case i when 1 then 'Pálida' when 2 then 'Gémea' else 'Furiosa' end,
        'cls', r.cls, 'level', 100, 'paragon', 0, 'points', v_bp, 'league', public.arena_league(v_bp),
        'snapshot', jsonb_build_object('hp', round((r.snapshot->>'hp')::numeric * v_f), 'dmg', round((r.snapshot->>'dmg')::numeric * v_f),
                                       'def', round((r.snapshot->>'def')::numeric * v_f), 'crit', (r.snapshot->>'crit')::numeric),
        'title', null, 'bot', true,
        'gain', greatest(4, public.arena_gain(r.points, v_bp) / 2), 'loss', public.arena_loss(r.points, v_bp));
    end loop;
    update public.arena_players set offers = v_list, offers_at = v_now where user_id = v_user;
  end if;
  return jsonb_build_object('opponents', v_list, 'refresh_at', floor(extract(epoch from coalesce(
    (select offers_at from public.arena_players where user_id = v_user), v_now) + interval '5 minutes') * 1000)::bigint,
    'save', v_ret);
end $$;

-- ---------- 3) Resultado de uma luta ----------
create or replace function public.arena_report(p_opponent text, p_win boolean) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_user uuid := auth.uid(); r public.arena_players; d public.arena_players; v_off jsonb; v_is_bot boolean;
  v_gain integer; v_loss integer; v_datt integer; v_ddef integer := 0; v_fichas integer;
  v_save jsonb; v_gold numeric := 0; v_rev bigint; v_now timestamptz := clock_timestamp(); v_lv integer; v_ret jsonb := null;
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  r := public.arena_lock_me(v_user);
  if r.fights_today >= 5 then raise exception 'Já fizeste as 5 lutas de hoje. Voltam à meia-noite.'; end if;
  select e into v_off from jsonb_array_elements(r.offers) e where e->>'id' = p_opponent limit 1;
  if v_off is null then raise exception 'Este adversário já não está disponível. Atualiza a lista.'; end if;
  v_is_bot := coalesce((v_off->>'bot')::boolean, false);
  v_gain := (v_off->>'gain')::int; v_loss := (v_off->>'loss')::int;
  v_datt := case when p_win then v_gain else -v_loss end;
  v_fichas := case when p_win then 3 else 1 end;
  update public.arena_players set points = greatest(0, points + v_datt),
    wins = wins + case when p_win then 1 else 0 end, losses = losses + case when p_win then 0 else 1 end,
    fights_today = fights_today + 1, week_fights = week_fights + 1, fichas = fichas + v_fichas,
    offers = (select coalesce(jsonb_agg(e), '[]'::jsonb) from jsonb_array_elements(offers) e where e->>'id' <> p_opponent),
    updated_at = now()
  where user_id = v_user returning * into r;
  if not v_is_bot then
    select * into d from public.arena_players where user_id = p_opponent::uuid for update;
    if found then
      v_ddef := case when p_win then -greatest(4, least(10, round(v_gain * 0.4)::int)) else 5 end;
      update public.arena_players set points = greatest(0, points + v_ddef),
        def_wins = def_wins + case when p_win then 0 else 1 end, def_losses = def_losses + case when p_win then 1 else 0 end,
        fichas = fichas + case when p_win then 0 else 1 end
      where user_id = d.user_id;
    end if;
  end if;
  insert into public.arena_matches (attacker, defender, attacker_name, defender_name, win, d_att, d_def)
  values (v_user, case when v_is_bot then null else p_opponent::uuid end, r.name, coalesce(v_off->>'name', ''), p_win, v_datt, v_ddef);
  if p_win then
    select save_data into v_save from public.game_saves where user_id = v_user for update;
    if found and coalesce(v_save->>'gold', '') ~ '^[0-9]+$' then
      v_lv := case when coalesce(v_save->>'level', '') ~ '^[0-9]+$' then (v_save->>'level')::int else 50 end;
      v_gold := round((100 + v_lv * 8) * case when v_is_bot then 0.5 else 1 end);
      v_save := jsonb_set(v_save, '{gold}', to_jsonb((v_save->>'gold')::numeric + v_gold), true);
      update public.game_saves set save_data = v_save, updated_at = v_now, revision = revision + 1
      where user_id = v_user returning revision into v_rev;
      v_ret := jsonb_build_object('save_data', v_save, 'revision', v_rev, 'updated_at', v_now);
    end if;
  end if;
  return jsonb_build_object('me', public.arena_me_json(r), 'delta', v_datt, 'fichas', v_fichas, 'gold', v_gold, 'save', v_ret);
end $$;

-- ---------- 4) Ranking da semana ----------
create or replace function public.arena_ranking() returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_user uuid := auth.uid(); v_week date;
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  perform public.arena_rollover();
  v_week := public.arena_week_of(public.arena_today());
  return jsonb_build_object('top', coalesce((select jsonb_agg(t) from (
      select row_number() over (order by points desc, wins desc, user_id) as rank, name, cls, level, paragon, points,
             public.arena_league(points) as league, title, user_id = v_user as me
      from public.arena_players where week = v_week and week_fights > 0
      order by points desc, wins desc, user_id limit 20) t), '[]'::jsonb));
end $$;

-- ---------- 5) Registo dos meus combates ----------
create or replace function public.arena_log() returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare v_user uuid := auth.uid();
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  return coalesce((select jsonb_agg(t) from (
    select case when attacker = v_user then 'ataque' else 'defesa' end as kind,
           case when attacker = v_user then defender_name else attacker_name end as other,
           case when attacker = v_user then win else not win end as won,
           case when attacker = v_user then d_att else d_def end as delta,
           floor(extract(epoch from created_at) * 1000)::bigint as at
    from public.arena_matches where attacker = v_user or defender = v_user
    order by created_at desc limit 15) t), '[]'::jsonb);
end $$;

-- ---------- 6) Loja de Fichas ----------
create or replace function public.arena_buy(p_item text, p_choice text default null) returns jsonb language plpgsql security definer
set search_path = public, pg_temp as $$
declare
  v_user uuid := auth.uid(); r public.arena_players; v_cost integer; v_limit integer; v_week text;
  v_buys jsonb; v_n integer; v_save jsonb; v_good jsonb; v_name text; v_key text; v_rev bigint; v_now timestamptz := clock_timestamp();
  v_have numeric;
begin
  if v_user is null then raise exception 'É necessário iniciar sessão.'; end if;
  r := public.arena_lock_me(v_user);
  select cost, lim into v_cost, v_limit from (values
    ('reforco', 15, 5), ('feitico', 25, 5), ('gema1', 10, 0), ('gema2', 30, 3),
    ('alquimia', 30, 3), ('nucleo', 180, 1), ('perola', 12, 0)) as c(k, cost, lim) where c.k = p_item;
  if v_cost is null then raise exception 'Artigo inválido.'; end if;
  if r.fichas < v_cost then raise exception 'Não tens Fichas suficientes.'; end if;
  v_week := public.arena_week_of(public.arena_today())::text;
  v_buys := case when r.buys->>'week' = v_week then r.buys else jsonb_build_object('week', v_week) end;
  v_n := coalesce((v_buys->>p_item)::int, 0);
  if v_limit > 0 and v_n >= v_limit then raise exception 'Já compraste o máximo desta semana.'; end if;
  select save_data into v_save from public.game_saves where user_id = v_user for update;
  if not found then raise exception 'Não foi encontrado o teu save.'; end if;
  if p_item = 'nucleo' then
    v_key := (array['prisma_safira', 'ourico_ametista'])[1 + floor(random() * 2)::int];
    if jsonb_typeof(v_save->'coreStones') is distinct from 'object' then v_save := jsonb_set(v_save, '{coreStones}', '{}'::jsonb, true); end if;
    v_have := case when coalesce(v_save->'coreStones'->>v_key, '') ~ '^[0-9]+$' then (v_save->'coreStones'->>v_key)::numeric else 0 end;
    v_save := jsonb_set(v_save, array['coreStones', v_key], to_jsonb(v_have + 1), true);
    v_name := case v_key when 'prisma_safira' then 'Prisma da Safira' else 'Ouriço de Ametista' end;
  else
    if p_item in ('gema1', 'gema2') and coalesce(p_choice, '') not in ('defesa', 'dano', 'vida', 'critico', 'chefes', 'escudo') then
      raise exception 'Escolhe o tipo de gema.';
    end if;
    v_good := case p_item
      when 'reforco' then jsonb_build_object('kind', 'livro', 'key', 'reforco', 'sub', 0, 'qty', 1)
      when 'feitico' then jsonb_build_object('kind', 'livro', 'key', 'feitico', 'sub', 0, 'qty', 1)
      when 'gema1' then jsonb_build_object('kind', 'gema', 'key', p_choice, 'sub', 0, 'qty', 1)
      when 'gema2' then jsonb_build_object('kind', 'gema', 'key', p_choice, 'sub', 1, 'qty', 1)
      when 'alquimia' then jsonb_build_object('kind', 'pedra', 'key', (array['rubi', 'safira', 'granada', 'ametista'])[1 + floor(random() * 4)::int], 'sub', 2, 'qty', 1)
      else jsonb_build_object('kind', 'perola', 'key', (array['branca', 'verde', 'azul', 'vermelha'])[1 + floor(random() * 4)::int], 'sub', 0, 'qty', 1) end;
    v_name := public.nx_good_name(v_good->>'kind', v_good->>'key', (v_good->>'sub')::int);
    v_save := public.nx_good_add(v_save, v_good);
  end if;
  v_buys := jsonb_set(v_buys, array[p_item], to_jsonb(v_n + 1), true);
  update public.arena_players set fichas = fichas - v_cost, buys = v_buys where user_id = v_user returning * into r;
  update public.game_saves set save_data = v_save, updated_at = v_now, revision = revision + 1
  where user_id = v_user returning revision into v_rev;
  return jsonb_build_object('save_data', v_save, 'revision', v_rev, 'updated_at', v_now, 'item', v_name, 'me', public.arena_me_json(r));
end $$;

-- Só as funções que o jogo chama ficam abertas a jogadores com sessão.
revoke all on function public.arena_rollover() from public, anon, authenticated;
revoke all on function public.arena_lock_me(uuid) from public, anon, authenticated;
revoke all on function public.arena_me_json(public.arena_players) from public, anon, authenticated;
revoke all on function public.arena_sync(jsonb) from public, anon;
revoke all on function public.arena_opponents(boolean) from public, anon;
revoke all on function public.arena_report(text, boolean) from public, anon;
revoke all on function public.arena_ranking() from public, anon;
revoke all on function public.arena_log() from public, anon;
revoke all on function public.arena_buy(text, text) from public, anon;
grant execute on function public.arena_sync(jsonb) to authenticated;
grant execute on function public.arena_opponents(boolean) to authenticated;
grant execute on function public.arena_report(text, boolean) to authenticated;
grant execute on function public.arena_ranking() to authenticated;
grant execute on function public.arena_log() to authenticated;
grant execute on function public.arena_buy(text, text) to authenticated;
