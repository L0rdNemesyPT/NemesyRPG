# Nemesy RPG — versão PWA

Nemesy RPG é um jogo de fantasia em estilo navegador/PWA, com combate por turnos, progressão de personagem, loot, classes e upgrades. O projeto foi pensado para funcionar em qualquer dispositivo, com visual imersivo e experiência de jogo portátil, incluindo a possibilidade de instalar a app no ecrã principal.

## Introdução ao jogo

O jogador começa por criar o seu herói e escolher uma classe: Guerreiro, Arqueiro ou Mago. A partir daí, a aventura começa com a exploração de pequenos combates, conquistas de ouro, XP, missões e equipamentos cada vez mais fortes.

O objetivo principal é simples: evoluir o personagem, sobreviver aos inimigos e derrotar desafios cada vez maiores. À medida que o nível sobe, aparecem mais monstros, melhores armas, novas habilidades e situações que exigem estratégia, gestão de recursos e decisões de equipamento.

Nemesy RPG combina elementos clássicos de RPG com um fluxo rápido e acessível: cada batalha tem impacto direto no progresso, e a escolha da classe/skill define muito do estilo de jogo.

## Breve informação do jogo

- Tipo: RPG de navegador / PWA
- Estilo: fantasia sombria, combate por turnos e progressão por nível
- Plataforma: web, mobile e offline após instalação
- Sistema principal: combate, loot, habilidades, upgrades e equipamento
- Objetivo: superar monstros, completar tarefas e tornar o herói cada vez mais forte

## Mini wiki

### Classes

- Guerreiro: foco em resistência, dano direto e capacidade de aguentar ataques na linha da frente.
- Arqueiro: rápido, preciso e ideal para dano à distância com ataques de veneno, sangramento ou critico.
- Mago: poderoso em magia, dano elemental e controlo de batalha, mas mais frágil.

### Sistemas principais

- Combate: batalhas por turnos com ataques normais, habilidades especiais, buffs, status e critico.
- Equipamento: armas e itens com impacto direto no dano, defesa e estatísticas.
- Habilidades: cada classe tem uma árvore de habilidades que evolui com o tempo e oferece estilos de jogo distintos.
- Progressão: XP, ouro, nível, missões e itens raros ajudam a fortalecer o personagem.
- PWA: o jogo pode ser instalado como app e continuar a funcionar mesmo sem ligação ativa após a primeira visita.

### Objetivo da aventura

A história do jogo é orientada por uma progressão de poder, onde o herói avança de combate em combate, enfrenta ameaças mais fortes, obtém melhor equipamento e se prepara para desafios finais. O foco é a sensação de crescimento constante e a descoberta de novas estratégias de ataque e defesa.

---

## Ficheiros do projeto

- `index.html` — ficheiro principal; contém o jogo e é onde podes editar o código.
- `manifest.webmanifest` — nome, ícones e definições da app instalável.
- `sw.js` — guarda os ficheiros do jogo para utilização offline após a primeira visita.
- `icon-192.png`, `icon-512.png`, `icon-512-maskable.png` — ícones da app.

## Publicação

O jogo está publicado no GitHub Pages em:

https://l0rdnemesypt.github.io/NemesyRPG/

O GitHub Pages serve o site por HTTPS, necessário para instalar a app e usar
o modo offline. A configuração do Pages publica a branch `main`, na pasta
raiz (`/(root)`).

## Passo 2 — Instalar no telemóvel Android

1. Abre esse link no **Chrome** do telemóvel.
2. Chrome mostra um aviso "Adicionar Nemesy RPG ao ecrã principal" (ou vai a
   ⋮ → "Instalar app" / "Adicionar ao ecrã principal").
3. Confirma — fica com ícone próprio, abre em ecrã inteiro, sem barra do
   browser, e depois da primeira vez continua a abrir mesmo sem internet.

## Editar e publicar atualizações

Edita `index.html` para alterar o jogo. Mantém os outros ficheiros na
mesma pasta e publica as alterações no mesmo repositório/hosting; o link do
jogo não muda. Para forçar a atualização da cache offline em todos os
dispositivos, incrementa o nome em `CACHE_NAME` no início de `sw.js` (por
exemplo, de `nemesy-rpg-v3` para `nemesy-rpg-v4`). O ficheiro
`Nemesy-RPG.html` redireciona instalações antigas para o novo endereço do jogo.

## Nota sobre os saves

É necessário criar conta ou iniciar sessão para jogar. O progresso é guardado
na conta Supabase e sincronizado automaticamente. O browser mantém uma cópia
local temporária para suportar a sincronização durante falhas de rede. Não existe
importação nem exportação de ficheiros de save; uma conta sem save na nuvem começa
um herói novo. É necessária ligação à internet para iniciar sessão e carregar o
save da conta. Se a ligação cair durante uma sessão aberta, o progresso continua
a ser guardado localmente e sincroniza quando a ligação voltar. Não limpes os
dados do browser enquanto houver alterações por sincronizar.

## Contas e sincronização Supabase

O jogo está ligado ao projeto Supabase configurado em `supabase-config.js`.
Para preparar os saves e o mercado, abre **SQL Editor** nesse projeto e executa
a versão atual de `supabase/schema.sql`. Se já executaste uma versão anterior,
executa novamente o ficheiro atualizado para criar as funções e tabelas de Trades.
A chave publishable usada pelo jogo
não tem permissões para criar tabelas; essa operação tem de ser feita no painel.

Em **Authentication → URL Configuration**, define como **Site URL**:
   `https://l0rdnemesypt.github.io/NemesyRPG/`
Confirma também que a confirmação por email está configurada como desejas. Nunca
coloques a chave `service_role` no jogo ou no GitHub.

A tabela aplica Row Level Security: cada conta só pode ler ou eliminar o seu
próprio save diretamente; as gravações passam pelo RPC autenticado. Cria uma
conta ou inicia sessão no ecrã de entrada. O save da nuvem é a fonte de verdade.
Uma sessão não fica guardada entre aberturas do jogo: é necessário iniciar
sessão novamente sempre que a app for aberta.

## Jogar com outras pessoas

Qualquer pessoa com o link pode jogar no seu próprio dispositivo. Na tab
**Trades**, cada jogador pode manter até 3 itens anunciados por ouro, comprar
itens de outros jogadores ou retirar os próprios anúncios. As compras e
transferências são executadas em transações na base de dados. O servidor valida
campos básicos do save e controla as operações de Trades. Como a progressão do
jogo ainda é calculada no browser, um utilizador determinado pode alterar dados
antes da sincronização; impedir isso por completo exige mover a lógica de jogo
para o servidor.
