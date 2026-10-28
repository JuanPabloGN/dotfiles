# dotfiles

Mi configuración de Linux para jugar y trabajar: Omarchy (Arch + Hyprland) en un
i9-11900K + RX 6900 XT, con NZXT Kraken X62 y Logitech G PRO X Wireless.

## Estructura

| Carpeta | Qué tiene | ¿Sirve en otra distro? |
|---|---|---|
| `comun/` | MangoHud, presets de EasyEffects, curva del Kraken, batería de audífonos | Sí, tal cual |
| `omarchy/` | Hyprland (Lua), barra de Omarchy, reloj, Ghostty, modo juego, Steam con MangoHud | Hay que adaptarlo |
| `sistema/` | `/etc`: undervolt (LACT), watts CPU (RAPL), NTSYNC, idioma de la hora | Sí, con sudo |
| `paquetes/` | Listas de paquetes (pacman, AUR, flatpak) | Arch y derivadas |

`rutas` define qué se respalda y a dónde va cada cosa. Para agregar un archivo, se
agrega una línea ahí.

## Uso

```bash
./respaldar.sh                         # sistema -> repo
git add -A && git commit -m "..." && git push

./instalar.sh comun omarchy            # repo -> sistema (en un PC nuevo)
./instalar.sh sistema                  # /etc, pide sudo
```

## Lo que no está en el repo (depende de la máquina)

- **Parámetro del kernel para el undervolt:** en `/etc/default/limine` agregar
  `KERNEL_CMDLINE[default]+=" amdgpu.ppfeaturemask=0xffffffff"` y correr `sudo limine-update`.
- **Disco de juegos (Crucial):** línea en `/etc/fstab` por UUID, montado en `/mnt/disco2` con `defaults,nofail`.
- **Idioma de la hora:** descomentar `es_CL.UTF-8` en `/etc/locale.gen` y correr `sudo locale-gen`.
- **Steam:** opción de lanzamiento de Ground Zero
  `PROTON_DISABLE_HIDRAW=0x1E71/0x170E,0x0B05/0x19AF,0x054C/0x0CE6 %command%` + Steam Input desactivado.

## Pasar a otra distro (por ejemplo Ryoku)

`comun/` y `sistema/` se instalan igual. De `omarchy/`, lo que hay que reescribir:
- Las reglas de ventana y atajos usan los helpers de Omarchy (`o.window`, `o.bind`).
  En otra distro se pasan a la sintaxis de Hyprland que use (`windowrule`, `bind`).
- La barra (`shell.json`, plugins) es propia de Omarchy. Los scripts de
  `bar/scripts/` imprimen JSON estilo Waybar, así que sirven en casi cualquier barra.
