-- ============================================================
-- 👥 AMIGOS (Herói → Amigos) — Nemesy RPG v98. É seguro voltar a executar.
-- Pedidos de amizade, bloqueios, chat privado 1 para 1 e trocas diretas entre amigos.
--
-- Segurança (mesma lógica do mercado de Trades):
--  • As tabelas não têm políticas: ninguém lhes toca diretamente, só pelas funções abaixo.
--  • Ao propor uma troca, os itens/ouro de quem propõe saem do save DENTRO do servidor e
--    ficam guardados na troca. Ao aceitar, o servidor troca tudo de uma vez.
--  • Quem não está a agir nunca vê o seu save alterado de surpresa: recebe as coisas como
--    "entregas" (friend_claims), aplicadas no próprio save com claim_friend_items().
--  • Os itens passam por clean_trade_item() (o mesmo verificador do mercado).
--  • Regras: nível 20+, até 100 000 de ouro enviado por dia, sem taxa, até 3 itens de
--    cada lado, troca expira em 48 h (tudo volta a quem propôs).
-- Requer: schema.sql (game_saves, clean_trade_item, hero_name_key) e guilds.sql (chat_mask).
-- ============================================================

create table if not exists public.friend_links (
  user_id uuid not null references auth.users (id) on delete cascade,
  friend_id uuid not null references auth.users (id) on delete cascade,
  status text not null check (status in ('pending', 'accepted')),
  requester uuid not null,
  created_at timestamptz not null default now(),
  primary key (user_id, friend_id),
  check (user_id <> friend_id)
);
create index if not exists friend_links_friend_idx on public.friend_links (friend_id);

create table if not exists public.friend_blocks (
  user_id uuid not null references auth.users (id) on delete cascade,
  blocked_id uuid not null references auth.users (id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, blocked_id)
);

create table if not exists public.friend_messages (
  id bigserial primary key,
  sender uuid not null references auth.users (id) on delete cascade,
  receiver uuid not null references auth.users (id) on delete cascade,
  body text not null,
  created_at timestamptz not null default now()
);
create index if not exists friend_messages_pair_idx on public.friend_messages (least(sender, receiver), greatest(sender, receiver), id);
create index if not exists friend_messages_receiver_idx on public.friend_messages (receiver, id);

create table if not exists public.friend_reads (
  user_id uuid not null references auth.users (id) on delete cascade,
  friend_id uuid not null references auth.users (id) on delete cascade,
  last_read_id bigint not null default 0,
  primary key (user_id, friend_id)
);

create table if not exists public.friend_trades (
  id uuid primary key default gen_random_uuid(),
  from_user uuid not null references auth.users (id) on delete cascade,
  to_user uuid not null references auth.users (id) on delete cascade,
  from_name text,
  to_name text,
  offer_items jsonb not null default '[]'::jsonb,      -- itens já retirados do save de quem propôs
  offer_gold bigint not null default 0 check (offer_gold >= 0),
  request_items jsonb not null default '[]'::jsonb,    -- cópia (para mostrar) dos itens pedidos ao amigo
  request_gold bigint not null default 0 check (request_gold >= 0),
  status text not null default 'open' check (status in ('open', 'accepted', 'declined', 'cancelled', 'expired')),
  created_at timestamptz not null default now(),
  expires_at timestamptz not null default now() + interval '48 hours',
  resolved_at timestamptz
);
create index if not exists friend_trades_from_idx on public.friend_trades (from_user, status);
create index if not exists friend_trades_to_idx on public.friend_trades (to_user, status);

create table if not exists public.friend_claims (
  id bigserial primary key,
  user_id uuid not null references auth.users (id) on delete cascade,
  items jsonb not null default '[]'::jsonb,
  gold bigint not null default 0 check (gold >= 0),
  reason text not null,
  from_name text,
  created_at timestamptz not null default now()
);
create index if not exists friend_claims_user_idx on public.friend_claims (user_id);

create table if not exists public.friend_gold_daily (
  user_id uuid not null references auth.users (id) on delete cascade,
  day date not null,
  amount bigint not null default 0,
  primary key (user_id, day)
);

alter table public.friend_links enable row level security;
alter table public.friend_blocks enable row level security;
alter table public.friend_messages enable row level security;
alter table public.friend_reads enable row level security;
alter table public.friend_trades enable row level security;
alter table public.friend_claims enable row level security;
alter table public.friend_gold_daily enable row level security;
revoke all on public.friend_links, public.friend_blocks, public.friend_messages, public.friend_reads,
  public.friend_trades, public.friend_claims, public.friend_gold_daily from anon, authenticated;

-- ---------- regras ----------
create or replace function public.friend_settings()
returns jsonb language sql immutable as $$
  select jsonb_build_object('min_level', 20, 'max_friends', 50, 'max_pending', 20, 'gold_daily', 100000,
    'max_items', 3, 'max_open_trades', 5, 'trade_hours', 48, 'chat_keep', 100, 'chat_max', 200)
$$;

create or replace function public.friend_name(p_user uuid)
returns text language sql stable security definer set search_path = public, pg_temp as $$
  select left(coalesce(nullif(btrim(save_data->>'name'), ''), 'Herói'), 16) from public.game_saves where user_id = p_user
