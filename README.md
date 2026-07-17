# ClaudeQuota

Sua quota do Claude na menu bar do Mac. Sem abrir Settings → Usage nunca mais.

![menu bar](docs/menubar.png)

**Em cima**: % restante da sessão de 5h. **Embaixo**: tempo até o reset. Clique para ver os limites semanais (todos os modelos + o limite por modelo, ex. Fable), com notificação opcional quando a sessão reseta.

![painel](docs/panel.png)

## Por quê

No plano Max, os limites (sessão de 5h + semanal por modelo) definem qual modelo usar e quando. Checar isso exige três cliques até as configurações do Claude. Agora é um relance ao lado do relógio: laranja ≥75% usado, vermelho ≥90%, ponto vermelho quando o limite semanal do modelo top aperta.

## Requisitos

macOS 13+, assinatura Claude (Pro/Max). O app compila localmente em ~5s (sem certificado da Apple não há como distribuir binário sem o Gatekeeper reclamar — e assim você pode auditar cada linha do que roda).

## Instalar

### Opção 1 — peça ao seu Claude (recomendado)

No Cowork ou Claude Code:

> Clone https://github.com/gustavohsouza/claudequota e instale seguindo o INSTALL-CLAUDE.md

### Opção 2 — manual

```bash
git clone https://github.com/gustavohsouza/claudequota.git
cd claudequota
./install.command
```

O script compila, instala em /Applications, garante o Claude Code CLI e abre o login da sua conta Claude (um clique em Authorize no browser). Depois, clique no item da menu bar e ative "Launch at login".

## Como funciona

1. Consulta `api.anthropic.com/api/oauth/usage` a cada 60s — endpoint read-only de metadados, **não consome quota**. Countdown recalculado localmente a cada 20s. Backoff automático em rate limit, cache do último snapshot.
2. Autenticação: reutiliza a credencial oficial do Claude Code CLI (Keychain, serviço `Claude Code-credentials`) e a renova automaticamente. Seu token nunca sai do seu Mac.
3. Um único arquivo Swift (~600 linhas), zero dependências, ~0% CPU.

## Solução de problemas

- `CQ ⚠` na menu bar → `claude auth login --claudeai` no Terminal, depois Refresh no painel.
- Estado bruto para debug: `~/Library/Application Support/ClaudeQuota/state.json`.

## Desinstalar

Quit no painel e `rm -rf /Applications/ClaudeQuota.app`. A credencial pertence ao Claude Code e permanece.

## Créditos

Feito 100% com Claude (Cowork): PRD, engenharia reversa do fluxo OAuth, código, testes, screenshots e este README. Humano envolvido: 2 cliques em Authorize.
