-- ============================================================
-- v104 — Gema nova "Pedra do Caça-Chefes" (tipo 'chefes').
-- Corre isto UMA vez no SQL Editor do Supabase (depois do schema.sql e admin.sql).
-- Sem isto, um item vendido/trocado perde a gema Caça-Chefes (o servidor só aceitava
-- as 4 gemas antigas) e o menu de Criador não consegue oferecer esta gema.
-- ============================================================

create or replace function public.clean_trade_item(p_item jsonb)
returns jsonb
language plpgsql
immutable
set search_path = public, pg_temp
as $$
declare
  v_slot text := p_item->>'slot';
  v_rarity text := p_item->>'rarity';
  v_color text; v_icon text; v_rname text; v_mult numeric;
  v_level numeric;
  v_upgrade numeric := 0;
  v_cap numeric;
  v_crit_cap numeric;
  v_name text;
  v_bonuses jsonb := '[]'::jsonb;
  v_sockets jsonb := '[]'::jsonb;
  v_socket_slots integer := 1;
  v_b jsonb;
  v_bmax numeric;
  v_nephalem jsonb := 'null'::jsonb;
  v_plus jsonb := 'null'::jsonb;
  v_pmin numeric; v_pmax numeric; v_pweapon boolean;
  v_altar jsonb := 'null'::jsonb;
  v_corruption jsonb := 'null'::jsonb;
  v_set text := null;
  v_unique text := null;
  v_i integer;
  v_g jsonb;
  v_out jsonb;
