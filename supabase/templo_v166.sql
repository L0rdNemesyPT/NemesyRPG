-- ============================================================
-- v166: Templo das Almas — o menu de Criador passa a poder oferecer a
-- "Chave do Templo das Almas". Executar uma vez no SQL Editor do Supabase.
-- ============================================================
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
    ('pearl_branca', array['pearls','branca'], 999),
    ('pearl_azul', array['pearls','azul'], 999),
    ('pearl_vermelha', array['pearls','vermelha'], 999),
    ('pearl_verde', array['pearls','verde'], 999)
$$;

revoke all on function public.admin_add_paths() from public, anon, authenticated;