$$;

create or replace function public.friend_level(p_user uuid)
returns integer language sql stable security definer set search_path = public, pg_temp as $$
  select case when coalesce(save_data->>'level', '') ~ '^[0-9]+$' then (save_data->>'level')::integer else 1 end
  from public.game_saves where user_id = p_user
$$;

create or replace function public.friend_are_friends(p_a uuid, p_b uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.friend_links where user_id = p_a and friend_id = p_b and status = 'accepted')
$$;

create or replace function public.friend_is_blocked(p_a uuid, p_b uuid)
returns boolean language sql stable security definer set search_path = public, pg_temp as $$
  select exists (select 1 from public.friend_blocks where (user_id = p_a and blocked_id = p_b) or (user_id = p_b and blocked_id = p_a))
$$;

-- Conta o ouro enviado hoje (UTC). p_delta negativo devolve (troca recusada/cancelada).
create or replace function public.friend_gold_add(p_user uuid, p_delta bigint)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_limit bigint := (public.friend_settings()->>'gold_daily')::bigint;
  v_now bigint;
begin
  if coalesce(p_delta, 0) = 0 then return; end if;
  insert into public.friend_gold_daily (user_id, day, amount) values (p_user, (now() at time zone 'utc')::date, greatest(p_delta, 0))
  on conflict (user_id, day) do update set amount = greatest(0, public.friend_gold_daily.amount + p_delta)
  returning amount into v_now;
  if p_delta > 0 and v_now > v_limit then
    raise exception 'Limite diário: só podes enviar % de ouro por dia a amigos (já enviaste % hoje).', v_limit, v_now - p_delta;
  end if;
end;
$$;

-- Devolve a quem propôs tudo o que está guardado numa troca (como entrega).
create or replace function public.friend_trade_refund(p_trade public.friend_trades, p_status text)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
begin
  update public.friend_trades set status = p_status, resolved_at = clock_timestamp() where id = p_trade.id and status = 'open';
  if not found then return; end if;
  if jsonb_array_length(p_trade.offer_items) > 0 or p_trade.offer_gold > 0 then
    insert into public.friend_claims (user_id, items, gold, reason, from_name)
    values (p_trade.from_user, p_trade.offer_items, p_trade.offer_gold, 'refund_' || p_status, p_trade.to_name);
  end if;
  -- o ouro devolvido deixa de contar para o limite diário (só se ainda for o mesmo dia)
  if p_trade.offer_gold > 0 and (p_trade.created_at at time zone 'utc')::date = (now() at time zone 'utc')::date then
    update public.friend_gold_daily set amount = greatest(0, amount - p_trade.offer_gold)
    where user_id = p_trade.from_user and day = (now() at time zone 'utc')::date;
  end if;
end;
$$;

-- Trocas que passaram das 48 h voltam para quem as propôs.
create or replace function public.friend_expire_trades()
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.friend_trades;
begin
  for r in select * from public.friend_trades where status = 'open' and expires_at < clock_timestamp() for update skip locked loop
    perform public.friend_trade_refund(r, 'expired');
  end loop;
end;
$$;

-- Cancela (e devolve) as trocas abertas entre dois jogadores — ao remover/bloquear.
create or replace function public.friend_cancel_between(p_a uuid, p_b uuid)
returns void language plpgsql security definer set search_path = public, pg_temp as $$
declare r public.friend_trades;
begin
  for r in select * from public.friend_trades where status = 'open'
    and ((from_user = p_a and to_user = p_b) or (from_user = p_b and to_user = p_a)) for update loop
    perform public.friend_trade_refund(r, 'cancelled');
  end loop;
end;
$$;

