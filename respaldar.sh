#!/bin/bash
# Copia la configuración actual del sistema al repo (sistema -> repo).
# Uso: ./respaldar.sh        Después: git add -A && git commit -m "..." && git push
set -euo pipefail
cd "$(dirname "$0")"

while read -r grupo ruta; do
  [[ -z $grupo || $grupo == \#* ]] && continue
  if [[ $grupo == sistema ]]; then origen="/$ruta"; else origen="$HOME/$ruta"; fi
  destino="$grupo/$ruta"

  if [[ ! -e $origen ]]; then
    echo "!! no existe, lo salto: $origen"
    continue
  fi
  mkdir -p "$(dirname "$destino")"
  if [[ -d $origen ]]; then
    rsync -a --delete --exclude '*.bak.*' --exclude '*.bak' "$origen/" "$destino/"
  else
    cp -a "$origen" "$destino"
  fi
  echo "ok  $origen"
done < rutas

# Listas de paquetes para reinstalar en otro sistema
mkdir -p paquetes
pacman -Qqen > paquetes/pacman.txt
pacman -Qqem > paquetes/aur.txt
command -v flatpak >/dev/null && flatpak list --app --columns=application > paquetes/flatpak.txt

echo
git status --short 2>/dev/null || true
