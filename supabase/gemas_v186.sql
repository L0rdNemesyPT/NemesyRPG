-- v186: Rework das gemas — 5 níveis (T1–T5) e Pó Estelar.
-- Trades e Menu de Criador passam a aceitar gemas T4/T5 (nos itens e à venda) e o Pó Estelar.

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
  v_mythic text := null;
  v_craft text := null;
  v_armor text := null;
  v_skin text := null;
  v_medio integer := null;
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
    ('mitico', '#C4F23A', '❇️', 'Mítico', 3.0),
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
        when 'vs_demonios' then 40 when 'vs_mortos' then 40 when 'dano_habilidade' then 10
        when 'res_fogo' then 12 when 'res_gelo' then 12 when 'res_eletricidade' then 12 when 'res_terra' then 12 else null end;
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

  -- v184: Míticos — chave do Mítico tem de existir e bater certo com o espaço do item.
  if p_item->>'mythic' is not null then
    if v_rarity <> 'mitico' or not exists (select 1 from (values
      ('coracao_vidro', 'amulet'), ('pacto_sangue', 'amulet'), ('sede_carrasco', 'weapon'), ('mil_feridas', 'weapon'),
      ('tempestade_presa', 'weapon'), ('arco_suspiro', 'weapon'), ('bastiao_martir', 'offhand'), ('egide_montanha', 'offhand'),
      ('coroa_avarento', 'head'), ('olho_ciclope', 'head'), ('peitoral_eclipse', 'chest'), ('coracao_tita', 'chest'),
      ('manto_fenix', 'cape'), ('capa_sombras', 'cape'), ('botas_vento', 'boots'), ('sandalias_peregrino', 'boots'),
      ('luvas_sanguessuga', 'gloves'), ('garras_berserker', 'gloves'), ('prisma_errante', 'artifact'), ('ampulheta', 'artifact')
    ) as m(k, sl) where m.k = p_item->>'mythic' and m.sl = v_slot) then
      raise exception 'Este item Mítico não é válido e não pode ser vendido.';
    end if;
    v_mythic := p_item->>'mythic';
  end if;

  -- v123: bónus de Craft (Esconderijo), só em Peitorais.
  if jsonb_typeof(p_item->'craftBonus') = 'object' then
    -- v164: Armas também têm bónus de Craft (lista própria).
    if not ((v_slot = 'chest' and p_item->'craftBonus'->>'key' in ('hp', 'regen', 'bossred', 'sorte', 'terramoto'))
         or (v_slot = 'weapon' and p_item->'craftBonus'->>'key' in ('w_boss', 'w_demon', 'w_undead', 'w_gems'))) then
      raise exception 'Este item tem um bónus de Craft inválido e não pode ser vendido.';
    end if;
    v_craft := p_item->'craftBonus'->>'key';
  end if;

  -- v147: tipo de armadura (Escudo Mágico) — só em Capacetes, Peitorais, Luvas e Botas.
  if p_item->>'armorKind' is not null then
    if p_item->>'armorKind' not in ('hybrid', 'es') or v_slot not in ('head', 'chest', 'gloves', 'boots') then
      raise exception 'Este item tem um tipo de armadura inválido e não pode ser vendido.';
    end if;
    v_armor := p_item->>'armorKind';
  end if;

  -- v163: Armas da Cripta (Labirinto da Cripta) — skin própria + 5% a 20% de Dano Médio inato.
  if p_item->>'skin' is not null then
    if p_item->>'skin' not in ('cripta-espada', 'cripta-cajado', 'cripta-arco') or v_slot <> 'weapon'
      or coalesce(p_item->>'innateMedio', '') !~ '^[0-9]{1,2}$'
      or (p_item->>'innateMedio')::integer not between 5 and 20 then
      raise exception 'Esta Arma da Cripta não é válida e não pode ser vendida.';
    end if;
    v_skin := p_item->>'skin';
    v_medio := (p_item->>'innateMedio')::integer;
  end if;

  if coalesce(p_item->>'socketSlots', '1') ~ '^[1-3]$' then v_socket_slots := (coalesce(p_item->>'socketSlots', '1'))::integer;
  else raise exception 'Este item tem sockets inválidos e não pode ser vendido.'; end if;
  for v_i in 0 .. v_socket_slots - 1 loop
    v_g := case when jsonb_typeof(p_item->'sockets') = 'array' then p_item->'sockets'->v_i else null end;
    if v_g is not null and jsonb_typeof(v_g) = 'object'
      and v_g->>'type' in ('defesa', 'dano', 'vida', 'critico', 'chefes', 'escudo')
      and coalesce(v_g->>'tier', '') ~ '^[0-4]$' then
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
  if v_mythic is not null then v_out := v_out || jsonb_build_object('mythic', v_mythic); end if;
  if v_craft is not null then v_out := v_out || jsonb_build_object('craftBonus', jsonb_build_object('key', v_craft)); end if;
  if v_armor is not null then v_out := v_out || jsonb_build_object('armorKind', v_armor); end if;
  if v_skin is not null then v_out := v_out || jsonb_build_object('skin', v_skin, 'innateMedio', v_medio); end if;
  -- v174: Amuleto da Abóbora (evento de Halloween) — só em amuletos.
  if p_item->>'hwSkin' = 'abobora' and v_slot = 'amulet' then v_out := v_out || jsonb_build_object('hwSkin', 'abobora'); end if;
  -- v173: Ascensão (Coração do Soberano) — só em itens +9.
  if jsonb_typeof(p_item->'ascended') = 'boolean' and (p_item->>'ascended')::boolean and v_upgrade = 9 then v_out := v_out || jsonb_build_object('ascended', true); end if;
  if p_item->>'season' = '1' then v_out := v_out || jsonb_build_object('season', 1); end if;
  return v_out;