-- ---------- pedidos de amizade ----------
create or replace function public.send_friend_request(p_name text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_me uuid := auth.uid();
  v_target uuid;
  v_cfg jsonb := public.friend_settings();
  v_count integer;
begin
  if v_me is null then raise exception 'É necessário iniciar sessão.'; end if;
  if public.hero_name_key(p_name) = '' then raise exception 'Escreve o nome do herói.'; end if;
  select user_id into v_target from public.game_saves
  where public.hero_name_key(save_data->>'name') = public.hero_name_key(p_name) limit 1;
  if v_target is null then raise exception 'Não existe nenhum herói com esse nome.'; end if;
  if v_target = v_me then raise exception 'Não te podes adicionar a ti próprio.'; end if;
  if exists (select 1 from public.friend_blocks where user_id = v_me and blocked_id = v_target) then
    raise exception 'Bloqueaste este jogador. Desbloqueia-o primeiro.';
  end if;
  if exists (select 1 from public.friend_blocks where user_id = v_target and blocked_id = v_me) then
    raise exception 'Não é possível adicionar este jogador.';
  end if;
  if public.friend_are_friends(v_me, v_target) then raise exception 'Já são amigos.'; end if;
  -- Se ele já me tinha pedido amizade, aceitar logo.
  if exists (select 1 from public.friend_links where user_id = v_me and friend_id = v_target and status = 'pending' and requester = v_target) then
    return public.respond_friend_request(v_target, true);
  end if;
  if exists (select 1 from public.friend_links where user_id = v_me and friend_id = v_target) then
    raise exception 'Já enviaste um pedido a este jogador.';
  end if;
  select count(*) into v_count from public.friend_links where user_id = v_me and status = 'accepted';
  if v_count >= (v_cfg->>'max_friends')::integer then raise exception 'Já tens o máximo de % amigos.', v_cfg->>'max_friends'; end if;
  select count(*) into v_count from public.friend_links where user_id = v_target and status = 'accepted';
  if v_count >= (v_cfg->>'max_friends')::integer then raise exception 'Esse jogador já tem a lista de amigos cheia.'; end if;
  select count(*) into v_count from public.friend_links where user_id = v_me and status = 'pending' and requester = v_me;
  if v_count >= (v_cfg->>'max_pending')::integer then raise exception 'Tens demasiados pedidos por responder. Espera ou cancela alguns.'; end if;
  insert into public.friend_links (user_id, friend_id, status, requester) values (v_me, v_target, 'pending', v_me), (v_target, v_me, 'pending', v_me);
  return jsonb_build_object('ok', true, 'status', 'pending', 'name', public.friend_name(v_target));
end;
$$;

create or replace function public.respond_friend_request(p_user uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_me uuid := auth.uid();
  v_cfg jsonb := public.friend_settings();
  v_count integer;
begin
  if v_me is null then raise exception 'É necessário iniciar sessão.'; end if;
  perform 1 from public.friend_links where user_id = v_me and friend_id = p_user and status = 'pending' for update;
  if not found then raise exception 'Este pedido já não existe.'; end if;
  if p_accept then
    if not exists (select 1 from public.friend_links where user_id = v_me and friend_id = p_user and requester = p_user) then
      raise exception 'Só quem recebeu o pedido o pode aceitar.';
    end if;
    select count(*) into v_count from public.friend_links where user_id = v_me and status = 'accepted';
    if v_count >= (v_cfg->>'max_friends')::integer then raise exception 'Já tens o máximo de % amigos.', v_cfg->>'max_friends'; end if;
    select count(*) into v_count from public.friend_links where user_id = p_user and status = 'accepted';
    if v_count >= (v_cfg->>'max_friends')::integer then raise exception 'Esse jogador já tem a lista de amigos cheia.'; end if;
    update public.friend_links set status = 'accepted', created_at = now()
    where (user_id = v_me and friend_id = p_user) or (user_id = p_user and friend_id = v_me);
    return jsonb_build_object('ok', true, 'status', 'accepted', 'name', public.friend_name(p_user));
  end if;
  -- recusar (quem recebeu) ou cancelar (quem enviou)
  delete from public.friend_links where (user_id = v_me and friend_id = p_user) or (user_id = p_user and friend_id = v_me);
  return jsonb_build_object('ok', true, 'status', 'removed');
end;
$$;

create or replace function public.remove_friend(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'É necessário iniciar sessão.'; end if;
  delete from public.friend_links where (user_id = v_me and friend_id = p_user) or (user_id = p_user and friend_id = v_me);
  perform public.friend_cancel_between(v_me, p_user);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.block_player(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'É necessário iniciar sessão.'; end if;
  if p_user is null or p_user = v_me then raise exception 'Jogador inválido.'; end if;
  if not exists (select 1 from public.game_saves where user_id = p_user) then raise exception 'Jogador inválido.'; end if;
  if (select count(*) from public.friend_blocks where user_id = v_me) >= 200 then raise exception 'Já bloqueaste demasiados jogadores.'; end if;
  insert into public.friend_blocks (user_id, blocked_id) values (v_me, p_user) on conflict do nothing;
  delete from public.friend_links where (user_id = v_me and friend_id = p_user) or (user_id = p_user and friend_id = v_me);
  perform public.friend_cancel_between(v_me, p_user);
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.unblock_player(p_user uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'É necessário iniciar sessão.'; end if;
  delete from public.friend_blocks where user_id = v_me and blocked_id = p_user;
  return jsonb_build_object('ok', true);
end;
$$;

-- ---------- lista ----------
create or replace function public.get_friends()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_me uuid := auth.uid();
  v_cfg jsonb := public.friend_settings();
begin
  if v_me is null then raise exception 'É necessário iniciar sessão.'; end if;
  perform public.friend_expire_trades();
  return jsonb_build_object(
    'settings', v_cfg,
    'my_level', public.friend_level(v_me),
    'gold_sent_today', coalesce((select amount from public.friend_gold_daily where user_id = v_me and day = (now() at time zone 'utc')::date), 0),
    'friends', coalesce((
      select jsonb_agg(jsonb_build_object(
        'id', l.friend_id, 'name', left(coalesce(nullif(btrim(g.save_data->>'name'), ''), 'Herói'), 16),
        'class', g.save_data->>'class', 'evolution', g.save_data->>'evolution',
        'level', case when coalesce(g.save_data->>'level', '') ~ '^[0-9]+$' then (g.save_data->>'level')::integer else 1 end,
        'guild', (select gg.name from public.guild_members gm join public.guilds gg on gg.id = gm.guild_id where gm.user_id = l.friend_id),
        'last_seen', floor(extract(epoch from g.updated_at) * 1000)::bigint,
        'unread', (select count(*) from public.friend_messages m where m.sender = l.friend_id and m.receiver = v_me
                   and m.id > coalesce((select r.last_read_id from public.friend_reads r where r.user_id = v_me and r.friend_id = l.friend_id), 0)),
        'trades_in', (select count(*) from public.friend_trades t where t.status = 'open' and t.from_user = l.friend_id and t.to_user = v_me),
        'trades_out', (select count(*) from public.friend_trades t where t.status = 'open' and t.from_user = v_me and t.to_user = l.friend_id)
      ) order by g.updated_at desc)
      from public.friend_links l join public.game_saves g on g.user_id = l.friend_id
      where l.user_id = v_me and l.status = 'accepted'), '[]'::jsonb),
    'incoming', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.friend_id, 'name', public.friend_name(l.friend_id), 'level', public.friend_level(l.friend_id),
        'class', (select save_data->>'class' from public.game_saves where user_id = l.friend_id)) order by l.created_at desc)
      from public.friend_links l where l.user_id = v_me and l.status = 'pending' and l.requester <> v_me), '[]'::jsonb),
    'outgoing', coalesce((
      select jsonb_agg(jsonb_build_object('id', l.friend_id, 'name', public.friend_name(l.friend_id), 'level', public.friend_level(l.friend_id)) order by l.created_at desc)
      from public.friend_links l where l.user_id = v_me and l.status = 'pending' and l.requester = v_me), '[]'::jsonb),
    'blocked', coalesce((
      select jsonb_agg(jsonb_build_object('id', b.blocked_id, 'name', coalesce(public.friend_name(b.blocked_id), 'Herói')) order by b.created_at desc)
      from public.friend_blocks b where b.user_id = v_me), '[]'::jsonb),
    'claims', (select count(*) from public.friend_claims where user_id = v_me)
  );
end;
$$;

-- Só os números (para a bolinha vermelha do mosaico): pedidos + mensagens + trocas recebidas.
create or replace function public.friend_badge()
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then return jsonb_build_object('total', 0); end if;
  return jsonb_build_object(
    'requests', (select count(*) from public.friend_links where user_id = v_me and status = 'pending' and requester <> v_me),
    'unread', (select count(*) from public.friend_messages m where m.receiver = v_me
               and exists (select 1 from public.friend_links l where l.user_id = v_me and l.friend_id = m.sender and l.status = 'accepted')
               and m.id > coalesce((select r.last_read_id from public.friend_reads r where r.user_id = v_me and r.friend_id = m.sender), 0)),
    'trades', (select count(*) from public.friend_trades where to_user = v_me and status = 'open' and expires_at > clock_timestamp()),
    'claims', (select count(*) from public.friend_claims where user_id = v_me)
  );
end;
$$;

-- ---------- chat privado ----------
create or replace function public.send_friend_message(p_friend uuid, p_body text)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_me uuid := auth.uid();
  v_body text := btrim(regexp_replace(regexp_replace(coalesce(p_body, ''), '[[:cntrl:]]+', ' ', 'g'), '[­͏؜ᅟᅠ឴឵᠋-᠏​‌‎‏‪-‮⁠-⁯⠀ㅤ︀-︍﻿ﾠ]', '', 'g'));
  v_id bigint;
  v_cut bigint;
begin
  if v_me is null then raise exception 'É necessário iniciar sessão.'; end if;
  if not public.friend_are_friends(v_me, p_friend) then raise exception 'Só podes falar com os teus amigos.'; end if;
  if public.friend_is_blocked(v_me, p_friend) then raise exception 'Não é possível falar com este jogador.'; end if;
  if char_length(v_body) < 1 then raise exception 'Escreve uma mensagem.'; end if;
  if char_length(v_body) > 200 then raise exception 'A mensagem pode ter no máximo 200 caracteres.'; end if;
  if exists (select 1 from public.friend_messages where sender = v_me and created_at > clock_timestamp() - interval '1 second') then
    raise exception 'Estás a escrever depressa demais. Espera um segundo.';
  end if;
  if (select count(*) from public.friend_messages where sender = v_me and created_at > clock_timestamp() - interval '1 minute') >= 30 then
    raise exception 'Demasiadas mensagens seguidas. Espera um pouco.';
  end if;
  insert into public.friend_messages (sender, receiver, body) values (v_me, p_friend, public.chat_mask(v_body)) returning id into v_id;
  -- Só se guardam as últimas 100 mensagens de cada conversa.
  select id into v_cut from public.friend_messages
  where least(sender, receiver) = least(v_me, p_friend) and greatest(sender, receiver) = greatest(v_me, p_friend)
  order by id desc offset 100 limit 1;
  if v_cut is not null then
    delete from public.friend_messages
    where least(sender, receiver) = least(v_me, p_friend) and greatest(sender, receiver) = greatest(v_me, p_friend) and id <= v_cut;
  end if;
  return jsonb_build_object('id', v_id);
end;
$$;

-- p_after_id = 0 → últimas 50; senão só as mais recentes. Marca a conversa como lida.
create or replace function public.get_friend_messages(p_friend uuid, p_after_id bigint default 0)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_me uuid := auth.uid();
  v_rows jsonb;
  v_max bigint;
begin
  if v_me is null then raise exception 'É necessário iniciar sessão.'; end if;
  if not public.friend_are_friends(v_me, p_friend) then raise exception 'Só podes ver conversas com os teus amigos.'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('id', t.id, 'body', t.body, 'is_me', t.sender = v_me,
           'at', floor(extract(epoch from t.created_at) * 1000)::bigint) order by t.id), '[]'::jsonb), max(t.id)
  into v_rows, v_max
  from (
    select * from public.friend_messages
    where least(sender, receiver) = least(v_me, p_friend) and greatest(sender, receiver) = greatest(v_me, p_friend)
      and id > coalesce(p_after_id, 0)
    order by id desc limit 50
  ) t;
  if v_max is not null then
    insert into public.friend_reads (user_id, friend_id, last_read_id) values (v_me, p_friend, v_max)
    on conflict (user_id, friend_id) do update set last_read_id = greatest(public.friend_reads.last_read_id, excluded.last_read_id);
  end if;
  return v_rows;
