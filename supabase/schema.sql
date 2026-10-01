create table if not exists public.game_saves (
  user_id uuid primary key references auth.users (id) on delete cascade,
  save_data jsonb not null,
  updated_at timestamptz not null default now()
);

alter table public.game_saves enable row level security;

revoke all on public.game_saves from anon, authenticated;
grant select, insert, update, delete on public.game_saves to authenticated;

drop policy if exists "Players can access their own save" on public.game_saves;
create policy "Players can access their own save"
  on public.game_saves
  for all
  to authenticated
  using (auth.uid() = user_id)
  with check (auth.uid() = user_id);

alter table public.game_saves add column if not exists revision bigint not null default 1;

revoke all on public.game_saves from anon, authenticated;
grant select, delete on public.game_saves to authenticated;

create or replace function public.save_player_game(p_save_data jsonb, p_expected_revision bigint)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_user_id uuid := auth.uid();
  v_revision bigint;
  v_updated_at timestamptz := clock_timestamp();
begin
  if v_user_id is null then raise exception 'É necessário iniciar sessão.'; end if;
  if coalesce(jsonb_typeof(p_save_data), '') <> 'object' then raise exception 'O save não é válido.'; end if;

  select revision into v_revision
  from public.game_saves
  where user_id = v_user_id
  for update;

  if not found then
    if p_expected_revision is not null then raise exception 'SAVE_CONFLICT'; end if;
    insert into public.game_saves (user_id, save_data, updated_at, revision)
    values (v_user_id, p_save_data, v_updated_at, 1)
    returning revision into v_revision;
  else
    if p_expected_revision is null or p_expected_revision <> v_revision then
      raise exception 'SAVE_CONFLICT';
    end if;
    v_revision := v_revision + 1;
    update public.game_saves
    set save_data = p_save_data, updated_at = v_updated_at, revision = v_revision
    where user_id = v_user_id;
  end if;

  return jsonb_build_object('save_data', p_save_data, 'updated_at', v_updated_at, 'revision', v_revision);
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
  if p_item_id is null or p_price < 1 or p_price > 2147483647 then
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
  v_seller_save jsonb;
  v_buyer_gold bigint;
  v_seller_gold bigint;
  v_buyer_inventory jsonb;
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

  perform user_id
  from public.game_saves
  where user_id in (v_buyer_id, v_listing.seller_id)
  order by user_id
  for update;

  select save_data into v_buyer_save from public.game_saves where user_id = v_buyer_id;
  if not found then raise exception 'Não foi encontrado o teu save.'; end if;
  select save_data into v_seller_save from public.game_saves where user_id = v_listing.seller_id;
  if not found then raise exception 'O vendedor já não tem um save ativo.'; end if;
  if coalesce(v_buyer_save->>'gold', '') !~ '^[0-9]+$' then raise exception 'O teu saldo de ouro não é válido.'; end if;
  if coalesce(v_seller_save->>'gold', '') !~ '^[0-9]+$' then raise exception 'O saldo do vendedor não é válido.'; end if;
  if coalesce(jsonb_typeof(v_buyer_save->'inventory'), '') <> 'array' then raise exception 'A tua mochila não é válida.'; end if;

  v_buyer_gold := (v_buyer_save->>'gold')::bigint;
  v_seller_gold := (v_seller_save->>'gold')::bigint;
  if v_buyer_gold < v_listing.price then raise exception 'Não tens ouro suficiente.'; end if;
  if v_seller_gold > 9007199254740991 - v_listing.price then raise exception 'O saldo do vendedor atingiu o limite suportado.'; end if;

  v_item := jsonb_set(v_listing.item, '{id}', to_jsonb('it_trade_' || replace(gen_random_uuid()::text, '-', '')), true);
  v_buyer_inventory := (v_buyer_save->'inventory') || jsonb_build_array(v_item);
  v_buyer_save := jsonb_set(v_buyer_save, '{gold}', to_jsonb(v_buyer_gold - v_listing.price), true);
  v_buyer_save := jsonb_set(v_buyer_save, '{inventory}', v_buyer_inventory, true);
  v_seller_save := jsonb_set(v_seller_save, '{gold}', to_jsonb(v_seller_gold + v_listing.price), true);

  update public.game_saves
  set save_data = v_buyer_save, updated_at = v_updated_at, revision = revision + 1
  where user_id = v_buyer_id
  returning revision into v_buyer_revision;
  update public.game_saves
  set save_data = v_seller_save, updated_at = v_updated_at, revision = revision + 1
  where user_id = v_listing.seller_id;
  delete from public.player_trade_listings where id = v_listing.id;

  return jsonb_build_object('save_data', v_buyer_save, 'updated_at', v_updated_at, 'revision', v_buyer_revision);
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
revoke all on function public.create_trade_listing(text, bigint) from public, anon;
revoke all on function public.purchase_trade_listing(uuid) from public, anon;
revoke all on function public.cancel_trade_listing(uuid) from public, anon;
grant execute on function public.save_player_game(jsonb, bigint) to authenticated;
grant execute on function public.create_trade_listing(text, bigint) to authenticated;
grant execute on function public.purchase_trade_listing(uuid) to authenticated;
grant execute on function public.cancel_trade_listing(uuid) to authenticated;