end;
$$;

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
    if p_sub is null or p_sub not between 0 and 4 then return null; end if;
    return (case p_key when 'defesa' then 'Pedra da Defesa' when 'dano' then 'Pedra do Dano'
      when 'vida' then 'Pedra da Vida' when 'critico' then 'Pedra do Crítico'
      when 'chefes' then 'Pedra do Caça-Chefes'
      when 'escudo' then 'Pedra do Escudo Mágico' end) || ' (T' || (p_sub + 1) || ')';
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
  elsif p_kind = 'gema' then v_root := 'gems'; v_len := 5;
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

create or replace function public.admin_add_paths()
returns table (k text, path text[], max_qty integer)
language sql
immutable
set search_path = public, pg_temp
as $$
  values
    ('scroll_feitico', array['scrolls','feitico'], 999),
    ('scroll_reforco', array['scrolls','reforco'], 999),
    ('scroll_feiticoPlus', array['scrolls','feiticoPlus'], 99),
    ('scroll_reforcoPlus', array['scrolls','reforcoPlus'], 99),
    ('nephalem', array['nephalemStones'], 99),
    ('smith_book', array['smithBooks'], 99),
    ('skill_book', array['skillBooks'], 999),
    ('profession_book', array['professionBooks'], 9),
    ('amnesia_book', array['amnesiaBooks'], 99),
    ('altar_charge', array['altarCharges'], 10),
    ('potion_hp', array['potions','hp'], 9999),
    ('potion_hp2', array['potions','hp2'], 9999),
    ('potion_def', array['potions','def'], 9999),
    ('potion_atk', array['potions','atk'], 9999),
    ('potion_fortune', array['potions','fortune'], 999),
    ('key_demonio_t1', array['catacumbKeys','demonio_t1'], 99),
    ('key_morte_t2', array['catacumbKeys','morte_t2'], 99),
    ('key_templo_almas', array['catacumbKeys','templo_almas'], 99),
    ('po_estelar', array['poEstelar'], 999),
    ('pearl_branca', array['pearls','branca'], 999),
    ('pearl_azul', array['pearls','azul'], 999),
    ('pearl_vermelha', array['pearls','vermelha'], 999),
    ('pearl_verde', array['pearls','verde'], 999)
$$;

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
      if v_op->>'gem' not in ('defesa', 'dano', 'vida', 'critico', 'chefes', 'escudo') or coalesce(v_op->>'tier', '') !~ '^[0-4]$' then raise exception 'Gema inválida.'; end if;
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

revoke all on function public.clean_trade_item(jsonb) from public, anon, authenticated;
revoke all on function public.admin_add_paths() from public, anon, authenticated;
revoke all on function public.admin_clean_ops(jsonb) from public, anon, authenticated;
revoke all on function public.nx_good_name(text, text, integer) from public, anon, authenticated;
revoke all on function public.nx_good_prepare(jsonb, text, text) from public, anon, authenticated;
