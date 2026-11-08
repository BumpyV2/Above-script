-- AutoHit loader — paste THIS into your executor, not the whole script.
--
-- REQUIRES THE REPO TO BE PUBLIC. While Above-script is private, the raw URL
-- below returns 404: private raw links only work with a short-lived ?token=
-- tied to a logged-in browser session, which an executor does not have.
-- Either flip the repo to Public, or host Autohit.lua as a secret gist and
-- swap its raw URL in below.
--
-- The ?v= cache-buster matters: raw.githubusercontent caches for ~5 min,
-- so without it a fresh push will not load straight away.

loadstring(game:HttpGet(
    "https://raw.githubusercontent.com/BumpyV2/Above-script/main/Autohit.lua?v=" .. tick()
))()
