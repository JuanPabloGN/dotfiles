-- Extra autostart processes.
-- o.launch_on_start("my-service")

-- Fondo animado (Lofi Girl, Workshop 3424949278). -p -a full: se pausa con una ventana en pantalla completa
-- load-scripts=no: sin el script MPRIS de mpv, así el fondo no aparece en el widget de música de la barra
-- ALL: en cualquier salida, así no se rompe si el monitor cambia de puerto (DP-1, DP-3...)
-- Desactivado 2026-11-11 al pasar al tema Midnight Drive (descomentar para volver al video):
-- o.launch_on_start('mpvpaper -p -a full -l bottom -o "no-audio loop hwdec=auto panscan=1.0 load-scripts=no" ALL /home/shonpol/.local/share/fondos/lofi-girl.mp4')

-- Vesktop (Discord) minimizado en la bandeja al iniciar sesión
o.launch_on_start("vesktop --start-minimized")