end;
$$;

-- ---------- trocas ----------
-- Itens que o amigo pode trocar (para escolheres o que lhe pedes). Itens 🔒 não aparecem.
create or replace function public.get_friend_inventory(p_friend uuid)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_me uuid := auth.uid();
  v_out jsonb := '[]'::jsonb;
  v_item jsonb;
  v_clean jsonb;
begin
  if v_me is null then raise exception 'É necessário iniciar sessão.'; end if;
  if not public.friend_are_friends(v_me, p_friend) then raise exception 'Só podes trocar com os teus amigos.'; end if;
  for v_item in select item from public.game_saves g, jsonb_array_elements(case when jsonb_typeof(g.save_data->'inventory') = 'array' then g.save_data->'inventory' else '[]'::jsonb end) item
                where g.user_id = p_friend loop
    if coalesce(v_item->>'locked', 'false') = 'true' or coalesce(v_item->>'id', '') = '' then continue; end if;
    begin
      v_clean := public.clean_trade_item(v_item);
      v_out := v_out || jsonb_build_array(jsonb_set(v_clean, '{id}', to_jsonb(v_item->>'id')));
    exception when others then null;
    end;
    exit when jsonb_array_length(v_out) >= 300;
  end loop;
  return v_out;
end;
$$;

-- Retira itens (por id) de um save. Devolve {save, items}. Erro se algum faltar/estiver 🔒.
create or replace function public.friend_take_items(p_save jsonb, p_ids text[])
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_inv jsonb := case when jsonb_typeof(p_save->'inventory') = 'array' then p_save->'inventory' else null end;
  v_id text;
  v_item jsonb;
  v_items jsonb := '[]'::jsonb;
  v_n integer;
