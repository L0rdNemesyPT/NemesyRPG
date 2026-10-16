-- ============================================================
-- Mercado v132: além de equipamento, vende-se Pérolas, Pedras de Alquimia, Gemas,
-- Livros/Pergaminhos e Talismãs. Um anúncio destes guarda em "item":
--   {"good":true,"kind":"perola|gema|pedra|livro|talisma","key":…,"sub":…,"qty":…,"unit":…,"name":…}
-- Quem compra leva o monte inteiro. O servidor tira as unidades do save do vendedor ao
-- anunciar e entrega-as ao comprador (ou devolve-as ao vendedor se retirar o anúncio).
-- Máximo de anúncios por jogador: 5. É seguro voltar a executar.
-- ============================================================

-- Nome oficial do objeto (o cliente nunca escolhe o nome). Devolve null se não for válido.
create or replace function public.nx_good_name(p_kind text, p_key text, p_sub integer)
returns text
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  if p_kind = 'perola' then
    return case p_key when 'branca' then 'Pérola Branca' when 'azul' then 'Pérola Azul'
      when 'vermelha' then 'Pérola Vermelha' when 'verde' then 'Pérola Verde' end;
  elsif p_kind = 'gema' then
    if p_sub is null or p_sub not between 0 and 2 then return null; end if;
    return (case p_key when 'defesa' then 'Pedra da Defesa' when 'dano' then 'Pedra do Dano'
      when 'vida' then 'Pedra da Vida' when 'critico' then 'Pedra do Crítico'
      when 'chefes' then 'Pedra do Caça-Chefes' end) || ' (T' || (p_sub + 1) || ')';
  elsif p_kind = 'pedra' then
    if p_sub is null or p_sub not between 0 and 9 then return null; end if;
    if p_sub = 9 then
      return case p_key when 'rubi' then 'Rubi Perfeito' when 'safira' then 'Safira Perfeita'
        when 'granada' then 'Granada Perfeita' when 'ametista' then 'Ametista Perfeita' end;
    end if;
    return (case p_key when 'rubi' then 'Rubi' when 'safira' then 'Safira'
      when 'granada' then 'Granada' when 'ametista' then 'Ametista' end) || ' Nv.' || (p_sub + 1);
  elsif p_kind = 'livro' then
    return case p_key when 'habilidades' then 'Livro de Habilidades' when 'amnesia' then 'Livro da Amnésia'
      when 'profissoes' then 'Livro das Profissões' when 'ferreiro' then 'Livro do Ferreiro'
      when 'feitico' then 'Pergaminho de Feitiço' when 'reforco' then 'Pergaminho de Reforço'
      when 'feiticoPlus' then 'Pergaminho de Feitiço ➕' when 'reforcoPlus' then 'Pergaminho de Reforço ➕' end;
  elsif p_kind = 'talisma' then
    return case p_key when 'fortune' then 'Talismã da Fortuna' when 'sabedoria' then 'Talismã da Sabedoria'
      when 'eclipse' then 'Talismã do Eclipse' end;
  end if;
  return null;
end;
$$;

-- Onde está guardado o contador deste objeto dentro do save.
create or replace function public.nx_good_path(p_kind text, p_key text, p_sub integer)
returns text[]
language plpgsql
immutable
set search_path = public, pg_temp
as $$
begin
  if p_kind = 'perola' then return array['pearls', p_key];
  elsif p_kind = 'gema' then return array['gems', p_key, p_sub::text];
  elsif p_kind = 'pedra' then return array['alchemyStones', p_key, p_sub::text];
  elsif p_kind = 'livro' then
    return case p_key when 'habilidades' then array['skillBooks'] when 'amnesia' then array['amnesiaBooks']
      when 'profissoes' then array['professionBooks'] when 'ferreiro' then array['smithBooks']
      else array['scrolls', p_key] end;
  end if;
  raise exception 'Objeto inválido.';
end;
$$;

