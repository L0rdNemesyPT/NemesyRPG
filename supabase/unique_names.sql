-- Nomes de herói únicos. Seguro voltar a executar (SQL Editor do Supabase).
--
-- Dois heróis não podem ter o mesmo nome. A comparação ignora maiúsculas/minúsculas
-- e espaços a mais ("Nemesy", "nemesy" e "  NEMESY " contam como o mesmo nome).
-- Heróis que JÁ tinham nomes repetidos antes deste ficheiro ficam como estão: a regra
-- só é verificada quando um herói é criado ou muda de nome.

-- Forma normalizada de um nome, usada para comparar.
create or replace function public.hero_name_key(p_name text)
returns text
language sql
immutable
as $$
  select lower(regexp_replace(btrim(coalesce(p_name, '')), '\s+', ' ', 'g'))
$$;

create index if not exists game_saves_hero_name_key_idx
  on public.game_saves (public.hero_name_key(save_data->>'name'));

-- Verificação no servidor: corre sempre que um save é criado ou alterado.
create or replace function public.game_saves_unique_name()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_key text := public.hero_name_key(new.save_data->>'name');
begin
  if v_key = '' then return new; end if;
  -- O nome não mudou: não há nada a verificar (os saves normais passam aqui).
  if tg_op = 'UPDATE' and public.hero_name_key(old.save_data->>'name') = v_key then
    return new;
  end if;
  -- Evita que dois jogadores fiquem com o mesmo nome ao mesmo tempo.
  perform pg_advisory_xact_lock(hashtext('hero_name:' || v_key));
  if exists (
    select 1 from public.game_saves g
    where g.user_id <> new.user_id
      and public.hero_name_key(g.save_data->>'name') = v_key
  ) then
    raise exception 'NAME_TAKEN: Esse nome de herói já está a ser usado por outro jogador.';
  end if;
  return new;
end;
$$;

drop trigger if exists game_saves_unique_name on public.game_saves;
create trigger game_saves_unique_name
  before insert or update of save_data on public.game_saves
  for each row execute function public.game_saves_unique_name();

-- Usado pelo jogo para avisar logo, antes de criar o herói ou de mudar o nome.
create or replace function public.is_hero_name_available(p_name text)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select public.hero_name_key(p_name) <> ''
    and not exists (
      select 1 from public.game_saves g
      where g.user_id <> coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid)
        and public.hero_name_key(g.save_data->>'name') = public.hero_name_key(p_name)
    )
$$;

revoke all on function public.is_hero_name_available(text) from public;
grant execute on function public.is_hero_name_available(text) to authenticated;
