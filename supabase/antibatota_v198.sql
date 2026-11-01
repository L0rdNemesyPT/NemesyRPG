-- ============================================================
-- v198: Proteção extra dos saves (anti-batota).
-- Executar uma vez no SQL Editor do Supabase (depois do saves_v194.sql).
--  • Quantidades com máximo (livros, poções, pergaminhos, pérolas, gemas, chaves, baús, Pó Estelar,
--    Pedras Nephalen…) nunca passam do limite do jogo.
--  • Itens com stats impossíveis para o seu nível (mochila e equipamento) ficam no máximo possível.
--  • Vila: recursos, níveis, soldados e aldeões dentro das regras.
--  • Como o Mercado lê o save do servidor, também deixa de ser possível vender quantidades inventadas.
-- Um jogador normal nunca passa destes limites — o jogo já os aplica sozinho.
-- ============================================================

-- Limite de cada stat de um item (igual ao das Trocas: folgado acima do máximo possível para o nível do item).
create or replace function public.nx_item_stat_cap(p_item jsonb, p_key text)
returns numeric
language sql
immutable
set search_path = public, pg_temp
as $$
  select case
    when p_key in ('hp', 'dmg', 'dmgMin', 'dmgMax', 'def', 'es') then (1 + lv * 0.35) * 5.5 * 2.5 + 10
    when p_key = 'crit' then (1 + lv * 0.35) * 5.5 * 0.006 * 1.3 + 0.05
    when p_key = 'regenPct' then 3
    when p_key = 'dmgReducedFromBossPct' then 0.081
    else null end
  from (select case when coalesce(p_item->>'itemLevel', '') ~ '^[0-9]{1,3}(\.[0-9]+)?$'
                    then least(200, greatest(1, (p_item->>'itemLevel')::numeric)) else 200 end as lv) l
$$;

