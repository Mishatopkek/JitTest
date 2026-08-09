-- =============================================================================
-- Daily driver. Put the caret on a statement, hit Ctrl+Enter.
--
-- Everything here is a one-liner because the logic lives in db/install.sql.
-- Run that script once first (and again after you edit it).
--
-- Toolbar must be set to the Postgres data source and the backlog database
-- (see CLAUDE.local.md). Then this file is versioned in git, unlike the
-- scratch console.
-- =============================================================================

SELECT id, game_name, finished, notes FROM custom.game_search('A');
SELECT * FROM custom.game_add('A', 1,2, 3
    , '');

    
    
-- Run this first in a fresh console. Rider's schema dropdown can set
-- search_path to "custom" alone, which hides pg_trgm's similarity() and breaks
-- the fuzzy queries below with "function similarity(...) does not exist".
SET search_path TO custom, public;


-- --- look things up ----------------------------------------------------------

SELECT id, game_name, finished, notes FROM custom.game_search('police');

SELECT * FROM custom.v_game_stats;

SELECT id, hours_average, finished FROM custom.v_game_by_length;

SELECT id, game_name, finished FROM custom.v_game_by_length;


-- --- what should I play next -------------------------------------------------

SELECT id, game_name FROM custom.game_random('short');

SELECT id, game_name FROM custom.game_random('medium');

SELECT id, game_name FROM custom.game_random('long');

SELECT id, game_name FROM custom.game_random();

-- Only games carrying every one of these tags.
SELECT id, game_name FROM custom.game_random('any', ARRAY['VR']);
SELECT id, game_name FROM custom.game_random('short', ARRAY['PC', 'co-op']);

-- game_random never returns a game with an unfinished predecessor in its
-- series. This is the pool it draws from, minus the tier filter.
SELECT id, game_name FROM custom.v_game_playable;

-- --- how long is a game in each third ----------------------------------------

SELECT * FROM custom.v_game_tier_stats WHERE tier_name = 'short';

SELECT * FROM custom.v_game_tier_stats WHERE tier_name = 'medium';

SELECT * FROM custom.v_game_tier_stats WHERE tier_name = 'long';

-- All three tiers side by side -- usually the one you actually want.
SELECT * FROM custom.v_game_tier_stats;


-- --- my play order -----------------------------------------------------------

-- The single next thing to play.
SELECT * FROM custom.v_game_next;

-- The whole ranked list.
SELECT * FROM custom.v_game_priority;

-- Still waiting for a number.
SELECT * FROM custom.v_game_unranked;

-- Assign a number. Name match is case-insensitive, exact first then substring;
-- it raises rather than guessing if the name hits more than one game.
SELECT id, game_name, priority FROM custom.game_prioritize('Yakuza 0', 1);
SELECT id, game_name, priority FROM custom.game_prioritize('Grand Theft Auto IV', 2);

-- Squeeze a game in at a spot, pushing everything below it down one.
SELECT id, game_name, priority FROM custom.game_prioritize_at('Into the Breach', 2);

-- Take a game back out of the ranking (the row stays).
SELECT id, game_name, priority FROM custom.game_unprioritize('Into the Breach');

-- Close up gaps and ties -- renumbers to a gapless 1..n, keeping order.
-- Returns only the rows it changed.
SELECT id, game_name, priority FROM custom.game_renumber();


-- --- add a game --------------------------------------------------------------

-- The three hour figures are required (they are NOT NULL on the table).
-- Do not pass hours_average -- it is a generated column, Postgres computes it
-- as round((main + extra + completionist) / 3.0, 2).
SELECT * FROM custom.game_add('b', 1, 2, 3);

-- Optional notes, and an optional starting priority.
SELECT * FROM custom.game_add('Hollow Knight', 25, 40, 60, 'metroidvania', 3);

-- Named args when you only want the later ones.
SELECT * FROM custom.game_add('Some Game', 5, 8, 12, p_priority => 1);

-- Tags and a series slot at insert time. p_series and p_series_position go
-- together -- one without the other raises.
SELECT * FROM custom.game_add('Yakuza Kiwami', 15, 30, 55,
                              p_tags => ARRAY['PC'],
                              p_series => 'Yakuza', p_series_position => 2);


