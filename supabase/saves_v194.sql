-- ============================================================
-- v194: Saves que ficavam bloqueados para sempre.
-- Executar uma vez no SQL Editor do Supabase.
--  • Quando um save era recusado (ex.: "itens novos a mais" depois de abrir centenas de baús,
--    ou mochila acima do limite), o jogo nunca mais conseguia sincronizar — e ações como
--    Doar XP à Guild, Trocas e Mercado davam "Não foi possível sincronizar o save".
--  • Agora: cada baú aberto conta como 1 item permitido; o orçamento de itens/ouro/níveis
--    cresce com o tempo desde o último save aceite (não fica preso); a mochila aceita uma
--    pequena folga (1600) para drops que caem com a mochila quase cheia; e a razão da recusa
--    passa a dizer os números.
-- ============================================================

update public.anticheat_config set max_inventory = greatest(max_inventory, 1600) where id;

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
  v_chests_used integer := 0;
  v_net_items integer;
  v_inv integer;
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

  v_inv := jsonb_array_length(p_save_data->'inventory');
  if v_inv > v_cfg.max_inventory then
    v_reason := format('mochila com itens a mais (%s/%s)', v_inv, v_cfg.max_inventory);
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
    -- v194: o orçamento enche até ao limite normal, mas se o último save aceite já é antigo
    -- passa a valer pelo menos o ritmo × tempo decorrido. Assim um save recusado deixa de
    -- ficar bloqueado para sempre: basta o tempo passar para o progresso legítimo caber.
    v_gold_budget := greatest(least(v_gold_cap,
      coalesce(v_row.gold_budget, v_gold_cap) + (v_cfg.gold_rate_base + v_cfg.gold_rate_per_level * v_level) * v_elapsed),
      (v_cfg.gold_rate_base + v_cfg.gold_rate_per_level * v_level) * v_elapsed);
    v_level_budget := greatest(least(v_cfg.level_burst,
      coalesce(v_row.level_budget, v_cfg.level_burst) + v_elapsed / greatest(v_cfg.level_refill_seconds, 1)),
      v_elapsed / greatest(v_cfg.level_refill_seconds, 1));
    v_item_budget := greatest(least(v_cfg.item_burst,
      coalesce(v_row.item_budget, v_cfg.item_burst) + v_elapsed * v_cfg.item_rate_per_second),
      v_elapsed * v_cfg.item_rate_per_second);

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

    -- v194: cada baú aberto pode dar 1 item (Abrir todos com centenas de Baús de Equipamento).
    v_chests_used := greatest(0,
      (case when jsonb_typeof(v_row.save_data->'chests') = 'array' then jsonb_array_length(v_row.save_data->'chests') else 0 end)
      - (case when jsonb_typeof(p_save_data->'chests') = 'array' then jsonb_array_length(p_save_data->'chests') else 0 end));
    v_net_items := greatest(v_added - v_chests_used, 0);

    -- Valor máximo de venda de um item (espelha itemSellValue com a raridade mais alta).
    v_sell_bound := round(10 * 5.5 * v_level / 3) + 5;
    v_gain := v_gold - v_old_gold - v_removed * v_sell_bound;
    v_level_gain := greatest(v_level - v_old_level, 0);

    if v_reason is null and v_level_gain > v_level_budget then
      v_reason := format('subida de nível rápida demais (+%s)', v_level_gain);
    elsif v_reason is null and v_net_items > v_item_budget then
      v_reason := format('itens novos a mais (+%s)', v_net_items);
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
        item_budget = v_item_budget - v_net_items,
        budget_at = v_now
    where user_id = v_user_id;
  end if;

  return jsonb_build_object('save_data', p_save_data, 'updated_at', v_now, 'revision', v_revision);
end;
$$;

revoke all on function public.save_player_game(jsonb, bigint) from public, anon;
grant execute on function public.save_player_game(jsonb, bigint) to authenticated;