-- Garante que o sítio do contador existe (bolsas de gemas e pedras com o tamanho certo).
create or replace function public.nx_good_prepare(p_save jsonb, p_kind text, p_key text)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_root text;
  v_len integer;
  v_arr jsonb;
begin
  if p_kind = 'perola' then v_root := 'pearls';
  elsif p_kind = 'gema' then v_root := 'gems'; v_len := 3;
  elsif p_kind = 'pedra' then v_root := 'alchemyStones'; v_len := 10;
  elsif p_kind = 'livro' and p_key in ('feitico', 'reforco', 'feiticoPlus', 'reforcoPlus') then v_root := 'scrolls';
  else return p_save;
  end if;
  if coalesce(jsonb_typeof(p_save->v_root), '') <> 'object' then
    p_save := jsonb_set(p_save, array[v_root], '{}'::jsonb, true);
  end if;
  if v_len is not null then
    v_arr := case when jsonb_typeof(p_save->v_root->p_key) = 'array' then p_save->v_root->p_key else '[]'::jsonb end;
    while jsonb_array_length(v_arr) < v_len loop v_arr := v_arr || '0'::jsonb; end loop;
    p_save := jsonb_set(p_save, array[v_root, p_key], v_arr, true);
  end if;
  return p_save;
end;
$$;

-- Junta ao save as unidades de um anúncio (compra ou anúncio retirado).
create or replace function public.nx_good_add(p_save jsonb, p_good jsonb)
returns jsonb
language plpgsql
volatile
set search_path = public, pg_temp
as $$
declare
  v_kind text := p_good->>'kind';
  v_key text := p_good->>'key';
  v_sub integer := coalesce((p_good->>'sub')::integer, 0);
  v_qty integer := coalesce((p_good->>'qty')::integer, 0);
  v_path text[];
  v_have numeric;
  v_tal jsonb;
