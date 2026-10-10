-- v80: aceita os novos bónus de armas (Contra Demónios, Contra Mortos-Vivos, Dano de Habilidade) no Trades.
-- Corre isto uma vez no SQL Editor do Supabase.

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
      and v_g->>'type' in ('defesa', 'dano', 'vida', 'critico')
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
    'bonuses', v_bonuses, 'nephalemBonus', v_nephalem, 'altarBonus', v_altar,
    'corruption', v_corruption, 'setKey', v_set
  );
  if v_unique is not null then v_out := v_out || jsonb_build_object('uniqueEffect', v_unique); end if;
  if p_item->>'season' = '1' then v_out := v_out || jsonb_build_object('season', 1); end if;
  return v_out;
end;
$$;

revoke all on function public.clean_trade_item(jsonb) from public, anon, authenticated;
