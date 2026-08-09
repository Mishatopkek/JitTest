-- =============================================================================
-- quick.sql -- the handful you actually run. Caret on a line, Ctrl+Enter.
--
-- Everything longer-tailed lives in db/queries.sql; the logic behind all of it
-- lives in db/install.sql, which has to have been run at least once.
--
-- Toolbar: the Postgres data source, the backlog database. See CLAUDE.local.md.
-- =============================================================================

-- Rider's schema dropdown can set search_path to "custom" alone, which hides
-- pg_trgm's similarity() and breaks anything fuzzy. Run this once per console.
SET search_path TO custom, public;

-- SELECT id, game_name, finished, notes FROM custom.game_search('Homeworld');

SELECT id, game_name, finished, notes, tags, priority, series, series_slot FROM custom.game_info('Border');
SELECT * FROM custom.game_add('Borderlands 4', 30.5, 50.5, 111
    , '');


-- --- the whole card ----------------------------------------------------------

-- Same search as game_search, with everything attached: tags, which series it
-- belongs to and where in it (series_slot of series_total), your play-order
-- position, and whether you can start it yet.
SELECT * FROM custom.game_info('Homeworld');

-- Same columns for the whole collection -- filter however you like.
SELECT * FROM custom.v_game WHERE tags @> ARRAY['Handheld'];
SELECT * FROM custom.v_game WHERE priority IS NOT NULL ORDER BY priority;
SELECT * FROM custom.v_game WHERE series IS NOT NULL ORDER BY series, series_slot;

-- Ready to start right now, best-ranked first. playable is false exactly when
-- blocked_by names the game standing in the way.
SELECT * FROM custom.v_game WHERE playable ORDER BY priority NULLS LAST, game_name;

SELECT unit_name FROM custom.v_game_tiers WHERE tier_name = 'short';
-- --- what do I play ----------------------------------------------------------

-- Roll for something. Draws from every unfinished game in the size you ask
-- for, then -- if the draw lands in the middle of a series -- hands you that
-- series' first unfinished game instead.
--
--   start_name      what to actually play
--   start_priority  where it sits in your play order (NULL = unranked)
--   start_tags      its tags
--   series          its series, with series_slot of series_total
--   drawn_name      what the dice said
--   redirected      true when those differ
--
SELECT * FROM custom.game_roll('short');
SELECT * FROM custom.game_roll('medium');
SELECT * FROM custom.game_roll('long');
SELECT * FROM custom.game_roll();

-- Same thing, restricted to games carrying ALL of these tags.
SELECT * FROM custom.game_roll('short',  ARRAY['Handheld']);
SELECT * FROM custom.game_roll('any',    ARRAY['PC']);
SELECT * FROM custom.game_roll('medium', ARRAY['Handheld', 'PC']);

-- Just the answer, no working shown.
SELECT start_name, start_hours FROM custom.game_roll('short');


-- Roll by ACTUAL HOURS instead of one of three buckets -- "I have four hours
-- tonight" rather than "give me something shortish". Bounds are inclusive and
-- NULL leaves that side open. pool_size says how many units matched before the
-- draw, so you can tell "1 of 30" from "1 of 1".
--
-- This is what the /roll page in Backlog.Web drives.
SELECT * FROM custom.game_roll_range(2, 6);        -- a two-to-six hour evening
SELECT * FROM custom.game_roll_range(NULL, 4);     -- anything under 4h
SELECT * FROM custom.game_roll_range(40, NULL);    -- something to sink into
SELECT * FROM custom.game_roll_range(2, 6, ARRAY['Handheld']);

-- No redirect here, unlike game_roll: the pool is playable units only, so the
-- range and the tags hold for the game you are actually handed.
SELECT start_name, start_hours, pool_size FROM custom.game_roll_range(2, 6);

-- Or by size instead of by hours: 1/2/3 = short/medium/long, the same thirds
-- v_game_tiers defines. The tier REPLACES the hour bounds rather than narrowing
-- them, so the bounds below are ignored.
SELECT * FROM custom.game_roll_range(NULL, NULL, NULL, 1);          -- something short
SELECT * FROM custom.game_roll_range(NULL, NULL, ARRAY['PC'], 3);   -- a long PC one
SELECT * FROM custom.game_roll_range(500, 600, NULL, 2);            -- tier wins

-- The shape of what is left: how many startable games sit in each length band.
-- One hour per band up to 200, then one open-ended 200+. Three equal thirds cannot
-- tell you whether the backlog is mostly quick hits or mostly monsters; this can.
--
-- units is the raw count for that hour; smoothed_units is a centred five-hour
-- rolling sum -- how many sit within two hours either side -- and is what the chart
-- at the top of /sizes plots. Raw 1h counts are mostly 0s and 1s at this scale.
-- The chart skips the 200+ row: it is 500h+ wide, so it would spike on width.
SELECT label, units, smoothed_units, band_hours
FROM custom.v_game_length_bands ORDER BY ord;

-- Only the hours that actually hold something -- the shape without the zeroes.
SELECT label, units, smoothed_units FROM custom.v_game_length_bands
WHERE units > 0 ORDER BY ord;

-- Sanity check after changing the band step: these two must agree, or a band is
-- double-counting or dropping games.
SELECT (SELECT sum(units) FROM custom.v_game_length_bands) AS banded,
       (SELECT count(*)   FROM custom.v_roll_pool)         AS pool;

