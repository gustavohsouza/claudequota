#!/bin/zsh
# ClaudeQuota — instalador local (compila na sua máquina, nada baixado de terceiros)
set -e
DIR="$(cd "$(dirname "$0")" && pwd)"
APP="/Applications/ClaudeQuota.app"

echo "═══ ClaudeQuota installer ═══"

# 1. Ferramentas de compilação (Xcode Command Line Tools)
if ! xcode-select -p >/dev/null 2>&1; then
  echo "→ Instalando as Command Line Tools da Apple (vai abrir uma janela do macOS)."
  echo "  Quando ela terminar, rode este instalador de novo."
  xcode-select --install || true
  exit 0
fi

# 2. Compilar e instalar
echo "→ Compilando..."
cd "$DIR"
swiftc -swift-version 5 -O -o ClaudeQuota main.swift
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp ClaudeQuota "$APP/Contents/MacOS/ClaudeQuota"
cp Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
rm -f ClaudeQuota
echo "✓ Instalado em $APP"

# 3. Claude Code CLI (fonte da autenticação)
if ! command -v claude >/dev/null 2>&1; then
  echo "→ Claude Code CLI não encontrado, tentando instalar..."
  if command -v npm >/dev/null 2>&1; then
    npm install -g @anthropic-ai/claude-code
  elif command -v brew >/dev/null 2>&1; then
    brew install node && npm install -g @anthropic-ai/claude-code
  else
    echo "⚠ Instale o Claude Code manualmente (https://claude.com/claude-code) e rode:"
    echo "    claude auth login --claudeai"
    echo "  Depois abra o ClaudeQuota de novo."
  fi
fi

# 4. Login na conta Claude (uma vez; o browser abre, clique em Authorize)
if command -v claude >/dev/null 2>&1; then
  if ! security find-generic-password -s "Claude Code-credentials" >/dev/null 2>&1; then
    echo "→ Login na sua conta Claude (o browser vai abrir, clique em Authorize)..."
    claude auth login --claudeai
  fi
fi

open "$APP"
echo "✓ Pronto! Olhe ao lado do relógio: % restante da sessão em cima, tempo até o reset embaixo."
echo "  Clique no item para ver os limites semanais e as opções."