begin
  if v_inv is null then raise exception 'A mochila não é válida.'; end if;
  foreach v_id in array coalesce(p_ids, '{}'::text[]) loop
    select count(*) into v_n from jsonb_array_elements(v_inv) i where i->>'id' = v_id;
    if v_n <> 1 then raise exception 'Um dos itens já não está na mochila.'; end if;
    select i into v_item from jsonb_array_elements(v_inv) i where i->>'id' = v_id;
    if coalesce(v_item->>'locked', 'false') = 'true' then raise exception 'Itens bloqueados (🔒) não podem ser trocados.'; end if;
    v_items := v_items || jsonb_build_array(public.clean_trade_item(v_item));
    select coalesce(jsonb_agg(i), '[]'::jsonb) into v_inv from jsonb_array_elements(v_inv) i where i->>'id' <> v_id;
  end loop;
  return jsonb_build_object('save', jsonb_set(p_save, '{inventory}', v_inv, true), 'items', v_items);
end;
$$;

-- Dá itens novos (com IDs novos) a um save.
create or replace function public.friend_give_items(p_save jsonb, p_items jsonb)
returns jsonb language plpgsql stable security definer set search_path = public, pg_temp as $$
declare
  v_inv jsonb := case when jsonb_typeof(p_save->'inventory') = 'array' then p_save->'inventory' else '[]'::jsonb end;
  v_item jsonb;
begin
  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    v_inv := v_inv || jsonb_build_array(jsonb_set(v_item, '{id}', to_jsonb('it_fr_' || replace(gen_random_uuid()::text, '-', '')), true));
  end loop;
  return jsonb_set(p_save, '{inventory}', v_inv, true);
end;
$$;

create or replace function public.friend_gold_of(p_save jsonb)
returns bigint language plpgsql immutable as $$
begin
  if coalesce(p_save->>'gold', '') !~ '^[0-9]+$' then raise exception 'O saldo de ouro não é válido.'; end if;
  return (p_save->>'gold')::bigint;
end;
$$;

