-- Change the default Omarchy look'n'feel.

-- https://wiki.hypr.land/Configuring/Basics/Variables/#general
-- hl.config({
--   general = {
--     -- No gaps between windows or borders.
--     gaps_in = 0,
--     gaps_out = 0,
--     border_size = 0,
--
--     -- Change to niri-like side-scrolling layout.
--     layout = "scrolling",
--   },
-- })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#decoration
-- hl.config({
--   decoration = {
--     -- Use round window corners.
--     rounding = 8,
--
--     -- Dim unfocused windows (0.0 = no dim, 1.0 = fully dimmed).
--     dim_inactive = true,
--     dim_strength = 0.15,
--   },
-- })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#animations
-- hl.config({
--   animations = {
--     -- Disable all animations.
--     enabled = false,
--   },
-- })

-- https://wiki.hypr.land/Configuring/Basics/Variables/#layout
-- hl.config({
--   layout = {
--     -- Avoid overly wide single-window layouts on wide screens.
--     single_window_aspect_ratio = { 1, 1 },
--   },
-- })

-- https://wiki.hypr.land/Configuring/Layouts/Scrolling-Layout/
-- hl.config({
--   scrolling = {
--     -- See only one column per screen instead of two.
--     column_width = 0.97,
--   },
-- })

-- VRR (FreeSync) solo en ventanas a pantalla completa (juegos). 0 = nunca, 1 = siempre, 2 = pantalla completa.
-- Monitor ASUS VG27AQL3A: requiere Adaptive-Sync activado en el menú del monitor.
hl.config({ misc = { vrr = 2 } })

-- Efecto "vidrio": esquinas redondeadas y desenfoque detrás de ventanas transparentes, barra y menús
hl.config({
  decoration = {
    rounding = 10,
    blur = { enabled = true, size = 6, passes = 2, new_optimizations = true },
  },
})
hl.layer_rule({ match = { namespace = "^(omarchy-bar|omarchy-menu|omarchy-notifications)$" }, blur = true, ignore_alpha = 0.2 })

-- Atenuar un poco las ventanas sin foco
hl.config({ decoration = { dim_inactive = true, dim_strength = 0.15 } })

-- Animaciones: ventanas que aparecen con un pequeño rebote y escritorios que se deslizan
hl.curve("rebote", { type = "bezier", points = { { 0.05, 0.9 }, { 0.1, 1.05 } } })
hl.animation({ leaf = "windowsIn", enabled = true, speed = 4, bezier = "rebote", style = "popin 80%" })
hl.animation({ leaf = "windowsMove", enabled = true, speed = 4, bezier = "easeOutQuint" })
hl.animation({ leaf = "workspaces", enabled = true, speed = 4, bezier = "easeOutQuint", style = "slide" })

-- Direct scanout para juegos en pantalla completa: el juego va directo a la pantalla sin pasar por el compositor (menos latencia)
-- 2 = solo cuando la ventana se declara como juego/video
hl.config({ render = { direct_scanout = 2 } })
