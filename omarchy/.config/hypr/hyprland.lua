-- Learn how to configure Hyprland: https://wiki.hypr.land/Configuring/Start/

-- Omarchy's bootstrap keeps path setup out of this user config.
dofile((os.getenv("OMARCHY_PATH") or "/usr/share/omarchy") .. "/default/hypr/bootstrap.lua")

-- Disable all Omarchy default bindings. Add your own in hypr/bindings.lua.
-- omarchy_default_bindings = false
--
-- Or disable only bindings for Omarchy's preinstalled apps/web apps while
-- keeping core window-manager bindings:
-- omarchy_preinstalled_bindings = false

-- Load Omarchy defaults.
require("default.hypr.omarchy")

-- Put your personal overrides in these files. They're loaded after Omarchy's
-- defaults so package updates can improve the defaults without rewriting your
-- ~/.config/hypr files.
require("hypr.monitors")
require("hypr.input")
require("hypr.bindings")
require("hypr.looknfeel")
require("hypr.autostart")

-- Toggle config flags dynamically.
require("default.hypr.toggles")

-- Add any other personal Hyprland configuration below.
-- o.window("qemu", { workspace = "5" })

-- Steam: ventana principal en mosaico (Omarchy la deja flotando en 1100x700); diálogos y amigos siguen flotando
o.window({ class = "steam", title = "Steam" }, { float = false })

-- CS2 abre como ventana sin bordes, que Hyprland no considera pantalla completa (sin VRR ni pausa del fondo animado)
o.window("cs2", { fullscreen = true, idle_inhibit = "fullscreen" })

-- Juegos de Steam (Proton): sin protector de pantalla ni bloqueo mientras están en pantalla completa (jugando con mando)
o.window("steam_app_.*", { idle_inhibit = "fullscreen" })

-- Escritorios fijos: 1 Zen y Chromium · 2 libre · 3 Steam · 4 terminal (Ghostty) · 5 Vesktop · 6 Claude
o.window("zen", { workspace = "1" })
o.window("vesktop", { workspace = "5 silent" })
o.window("chromium", { workspace = "1" })
o.window("steam", { workspace = "3" })
o.window("com.mitchellh.ghostty", { workspace = "4" })
o.window("org.omarchy.agent", { workspace = "6" })

-- Terminal más transparente para que se vea el fondo con desenfoque (Omarchy usa 0.985/0.96)
o.window("com.mitchellh.ghostty", { tag = "-default-opacity", opacity = "0.88 0.8" })