-- Devolve o item com os stats dentro dos limites (e a melhoria entre 0 e 9).
create or replace function public.nx_clamp_item(p_item jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_f text; v_k text; v_v jsonb; v_cap numeric; v_obj jsonb;
begin
  if coalesce(jsonb_typeof(p_item), '') <> 'object' then return p_item; end if;
  foreach v_f in array array['stats', 'baseStats'] loop
    if jsonb_typeof(p_item->v_f) = 'object' then
      v_obj := p_item->v_f;
      for v_k, v_v in select key, value from jsonb_each(p_item->v_f) loop
        v_cap := public.nx_item_stat_cap(p_item, v_k);
        if v_cap is null then continue; end if;
        if jsonb_typeof(v_v) <> 'number' then v_obj := v_obj - v_k;
        elsif (v_v #>> '{}')::numeric > v_cap then v_obj := jsonb_set(v_obj, array[v_k], to_jsonb(round(v_cap, 4)));
        elsif (v_v #>> '{}')::numeric < 0 then v_obj := jsonb_set(v_obj, array[v_k], '0'::jsonb);
        end if;
      end loop;
      p_item := jsonb_set(p_item, array[v_f], v_obj);
    end if;
  end loop;
  if p_item ? 'upgrade' and (coalesce(p_item->>'upgrade', '') !~ '^[0-9]$') then p_item := jsonb_set(p_item, '{upgrade}', '0'::jsonb); end if;
  return p_item;
end;
$$;

-- true se algum item da lista tem stats fora dos limites (ou uma melhoria inválida).
create or replace function public.nx_items_bad(p_items jsonb)
returns boolean
language sql
immutable
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from jsonb_array_elements(case when jsonb_typeof(p_items) = 'array' then p_items else '[]'::jsonb end) it
    cross join lateral (select case when jsonb_typeof(it->'itemLevel') = 'number' then least(200, greatest(1, (it->>'itemLevel')::numeric)) else 200 end as lv) l
    cross join lateral (select key, value from jsonb_each(case when jsonb_typeof(it->'stats') = 'object' then it->'stats' else '{}'::jsonb end)
                        union all select key, value from jsonb_each(case when jsonb_typeof(it->'baseStats') = 'object' then it->'baseStats' else '{}'::jsonb end)) s
    where s.key in ('hp', 'dmg', 'dmgMin', 'dmgMax', 'def', 'es', 'crit', 'regenPct', 'dmgReducedFromBossPct')
      and (jsonb_typeof(s.value) <> 'number'
        or (s.value #>> '{}')::numeric < 0
        or (s.value #>> '{}')::numeric > case s.key when 'crit' then (1 + l.lv * 0.35) * 5.5 * 0.006 * 1.3 + 0.05
                                                   when 'regenPct' then 3 when 'dmgReducedFromBossPct' then 0.081
                                                   else (1 + l.lv * 0.35) * 5.5 * 2.5 + 10 end)
  ) or exists (select 1 from jsonb_array_elements(case when jsonb_typeof(p_items) = 'array' then p_items else '[]'::jsonb end) it
               where it ? 'upgrade' and coalesce(it->>'upgrade', '') !~ '^[0-9]$')
$$;

-- v198: põe o save dentro dos limites do jogo antes de ser gravado. Quantidades acima do máximo
-- ficam no máximo, itens com stats impossíveis ficam com o valor máximo possível e a Vila fica
-- dentro das regras. Um jogador normal nunca passa destes limites (o jogo já os aplica sozinho).
create or replace function public.nx_sanitize_save(p jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  c record; v_k text; v_v jsonb; v_cap numeric; v_obj jsonb; v_arr jsonb;
begin
  if coalesce(jsonb_typeof(p), '') <> 'object' then return p; end if;
  -- 1. Quantidades com máximo (iguais a RES_CAPS no jogo)
  for c in select * from (values
    ('{skillBooks}'::text[], 120), ('{smithBooks}'::text[], 30), ('{professionBooks}'::text[], 10), ('{amnesiaBooks}'::text[], 10),
    ('{nephalemStones}'::text[], 30), ('{poEstelar}'::text[], 50),
    ('{potions,hp}'::text[], 120), ('{potions,hp2}'::text[], 120), ('{potions,def}'::text[], 120), ('{potions,atk}'::text[], 120),
    ('{potions,elem}'::text[], 120), ('{potions,fortune}'::text[], 30),
    ('{scrolls,feitico}'::text[], 500), ('{scrolls,reforco}'::text[], 500), ('{scrolls,feiticoPlus}'::text[], 99), ('{scrolls,reforcoPlus}'::text[], 99),
    ('{pearls,branca}'::text[], 999), ('{pearls,azul}'::text[], 999), ('{pearls,vermelha}'::text[], 999), ('{pearls,verde}'::text[], 999)
  ) as t(path, cap) loop
    v_v := p #> c.path;
    if v_v is null or jsonb_typeof(v_v) = 'null' then continue; end if;
    if jsonb_typeof(v_v) <> 'number' or (v_v #>> '{}')::numeric < 0 then p := jsonb_set(p, c.path, '0'::jsonb);
    elsif (v_v #>> '{}')::numeric > c.cap then p := jsonb_set(p, c.path, to_jsonb(c.cap)); end if;
  end loop;
  -- Chaves das catacumbas (99 de cada)
  if jsonb_typeof(p->'catacumbKeys') = 'object' then
    v_obj := p->'catacumbKeys';
    for v_k, v_v in select key, value from jsonb_each(p->'catacumbKeys') loop
      if jsonb_typeof(v_v) <> 'number' or (v_v #>> '{}')::numeric < 0 then v_obj := jsonb_set(v_obj, array[v_k], '0'::jsonb);
      elsif (v_v #>> '{}')::numeric > 99 then v_obj := jsonb_set(v_obj, array[v_k], '99'::jsonb); end if;
    end loop;
    p := jsonb_set(p, '{catacumbKeys}', v_obj);
  end if;
  -- Gemas (999 de cada tipo e nível)
  if jsonb_typeof(p->'gems') = 'object' then
    v_obj := '{}'::jsonb;
    for v_k, v_v in select key, value from jsonb_each(p->'gems') loop
      if jsonb_typeof(v_v) = 'array' then
        v_obj := v_obj || jsonb_build_object(v_k, (select coalesce(jsonb_agg(case when jsonb_typeof(x) = 'number' then to_jsonb(least(999, greatest(0, floor((x #>> '{}')::numeric)))) else '0'::jsonb end order by n), '[]'::jsonb)
                                                   from jsonb_array_elements(v_v) with ordinality a(x, n) where n <= 5));
      else v_obj := v_obj || jsonb_build_object(v_k, v_v); end if;
    end loop;
    p := jsonb_set(p, '{gems}', v_obj);
  end if;
  -- Baús por abrir (500)
  if jsonb_typeof(p->'chests') = 'array' and jsonb_array_length(p->'chests') > 500 then
    p := jsonb_set(p, '{chests}', (select jsonb_agg(x order by n) from jsonb_array_elements(p->'chests') with ordinality a(x, n) where n <= 500));
  end if;
  -- 2. Itens com stats impossíveis (mochila e equipamento)
  if jsonb_typeof(p->'inventory') = 'array' and public.nx_items_bad(p->'inventory') then
    p := jsonb_set(p, '{inventory}', (select coalesce(jsonb_agg(public.nx_clamp_item(it) order by n), '[]'::jsonb) from jsonb_array_elements(p->'inventory') with ordinality a(it, n)));
  end if;
  if jsonb_typeof(p->'equipment') = 'object' and public.nx_items_bad((select coalesce(jsonb_agg(e.value), '[]'::jsonb) from jsonb_each(p->'equipment') e where jsonb_typeof(e.value) = 'object')) then
    p := jsonb_set(p, '{equipment}', (select coalesce(jsonb_object_agg(e.key, public.nx_clamp_item(e.value)), '{}'::jsonb) from jsonb_each(p->'equipment') e));
  end if;
  -- 3. Vila: recursos até ao máximo do Armazém (Nv. 5), edifícios e melhorias até 5, soldados e aldeões com teto
  if jsonb_typeof(p->'vila') = 'object' then
    for c in select * from (values ('r', 7500), ('b', 5), ('up', 5), ('army', 60), ('jobs', 28), ('cool', 720)) as t(k, cap) loop
      if jsonb_typeof(p->'vila'->c.k) = 'object' then
        v_obj := p->'vila'->c.k;
        for v_k, v_v in select key, value from jsonb_each(p->'vila'->c.k) loop
          if jsonb_typeof(v_v) <> 'number' or (v_v #>> '{}')::numeric < 0 then v_obj := jsonb_set(v_obj, array[v_k], '0'::jsonb);
          elsif (v_v #>> '{}')::numeric > c.cap then v_obj := jsonb_set(v_obj, array[v_k], to_jsonb(c.cap)); end if;
        end loop;
        p := jsonb_set(p, array['vila', c.k], v_obj);
      end if;
    end loop;
    if jsonb_typeof(p->'vila'->'train') = 'array' and jsonb_array_length(p->'vila'->'train') > 60 then
      p := jsonb_set(p, '{vila,train}', (select jsonb_agg(x order by n) from jsonb_array_elements(p->'vila'->'train') with ordinality a(x, n) where n <= 60));
    end if;
    if jsonb_typeof(p->'vila'->'exp') = 'object' and jsonb_typeof(p->'vila'->'exp'->'me') = 'object' then
      v_obj := p->'vila'->'exp'->'me';
      for v_k, v_v in select key, value from jsonb_each(v_obj) loop
        if jsonb_typeof(v_v) <> 'number' or (v_v #>> '{}')::numeric < 0 then v_obj := jsonb_set(v_obj, array[v_k], '0'::jsonb);
        elsif (v_v #>> '{}')::numeric > 60 then v_obj := jsonb_set(v_obj, array[v_k], '60'::jsonb); end if;
      end loop;
      p := jsonb_set(p, '{vila,exp,me}', v_obj);
    end if;
  end if;
  return p;
end;
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

  -- v198: tudo dentro dos limites do jogo antes de gravar (quantidades, stats dos itens, Vila).
  p_save_data := public.nx_sanitize_save(p_save_data);

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

revoke all on function public.nx_item_stat_cap(jsonb, text) from public, anon, authenticated;
revoke all on function public.nx_clamp_item(jsonb) from public, anon, authenticated;
revoke all on function public.nx_items_bad(jsonb) from public, anon, authenticated;
revoke all on function public.nx_sanitize_save(jsonb) from public, anon, authenticated;
revoke all on function public.save_player_game(jsonb, bigint) from public, anon;
grant execute on function public.save_player_game(jsonb, bigint) to authenticated;
