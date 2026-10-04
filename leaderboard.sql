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