-- (as listas de itens chegam em JSON — funciona igual em qualquer cliente)
drop function if exists public.propose_friend_trade(uuid, text[], bigint, text[], bigint);
create or replace function public.propose_friend_trade(p_friend uuid, p_offer_ids jsonb, p_offer_gold bigint, p_request_ids jsonb, p_request_gold bigint)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_me uuid := auth.uid();
  v_cfg jsonb := public.friend_settings();
  v_save jsonb;
  v_friend_save jsonb;
  v_taken jsonb;
  v_req jsonb;
  v_offer_gold bigint := greatest(coalesce(p_offer_gold, 0), 0);
  v_request_gold bigint := greatest(coalesce(p_request_gold, 0), 0);
  v_offer_ids text[];
  v_request_ids text[];
  v_gold bigint;
  v_id uuid;
  v_rev bigint;
  v_now timestamptz := clock_timestamp();
begin
  if v_me is null then raise exception 'É necessário iniciar sessão.'; end if;
  if coalesce(jsonb_typeof(p_offer_ids), 'array') <> 'array' or coalesce(jsonb_typeof(p_request_ids), 'array') <> 'array' then raise exception 'Lista de itens inválida.'; end if;
  select coalesce(array_agg(x), '{}'::text[]) into v_offer_ids from jsonb_array_elements_text(coalesce(p_offer_ids, '[]'::jsonb)) x;
  select coalesce(array_agg(x), '{}'::text[]) into v_request_ids from jsonb_array_elements_text(coalesce(p_request_ids, '[]'::jsonb)) x;
  perform public.friend_expire_trades();
  if not public.friend_are_friends(v_me, p_friend) then raise exception 'Só podes trocar com os teus amigos.'; end if;
  if public.friend_is_blocked(v_me, p_friend) then raise exception 'Não é possível trocar com este jogador.'; end if;
  if public.friend_level(v_me) < (v_cfg->>'min_level')::integer then raise exception 'As trocas com amigos abrem no nível %.', v_cfg->>'min_level'; end if;
  if coalesce(public.friend_level(p_friend), 0) < (v_cfg->>'min_level')::integer then raise exception 'O teu amigo ainda não chegou ao nível %.', v_cfg->>'min_level'; end if;
  if cardinality(v_offer_ids) > (v_cfg->>'max_items')::integer or cardinality(v_request_ids) > (v_cfg->>'max_items')::integer then
    raise exception 'No máximo % itens de cada lado.', v_cfg->>'max_items';
  end if;
  if (select count(distinct x) from unnest(v_offer_ids) x) <> cardinality(v_offer_ids) or (select count(distinct x) from unnest(v_request_ids) x) <> cardinality(v_request_ids) then
    raise exception 'Itens repetidos na troca.';
  end if;
  if v_offer_gold > 2000000000 or v_request_gold > 2000000000 then raise exception 'Quantia de ouro inválida.'; end if;
  if cardinality(v_offer_ids) = 0 and v_offer_gold = 0 then raise exception 'Escolhe pelo menos um item ou ouro para dar.'; end if;
  if (select count(*) from public.friend_trades where from_user = v_me and status = 'open') >= (v_cfg->>'max_open_trades')::integer then
    raise exception 'Já tens % trocas à espera de resposta.', v_cfg->>'max_open_trades';
  end if;

  select save_data into v_save from public.game_saves where user_id = v_me for update;
  if not found then raise exception 'Não foi encontrado o teu save.'; end if;
  v_gold := public.friend_gold_of(v_save);
  if v_gold < v_offer_gold then raise exception 'Não tens ouro suficiente.'; end if;

  -- itens pedidos: têm de existir agora na mochila do amigo (cópia só para mostrar)
  select save_data into v_friend_save from public.game_saves where user_id = p_friend;
  v_req := (public.friend_take_items(v_friend_save, v_request_ids))->'items';
  v_req := (select coalesce(jsonb_agg(jsonb_set(x.item, '{id}', to_jsonb(v_request_ids[x.n]))), '[]'::jsonb)
            from jsonb_array_elements(v_req) with ordinality x(item, n));

  v_taken := public.friend_take_items(v_save, v_offer_ids);
  v_save := jsonb_set(v_taken->'save', '{gold}', to_jsonb(v_gold - v_offer_gold), true);
  perform public.friend_gold_add(v_me, v_offer_gold);

  insert into public.friend_trades (from_user, to_user, from_name, to_name, offer_items, offer_gold, request_items, request_gold, expires_at)
  values (v_me, p_friend, public.friend_name(v_me), public.friend_name(p_friend), v_taken->'items', v_offer_gold, v_req, v_request_gold,
          v_now + make_interval(hours => (v_cfg->>'trade_hours')::integer))
  returning id into v_id;

  update public.game_saves set save_data = v_save, updated_at = v_now, revision = revision + 1
  where user_id = v_me returning revision into v_rev;
  return jsonb_build_object('trade_id', v_id, 'save_data', v_save, 'updated_at', v_now, 'revision', v_rev);
end;
$$;

create or replace function public.respond_friend_trade(p_trade uuid, p_accept boolean)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_me uuid := auth.uid();
  v_t public.friend_trades;
  v_save jsonb;
  v_taken jsonb;
  v_gold bigint;
  v_ids text[];
  v_rev bigint;
  v_now timestamptz := clock_timestamp();
