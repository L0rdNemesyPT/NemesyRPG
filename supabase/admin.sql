-- ============================================================
-- NEMESY RPG · MENU DE CRIADOR (v87)
-- Corre este ficheiro uma vez no SQL Editor do Supabase.
-- Depois adiciona o TEU utilizador como criador (ver o fim do ficheiro).
--
-- Segurança:
--  • As tabelas admins / admin_gifts / admin_log não são visíveis a nenhum jogador
--    (RLS ligado e sem políticas; só as funções abaixo lhes mexem).
--  • Todas as funções de criador verificam no servidor se quem chama está em
--    public.admins E se a sessão foi confirmada com a verificação em 2 passos (aal2).
--  • Nada é dado diretamente: o criador cria um "presente" e é o próprio jogador
--    (com a sessão dele) que o recebe com claim_admin_gifts(). Assim nunca se mexe
--    num save que está aberto noutro telemóvel.
--  • Tudo fica registado em admin_log.
-- ============================================================

create table if not exists public.admins (
  user_id uuid primary key references auth.users (id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.admins enable row level security;
revoke all on public.admins from public, anon, authenticated;

create table if not exists public.admin_gifts (
  id uuid primary key default gen_random_uuid(),
  target_id uuid not null references auth.users (id) on delete cascade,
  admin_id uuid not null,
  ops jsonb not null,
  note text,
  created_at timestamptz not null default now()
);
create index if not exists admin_gifts_target_idx on public.admin_gifts (target_id);
alter table public.admin_gifts enable row level security;
revoke all on public.admin_gifts from public, anon, authenticated;

create table if not exists public.admin_log (
  id bigserial primary key,
  at timestamptz not null default now(),
  admin_id uuid,
  target_id uuid,
  target_name text,
  action text not null,
  details jsonb
);
alter table public.admin_log enable row level security;
revoke all on public.admin_log from public, anon, authenticated;

-- Lança erro se quem chama não for criador com a verificação em 2 passos feita.
create or replace function public.admin_require()
returns uuid
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or not exists (select 1 from public.admins where user_id = v_uid) then
    raise exception 'Sem permissão.';
  end if;
  if coalesce(auth.jwt()->>'aal', '') <> 'aal2' then
    raise exception 'MFA_REQUIRED';
  end if;
  return v_uid;
end;
$$;

-- O jogo pergunta isto para saber se mostra o menu. Só responde sobre a própria conta.
create or replace function public.admin_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = public, pg_temp
as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or not exists (select 1 from public.admins where user_id = v_uid) then
    return jsonb_build_object('admin', false);
  end if;
  return jsonb_build_object('admin', true, 'mfa', coalesce(auth.jwt()->>'aal', '') = 'aal2');
end;
$$;

-- Recursos que se podem dar (caminho no save → máximo por presente).
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

-- Valida a lista de operações de um presente. Devolve as operações limpas.
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
revoke all on function public.admin_status() from public, anon;
revoke all on function public.admin_find_player(text) from public, anon;
revoke all on function public.admin_send_gift(uuid, jsonb, text) from public, anon;
revoke all on function public.admin_get_log(integer) from public, anon;
revoke all on function public.claim_admin_gifts() from public, anon;
revoke all on function public.has_admin_gifts() from public, anon;
grant execute on function public.has_admin_gifts() to authenticated;
grant execute on function public.admin_status() to authenticated;
grant execute on function public.admin_find_player(text) to authenticated;
grant execute on function public.admin_send_gift(uuid, jsonb, text) to authenticated;
grant execute on function public.admin_get_log(integer) to authenticated;
grant execute on function public.claim_admin_gifts() to authenticated;

-- ============================================================
-- PASSO FINAL (só uma vez): tornar a TUA conta criadora.
-- 1. Supabase → Authentication → Users → copia o "User UID" da tua conta.
-- 2. Substitui o texto abaixo pelo teu UID e corre só esta linha:
--
--   insert into public.admins (user_id) values ('COLA-AQUI-O-TEU-UID') on conflict do nothing;
--
-- Para retirar o acesso: delete from public.admins where user_id = '...';
-- ============================================================