begin
  if coalesce(jsonb_typeof(p_item), '') <> 'object' then raise exception 'Este item não é válido para venda.'; end if;
  if v_slot is null or v_slot not in ('weapon', 'offhand', 'head', 'chest', 'cape', 'boots', 'gloves', 'amulet', 'artifact') then
    raise exception 'Este item não é válido para venda.';
  end if;

  select r.color, r.icon, r.name, r.mult into v_color, v_icon, v_rname, v_mult
  from (values
    ('comum', '#B9B4A8', '⚪', 'Comum', 1.0),
    ('incomum', '#4E8FD6', '🔵', 'Incomum', 1.3),
    ('raro', '#9A5FD6', '🟣', 'Raro', 1.8),
    ('lendario', '#C9A227', '🟡', 'Lendário', 2.8),
    ('unico', '#D6822E', '🟠', 'Único', 4.0),
    ('demoniaco', '#C13B3B', '🔴', 'Demoníaco', 4.3),
    ('set', '#5FA05F', '🟢', 'Set', 3.2),
    ('divino', '#3FE0D0', '💠', 'Divino', 5.5),
    ('temporada', '#F2C94C', '⭐', 'Temporada', 4.0)
  ) as r(key, color, icon, name, mult)
  where r.key = v_rarity;
  if v_color is null then raise exception 'Este item tem uma raridade inválida e não pode ser vendido.'; end if;

  if coalesce(p_item->>'itemLevel', '') !~ '^[1-9][0-9]{0,2}$' then raise exception 'Este item tem um nível inválido e não pode ser vendido.'; end if;
  v_level := (p_item->>'itemLevel')::numeric;
  if v_level > 200 then raise exception 'Este item tem um nível inválido e não pode ser vendido.'; end if;
  if p_item ? 'upgrade' and jsonb_typeof(p_item->'upgrade') <> 'null' then
    if coalesce(p_item->>'upgrade', '') !~ '^[0-9]$' then raise exception 'Este item tem uma melhoria inválida e não pode ser vendido.'; end if;
    v_upgrade := (p_item->>'upgrade')::numeric;
  end if;

  -- Limite folgado acima do máximo que generateItem pode gerar (mesma fórmula de poder,
  -- com a raridade mais forte e margem para itens de versões antigas).
  v_cap := (1 + v_level * 0.35) * 5.5 * 2.5 + 10;
  v_crit_cap := (1 + v_level * 0.35) * 5.5 * 0.006 * 1.3 + 0.05;

  v_name := btrim(regexp_replace(regexp_replace(coalesce(p_item->>'name', ''), '[<>"''`&\\]', '', 'g'), '\s+', ' ', 'g'));
  v_name := left(v_name, 60);
  if v_name = '' then v_name := 'Item'; end if;

  if jsonb_typeof(p_item->'bonuses') = 'array' then
    if jsonb_array_length(p_item->'bonuses') > 2 then raise exception 'Este item tem bónus a mais e não pode ser vendido.'; end if;
    for v_b in select value from jsonb_array_elements(p_item->'bonuses') loop
      v_bmax := case v_b->>'key'
        when 'dano_pct' then 20 when 'vs_animais' then 40 when 'vs_humanos' then 40
        when 'atordoamento' then 30 when 'esquiva' then 20 when 'regeneracao' then 6
        when 'envenenamento' then 40 when 'dano_medio_pct' then 10
        when 'vs_demonios' then 40 when 'vs_mortos' then 40 when 'dano_habilidade' then 10 else null end;
      if v_bmax is null or jsonb_typeof(v_b->'value') <> 'number'
        or (v_b->>'value')::numeric < 0 or (v_b->>'value')::numeric > v_bmax then
        raise exception 'Este item tem bónus inválidos e não pode ser vendido.';
      end if;
      v_bonuses := v_bonuses || jsonb_build_array(jsonb_build_object('key', v_b->>'key', 'value', (v_b->>'value')::numeric));
    end loop;
  end if;

  if jsonb_typeof(p_item->'nephalemBonus') = 'object' then
    v_bmax := case p_item->'nephalemBonus'->>'key' when 'dano_pct' then 5 when 'envenenamento' then 3 when 'vida_flat' then 80 else null end;
    if v_bmax is null or jsonb_typeof(p_item->'nephalemBonus'->'value') <> 'number'
      or (p_item->'nephalemBonus'->>'value')::numeric < 0 or (p_item->'nephalemBonus'->>'value')::numeric > v_bmax then
      raise exception 'Este item tem um bónus Nephalen inválido e não pode ser vendido.';
    end if;
    v_nephalem := jsonb_build_object('key', p_item->'nephalemBonus'->>'key', 'value', (p_item->'nephalemBonus'->>'value')::numeric);
  end if;

  -- v86: Bónus ➕ (Pergaminhos ➕ da Torre). Um só por item; arma e outros itens têm bónus diferentes.
  if jsonb_typeof(p_item->'plusBonus') = 'object' then
    select mn, mx, w into v_pmin, v_pmax, v_pweapon from (values
      ('pp_dano', 1, 3, true), ('pp_boss', 2, 10, true), ('pp_vampiro', 2, 5, true),
      ('pp_def', 2, 5, false), ('pp_hp', 100, 300, false), ('pp_crit', 2, 5, false)
    ) as t(k, mn, mx, w) where t.k = p_item->'plusBonus'->>'key';
    if v_pmin is null or v_pweapon <> (v_slot = 'weapon') or jsonb_typeof(p_item->'plusBonus'->'value') <> 'number'
      or (p_item->'plusBonus'->>'value')::numeric < v_pmin or (p_item->'plusBonus'->>'value')::numeric > v_pmax then
      raise exception 'Este item tem um bónus ➕ inválido e não pode ser vendido.';
    end if;
    v_plus := jsonb_build_object('key', p_item->'plusBonus'->>'key', 'value', (p_item->'plusBonus'->>'value')::numeric);
  end if;

  if jsonb_typeof(p_item->'altarBonus') = 'object' then
    v_altar := case p_item->'altarBonus'->>'key'
      when 'furioso' then '{"key":"furioso","dmgPct":5}'::jsonb
      when 'glorioso' then '{"key":"glorioso","dmgVsBossPct":0.08}'::jsonb
      when 'gladiador' then '{"key":"gladiador","dmgReducedFromBossPct":0.05}'::jsonb
      when 'fortaleza' then '{"key":"fortaleza","hpFlat":100}'::jsonb
      else null end;
    if v_altar is null then raise exception 'Este item tem um bónus de Altar inválido e não pode ser vendido.'; end if;
  end if;

  if jsonb_typeof(p_item->'corruption') = 'object' and jsonb_typeof(p_item->'corruption'->'hpDebuff') = 'number' then
    v_corruption := jsonb_build_object('hpDebuff', greatest(0, round((p_item->'corruption'->>'hpDebuff')::numeric)));
  end if;
  if v_rarity = 'demoniaco' and v_corruption = 'null'::jsonb then
    raise exception 'Este item Demoníaco não tem a corrupção e não pode ser vendido.';
  end if;

  if p_item->>'setKey' is not null then
    if p_item->>'setKey' not in ('dragao', 'sombras', 'celestial', 'luar') then raise exception 'Este item tem um set inválido e não pode ser vendido.'; end if;
    v_set := p_item->>'setKey';
  end if;
  if p_item->>'uniqueEffect' is not null then
    if p_item->>'uniqueEffect' <> 'bleedImmune' or v_slot not in ('amulet', 'chest') then
      raise exception 'Este item tem um efeito inválido e não pode ser vendido.';
    end if;
    v_unique := 'bleedImmune';
  end if;

  if coalesce(p_item->>'socketSlots', '1') ~ '^[1-3]$' then v_socket_slots := (coalesce(p_item->>'socketSlots', '1'))::integer;
  else raise exception 'Este item tem sockets inválidos e não pode ser vendido.'; end if;
  for v_i in 0 .. v_socket_slots - 1 loop
    v_g := case when jsonb_typeof(p_item->'sockets') = 'array' then p_item->'sockets'->v_i else null end;
    if v_g is not null and jsonb_typeof(v_g) = 'object'
      and v_g->>'type' in ('defesa', 'dano', 'vida', 'critico', 'chefes')
      and coalesce(v_g->>'tier', '') ~ '^[0-2]$' then
      v_sockets := v_sockets || jsonb_build_array(jsonb_build_object('type', v_g->>'type', 'tier', (v_g->>'tier')::integer));
    else
      v_sockets := v_sockets || jsonb_build_array(null::jsonb);
    end if;
  end loop;

  v_out := jsonb_build_object(
    'id', coalesce(p_item->>'id', ''),
    'slot', v_slot, 'name', v_name,
    'rarity', v_rarity, 'rarityColor', v_color, 'rarityName', v_rname, 'rarityIcon', v_icon,
    'itemLevel', v_level, 'upgrade', v_upgrade,
    'stats', public.clean_trade_stats(p_item->'stats', v_cap, v_crit_cap),
    'baseStats', public.clean_trade_stats(p_item->'baseStats', v_cap, v_crit_cap),
    'socketSlots', v_socket_slots, 'sockets', v_sockets,
    'bonuses', v_bonuses, 'nephalemBonus', v_nephalem, 'plusBonus', v_plus, 'altarBonus', v_altar,
    'corruption', v_corruption, 'setKey', v_set
  );
  if v_unique is not null then v_out := v_out || jsonb_build_object('uniqueEffect', v_unique); end if;
  if p_item->>'season' = '1' then v_out := v_out || jsonb_build_object('season', 1); end if;
  return v_out;