begin
  if v_me is null then raise exception 'É necessário iniciar sessão.'; end if;
  select * into v_t from public.friend_trades where id = p_trade for update;
  if not found or v_t.to_user <> v_me then raise exception 'Esta troca já não existe.'; end if;
  if v_t.status <> 'open' then raise exception 'Esta troca já foi resolvida.'; end if;
  if v_t.expires_at < v_now then perform public.friend_trade_refund(v_t, 'expired'); return jsonb_build_object('ok', false, 'status', 'expired'); end if;

  if not p_accept then
    perform public.friend_trade_refund(v_t, 'declined');
    return jsonb_build_object('ok', true, 'status', 'declined');
  end if;

  if public.friend_level(v_me) < (public.friend_settings()->>'min_level')::integer then
    raise exception 'As trocas com amigos abrem no nível %.', public.friend_settings()->>'min_level';
  end if;
  select save_data into v_save from public.game_saves where user_id = v_me for update;
  if not found then raise exception 'Não foi encontrado o teu save.'; end if;
  v_gold := public.friend_gold_of(v_save);
  if v_gold < v_t.request_gold then raise exception 'Não tens ouro suficiente para esta troca.'; end if;
  select coalesce(array_agg(x->>'id'), '{}'::text[]) into v_ids from jsonb_array_elements(v_t.request_items) x;
  v_taken := public.friend_take_items(v_save, v_ids);
  v_save := v_taken->'save';
  if jsonb_array_length(v_save->'inventory') + jsonb_array_length(v_t.offer_items) > 1500 then raise exception 'A tua mochila está cheia.'; end if;
  v_save := public.friend_give_items(v_save, v_t.offer_items);
  v_save := jsonb_set(v_save, '{gold}', to_jsonb(v_gold - v_t.request_gold + v_t.offer_gold), true);
  perform public.friend_gold_add(v_me, v_t.request_gold);

  update public.friend_trades set status = 'accepted', resolved_at = v_now where id = v_t.id;
  if jsonb_array_length(v_taken->'items') > 0 or v_t.request_gold > 0 then
    insert into public.friend_claims (user_id, items, gold, reason, from_name)
    values (v_t.from_user, v_taken->'items', v_t.request_gold, 'trade', v_t.to_name);
  else
    insert into public.friend_claims (user_id, items, gold, reason, from_name) values (v_t.from_user, '[]'::jsonb, 0, 'gift_ok', v_t.to_name);
  end if;

  update public.game_saves set save_data = v_save, updated_at = v_now, revision = revision + 1
  where user_id = v_me returning revision into v_rev;
  return jsonb_build_object('ok', true, 'status', 'accepted', 'save_data', v_save, 'updated_at', v_now, 'revision', v_rev,
    'got_items', jsonb_array_length(v_t.offer_items), 'got_gold', v_t.offer_gold);
end;
$$;

