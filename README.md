# Nemesy RPG — versão PWA

Esta pasta contém tudo o que precisas para publicar o Nemesy RPG como PWA
(app instalável a partir do browser, com ícone próprio e a funcionar offline).

Ficheiros:
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
