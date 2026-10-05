-- Relógio do servidor (usado pelo Mercado Negro para as 3 horas não dependerem do relógio do telemóvel).
-- É seguro voltar a executar. Sem esta função o jogo usa o relógio do dispositivo.
create or replace function public.get_server_time()
returns bigint
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select floor(extract(epoch from clock_timestamp()) * 1000)::bigint;
$$;

revoke all on function public.get_server_time() from public, anon;
grant execute on function public.get_server_time() to authenticated;
