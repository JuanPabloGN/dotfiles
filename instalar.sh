#!/bin/bash
# Copia la configuración del repo al sistema (repo -> sistema).
# Uso: ./instalar.sh comun            solo lo que sirve en cualquier distro
#      ./instalar.sh comun omarchy    + lo propio de Omarchy
#      ./instalar.sh sistema          archivos de /etc (pide sudo)
# Lo que se sobrescribe queda respaldado con la extensión .bak.<fecha>.
set -euo pipefail
cd "$(dirname "$0")"

(($# == 0)) && { sed -n '2,6p' "$0"; exit 1; }
fecha=$(date +%Y%m%d-%H%M%S)

while read -r grupo ruta; do
  [[ -z $grupo || $grupo == \#* ]] && continue
  [[ " $* " == *" $grupo "* ]] || continue
  origen="$grupo/$ruta"
  [[ -e $origen ]] || { echo "!! falta en el repo: $origen"; continue; }

  if [[ $grupo == sistema ]]; then
    destino="/$ruta"
    [[ -e $destino ]] && sudo cp -a "$destino" "$destino.bak.$fecha"
    sudo install -D -m 644 "$origen" "$destino"
  else
    destino="$HOME/$ruta"
    mkdir -p "$(dirname "$destino")"
    if [[ -d $origen ]]; then
      rsync -a --backup --suffix=".bak.$fecha" "$origen/" "$destino/"
    else
      [[ -e $destino ]] && cp -a "$destino" "$destino.bak.$fecha"
      cp -a "$origen" "$destino"
    fi
  fi
  echo "ok  $destino"
done < rutas

cat <<'EOF'

Pasos que el script no hace (ver README.md):
 - systemctl --user enable --now kraken-curva.service
 - sistema: sudo locale-gen (con es_CL.UTF-8 descomentado), sudo systemctl enable --now lactd
 - omarchy: omarchy restart shell
EOF
