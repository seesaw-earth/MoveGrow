#!/bin/zsh
set -euo pipefail

REPO="Seesaw2025/MoveGrow"
BRANCH="main"

command -v git >/dev/null || { echo "git is required" >&2; exit 1; }
command -v gh >/dev/null || { echo "GitHub CLI (gh) is required: https://cli.github.com" >&2; exit 1; }

gh auth status

if [ ! -d .git ]; then
  git init -b "$BRANCH"
fi

git add .
if ! git diff --cached --quiet; then
  git commit -m "Open-source MoveGrow 1.0 submission candidate"
fi

if ! git remote get-url origin >/dev/null 2>&1; then
  gh repo create "$REPO" --public --source=. --remote=origin --push 
else
  git push -u origin "$BRANCH"
fi

# Publish /docs with GitHub Pages. POST creates Pages; PUT updates existing Pages.
if ! printf '%s' '{"source":{"branch":"main","path":"/docs"}}' | gh api -X POST "repos/$REPO/pages" --input - >/dev/null 2>&1; then
  printf '%s' '{"source":{"branch":"main","path":"/docs"}}' | gh api -X PUT "repos/$REPO/pages" --input - >/dev/null
fi

echo "Repository: https://github.com/$REPO"
echo "Privacy:   https://seesaw2025.github.io/MoveGrow/privacy.html"
echo "Support:   https://seesaw2025.github.io/MoveGrow/support.html"
echo "Home:      https://seesaw2025.github.io/MoveGrow/"
echo "Tag v1.0.0 only after this source exactly matches the archived App Store build."