-- Quem propôs cancela: recebe logo de volta no próprio save.
create or replace function public.cancel_friend_trade(p_trade uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_me uuid := auth.uid();
  v_t public.friend_trades;
  v_save jsonb;
  v_rev bigint;
  v_now timestamptz := clock_timestamp();
begin
  if v_me is null then raise exception 'É necessário iniciar sessão.'; end if;
  select * into v_t from public.friend_trades where id = p_trade for update;
  if not found or v_t.from_user <> v_me then raise exception 'Esta troca já não existe.'; end if;
  if v_t.status <> 'open' then raise exception 'Esta troca já foi resolvida.'; end if;
  select save_data into v_save from public.game_saves where user_id = v_me for update;
  if not found then raise exception 'Não foi encontrado o teu save.'; end if;
  v_save := public.friend_give_items(v_save, v_t.offer_items);
  v_save := jsonb_set(v_save, '{gold}', to_jsonb(public.friend_gold_of(v_save) + v_t.offer_gold), true);
  update public.friend_trades set status = 'cancelled', resolved_at = v_now where id = v_t.id;
  if v_t.offer_gold > 0 and (v_t.created_at at time zone 'utc')::date = (now() at time zone 'utc')::date then
    update public.friend_gold_daily set amount = greatest(0, amount - v_t.offer_gold) where user_id = v_me and day = (now() at time zone 'utc')::date;
  end if;
  update public.game_saves set save_data = v_save, updated_at = v_now, revision = revision + 1
  where user_id = v_me returning revision into v_rev;
  return jsonb_build_object('ok', true, 'save_data', v_save, 'updated_at', v_now, 'revision', v_rev);
end;
$$;

-- Trocas com um amigo (abertas + últimas 10 resolvidas).
create or replace function public.get_friend_trades(p_friend uuid)
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare v_me uuid := auth.uid();
begin
  if v_me is null then raise exception 'É necessário iniciar sessão.'; end if;
  perform public.friend_expire_trades();
  return coalesce((
    select jsonb_agg(jsonb_build_object('id', t.id, 'mine', t.from_user = v_me, 'status', t.status,
      'offer_items', t.offer_items, 'offer_gold', t.offer_gold, 'request_items', t.request_items, 'request_gold', t.request_gold,
      'created_at', floor(extract(epoch from t.created_at) * 1000)::bigint, 'expires_at', floor(extract(epoch from t.expires_at) * 1000)::bigint)
      order by (t.status = 'open') desc, t.created_at desc)
    from (
      select * from public.friend_trades
      where ((from_user = v_me and to_user = p_friend) or (from_user = p_friend and to_user = v_me))
      order by (status = 'open') desc, created_at desc limit 15
    ) t
  ), '[]'::jsonb);
end;
$$;

-- Entregas pendentes (itens/ouro de trocas aceites, recusadas, canceladas ou expiradas).
create or replace function public.claim_friend_items()
returns jsonb language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_me uuid := auth.uid();
  v_save jsonb;
  v_c record;
  v_lines jsonb := '[]'::jsonb;
  v_gold numeric;
  v_n integer := 0;
  v_rev bigint;
  v_now timestamptz := clock_timestamp();
begin
  if v_me is null then raise exception 'É necessário iniciar sessão.'; end if;
  perform public.friend_expire_trades();
  select save_data into v_save from public.game_saves where user_id = v_me for update;
  if not found then return jsonb_build_object('count', 0); end if;
  v_gold := public.friend_gold_of(v_save);
  for v_c in delete from public.friend_claims where user_id = v_me returning * loop
    v_n := v_n + 1;
    v_save := public.friend_give_items(v_save, v_c.items);
    v_gold := v_gold + v_c.gold;
    v_lines := v_lines || jsonb_build_array(jsonb_build_object('reason', v_c.reason, 'from', v_c.from_name, 'gold', v_c.gold,
      'items', (select coalesce(jsonb_agg(jsonb_build_object('name', i->>'name', 'rarity', i->>'rarity')), '[]'::jsonb) from jsonb_array_elements(v_c.items) i)));
  end loop;
  if v_n = 0 then return jsonb_build_object('count', 0); end if;
  if v_gold > 9007199254740991 then raise exception 'O teu saldo atingiu o limite suportado.'; end if;
  if jsonb_array_length(v_save->'inventory') > 1500 then raise exception 'A tua mochila está cheia — liberta espaço para receberes os itens.'; end if;
  v_save := jsonb_set(v_save, '{gold}', to_jsonb(v_gold), true);
  update public.game_saves set save_data = v_save, updated_at = v_now, revision = revision + 1
  where user_id = v_me returning revision into v_rev;
  return jsonb_build_object('count', v_n, 'lines', v_lines, 'save_data', v_save, 'updated_at', v_now, 'revision', v_rev);
end;
$$;

-- Recomeçar a aventura: além dos anúncios, também não pode haver trocas com amigos abertas.
create or replace function public.reset_player_game()
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
begin
  if v_user_id is null then raise exception 'É necessário iniciar sessão.'; end if;
  perform 1 from public.game_saves where user_id = v_user_id for update;
  if exists (select 1 from public.player_trade_listings where seller_id = v_user_id) then
    raise exception 'Retira os teus anúncios no separador Trades antes de recomeçar a aventura.';
  end if;
  if exists (select 1 from public.friend_trades where from_user = v_user_id and status = 'open') then
    raise exception 'Cancela as tuas trocas com amigos (Herói → Amigos) antes de recomeçar a aventura.';
  end if;
  delete from public.friend_claims where user_id = v_user_id;
  delete from public.game_saves where user_id = v_user_id;
end;
$$;

-- ---------- permissões ----------
revoke all on function public.friend_settings(), public.friend_name(uuid), public.friend_level(uuid), public.friend_are_friends(uuid, uuid),
  public.friend_is_blocked(uuid, uuid), public.friend_gold_add(uuid, bigint), public.friend_trade_refund(public.friend_trades, text),
  public.friend_expire_trades(), public.friend_cancel_between(uuid, uuid), public.friend_take_items(jsonb, text[]),
  public.friend_give_items(jsonb, jsonb), public.friend_gold_of(jsonb) from public, anon, authenticated;
revoke all on function public.send_friend_request(text), public.respond_friend_request(uuid, boolean), public.remove_friend(uuid),
  public.block_player(uuid), public.unblock_player(uuid), public.get_friends(), public.friend_badge(),
  public.send_friend_message(uuid, text), public.get_friend_messages(uuid, bigint), public.get_friend_inventory(uuid),
  public.propose_friend_trade(uuid, jsonb, bigint, jsonb, bigint), public.respond_friend_trade(uuid, boolean),
  public.cancel_friend_trade(uuid), public.get_friend_trades(uuid), public.claim_friend_items(), public.reset_player_game() from public, anon;
grant execute on function public.send_friend_request(text), public.respond_friend_request(uuid, boolean), public.remove_friend(uuid),
  public.block_player(uuid), public.unblock_player(uuid), public.get_friends(), public.friend_badge(),
  public.send_friend_message(uuid, text), public.get_friend_messages(uuid, bigint), public.get_friend_inventory(uuid),
  public.propose_friend_trade(uuid, jsonb, bigint, jsonb, bigint), public.respond_friend_trade(uuid, boolean),
  public.cancel_friend_trade(uuid), public.get_friend_trades(uuid), public.claim_friend_items(), public.reset_player_game() to authenticated;