end;
$$;

revoke all on function public.clean_trade_stats(jsonb, numeric, numeric) from public, anon, authenticated;
revoke all on function public.clean_trade_item(jsonb) from public, anon, authenticated;

create or replace function public.admin_clean_ops(p_ops jsonb)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_op jsonb;
  v_out jsonb := '[]'::jsonb;
  v_kind text;
  v_n numeric;
  v_max integer;
  v_item jsonb;
begin
  if coalesce(jsonb_typeof(p_ops), '') <> 'array' or jsonb_array_length(p_ops) = 0 or jsonb_array_length(p_ops) > 30 then
    raise exception 'Presente vazio ou com operações a mais.';
  end if;
  for v_op in select value from jsonb_array_elements(p_ops) loop
    v_kind := v_op->>'op';
    if v_kind in ('gold', 'xp', 'set_level', 'add', 'gem') then
      if coalesce(v_op->>'amount', '') !~ '^[1-9][0-9]{0,9}$' then raise exception 'Quantidade inválida.'; end if;
      v_n := (v_op->>'amount')::numeric;
    end if;
    if v_kind = 'gold' then
      if v_n > 100000000 then raise exception 'Ouro: máximo 100 000 000 por presente.'; end if;
      v_out := v_out || jsonb_build_array(jsonb_build_object('op', 'gold', 'amount', v_n));
    elsif v_kind = 'xp' then
      if v_n > 100000000 then raise exception 'XP: máximo 100 000 000 por presente.'; end if;
      v_out := v_out || jsonb_build_array(jsonb_build_object('op', 'xp', 'amount', v_n));
    elsif v_kind = 'set_level' then
      if v_n > 200 then raise exception 'Nível máximo: 200.'; end if;
      v_out := v_out || jsonb_build_array(jsonb_build_object('op', 'set_level', 'amount', v_n));
    elsif v_kind = 'add' then
      select max_qty into v_max from public.admin_add_paths() where k = v_op->>'key';
      if v_max is null then raise exception 'Recurso desconhecido.'; end if;
      if v_n > v_max then raise exception 'Quantidade acima do máximo (%).', v_max; end if;
      v_out := v_out || jsonb_build_array(jsonb_build_object('op', 'add', 'key', v_op->>'key', 'amount', v_n));
    elsif v_kind = 'gem' then
      if v_op->>'gem' not in ('defesa', 'dano', 'vida', 'critico', 'chefes') or coalesce(v_op->>'tier', '') !~ '^[0-2]$' then raise exception 'Gema inválida.'; end if;
      if v_n > 999 then raise exception 'Gemas: máximo 999.'; end if;
      v_out := v_out || jsonb_build_array(jsonb_build_object('op', 'gem', 'gem', v_op->>'gem', 'tier', (v_op->>'tier')::int, 'amount', v_n));
    elsif v_kind = 'item' then
      -- O item passa pela mesma limpeza/validação do Trades (stats, nível ≤ 200, bónus…).
      begin
        v_item := public.clean_trade_item(v_op->'item');
      exception when others then
        raise exception 'Item inválido: %', sqlerrm;
      end;
      v_out := v_out || jsonb_build_array(jsonb_build_object('op', 'item', 'item', v_item));
    else
      raise exception 'Operação desconhecida.';
    end if;
  end loop;
  return v_out;
