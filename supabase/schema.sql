create table if not exists public.game_saves (
  user_id uuid primary key references auth.users (id) on delete cascade,
  save_data jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.game_saves enable row level security;

revoke all on public.game_saves from anon, authenticated;
grant select on public.game_saves to authenticated;

drop policy if exists "Players can access their own save" on public.game_saves;
create policy "Players can access their own save"
  on public.game_saves
  for all
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

alter table public.game_saves add column if not exists revision bigint not null default 1;

revoke all on public.game_saves from anon, authenticated;
grant select on public.game_saves to authenticated;

-- ============================================================
-- Proteção contra adulteração (validada no servidor)
-- Os limites ficam em public.anticheat_config e podem ser ajustados com UPDATE.
-- enforce = false => só regista avisos nos logs do Postgres, sem recusar saves.
-- ============================================================
create table if not exists public.anticheat_config (
  id boolean primary key default true check (id),
  enforce boolean not null default true,
  new_hero_max_level integer not null default 25,
  new_hero_max_gold bigint not null default 5000,
  new_hero_max_items integer not null default 60,
  max_inventory integer not null default 1500,
  level_burst numeric not null default 30,
  level_refill_seconds numeric not null default 20,
  item_burst numeric not null default 300,
  item_rate_per_second numeric not null default 0.2,
  gold_burst_base numeric not null default 5000,
  gold_burst_per_level numeric not null default 300,
  gold_rate_base numeric not null default 5,
  gold_rate_per_level numeric not null default 5,
  gold_cap_seconds numeric not null default 1800
);
insert into public.anticheat_config (id) values (true) on conflict (id) do nothing;
alter table public.anticheat_config enable row level security;
revoke all on public.anticheat_config from anon, authenticated;

alter table public.game_saves add column if not exists gold_budget numeric;
alter table public.game_saves add column if not exists level_budget numeric;
alter table public.game_saves add column if not exists item_budget numeric;
alter table public.game_saves add column if not exists budget_at timestamptz;

-- IDs de todos os itens de um save (mochila + equipamento).
create or replace function public.save_item_ids(p_save jsonb)
returns setof text
language sql
immutable
set search_path = public, pg_temp
as $$
  select inv.item->>'id'
  from jsonb_array_elements(
    case when jsonb_typeof(p_save->'inventory') = 'array' then p_save->'inventory' else '[]'::jsonb end
  ) as inv(item)
  where jsonb_typeof(inv.item) = 'object' and inv.item->>'id' is not null
  union
  select eq.value->>'id'
  from jsonb_each(
    case when jsonb_typeof(p_save->'equipment') = 'object' then p_save->'equipment' else '{}'::jsonb end
  ) as eq
  where jsonb_typeof(eq.value) = 'object' and eq.value->>'id' is not null
$$;

create or replace function public.save_player_game(p_save_data jsonb, p_expected_revision bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_cfg public.anticheat_config%rowtype;
  v_row public.game_saves%rowtype;
  v_revision bigint;
  v_now timestamptz := clock_timestamp();
  v_level numeric;
  v_gold numeric;
  v_old_level numeric;
  v_old_gold numeric;
  v_elapsed numeric;
  v_gold_cap numeric;
  v_gold_budget numeric;
  v_level_budget numeric;
  v_item_budget numeric;
  v_removed integer;
  v_added integer;
  v_gain numeric;
  v_level_gain numeric;
  v_sell_bound numeric;
  v_reason text := null;
begin
  if v_user_id is null then raise exception 'É necessário iniciar sessão.'; end if;
  if coalesce(jsonb_typeof(p_save_data), '') <> 'object' then raise exception 'O save não é válido.'; end if;
  if coalesce(jsonb_typeof(p_save_data->'class'), '') <> 'string'
    or p_save_data->>'class' not in ('guerreiro', 'arqueiro', 'mago') then
    raise exception 'A classe do save não é válida.';
  end if;
  if coalesce(jsonb_typeof(p_save_data->'inventory'), '') <> 'array' then
    raise exception 'A mochila do save não é válida.';
  end if;
  if coalesce(p_save_data->>'level', '') !~ '^[1-9][0-9]*$'
    or (p_save_data->>'level')::numeric > 1000000 then
    raise exception 'O nível do save não é válido.';
  end if;
  if coalesce(p_save_data->>'gold', '') !~ '^(0|[1-9][0-9]*)$'
    or (p_save_data->>'gold')::numeric > 9007199254740991 then
    raise exception 'O ouro do save não é válido.';
  end if;

  select * into v_cfg from public.anticheat_config where id;
  v_level := (p_save_data->>'level')::numeric;
  v_gold := (p_save_data->>'gold')::numeric;

  if jsonb_array_length(p_save_data->'inventory') > v_cfg.max_inventory then
    v_reason := 'mochila com itens a mais';
  end if;

  select * into v_row
  from public.game_saves
  where user_id = v_user_id
  for update;

  if not found then
    if p_expected_revision is not null then raise exception 'SAVE_CONFLICT'; end if;
    if v_reason is null and (
      v_level > v_cfg.new_hero_max_level
      or v_gold > v_cfg.new_hero_max_gold
      or jsonb_array_length(p_save_data->'inventory') > v_cfg.new_hero_max_items
    ) then
      v_reason := 'herói novo com nível, ouro ou itens acima do possível';
    end if;
    if v_reason is not null then
      if v_cfg.enforce then raise exception 'SAVE_REJECTED: %', v_reason;
      else raise warning 'SAVE_REJECTED (monitor) user=% : %', v_user_id, v_reason; end if;
    end if;
    insert into public.game_saves (user_id, save_data, updated_at, revision, budget_at)
    values (v_user_id, p_save_data, v_now, 1, v_now)
    returning revision into v_revision;
  else
    if p_expected_revision is null or p_expected_revision <> v_row.revision then
      raise exception 'SAVE_CONFLICT';
    end if;

    if v_reason is null and p_save_data->>'class' is distinct from v_row.save_data->>'class' then
      v_reason := 'a classe do herói não pode mudar';
    end if;

    -- O nome do herói só pode mudar uma vez (nameChanged passa a true e nunca volta a false).
    if v_reason is null and p_save_data->>'name' is distinct from v_row.save_data->>'name' then
      if coalesce(v_row.save_data->>'nameChanged', 'false') = 'true'
        or coalesce(p_save_data->>'nameChanged', 'false') <> 'true'
        or char_length(btrim(coalesce(p_save_data->>'name', ''))) not between 1 and 16 then
        v_reason := 'o nome do herói só pode ser alterado uma vez';
      end if;
    elsif v_reason is null
      and coalesce(v_row.save_data->>'nameChanged', 'false') = 'true'
      and coalesce(p_save_data->>'nameChanged', 'false') <> 'true' then
      v_reason := 'o nome do herói só pode ser alterado uma vez';
    end if;

    v_old_level := case when v_row.save_data->>'level' ~ '^[1-9][0-9]*$' then (v_row.save_data->>'level')::numeric else v_level end;
    v_old_gold := case when v_row.save_data->>'gold' ~ '^(0|[1-9][0-9]*)$' then (v_row.save_data->>'gold')::numeric else v_gold end;
    v_elapsed := greatest(0, extract(epoch from (v_now - coalesce(v_row.budget_at, v_now))));

    v_gold_cap := (v_cfg.gold_rate_base + v_cfg.gold_rate_per_level * v_level) * v_cfg.gold_cap_seconds
                  + v_cfg.gold_burst_base + v_cfg.gold_burst_per_level * v_level;
    v_gold_budget := least(v_gold_cap,
      coalesce(v_row.gold_budget, v_gold_cap) + (v_cfg.gold_rate_base + v_cfg.gold_rate_per_level * v_level) * v_elapsed);
    v_level_budget := least(v_cfg.level_burst,
      coalesce(v_row.level_budget, v_cfg.level_burst) + v_elapsed / greatest(v_cfg.level_refill_seconds, 1));
    v_item_budget := least(v_cfg.item_burst,
      coalesce(v_row.item_budget, v_cfg.item_burst) + v_elapsed * v_cfg.item_rate_per_second);

    select count(*) into v_removed from (
      select i from public.save_item_ids(v_row.save_data) as i
      except
      select i from public.save_item_ids(p_save_data) as i
    ) removed;
    select count(*) into v_added from (
      select i from public.save_item_ids(p_save_data) as i
      except
      select i from public.save_item_ids(v_row.save_data) as i
    ) added;

    -- Valor máximo de venda de um item (espelha itemSellValue com a raridade mais alta).
    v_sell_bound := round(10 * 5.5 * v_level / 3) + 5;
    v_gain := v_gold - v_old_gold - v_removed * v_sell_bound;
    v_level_gain := greatest(v_level - v_old_level, 0);

    if v_reason is null and v_level_gain > v_level_budget then
      v_reason := format('subida de nível rápida demais (+%s)', v_level_gain);
    elsif v_reason is null and v_added > v_item_budget then
      v_reason := format('itens novos a mais (+%s)', v_added);
    elsif v_reason is null and v_gain > v_gold_budget then
      v_reason := format('ouro a subir rápido demais (+%s)', v_gold - v_old_gold);
    elsif v_reason is null and exists (
      select i from public.save_item_ids(p_save_data) as i
      where i like 'it\_trade\_%'
      except
      select i from public.save_item_ids(v_row.save_data) as i
    ) then
      v_reason := 'itens de troca só podem ser criados pelo servidor';
    end if;

    if v_reason is not null then
      if v_cfg.enforce then raise exception 'SAVE_REJECTED: %', v_reason;
      else raise warning 'SAVE_REJECTED (monitor) user=% : %', v_user_id, v_reason; end if;
    end if;

    v_revision := v_row.revision + 1;
    update public.game_saves
    set save_data = p_save_data, updated_at = v_now, revision = v_revision,
        gold_budget = v_gold_budget - greatest(v_gain, 0),
        level_budget = v_level_budget - v_level_gain,
        item_budget = v_item_budget - v_added,
        budget_at = v_now
    where user_id = v_user_id;
  end if;

  return jsonb_build_object('save_data', p_save_data, 'updated_at', v_now, 'revision', v_revision);
end;
$$;

create table if not exists public.player_trade_listings (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references public.game_saves (user_id) on delete cascade,
  seller_name text not null,
  item jsonb not null,
  price bigint not null check (price > 0 and price <= 2147483647),
  created_at timestamptz not null default now()
);

create index if not exists player_trade_listings_created_at_idx
  on public.player_trade_listings (created_at desc);

alter table public.player_trade_listings enable row level security;
revoke all on public.player_trade_listings from anon, authenticated;
grant select on public.player_trade_listings to authenticated;

drop policy if exists "Authenticated players can view trade listings" on public.player_trade_listings;
create policy "Authenticated players can view trade listings"
  on public.player_trade_listings
  for select
  to authenticated
  using (true);

create or replace function public.create_trade_listing(p_item_id text, p_price bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_save jsonb;
  v_item jsonb;
  v_position bigint;
  v_item_count integer;
  v_listing_count integer;
  v_inventory jsonb;
  v_listing_id uuid;
  v_revision bigint;
  v_updated_at timestamptz := clock_timestamp();
begin
  if v_user_id is null then raise exception 'É necessário iniciar sessão.'; end if;
  if p_item_id is null or p_price is null or p_price < 1 or p_price > 2147483647 then
    raise exception 'Indica o item e um preço válido.';
  end if;

  select save_data into v_save
  from public.game_saves
  where user_id = v_user_id
  for update;
  if not found then raise exception 'Não foi encontrado um save para esta conta.'; end if;
  if coalesce(jsonb_typeof(v_save->'inventory'), '') <> 'array' then raise exception 'A mochila não é válida.'; end if;

  select count(*) into v_listing_count
  from public.player_trade_listings
  where seller_id = v_user_id;
  if v_listing_count >= 3 then raise exception 'Podes ter no máximo 3 itens à venda.'; end if;

  select count(*) into v_item_count
  from jsonb_array_elements(v_save->'inventory') as inventory(item)
  where item->>'id' = p_item_id;
  if v_item_count <> 1 then raise exception 'O item já não está na mochila ou não tem um ID único.'; end if;

  select item, position into v_item, v_position
  from jsonb_array_elements(v_save->'inventory') with ordinality as inventory(item, position)
  where item->>'id' = p_item_id;

  select coalesce(jsonb_agg(item order by position), '[]'::jsonb) into v_inventory
  from jsonb_array_elements(v_save->'inventory') with ordinality as inventory(item, position)
  where position <> v_position;

  v_save := jsonb_set(v_save, '{inventory}', v_inventory, true);
  insert into public.player_trade_listings (seller_id, seller_name, item, price)
  values (v_user_id, left(coalesce(v_save->>'name', 'Jogador'), 16), v_item, p_price)
  returning id into v_listing_id;

  update public.game_saves
  set save_data = v_save, updated_at = v_updated_at, revision = revision + 1
  where user_id = v_user_id
  returning revision into v_revision;

  return jsonb_build_object('listing_id', v_listing_id, 'save_data', v_save, 'updated_at', v_updated_at, 'revision', v_revision);
end;
$$;

-- ============================================================
-- Trades v2: o dinheiro das vendas fica num registo próprio (trade_proceeds)
-- em vez de alterar o save do vendedor. Assim uma venda nunca invalida o save
-- aberto do vendedor (SAVE_CONFLICT) nem lhe faz perder progresso por sincronizar.
-- O vendedor recebe o ouro ao chamar claim_trade_proceeds().
-- ============================================================
create table if not exists public.trade_proceeds (
  id uuid primary key default gen_random_uuid(),
  seller_id uuid not null references auth.users (id) on delete cascade,
  amount bigint not null check (amount > 0),
  item_name text,
  created_at timestamptz not null default now()
);

create index if not exists trade_proceeds_seller_idx on public.trade_proceeds (seller_id);

alter table public.trade_proceeds enable row level security;
revoke all on public.trade_proceeds from anon, authenticated;
grant select on public.trade_proceeds to authenticated;

drop policy if exists "Sellers can view their pending proceeds" on public.trade_proceeds;
create policy "Sellers can view their pending proceeds"
  on public.trade_proceeds
  for select
  to authenticated
  using (seller_id = auth.uid());

create or replace function public.purchase_trade_listing(p_listing_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_buyer_id uuid := auth.uid();
  v_listing public.player_trade_listings%rowtype;
  v_buyer_save jsonb;
  v_buyer_gold bigint;
  v_item jsonb;
  v_buyer_revision bigint;
  v_updated_at timestamptz := clock_timestamp();
begin
  if v_buyer_id is null then raise exception 'É necessário iniciar sessão.'; end if;

  select * into v_listing
  from public.player_trade_listings
  where id = p_listing_id
  for update;
  if not found then raise exception 'Este anúncio já não está disponível.'; end if;
  if v_listing.seller_id = v_buyer_id then raise exception 'Não podes comprar o teu próprio item.'; end if;

  select save_data into v_buyer_save
  from public.game_saves
  where user_id = v_buyer_id
  for update;
  if not found then raise exception 'Não foi encontrado o teu save.'; end if;
  if coalesce(v_buyer_save->>'gold', '') !~ '^[0-9]+$' then raise exception 'O teu saldo de ouro não é válido.'; end if;
  if coalesce(jsonb_typeof(v_buyer_save->'inventory'), '') <> 'array' then raise exception 'A tua mochila não é válida.'; end if;

  v_buyer_gold := (v_buyer_save->>'gold')::bigint;
  if v_buyer_gold < v_listing.price then raise exception 'Não tens ouro suficiente.'; end if;

  v_item := jsonb_set(v_listing.item, '{id}', to_jsonb('it_trade_' || replace(gen_random_uuid()::text, '-', '')), true);
  v_buyer_save := jsonb_set(v_buyer_save, '{gold}', to_jsonb(v_buyer_gold - v_listing.price), true);
  v_buyer_save := jsonb_set(v_buyer_save, '{inventory}', (v_buyer_save->'inventory') || jsonb_build_array(v_item), true);

  update public.game_saves
  set save_data = v_buyer_save, updated_at = v_updated_at, revision = revision + 1
  where user_id = v_buyer_id
  returning revision into v_buyer_revision;

  insert into public.trade_proceeds (seller_id, amount, item_name)
  values (v_listing.seller_id, v_listing.price, left(coalesce(v_listing.item->>'name', 'Item'), 60));

  delete from public.player_trade_listings where id = v_listing.id;

  return jsonb_build_object('save_data', v_buyer_save, 'updated_at', v_updated_at, 'revision', v_buyer_revision);
end;
$$;

create or replace function public.claim_trade_proceeds()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_save jsonb;
  v_gold numeric;
  v_total numeric;
  v_count integer;
  v_revision bigint;
  v_updated_at timestamptz := clock_timestamp();
begin
  if v_user_id is null then raise exception 'É necessário iniciar sessão.'; end if;

  select save_data into v_save
  from public.game_saves
  where user_id = v_user_id
  for update;
  if not found then return jsonb_build_object('count', 0, 'claimed', 0); end if;
  if coalesce(v_save->>'gold', '') !~ '^[0-9]+$' then raise exception 'O teu saldo de ouro não é válido.'; end if;

  with claimed as (
    delete from public.trade_proceeds where seller_id = v_user_id returning amount
  )
  select coalesce(sum(amount), 0), count(*) into v_total, v_count from claimed;

  if v_count = 0 then return jsonb_build_object('count', 0, 'claimed', 0); end if;

  v_gold := (v_save->>'gold')::numeric;
  -- Se passar do limite o erro desfaz o delete: o ouro fica pendente, nunca se perde.
  if v_gold + v_total > 9007199254740991 then raise exception 'O teu saldo atingiu o limite suportado.'; end if;

  v_save := jsonb_set(v_save, '{gold}', to_jsonb(v_gold + v_total), true);
  update public.game_saves
  set save_data = v_save, updated_at = v_updated_at, revision = revision + 1
  where user_id = v_user_id
  returning revision into v_revision;

  return jsonb_build_object('count', v_count, 'claimed', v_total, 'updated_at', v_updated_at, 'revision', v_revision);
end;
$$;

-- Recomeçar a aventura passa a ser feito por aqui (apagar a linha diretamente deixa de ser
-- permitido): impede perder itens anunciados e voltar a criar um save com valores arbitrários.
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
  delete from public.game_saves where user_id = v_user_id;
end;
$$;

create or replace function public.cancel_trade_listing(p_listing_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_listing public.player_trade_listings%rowtype;
  v_save jsonb;
  v_inventory jsonb;
  v_item jsonb;
  v_revision bigint;
  v_updated_at timestamptz := clock_timestamp();
begin
  if v_user_id is null then raise exception 'É necessário iniciar sessão.'; end if;

  select * into v_listing
  from public.player_trade_listings
  where id = p_listing_id
  for update;
  if not found then raise exception 'Este anúncio já não está disponível.'; end if;
  if v_listing.seller_id <> v_user_id then raise exception 'Só o vendedor pode cancelar este anúncio.'; end if;

  select save_data into v_save
  from public.game_saves
  where user_id = v_user_id
  for update;
  if not found then raise exception 'Não foi encontrado um save para esta conta.'; end if;
  if coalesce(jsonb_typeof(v_save->'inventory'), '') <> 'array' then raise exception 'A mochila não é válida.'; end if;

  v_item := jsonb_set(v_listing.item, '{id}', to_jsonb('it_trade_' || replace(gen_random_uuid()::text, '-', '')), true);
  v_inventory := (v_save->'inventory') || jsonb_build_array(v_item);
  v_save := jsonb_set(v_save, '{inventory}', v_inventory, true);
  update public.game_saves
  set save_data = v_save, updated_at = v_updated_at, revision = revision + 1
  where user_id = v_user_id
  returning revision into v_revision;
  delete from public.player_trade_listings where id = v_listing.id;

  return jsonb_build_object('save_data', v_save, 'updated_at', v_updated_at, 'revision', v_revision);
end;
$$;

revoke all on function public.save_player_game(jsonb, bigint) from public, anon;
revoke all on function public.claim_trade_proceeds() from public, anon;
revoke all on function public.reset_player_game() from public, anon;
revoke all on function public.save_item_ids(jsonb) from public, anon, authenticated;
revoke all on function public.create_trade_listing(text, bigint) from public, anon;
revoke all on function public.purchase_trade_listing(uuid) from public, anon;
revoke all on function public.cancel_trade_listing(uuid) from public, anon;
grant execute on function public.save_player_game(jsonb, bigint) to authenticated;
grant execute on function public.create_trade_listing(text, bigint) to authenticated;
grant execute on function public.purchase_trade_listing(uuid) to authenticated;
grant execute on function public.cancel_trade_listing(uuid) to authenticated;
grant execute on function public.claim_trade_proceeds() to authenticated;
grant execute on function public.reset_player_game() to authenticated;

-- ============================================================
-- Classificação (Cidade → Classificação): top 3 por nível e top 3 por ouro.
-- Só expõe nome da personagem, classe, nível e ouro. É seguro voltar a executar.
-- ============================================================
create or replace function public.get_leaderboard()
returns jsonb
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  with players as (
    select
      user_id,
      left(coalesce(nullif(btrim(save_data->>'name'), ''), 'Herói'), 16) as name,
      case when save_data->>'class' in ('guerreiro', 'arqueiro', 'mago') then save_data->>'class' else 'guerreiro' end as class,
      case when save_data->>'level' ~ '^[1-9][0-9]{0,6}$' then (save_data->>'level')::bigint else 0 end as level,
      case when save_data->>'xp' ~ '^[0-9]{1,15}$' then (save_data->>'xp')::numeric else 0 end as xp,
      case when save_data->>'gold' ~ '^(0|[1-9][0-9]{0,15})$' then (save_data->>'gold')::numeric else 0 end as gold
    from public.game_saves
  )
  select jsonb_build_object(
    'levels', coalesce((
      select jsonb_agg(jsonb_build_object('name', t.name, 'class', t.class, 'level', t.level, 'is_me', t.user_id = auth.uid()))
      from (select * from players where level > 0 order by level desc, xp desc, name limit 3) t
    ), '[]'::jsonb),
    'gold', coalesce((
      select jsonb_agg(jsonb_build_object('name', t.name, 'class', t.class, 'level', t.level, 'gold', t.gold, 'is_me', t.user_id = auth.uid()))
      from (select * from players where level > 0 order by gold desc, level desc, name limit 3) t
    ), '[]'::jsonb)
  );
$$;

revoke all on function public.get_leaderboard() from public, anon;
grant execute on function public.get_leaderboard() to authenticated;

-- Relógio do servidor (usado pelo Mercado Negro para as 3 horas não dependerem do relógio do telemóvel).
-- É seguro voltar a executar. Sem esta função o jogo usa o relógio do dispositivo.
create or replace function public.get_server_time()
returns bigint
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
$$;

revoke all on function public.get_server_time() from public, anon;
grant execute on function public.get_server_time() to authenticated;

-- ===== Nomes de herói únicos (ver também unique_names.sql) =====
-- Nomes de herói únicos. Seguro voltar a executar (SQL Editor do Supabase).
--
-- Dois heróis não podem ter o mesmo nome. A comparação ignora maiúsculas/minúsculas
-- e espaços a mais ("Nemesy", "nemesy" e "  NEMESY " contam como o mesmo nome).
-- Heróis que JÁ tinham nomes repetidos antes deste ficheiro ficam como estão: a regra
-- só é verificada quando um herói é criado ou muda de nome.

-- Forma normalizada de um nome, usada para comparar.
create or replace function public.hero_name_key(p_name text)
returns text
language sql
immutable
as $$
  select lower(regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g'))
$$;

create index if not exists game_saves_hero_name_key_idx
  on public.game_saves (public.hero_name_key(save_data->>'name'));

-- Verificação no servidor: corre sempre que um save é criado ou alterado.
create or replace function public.game_saves_unique_name()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key text := public.hero_name_key(new.save_data->>'name');
begin
  if v_key = '' then return new; end if;
  -- O nome não mudou: não há nada a verificar (os saves normais passam aqui).
  if tg_op = 'UPDATE' and public.hero_name_key(old.save_data->>'name') = v_key then
    return new;
  end if;
  -- Evita que dois jogadores fiquem com o mesmo nome ao mesmo tempo.
  perform pg_advisory_xact_lock(hashtext('hero_name:' || v_key));
  if exists (
    select 1 from public.game_saves g
    where g.user_id <> new.user_id
      and public.hero_name_key(g.save_data->>'name') = v_key
  ) then
    raise exception 'NAME_TAKEN: Esse nome de herói já está a ser usado por outro jogador.';
  end if;
  return new;
end;
$$;

drop trigger if exists game_saves_unique_name on public.game_saves;
create trigger game_saves_unique_name
  before insert or update of save_data on public.game_saves
  for each row execute function public.game_saves_unique_name();

-- Usado pelo jogo para avisar logo, antes de criar o herói ou de mudar o nome.
create or replace function public.is_hero_name_available(p_name text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.hero_name_key(p_name) <> ''
    and not exists (
      select 1 from public.game_saves g
      where g.user_id <> coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid)
        and public.hero_name_key(g.save_data->>'name') = public.hero_name_key(p_name)
    )
$$;

revoke all on function public.is_hero_name_available(text) from public;
grant execute on function public.is_hero_name_available(text) to authenticated;