-- The pool itself, which is what both the range roll and the tiers draw from.
SELECT unit_name, game_name AS owned_as, hours, priority, tags
FROM custom.v_roll_pool
ORDER BY hours;


-- --- what is in each size ----------------------------------------------------

-- Every playable game in every bucket, shortest first. This is the exact pool
-- game_roll and game_random draw from, so if something is not here, neither
-- can offer it.
SELECT tier, tier_name, unit_name, game_name AS owned_as, hours_average AS hours
FROM custom.v_game_tiers
ORDER BY tier, hours_average;

-- One bucket at a time.
SELECT unit_name, hours_average AS hours FROM custom.v_game_tiers
WHERE tier_name = 'short' ORDER BY hours_average;

SELECT unit_name, hours_average AS hours FROM custom.v_game_tiers
WHERE tier_name = 'medium' ORDER BY hours_average;

SELECT unit_name, hours_average AS hours FROM custom.v_game_tiers
WHERE tier_name = 'long' ORDER BY hours_average;

-- All three side by side, one row per bucket, names collapsed into a column.
SELECT tier_name,
       count(*) AS games,
       round(min(hours_average), 1) || '-' || round(max(hours_average), 1) || 'h' AS span,
       string_agg(unit_name, ', ' ORDER BY hours_average) AS games_list
FROM custom.v_game_tiers
GROUP BY tier, tier_name
ORDER BY tier;

-- The buckets are NTILE(3): three equal-sized thirds, not fixed hour cutoffs.
-- So "long" means "longest third of what you can start", and the boundaries
-- move as you finish things. v_game_tier_stats shows where they currently cut.
SELECT * FROM custom.v_game_tier_stats;

-- Only what you can start, with its size, best-ranked first.
SELECT t.tier_name, t.unit_name, t.hours_average AS hours, u.priority
FROM custom.v_game_tiers t
JOIN custom.v_unit u ON u.game_id = t.game_id
                    AND u.part_id IS NOT DISTINCT FROM t.part_id
ORDER BY u.priority NULLS LAST;


-- --- the two rolls, and when to use which ------------------------------------
--
-- game_roll  REDIRECTS. Draws from everything, sends you to the head of the
--            series when it lands mid-chain.
-- game_random EXCLUDES. Mid-series games are never in the pool at all.
--
-- Two consequences worth knowing before you pick one:
--
--  1. Weighting. To game_random, a six-game series is one entry. To game_roll
--     it is six, so long series come up six times as often -- fair, if you
--     think of them as six games you still have to get through.
--
--  2. The size and tag filters apply to the DRAW, not to what you end up with.
--     Roll 'long', land on Yakuza 5, get sent to Yakuza 0 -- which may be a
--     medium. Ask for ARRAY['VR'] and the entry that matched VR is not
--     necessarily the one you are told to start.
--
-- So: game_roll when the series matters more than the filter, game_random when
-- the filter has to hold for the game you actually play.

SELECT id, game_name FROM custom.game_random('short');
SELECT id, game_name FROM custom.game_random('any', ARRAY['VR']);

-- Neither can offer a game with no recorded hours -- the tiering drops them.
-- This says how many that is.
SELECT missing_hours FROM custom.v_game_stats;


-- --- finishing ---------------------------------------------------------------

-- Marking something finished is the only thing that unblocks what comes after
-- it, in a series or inside a collection.
SELECT id, game_name, finished FROM custom.game_finish('Alan Wake');
SELECT id, game_name, finished FROM custom.game_finish('Alan Wake', false);

-- One game inside a collection. Exact name first, then substring -- so
-- 'Mass Effect' means part 1, not all three parts containing that text.
SELECT * FROM custom.part_finish('Mass Effect Legendary Edition', 'Mass Effect');
SELECT * FROM custom.part_finish('Mass Effect Legendary Edition', 'Mass Effect 2', false);


-- --- splitting a collection --------------------------------------------------

-- One purchase, several games. The row stays one row -- the games inside it
-- live in custom.game_part -- so the table never claims you bought three
-- things. The roll and the blocking both work on the parts.
SELECT * FROM custom.game_split('Mass Effect Legendary Edition',
                                'Mass Effect', 'Mass Effect 2', 'Mass Effect 3');

SELECT * FROM custom.game_split('Phoenix Wright: Ace Attorney Trilogy',
                                'Phoenix Wright: Ace Attorney',
                                'Justice for All',
                                'Trials and Tribulations');

-- Re-running replaces the list but keeps progress: parts that survive by name
-- keep their finished flag. Undo entirely with game_unsplit.
SELECT custom.game_unsplit('Mass Effect Legendary Edition');

-- A collection and a standalone sequel in one chain: parts first, then the
-- separate purchase. series_order works on rows; the parts come along.
SELECT custom.series_order('Mass Effect',
                           'Mass Effect Legendary Edition', 'Mass Effect Andromeda');

-- Every playable unit, with what is standing in front of it.
SELECT * FROM custom.v_unit ORDER BY series, series_position, part_position;

-- Only the things you can actually start right now.
SELECT unit_name, game_name, hours FROM custom.v_unit WHERE playable ORDER BY unit_name;

-- Why something never comes up.
SELECT * FROM custom.v_game_blocked;


-- --- the ranked list ---------------------------------------------------------

-- The single next thing, by your hand-ranking, series-blocked games skipped.
SELECT * FROM custom.v_game_next;

-- The whole ranked list.
SELECT * FROM custom.v_game_priority;
