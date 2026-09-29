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

- `index.html` — o jogo (com o manifest e o service worker já ligados)
- `manifest.json` — nome, ícone e cor da app
- `sw.js` — permite abrir o jogo offline depois da primeira visita
- `icon-192.png`, `icon-512.png`, `icon-512-maskable.png` — ícones da app

## Passo 1 — Colocar estes ficheiros online (é obrigatório usar HTTPS)

Um PWA só funciona servido por HTTPS (não abre como PWA em `file://`).
A forma mais simples e gratuita é o **GitHub Pages**:

1. Cria uma conta no GitHub (github.com) se ainda não tiveres.
2. Cria um repositório novo, por exemplo `nemesy-rpg`.
3. Faz upload destes 6 ficheiros para esse repositório (botão "Add file" →
   "Upload files" no site do GitHub — não precisas de linha de comandos).
4. Vai a **Settings → Pages** do repositório, em "Branch" escolhe `main` e
   pasta `/ (root)`, e grava.
5. Ao fim de 1-2 minutos o GitHub dá-te um link tipo:
   `https://o-teu-utilizador.github.io/nemesy-rpg/`

Alternativas igualmente boas e gratuitas: **Netlify** ou **Vercel** — nesses
basta arrastar a pasta para o browser deles (drag & drop), sem precisares
sequer de conta no GitHub.

## Passo 2 — Instalar no telemóvel Android

1. Abre esse link no **Chrome** do telemóvel.
2. Chrome mostra um aviso "Adicionar Nemesy RPG ao ecrã principal" (ou vai a
   ⋮ → "Instalar app" / "Adicionar ao ecrã principal").
3. Confirma — fica com ícone próprio, abre em ecrã inteiro, sem barra do
   browser, e depois da primeira vez continua a abrir mesmo sem internet.

## Publicar uma atualização mais tarde

Sempre que fizeres alterações ao jogo:
1. Substitui o `index.html` pela nova versão no repositório/hosting.
2. Abre `sw.js` e muda `nemesy-rpg-v1` para `nemesy-rpg-v2` (ou seguinte) —
   isto é importante, porque é o que faz o telemóvel descarregar a versão
   nova em vez de continuar a mostrar a antiga a partir da cache.

## Nota sobre os saves

O jogo guarda o progresso em `localStorage`, isolado por app instalada —
não sincroniza entre telemóveis nem sobrevive a desinstalar a app. Usa o
botão de exportar/importar save (já existe nas Definições do jogo) antes de
desinstalar ou trocar de telemóvel.

## Jogar com outras pessoas

Depois de publicares o PWA, qualquer pessoa com o link pode jogar no seu
próprio dispositivo. O jogo continua a ser individual e offline: não tem
contas, ranking global, partidas em tempo real nem saves sincronizados. A
secção Amigos permite trocar itens por códigos, mas não valida as trocas num
servidor. Para essas funcionalidades é necessário criar e alojar um backend
com autenticação e armazenamento partilhado.