end;
$$;

-- Procura um jogador pelo nome do herói (só criadores).
create or replace function public.admin_find_player(p_name text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare v_row record;
begin
  perform public.admin_require();
  select user_id, save_data->>'name' as name, save_data->>'level' as level, save_data->>'class' as cls
    into v_row
  from public.game_saves
  where public.hero_name_key(save_data->>'name') = public.hero_name_key(p_name)
  limit 1;
  if not found then return null; end if;
  return jsonb_build_object('user_id', v_row.user_id, 'name', v_row.name, 'level', v_row.level, 'class', v_row.cls);
end;
$$;

-- Cria um presente para um jogador (p_target null = para mim).
create or replace function public.admin_send_gift(p_target uuid, p_ops jsonb, p_note text)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_admin uuid := public.admin_require();
  v_target uuid := coalesce(p_target, v_admin);
  v_name text;
  v_ops jsonb;
  v_note text := left(btrim(regexp_replace(coalesce(p_note, ''), '[<>"''`&\\]', '', 'g')), 140);
  v_id uuid;
  v_recent integer;
begin
  select save_data->>'name' into v_name from public.game_saves where user_id = v_target;
  if not found then raise exception 'Jogador não encontrado.'; end if;
  -- Travão contra enganos/abusos: no máximo 60 presentes por hora.
  select count(*) into v_recent from public.admin_log where admin_id = v_admin and action = 'gift' and at > now() - interval '1 hour';
  if v_recent >= 60 then raise exception 'Limite de 60 presentes por hora atingido.'; end if;
  v_ops := public.admin_clean_ops(p_ops);
  insert into public.admin_gifts (target_id, admin_id, ops, note) values (v_target, v_admin, v_ops, nullif(v_note, '')) returning id into v_id;
  insert into public.admin_log (admin_id, target_id, target_name, action, details)
  values (v_admin, v_target, v_name, 'gift', jsonb_build_object('gift_id', v_id, 'ops', v_ops, 'note', v_note));
  return jsonb_build_object('id', v_id, 'target_name', v_name, 'self', v_target = v_admin);
end;
$$;

-- Últimas ações (só criadores).
create or replace function public.admin_get_log(p_limit integer default 30)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  perform public.admin_require();
  return coalesce((
    select jsonb_agg(jsonb_build_object('at', at, 'target_name', target_name, 'action', action, 'details', details) order by id desc)
    from (select * from public.admin_log order by id desc limit least(greatest(coalesce(p_limit, 30), 1), 100)) l
  ), '[]'::jsonb);
end;
$$;

-- O jogo pergunta se há presentes à espera (só da própria conta), antes de sincronizar.
create or replace function public.has_admin_gifts()
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (select 1 from public.admin_gifts where target_id = auth.uid());
$$;

-- O jogador recebe os presentes pendentes. Corre com a sessão do próprio jogador.
create or replace function public.claim_admin_gifts()
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_save jsonb;
  v_gift record;
  v_op jsonb;
  v_count integer := 0;
  v_notes jsonb := '[]'::jsonb;
  v_lines jsonb := '[]'::jsonb;
  v_path text[];
  v_cur numeric;
  v_level integer;
  v_xp numeric;
  v_need numeric;
  v_item jsonb;
  v_revision bigint;
  v_now timestamptz := clock_timestamp();
begin
  if v_uid is null then raise exception 'É necessário iniciar sessão.'; end if;
  if not exists (select 1 from public.admin_gifts where target_id = v_uid) then
    return jsonb_build_object('count', 0);
  end if;
  select save_data into v_save from public.game_saves where user_id = v_uid for update;
  if not found then return jsonb_build_object('count', 0); end if;

  for v_gift in delete from public.admin_gifts where target_id = v_uid returning * loop
    v_count := v_count + 1;
    if v_gift.note is not null then v_notes := v_notes || to_jsonb(v_gift.note); end if;
    for v_op in select value from jsonb_array_elements(public.admin_clean_ops(v_gift.ops)) loop
      if v_op->>'op' = 'gold' then
        v_cur := coalesce(nullif(v_save->>'gold', '')::numeric, 0) + (v_op->>'amount')::numeric;
        v_save := jsonb_set(v_save, '{gold}', to_jsonb(least(v_cur, 9007199254740991)), true);
        v_lines := v_lines || to_jsonb('🪙 ' || (v_op->>'amount') || ' ouro');
      elsif v_op->>'op' in ('xp', 'set_level') then
        v_level := greatest(1, coalesce(nullif(v_save->>'level', '')::int, 1));
        if v_op->>'op' = 'set_level' then
          v_level := (v_op->>'amount')::int; v_xp := 0;
          v_lines := v_lines || to_jsonb('⭐ Nível ' || v_level);
        else
          v_xp := coalesce(nullif(v_save->>'xp', '')::numeric, 0) + (v_op->>'amount')::numeric;
          loop
            exit when v_level >= 200;
            v_need := public.hero_xp_for_level(v_level);
            exit when v_xp < v_need;
            v_xp := v_xp - v_need; v_level := v_level + 1;
          end loop;
          if v_level >= 200 then v_xp := 0; end if;
          v_lines := v_lines || to_jsonb('✨ ' || (v_op->>'amount') || ' XP');
        end if;
        v_save := jsonb_set(jsonb_set(v_save, '{level}', to_jsonb(v_level), true), '{xp}', to_jsonb(round(v_xp)), true);
      elsif v_op->>'op' = 'add' then
        select path into v_path from public.admin_add_paths() where k = v_op->>'key';
        if array_length(v_path, 1) = 2 and jsonb_typeof(v_save->v_path[1]) is distinct from 'object' then
          v_save := jsonb_set(v_save, array[v_path[1]], '{}'::jsonb, true);
        end if;
        v_cur := coalesce(nullif(v_save #>> v_path, '')::numeric, 0) + (v_op->>'amount')::numeric;
        v_save := jsonb_set(v_save, v_path, to_jsonb(v_cur), true);
        v_lines := v_lines || to_jsonb((v_op->>'key') || ' ×' || (v_op->>'amount'));
      elsif v_op->>'op' = 'gem' then
        if jsonb_typeof(v_save #> array['gems', v_op->>'gem']) is distinct from 'array' then
          v_save := jsonb_set(v_save, array['gems', v_op->>'gem'], '[0,0,0]'::jsonb, true);
        end if;
        v_path := array['gems', v_op->>'gem', v_op->>'tier'];
        v_cur := coalesce(nullif(v_save #>> v_path, '')::numeric, 0) + (v_op->>'amount')::numeric;
        v_save := jsonb_set(v_save, v_path, to_jsonb(v_cur), true);
        v_lines := v_lines || to_jsonb('gem:' || (v_op->>'gem') || ':' || (v_op->>'tier') || ' ×' || (v_op->>'amount'));
      elsif v_op->>'op' = 'item' then
        v_item := jsonb_set(v_op->'item', '{id}', to_jsonb('it_admin_' || replace(gen_random_uuid()::text, '-', '')), true);
        v_save := jsonb_set(v_save, '{inventory}', coalesce(v_save->'inventory', '[]'::jsonb) || jsonb_build_array(v_item), true);
        v_lines := v_lines || to_jsonb('item:' || coalesce(v_item->>'name', 'Item'));
      end if;
    end loop;
    insert into public.admin_log (admin_id, target_id, target_name, action, details)
    values (v_gift.admin_id, v_uid, v_save->>'name', 'claimed', jsonb_build_object('gift_id', v_gift.id));
  end loop;

  update public.game_saves
  set save_data = v_save, updated_at = v_now, revision = revision + 1
  where user_id = v_uid
  returning revision into v_revision;

  return jsonb_build_object('count', v_count, 'notes', v_notes, 'lines', v_lines,
    'save_data', v_save, 'updated_at', v_now, 'revision', v_revision);
end;
$$;

revoke all on function public.admin_require() from public, anon, authenticated;
revoke all on function public.admin_add_paths() from public, anon, authenticated;
revoke all on function public.admin_clean_ops(jsonb) from public, anon, authenticated;
