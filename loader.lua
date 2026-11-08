-- AutoHit loader — paste THIS into your executor, not the whole script.
-- Replace USER/REPO/BRANCH with your own.
-- The ?v= cache-buster matters: raw.githubusercontent caches for ~5 min.
loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/USER/REPO/main/autohit.lua?v=" .. tick()
))()