begin
  if public.nx_good_name(v_kind, v_key, v_sub) is null or v_qty < 1 or v_qty > 9999 then
    raise exception 'Este anúncio tem um objeto inválido.';
  end if;
  if v_kind = 'talisma' then
    v_tal := jsonb_build_object('id', 'tal_' || substr(replace(gen_random_uuid()::text, '-', ''), 1, 10),
      'key', v_key, 'battlesRemaining', greatest(1, least(50, coalesce((p_good->>'battles')::integer, 50))));
    if coalesce(jsonb_typeof(p_save->'talismans'), '') <> 'array' then
      p_save := jsonb_set(p_save, '{talismans}', '[]'::jsonb, true);
    end if;
    return jsonb_set(p_save, '{talismans}', (p_save->'talismans') || jsonb_build_array(v_tal), true);
  end if;
  p_save := public.nx_good_prepare(p_save, v_kind, v_key);
  v_path := public.nx_good_path(v_kind, v_key, v_sub);
  v_have := case when coalesce(p_save #>> v_path, '') ~ '^[0-9]+$' then (p_save #>> v_path)::numeric else 0 end;
  return jsonb_set(p_save, v_path, to_jsonb(v_have + v_qty), true);
end;
$$;

-- Anunciar pérolas, pedras, gemas, livros ou um talismã.
-- p_unit = preço por unidade; o anúncio custa ao comprador p_unit × p_qty.
-- Talismã: p_key é o id do talismã na mochila (vende-se 1 de cada vez, e não pode estar equipado).
create or replace function public.create_goods_listing(p_kind text, p_key text, p_sub integer, p_qty integer, p_unit bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_save jsonb;
  v_listing_count integer;
  v_sub integer := coalesce(p_sub, 0);
  v_total numeric;
  v_name text;
  v_path text[];
  v_have numeric;
  v_good jsonb;
  v_tal jsonb;
  v_listing_id uuid;
  v_revision bigint;
  v_updated_at timestamptz := clock_timestamp();
begin
  if v_user_id is null then raise exception 'É necessário iniciar sessão.'; end if;
  if p_kind is null or p_key is null or p_qty is null or p_unit is null then raise exception 'Indica o objeto, a quantidade e o preço.'; end if;
  if p_qty < 1 or p_qty > 9999 then raise exception 'Quantidade inválida.'; end if;
  if p_unit < 1 then raise exception 'Indica um preço válido.'; end if;
  v_total := p_unit::numeric * p_qty;
  if v_total > 2147483647 then raise exception 'O preço total não pode passar de 2 147 483 647 ouro.'; end if;

  select save_data into v_save from public.game_saves where user_id = v_user_id for update;
  if not found then raise exception 'Não foi encontrado um save para esta conta.'; end if;

  select count(*) into v_listing_count from public.player_trade_listings where seller_id = v_user_id;
  if v_listing_count >= 5 then raise exception 'Podes ter no máximo 5 anúncios ativos.'; end if;

  if p_kind = 'talisma' then
    if p_qty <> 1 then raise exception 'Os talismãs vendem-se um de cada vez.'; end if;
    if coalesce(jsonb_typeof(v_save->'talismans'), '') <> 'array' then raise exception 'Não tens esse talismã.'; end if;
    select t into v_tal from jsonb_array_elements(v_save->'talismans') as t where t->>'id' = p_key limit 1;
    if v_tal is null then raise exception 'Não tens esse talismã.'; end if;
    if (v_save->'equipment'->>'talisman') is not distinct from p_key then raise exception 'Tira o talismã antes de o vender.'; end if;
    v_name := public.nx_good_name('talisma', v_tal->>'key', 0);
    if v_name is null or coalesce(v_tal->>'battlesRemaining', '') !~ '^[0-9]+$' or (v_tal->>'battlesRemaining')::integer < 1 then
      raise exception 'Este talismã não pode ser vendido.';
    end if;
    v_save := jsonb_set(v_save, '{talismans}',
      coalesce((select jsonb_agg(t) from jsonb_array_elements(v_save->'talismans') as t where t->>'id' is distinct from p_key), '[]'::jsonb), true);
    v_good := jsonb_build_object('good', true, 'kind', 'talisma', 'key', v_tal->>'key', 'sub', 0, 'qty', 1, 'unit', p_unit,
      'battles', least(50, (v_tal->>'battlesRemaining')::integer), 'name', v_name);
  else
    v_name := public.nx_good_name(p_kind, p_key, v_sub);
    if v_name is null then raise exception 'Este objeto não pode ser vendido.'; end if;
    v_save := public.nx_good_prepare(v_save, p_kind, p_key);
    v_path := public.nx_good_path(p_kind, p_key, v_sub);
    v_have := case when coalesce(v_save #>> v_path, '') ~ '^[0-9]+$' then (v_save #>> v_path)::numeric else 0 end;
    if v_have < p_qty then raise exception 'Não tens unidades suficientes (tens %).', v_have; end if;
    v_save := jsonb_set(v_save, v_path, to_jsonb(v_have - p_qty), true);
    v_good := jsonb_build_object('good', true, 'kind', p_kind, 'key', p_key, 'sub', v_sub, 'qty', p_qty, 'unit', p_unit, 'name', v_name);
  end if;

  insert into public.player_trade_listings (seller_id, seller_name, item, price)
  values (v_user_id, left(coalesce(v_save->>'name', 'Jogador'), 16), v_good, v_total::bigint)
  returning id into v_listing_id;

  update public.game_saves
  set save_data = v_save, updated_at = v_updated_at, revision = revision + 1
  where user_id = v_user_id
  returning revision into v_revision;

  return jsonb_build_object('listing_id', v_listing_id, 'save_data', v_save, 'updated_at', v_updated_at, 'revision', v_revision);
end;
$$;

-- Anúncios de equipamento: limite passa de 3 para 5.
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
  if v_listing_count >= 5 then raise exception 'Podes ter no máximo 5 anúncios ativos.'; end if;

  select count(*) into v_item_count
  from jsonb_array_elements(v_save->'inventory') as inventory(item)
  where item->>'id' = p_item_id;
  if v_item_count <> 1 then raise exception 'O item já não está na mochila ou não tem um ID único.'; end if;

  select item, position into v_item, v_position
  from jsonb_array_elements(v_save->'inventory') with ordinality as inventory(item, position)
  where item->>'id' = p_item_id;

  -- Valida e limpa o item (nome, raridade, stats…). Se for impossível, a venda é recusada
  -- e nada muda no save.
  v_item := public.clean_trade_item(v_item);

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


-- Compra: equipamento ou objetos (o monte inteiro).
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

  if coalesce(v_listing.item->>'good', '') = 'true' then
    -- v132: pérolas, pedras, gemas, livros e talismãs (compra-se o monte inteiro).
    v_buyer_save := public.nx_good_add(v_buyer_save, v_listing.item);
  else
    begin
      v_item := public.clean_trade_item(v_listing.item);
    exception when others then
      raise exception 'Este anúncio tem um item inválido e não pode ser comprado.';
    end;
    v_item := jsonb_set(v_item, '{id}', to_jsonb('it_trade_' || replace(gen_random_uuid()::text, '-', '')), true);
    v_buyer_save := jsonb_set(v_buyer_save, '{inventory}', (v_buyer_save->'inventory') || jsonb_build_array(v_item), true);
  end if;
  v_buyer_save := jsonb_set(v_buyer_save, '{gold}', to_jsonb(v_buyer_gold - v_listing.price), true);

  update public.game_saves
  set save_data = v_buyer_save, updated_at = v_updated_at, revision = revision + 1
  where user_id = v_buyer_id
  returning revision into v_buyer_revision;

  insert into public.trade_proceeds (seller_id, amount, item_name)
  values (v_listing.seller_id, v_listing.price, left(case when coalesce(v_listing.item->>'good', '') = 'true' and coalesce((v_listing.item->>'qty')::int, 1) > 1 then (v_listing.item->>'qty') || '× ' else '' end || coalesce(v_listing.item->>'name', 'Item'), 60));

  delete from public.player_trade_listings where id = v_listing.id;

  return jsonb_build_object('save_data', v_buyer_save, 'updated_at', v_updated_at, 'revision', v_buyer_revision);
end;
$$;


-- Retirar anúncio: devolve o equipamento ou os objetos ao vendedor.
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

  if coalesce(v_listing.item->>'good', '') = 'true' then
    v_save := public.nx_good_add(v_save, v_listing.item);
  else
    v_item := jsonb_set(v_listing.item, '{id}', to_jsonb('it_trade_' || replace(gen_random_uuid()::text, '-', '')), true);
    v_inventory := (v_save->'inventory') || jsonb_build_array(v_item);
    v_save := jsonb_set(v_save, '{inventory}', v_inventory, true);
  end if;
  update public.game_saves
  set save_data = v_save, updated_at = v_updated_at, revision = revision + 1
  where user_id = v_user_id
  returning revision into v_revision;
  delete from public.player_trade_listings where id = v_listing.id;

  return jsonb_build_object('save_data', v_save, 'updated_at', v_updated_at, 'revision', v_revision);
end;
$$;


revoke all on function public.nx_good_name(text, text, integer) from public, anon, authenticated;
revoke all on function public.nx_good_path(text, text, integer) from public, anon, authenticated;
revoke all on function public.nx_good_prepare(jsonb, text, text) from public, anon, authenticated;
revoke all on function public.nx_good_add(jsonb, jsonb) from public, anon, authenticated;
revoke all on function public.create_goods_listing(text, text, integer, integer, bigint) from public, anon;
grant execute on function public.create_goods_listing(text, text, integer, integer, bigint) to authenticated;
revoke all on function public.create_trade_listing(text, bigint) from public, anon;
revoke all on function public.purchase_trade_listing(uuid) from public, anon;
revoke all on function public.cancel_trade_listing(uuid) from public, anon;
grant execute on function public.create_trade_listing(text, bigint) to authenticated;
grant execute on function public.purchase_trade_listing(uuid) to authenticated;
grant execute on function public.cancel_trade_listing(uuid) to authenticated;