-- --- tags --------------------------------------------------------------------

-- Attach tags. Creates any that do not exist yet; re-running is harmless.
SELECT * FROM custom.game_tag_add('Yakuza 0', 'PC', 'long');
SELECT * FROM custom.game_tag_add('Beat Saber', 'VR', 'PC');
SELECT * FROM custom.game_tag_add('Into the Breach', 'Handheld', 'PC');

-- Take one off (the tag itself stays, other games still use it).
SELECT * FROM custom.game_tag_remove('Yakuza 0', 'long');

-- Who has what.
SELECT * FROM custom.v_game_tags WHERE tags <> '{}';
SELECT * FROM custom.v_tag_stats;

-- Filter. game_by_tag needs ALL of them, game_by_any_tag needs one.
SELECT id, game_name FROM custom.game_by_tag('PC', 'co-op');
SELECT id, game_name FROM custom.game_by_any_tag('VR', 'Handheld');

-- Housekeeping. Matching is case-insensitive everywhere, so 'pc' and 'PC'
-- can never both exist -- but 'handheld' and 'Handhled' can.
SELECT custom.tag_rename('Handhled', 'Handheld');
SELECT * FROM custom.tag_prune();


-- --- series ------------------------------------------------------------------

-- Record a whole series in play order, in one call. Every name is resolved
-- before anything is written, so a typo aborts the lot instead of leaving
-- half a series recorded.
SELECT id, game_name, series_position
FROM custom.series_order('Yakuza', 'Yakuza 0', 'Yakuza Kiwami', 'Yakuza 2');

-- Or one at a time. Positions need not be dense: numbering 10, 20, 30 leaves
-- room to slot a prequel in later without touching the rest.
SELECT id, game_name, series_position FROM custom.game_series_set('Persona 5', 'Persona', 5);

-- Take a game back out of its series.
SELECT id, game_name FROM custom.game_series_clear('Persona 5');

-- The whole picture. is_next_in_series marks the one you may start.
SELECT * FROM custom.v_game_series;

-- Why a game never comes up in game_random(): something ahead of it is
-- unfinished. To unblock a game you will never actually play, mark the
-- blocker finished -- that is the only thing the gate looks at.
SELECT * FROM custom.v_game_blocked;

-- Where your drag-and-drop order argues with series order.
SELECT * FROM custom.v_game_priority_conflicts;

-- Series you have not recorded yet, guessed from shared leading words.
-- Crude on purpose: skim it, keep the real ones.
SELECT * FROM custom.v_game_series_candidates;


-- --- hygiene -----------------------------------------------------------------

SELECT * FROM custom.v_game_dupes;

SELECT * FROM custom.v_game_similar;

-- Loosen the fuzzy threshold for a one-off wider sweep.
SELECT g1.game_name, g2.game_name, round(similarity(g1.game_name, g2.game_name)::numeric, 3) AS score
FROM custom.game_completion_times g1
JOIN custom.game_completion_times g2 ON g1.id < g2.id
WHERE similarity(g1.game_name, g2.game_name) > 0.5
ORDER BY score DESC;


-- --- diagnostics -------------------------------------------------------------

-- Run these three together when similarity() reports "does not exist".
-- Expect: the backlog database / a path containing public / one pg_trgm row.
SELECT current_database();
SHOW search_path;
SELECT e.extname, e.extversion, n.nspname AS installed_in
FROM pg_extension e JOIN pg_namespace n ON n.oid = e.extnamespace
ORDER BY e.extname;

-- Confirm the saved objects are installed.
SELECT c.relkind, n.nspname, c.relname
FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname = 'custom' AND c.relname LIKE 'v_game%'
UNION ALL
SELECT 'f', n.nspname, p.proname
FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname = 'custom' AND p.proname LIKE 'game_%'
ORDER BY 1, 3;

-- Real column types of the table, for when you need them.
SELECT column_name, data_type, is_nullable, column_default
FROM information_schema.columns
WHERE table_schema = 'custom' AND table_name = 'game_completion_times'
ORDER BY ordinal_position;
