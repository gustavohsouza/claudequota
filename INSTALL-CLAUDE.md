# Instruções para o Claude (Cowork ou Claude Code) instalar o ClaudeQuota

Você (Claude) recebeu esta pasta com o código-fonte do ClaudeQuota, um app de menu bar
para macOS que mostra os limites de uso do Claude (sessão 5h + limites semanais) ao lado
do relógio. Instale-o de ponta a ponta para o usuário. Requisitos: macOS 13+, assinatura
Claude (Pro/Max).

## Passos

1. **Verifique o toolchain**: `xcode-select -p` e `swiftc --version`. Se não houver
   Command Line Tools, rode `xcode-select --install`, avise o usuário para concluir a
   janela do macOS e retome depois.

2. **Compile e instale** (a partir desta pasta):
   ```
   swiftc -swift-version 5 -O -o ClaudeQuota main.swift
   rm -rf /Applications/ClaudeQuota.app
   mkdir -p /Applications/ClaudeQuota.app/Contents/MacOS /Applications/ClaudeQuota.app/Contents/Resources
   cp ClaudeQuota /Applications/ClaudeQuota.app/Contents/MacOS/ClaudeQuota
   cp Info.plist /Applications/ClaudeQuota.app/Contents/Info.plist
   codesign --force --deep --sign - /Applications/ClaudeQuota.app
   ```

3. **Garanta a autenticação** — o app lê a credencial do Claude Code CLI no Keychain
   (serviço `Claude Code-credentials`) e a renova sozinho depois:
   - Cheque: `security find-generic-password -s "Claude Code-credentials"` (só metadados).
   - Se não existir: garanta o CLI (`npm i -g @anthropic-ai/claude-code`) e rode
     `claude auth login --claudeai`. O browser abre; o USUÁRIO clica em Authorize na
     conta dele. Nunca leia ou exiba o token.

4. **Lance e valide**: `open /Applications/ClaudeQuota.app`. Após ~5s, confira
   `~/Library/Application Support/ClaudeQuota/state.json` — deve conter `"status" : "ok"`
   e os percentuais. O item aparece ao lado do relógio (2 linhas: % restante / countdown).

5. **Sugira ao usuário**: clicar no item e ativar "Launch at login" no painel.

## Notas de segurança
- Não modifique o main.swift. Não imprima tokens. O app só chama a API read-only de
  usage da Anthropic (`api.anthropic.com/api/oauth/usage`) — não consome quota.
- Se o menu bar mostrar `CQ ⚠`: rerun `claude auth login --claudeai`.
