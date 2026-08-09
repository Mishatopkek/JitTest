-- =============================================================================
-- custom.game_completion_times -- saved views & functions
--
-- Target: PostgreSQL 16, schema "custom". Host and database are in
-- CLAUDE.local.md, which is not committed.
-- Idempotent: safe to re-run after any edit. Creates nothing but views and
-- functions (all prefixed v_game_ / game_), so it cannot touch your data.
--
-- Run in Rider: open this file, pick the Postgres data source and the backlog
-- database in the toolbar, then Execute (Ctrl+Enter with nothing selected
-- runs the whole script).
-- =============================================================================


-- -----------------------------------------------------------------------------
-- 0. Session setup
-- -----------------------------------------------------------------------------

-- Rider derives search_path from the schema dropdown. Picking "custom" drops
-- "public", which hides pg_trgm's similarity() and produces:
--     ERROR: function similarity(character varying, character varying)
--            does not exist
-- Pinning both schemas here makes the script resolve regardless of the dropdown.
SET search_path TO custom, public;

-- Extensions are per-database, and the data source's jdbc-url defaults to
-- database "postgres" while the table lives in the backlog database.
-- Installing pg_trgm while connected to the wrong database is the other way
-- similarity() goes missing. Fail loudly instead of building half the script
-- against nothing.
--
-- Probing for the table beats comparing current_database() to a hardcoded
-- name: it tests the precondition that actually matters -- can this script see
-- the table it is about to build on -- and it keeps the database name out of a
-- committed file.
DO $$
BEGIN
    IF to_regclass('custom.game_completion_times') IS NULL THEN
        RAISE EXCEPTION
            'Wrong database: connected to "%", which has no '
            'custom.game_completion_times. Change the database dropdown in '
            'the Rider toolbar.', current_database();
    END IF;
END;
$$;


-- -----------------------------------------------------------------------------
-- 1. Extensions and indexes (one-time setup)
-- -----------------------------------------------------------------------------

-- Trigram matching, used by v_game_similar and by ILIKE search acceleration.
-- Pinned to public so the schema is predictable no matter what search_path
-- looked like the first time this ran. No-op if already installed elsewhere.
CREATE EXTENSION IF NOT EXISTS pg_trgm SCHEMA public;

-- Makes both `game_name ILIKE '%foo%'` and similarity() able to use an index
-- instead of scanning every row.
CREATE INDEX IF NOT EXISTS game_completion_times_name_trgm_idx
    ON custom.game_completion_times
    USING gin (game_name gin_trgm_ops);


-- -----------------------------------------------------------------------------
-- 1b. Manual play-order column
--
-- priority = your own ranking. 1 is next up, 2 after that, and so on.
-- NULL means unranked, which is the default for all 176 existing rows.
--
-- Deliberately NOT unique. A unique constraint would force you to renumber
-- every game below an insertion point before the insert could commit, which
-- makes "put this at 3" a multi-statement chore. Ties are legal instead, and
-- custom.game_renumber() compacts them away when you want a clean 1..n.
-- -----------------------------------------------------------------------------

ALTER TABLE custom.game_completion_times
    ADD COLUMN IF NOT EXISTS priority integer;

ALTER TABLE custom.game_completion_times
    DROP CONSTRAINT IF EXISTS game_completion_times_priority_positive;
ALTER TABLE custom.game_completion_times
    ADD CONSTRAINT game_completion_times_priority_positive
        CHECK (priority IS NULL OR priority > 0);

-- Partial: only ranked rows are indexed, so it stays small while the backlog
-- is mostly unranked.
CREATE INDEX IF NOT EXISTS game_completion_times_priority_idx
    ON custom.game_completion_times (priority)
    WHERE priority IS NOT NULL;


-- -----------------------------------------------------------------------------
-- 1c. Tags
--
-- A game has many tags and a tag has many games ("PC", "VR", "Handheld",
-- "co-op", "backlog-2026"), so this is a proper link table rather than a
-- text[] column. The cost is one extra join; the benefit is that renaming a
-- tag is one UPDATE and a typo shows up as a new row in v_tag_stats instead
-- of hiding inside 176 arrays.
--
-- The tables are named custom.tag / custom.game_tag_link, not custom.game_tag,
-- because a table also defines a composite type -- and a table named game_tag
-- would make the expression game_tag(x) ambiguous between a function call and
-- field selection.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS custom.tag (
    id       serial PRIMARY KEY,
    tag_name varchar(64) NOT NULL
);

-- Case-insensitive uniqueness: "PC" and "pc" must not both exist. Stored as
-- typed, so the display casing you first used is the casing you keep.
CREATE UNIQUE INDEX IF NOT EXISTS tag_name_lower_uidx
    ON custom.tag (lower(tag_name));

CREATE TABLE IF NOT EXISTS custom.game_tag_link (
    game_id int NOT NULL REFERENCES custom.game_completion_times (id) ON DELETE CASCADE,
    tag_id  int NOT NULL REFERENCES custom.tag (id) ON DELETE CASCADE,
    PRIMARY KEY (game_id, tag_id)
);

-- The PK already covers game_id -> tags. This covers tags -> games, which is
-- what "everything tagged VR" needs.
CREATE INDEX IF NOT EXISTS game_tag_link_tag_idx
    ON custom.game_tag_link (tag_id);


-- -----------------------------------------------------------------------------
-- 1d. Series
--
-- A game belongs to at most one series, so this is two columns on the table
-- rather than another link table. series_position is the order you should play
-- them in: 1, 2, 3.
--
-- The point of this is custom.v_game_playable below -- it hides any entry that
-- still has an unfinished predecessor, so game_random() can never hand you the
-- middle of a trilogy.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS custom.series (
    id          serial PRIMARY KEY,
    series_name varchar(128) NOT NULL
);

CREATE UNIQUE INDEX IF NOT EXISTS series_name_lower_uidx
    ON custom.series (lower(series_name));

ALTER TABLE custom.game_completion_times
    ADD COLUMN IF NOT EXISTS series_id       integer,
    ADD COLUMN IF NOT EXISTS series_position integer;

-- Deliberately NO ON DELETE SET NULL. Clearing series_id alone would leave a
-- stale series_position behind and violate the check below, so deleting a
-- series that still has games fails loudly instead. Detach them first with
-- custom.game_series_clear().
ALTER TABLE custom.game_completion_times
    DROP CONSTRAINT IF EXISTS game_completion_times_series_fk;
ALTER TABLE custom.game_completion_times
    ADD CONSTRAINT game_completion_times_series_fk
        FOREIGN KEY (series_id) REFERENCES custom.series (id);

-- Both columns or neither. A series_id without a position has no place in the
-- ordering and would be silently unplayable-gating nothing.
ALTER TABLE custom.game_completion_times
    DROP CONSTRAINT IF EXISTS game_completion_times_series_complete;
ALTER TABLE custom.game_completion_times
    ADD CONSTRAINT game_completion_times_series_complete
        CHECK ((series_id IS NULL AND series_position IS NULL)
            OR (series_id IS NOT NULL AND series_position IS NOT NULL
                AND series_position > 0));

-- Positions are NOT unique, for the same reason priorities are not: inserting
-- a prequel at position 1 would otherwise fail until you had renumbered the
-- rest by hand. A tie just means both entries unblock at the same time, which
-- is the right answer for things like "Soul Reaver 1 & 2 Remastered".
CREATE INDEX IF NOT EXISTS game_completion_times_series_idx
    ON custom.game_completion_times (series_id, series_position)
    WHERE series_id IS NOT NULL;


-- -----------------------------------------------------------------------------
-- 1e. Splitting: the games inside a game
--
-- Mass Effect Legendary Edition is one purchase and three games. Adding three
-- rows would be a lie about what you own; keeping one row means you cannot
-- finish ME1 and have ME2 come up next. So the collection stays exactly one row
-- in game_completion_times, and the games inside it live here.
--
-- A game with no parts is one playable unit. A game with N parts is N units.
-- Everything downstream -- blocking, rolling, tiering -- works on units, so a
-- split collection behaves like a series without pretending to be several
-- purchases. See custom.v_game_unit.
--
-- part_position is NOT unique, for the same reason priority and series_position
-- are not: rewriting the list in one statement would otherwise trip a unique
-- index halfway through. custom.game_split() always writes a dense 1..n.
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS custom.game_part (
    id            serial PRIMARY KEY,
    game_id       int NOT NULL REFERENCES custom.game_completion_times (id) ON DELETE CASCADE,
    part_position int NOT NULL CHECK (part_position > 0),
    part_name     varchar(128) NOT NULL,
    -- NULL means "share the parent's hours evenly", computed in v_game_unit.
    -- Set it only when you actually know a part's length.
    hours         numeric,
    finished      boolean NOT NULL DEFAULT false
);

CREATE INDEX IF NOT EXISTS game_part_game_idx
    ON custom.game_part (game_id, part_position);


-- -----------------------------------------------------------------------------
-- 2. Views (no arguments -- just SELECT from them)
--
-- v_game_unit and v_unit come first: almost everything below is defined in
-- terms of them, and a view cannot be created before what it reads.
-- -----------------------------------------------------------------------------

-- One row per PLAYABLE UNIT. A game with no parts is itself one unit; a game
-- with parts contributes one unit per part and does not appear itself.
--
-- This is the grain the rest of the file works at, and the reason splitting a
-- collection does not require lying about what you own.
--
-- A part with no hours of its own gets an even share of the parent's. Rough,
-- but better than NULL, which would drop it out of the tiers entirely. Set
-- game_part.hours when you know better.
DROP VIEW IF EXISTS custom.v_game_unit CASCADE;
CREATE VIEW custom.v_game_unit AS
SELECT g.id                AS game_id,
       NULL::int           AS part_id,
       g.game_name::text   AS unit_name,
       g.game_name::text   AS game_name,
       false               AS is_part,
       g.finished,
       g.hours_average     AS hours,
       g.series_id,
       g.series_position,
       0                   AS part_position,
       g.priority
FROM custom.game_completion_times g
WHERE NOT EXISTS (SELECT 1 FROM custom.game_part p WHERE p.game_id = g.id)
UNION ALL
SELECT g.id,
       p.id,
       p.part_name::text,
       g.game_name::text,
       true,
       p.finished,
       coalesce(p.hours, round(g.hours_average / cnt.n, 2)),
       g.series_id,
       g.series_position,
       p.part_position,
       g.priority
FROM custom.game_completion_times g
JOIN custom.game_part p ON p.game_id = g.id
CROSS JOIN LATERAL (
    SELECT count(*) AS n FROM custom.game_part q WHERE q.game_id = g.id
) cnt;


-- The same units, plus what is standing in front of each one.
--
-- A unit is blocked by any earlier unfinished unit, where "earlier" means:
--   * inside the same collection, a lower part_position -- so ME2 waits for
--     ME1 even when the collection is in no series at all; or
--   * inside the same series, a lower (series_position, part_position) -- so
--     the ordering runs straight through collections and standalone games
--     alike. Mass Effect 1, 2, 3, then Andromeda.
--
-- The row comparison (a, b) < (c, d) is lexicographic, which is exactly the
-- "series slot first, then part" ordering wanted here.
DROP VIEW IF EXISTS custom.v_unit CASCADE;
CREATE VIEW custom.v_unit AS
SELECT u.*,
       s.series_name::text AS series,
       blocker.unit_name   AS blocked_by,
       (u.finished = false AND blocker.unit_name IS NULL) AS playable
FROM custom.v_game_unit u
LEFT JOIN custom.series s ON s.id = u.series_id
LEFT JOIN LATERAL (
    SELECT e.unit_name
    FROM custom.v_game_unit e
    WHERE e.finished = false
      AND (
            (u.series_id IS NOT NULL
             AND e.series_id = u.series_id
             AND (e.series_position, e.part_position) < (u.series_position, u.part_position))
         OR (e.game_id = u.game_id AND e.part_position < u.part_position)
          )
    ORDER BY e.series_position, e.part_position
    LIMIT 1
) blocker ON true;

-- Everything, longest first. NULL length sorts last rather than first.
DROP VIEW IF EXISTS custom.v_game_by_length;
CREATE VIEW custom.v_game_by_length AS
SELECT id,
       game_name,
       hours_average,
       finished
FROM custom.game_completion_times
ORDER BY hours_average DESC NULLS LAST;


-- One-row summary of the whole collection.
DROP VIEW IF EXISTS custom.v_game_stats;
CREATE VIEW custom.v_game_stats AS
SELECT count(*)                                                        AS games,
       count(*) FILTER (WHERE finished)                                AS finished,
       count(*) FILTER (WHERE NOT finished)                            AS backlog,
       count(*) FILTER (WHERE hours_average IS NULL)                   AS missing_hours,
       round(avg(hours_average)::numeric, 2)                           AS avg_hours,
       round(min(hours_average)::numeric, 2)                           AS min_hours,
       round(max(hours_average)::numeric, 2)                           AS max_hours,
       round(sum(hours_average) FILTER (WHERE NOT finished)::numeric, 1)
                                                                       AS backlog_hours
FROM custom.game_completion_times;


-- Unfinished games split into three equal-sized length buckets.
-- This is the view custom.game_random() draws from -- query it directly when
-- you want to see the whole tier instead of one random pick.
--
-- Rows with hours_average IS NULL are excluded: NTILE sorts NULLs last, which
-- would silently file every unmeasured game under "long". Drop the IS NOT NULL
-- if you would rather see them.
--
-- Tiering is over UNITS, not rows: a split collection is three medium games,
-- not one long one, and that is what you actually sit down to play. It is also
-- restricted to playable units, so a game you cannot start yet does not shift
-- the boundaries of a bucket you are choosing from.
--
-- THE rollable pool: every unit you could sit down and start right now, with
-- its tags attached. One definition, because three different things draw from
-- it -- v_game_tiers below, game_roll_range(), and the live count on /roll --
-- and they must not disagree about what is eligible.
--
-- "playable" already means unfinished AND not blocked by an earlier unit in its
-- collection or series, so a mid-series game cannot appear here at all. That is
-- what lets game_roll_range() skip the series redirect that game_roll() does:
-- there is nothing to redirect away from. See the note on that function.
--
-- hours IS NOT NULL is required by every consumer: NTILE would file unmeasured
-- games under "long", and an hours range cannot say anything about a game whose
-- length is unknown. v_game_stats.missing_hours counts what this drops.
DROP VIEW IF EXISTS custom.v_roll_pool CASCADE;
CREATE VIEW custom.v_roll_pool AS
SELECT u.game_id,
       u.part_id,
       u.unit_name,
       u.game_name,
       u.hours,
       u.priority,
       u.series,
       u.series_id,
       u.series_position,
       coalesce(tg.tags, '{}'::text[]) AS tags
FROM custom.v_unit u
LEFT JOIN LATERAL (
    SELECT array_agg(t.tag_name::text ORDER BY t.tag_name) AS tags
    FROM custom.game_tag_link l
    JOIN custom.tag t ON t.id = l.tag_id
    WHERE l.game_id = u.game_id
) tg ON true
WHERE u.playable
  AND u.hours IS NOT NULL;

COMMENT ON VIEW custom.v_roll_pool IS
    'Units you can start right now, with tags. The single definition of the '
    'pool that v_game_tiers, game_roll_range() and the /roll count all use.';


-- v_game_tier_stats is built on this view, so it must be dropped first --
-- a bare DROP VIEW fails while a dependent view exists.
--
-- Built on v_roll_pool rather than restating its WHERE clause, so the tiers can
-- never bucket a different set of games than the roll draws from. Column list
-- is unchanged: game_random(), game_roll() and the app all join to it.
DROP VIEW IF EXISTS custom.v_game_tier_stats;
DROP VIEW IF EXISTS custom.v_game_tiers CASCADE;
CREATE VIEW custom.v_game_tiers AS
SELECT game_id AS id,          -- kept so old queries joining on id still work
       game_id,
       part_id,
       unit_name,
       game_name,
       hours AS hours_average,
       NTILE(3) OVER (ORDER BY hours) AS tier,
       CASE NTILE(3) OVER (ORDER BY hours)
           WHEN 1 THEN 'short'
           WHEN 2 THEN 'medium'
           ELSE        'long'
       END                            AS tier_name
FROM custom.v_roll_pool;


-- Your hand-ranked play order, best first.
DROP VIEW IF EXISTS custom.v_game_priority;
CREATE VIEW custom.v_game_priority AS
SELECT priority,
       id,
       game_name,
       hours_average,
       finished,
       notes
FROM custom.game_completion_times
WHERE priority IS NOT NULL
ORDER BY priority, game_name;


-- The single next thing to play: lowest priority number, not yet finished,
-- and not blocked by an earlier unfinished game in its own series.
--
-- Defined further down (section 2b) because it reads from v_game_playable.


-- Unfinished and unranked -- the pile still waiting for a number.
DROP VIEW IF EXISTS custom.v_game_unranked;
CREATE VIEW custom.v_game_unranked AS
SELECT id,
       game_name,
       hours_average
FROM custom.game_completion_times
WHERE priority IS NULL
  AND finished = false
ORDER BY game_name;


-- One row per length tier: how big the bucket is and what it averages.
-- min_hours/max_hours are the tier's actual boundaries, so reading three rows
-- tells you where NTILE decided to cut.
--
-- Averages are pulled toward outliers -- one 200-hour RPG drags the whole
-- "long" average up. median_hours is the same number an outlier cannot move.
DROP VIEW IF EXISTS custom.v_game_tier_stats;
CREATE VIEW custom.v_game_tier_stats AS
SELECT tier,
       tier_name,
       count(*)                                                             AS games,
       round(avg(hours_average)::numeric, 2)                                AS avg_hours,
       round((percentile_cont(0.5) WITHIN GROUP (ORDER BY hours_average))::numeric, 2)
                                                                            AS median_hours,
       round(min(hours_average)::numeric, 2)                                AS min_hours,
       round(max(hours_average)::numeric, 2)                                AS max_hours,
       round(sum(hours_average)::numeric, 1)                                AS total_hours
FROM custom.v_game_tiers
GROUP BY tier, tier_name
ORDER BY tier;


-- The shape of what is left to play: how many startable games sit in each length
-- band. Where v_game_tier_stats answers "where did NTILE cut", this answers "is
-- the backlog mostly quick hits or mostly monsters", which the three equal
-- thirds structurally cannot show -- thirds are always a third each.
--
-- Bands are half-open, [lo, hi), so nothing is counted twice and a game sitting
-- exactly on a boundary lands in the upper band. The top band is open-ended
-- because the pool reaches 718 hours.
--
-- Bands are deliberately uneven, narrow where the games are: 90% of the pool is
-- under 60h with a median near 18h, so even 70-hour-wide bands would put almost
-- everything in the first bar and say nothing.
--
-- LEFT JOIN, not an inner one: an empty band must still return its row. Dropping
-- it would close the gap on the chart's x-axis and misdescribe the distribution.
DROP VIEW IF EXISTS custom.v_game_length_bands;
CREATE VIEW custom.v_game_length_bands AS
WITH band (ord, label, lo, hi) AS (
    VALUES ( 1, '0–2',    0::numeric,  2::numeric),
           ( 2, '2–4',    2,           4),
           ( 3, '4–6',    4,           6),
           ( 4, '6–10',   6,          10),
           ( 5, '10–15', 10,          15),
           ( 6, '15–20', 15,          20),
           ( 7, '20–30', 20,          30),
           ( 8, '30–40', 30,          40),
           ( 9, '40–60', 40,          60),
           (10, '60+',   60,          NULL)
)
SELECT b.ord,
       b.label,
       b.lo                                              AS from_hours,
       b.hi                                              AS to_hours,
       count(r.game_id)                                  AS units,
       round(coalesce(sum(r.hours), 0)::numeric, 1)      AS band_hours
FROM band b
LEFT JOIN custom.v_roll_pool r
       ON r.hours >= b.lo
      AND (b.hi IS NULL OR r.hours < b.hi)
GROUP BY b.ord, b.label, b.lo, b.hi
ORDER BY b.ord;

COMMENT ON VIEW custom.v_game_length_bands IS
    'Distribution of the startable pool across length bands -- the shape of the '
    'backlog. Half-open bands, empty ones included, top band open-ended.';


-- Exact duplicates: same name once punctuation, spacing and case are stripped.
--
-- NOTE: your original ran regexp_replace(game_name, '[^a-z0-9]', ...) BEFORE
-- lower(). Regex classes are case-sensitive, so every capital letter matched
-- the negated class and was deleted -- 'Mass Effect' normalized to 'asffect'.
-- Order is swapped here: lower() first, then strip.
DROP VIEW IF EXISTS custom.v_game_dupes;
CREATE VIEW custom.v_game_dupes AS
SELECT regexp_replace(lower(game_name), '[^a-z0-9]', '', 'g') AS normalized_name,
       count(*)                                               AS copies,
       array_agg(id ORDER BY id)                              AS ids,
       array_agg(game_name ORDER BY game_name)                AS names
FROM custom.game_completion_times
GROUP BY 1
HAVING count(*) > 1
ORDER BY copies DESC, normalized_name;


-- Fuzzy near-duplicates: typos, subtitles, "II" vs "2".
-- g1.id < g2.id gives each pair once and never pairs a row with itself.
DROP VIEW IF EXISTS custom.v_game_similar;
CREATE VIEW custom.v_game_similar AS
SELECT g1.id                        AS id_a,
       g1.game_name                 AS name_a,
       g2.id                        AS id_b,
       g2.game_name                 AS name_b,
       round(sim.score::numeric, 3) AS score
FROM custom.game_completion_times g1
JOIN custom.game_completion_times g2
     ON g1.id < g2.id
CROSS JOIN LATERAL (
    SELECT similarity(g1.game_name, g2.game_name) AS score
) sim
WHERE sim.score > 0.7
ORDER BY sim.score DESC;


-- -----------------------------------------------------------------------------
-- 2b. Tag and series views
-- -----------------------------------------------------------------------------

-- Every game with its tags collapsed into one array column.
-- LEFT JOIN plus the FILTER keeps untagged games in the result with '{}'
-- rather than {NULL}, which is what a bare array_agg would produce.
DROP VIEW IF EXISTS custom.v_game_tags;
CREATE VIEW custom.v_game_tags AS
SELECT g.id,
       g.game_name,
       g.finished,
       g.priority,
       coalesce(
           array_agg(t.tag_name::text ORDER BY t.tag_name) FILTER (WHERE t.id IS NOT NULL),
           '{}'::text[]
       ) AS tags
FROM custom.game_completion_times g
LEFT JOIN custom.game_tag_link l ON l.game_id = g.id
LEFT JOIN custom.tag t          ON t.id = l.tag_id
GROUP BY g.id, g.game_name, g.finished, g.priority;


-- One row per tag: how many games carry it, and how much play time it adds up
-- to. Read this after a tagging session -- a tag with exactly one game is
-- usually a typo of a tag with forty.
DROP VIEW IF EXISTS custom.v_tag_stats;
CREATE VIEW custom.v_tag_stats AS
SELECT t.id,
       t.tag_name,
       count(l.game_id)                                     AS games,
       count(l.game_id) FILTER (WHERE g.finished)           AS finished,
       count(l.game_id) FILTER (WHERE NOT g.finished)       AS backlog,
       round(sum(g.hours_average) FILTER (WHERE NOT g.finished)::numeric, 1)
                                                            AS backlog_hours
FROM custom.tag t
LEFT JOIN custom.game_tag_link l           ON l.tag_id  = t.id
LEFT JOIN custom.game_completion_times g   ON g.id      = l.game_id
GROUP BY t.id, t.tag_name
ORDER BY count(l.game_id) DESC, t.tag_name;


-- Every series laid out in play order.
--
-- is_next_in_series marks the earliest unfinished entry -- the one you are
-- allowed to start. The window aggregate computes "lowest unfinished position
-- in this series" for every row at once, which is cheaper than a correlated
-- subquery per row. It is NULL for a series you have finished completely.
DROP VIEW IF EXISTS custom.v_game_series;
CREATE VIEW custom.v_game_series AS
SELECT s.series_name,
       g.series_position,
       g.id,
       g.game_name,
       g.hours_average,
       g.finished,
       g.priority,
       g.series_position = min(g.series_position) FILTER (WHERE NOT g.finished)
                               OVER (PARTITION BY g.series_id) AS is_next_in_series
FROM custom.game_completion_times g
JOIN custom.series s ON s.id = g.series_id
ORDER BY s.series_name, g.series_position;


-- The backlog you are actually allowed to start right now.
--
-- A game qualifies when it is unfinished AND either has no series, or has no
-- unfinished predecessor inside its series. This is the view that stops a
-- random pick from landing on Yakuza 3 while 0, Kiwami and 2 sit unplayed.
--
-- Note what does NOT gate: priority, tags, missing hours. Only the series
-- chain. Everything else is a filter you apply on top.
--
-- SELECT g.* keeps the row type identical to the table, so the functions that
-- return SETOF custom.game_completion_times can read from this view directly.
--
-- v_game_next is built on this view, so it has to go first -- a bare DROP VIEW
-- fails while a dependent view exists. It is recreated at the end of this
-- section.
DROP VIEW IF EXISTS custom.v_game_next;
DROP VIEW IF EXISTS custom.v_game_playable;
CREATE VIEW custom.v_game_playable AS
SELECT g.*
FROM custom.game_completion_times g
WHERE EXISTS (SELECT 1 FROM custom.v_unit u WHERE u.game_id = g.id AND u.playable);


-- The mirror image: unfinished games held back by an earlier entry, and which
-- entry is holding them. Check here when a game you expected never comes up
-- in game_random().
--
-- If the blocker is something you will never play, mark it finished -- that is
-- the intended escape hatch, and it is why finished is the only thing the
-- gate looks at.
-- Over units, so it catches part 2 of a collection waiting on part 1 as well
-- as game 3 of a series waiting on game 1. "chain" is the series when there is
-- one, else the collection the parts belong to.
DROP VIEW IF EXISTS custom.v_game_blocked;
CREATE VIEW custom.v_game_blocked AS
SELECT coalesce(u.series, u.game_name) AS chain,
       u.game_id,
       u.unit_name,
       u.series_position,
       u.part_position,
       u.blocked_by,
       u.game_name AS owned_as
FROM custom.v_unit u
WHERE u.finished = false
  AND u.blocked_by IS NOT NULL
ORDER BY chain, u.series_position, u.part_position;


-- Hand-ranked order that contradicts series order: a game you ranked to play
-- before something that has to come first.
--
-- The drag-and-drop UI will happily let you build this, because dragging is
-- about what you want next and the series chain is about what makes sense.
-- This view is where the disagreement shows up.
DROP VIEW IF EXISTS custom.v_game_priority_conflicts;
CREATE VIEW custom.v_game_priority_conflicts AS
SELECT s.series_name,
       g.priority          AS ranked_priority,
       g.id                AS ranked_id,
       g.game_name         AS ranked_name,
       g.series_position   AS ranked_position,
       e.priority          AS blocker_priority,
       e.id                AS blocker_id,
       e.game_name         AS blocker_name,
       e.series_position   AS blocker_position
FROM custom.game_completion_times g
JOIN custom.series s                    ON s.id = g.series_id
JOIN custom.game_completion_times e     ON e.series_id       = g.series_id
                                       AND e.finished        = false
                                       AND e.series_position < g.series_position
WHERE g.priority IS NOT NULL
  AND g.finished = false
  AND (e.priority IS NULL OR e.priority > g.priority)
ORDER BY g.priority;


-- Guesses at series you have not recorded yet, by shared leading word.
--
-- Crude on purpose: it strips a leading article, takes the first word, and
-- reports words shared by more than one unassigned game. It will offer you
-- nonsense pairs ("Little Nightmares" / "Little Gator") alongside real ones.
-- Treat it as a worklist to skim, not an answer -- then record the real ones
-- with custom.game_series_set().
DROP VIEW IF EXISTS custom.v_game_series_candidates;
CREATE VIEW custom.v_game_series_candidates AS
WITH lead_words AS (
    SELECT g.id,
           g.game_name,
           split_part(
               regexp_replace(
                   lower(regexp_replace(g.game_name, '^(the|a|an)\s+', '', 'i')),
                   '[^a-z0-9 ]', '', 'g'),
               ' ', 1) AS lead_word
    FROM custom.game_completion_times g
    WHERE g.series_id IS NULL
)
SELECT lead_word,
       count(*)                                  AS games,
       array_agg(id ORDER BY game_name)          AS ids,
       array_agg(game_name ORDER BY game_name)   AS names
FROM lead_words
WHERE lead_word <> ''
GROUP BY lead_word
HAVING count(*) > 1
ORDER BY count(*) DESC, lead_word;


-- The single next thing to play: lowest priority number, unfinished, and not
-- blocked by an earlier unfinished game in its series.
--
-- Behaviour change: this used to read the table directly, so it could name a
-- mid-series game. It now reads v_game_playable.
DROP VIEW IF EXISTS custom.v_game_next;
CREATE VIEW custom.v_game_next AS
SELECT u.priority,
       u.game_id   AS id,
       u.unit_name AS game_name,   -- the part, when the game is split
       u.game_name AS owned_as,    -- the row you actually own
       u.hours     AS hours_average
FROM custom.v_unit u
WHERE u.playable
  AND u.priority IS NOT NULL
ORDER BY u.priority, u.series_position, u.part_position, u.unit_name
LIMIT 1;


-- One row per game with everything about it in one place: tags, where it sits
-- in its series, where it sits in your play order, and whether you can start
-- it. This is the view to SELECT from when you want to look at a game rather
-- than compute over the collection.
--
--     SELECT * FROM custom.v_game WHERE game_name ILIKE '%yakuza%';
--     SELECT * FROM custom.v_game WHERE priority IS NOT NULL ORDER BY priority;
--     SELECT * FROM custom.v_game WHERE tags @> ARRAY['VR'];
--
-- Three LATERAL joins instead of one GROUP BY. The tag aggregate is the reason:
-- grouping the whole row by nine columns to collect an array is both slower and
-- fragile when a column is added, whereas a lateral aggregate over the link
-- table touches only the rows for this game.
--
-- series_total counts every entry in the series, finished included -- "#2 of 5"
-- is only useful if the 5 means the whole thing.
DROP VIEW IF EXISTS custom.v_game;
CREATE VIEW custom.v_game AS
SELECT g.id,
       g.game_name,
       g.hours_average,
       -- A split game's finished state is the roll-up of its parts. The stored
       -- flag is kept in step by game_finish/part_finish, but the parts are the
       -- source of truth, so derive rather than trust.
       CASE WHEN parts.n > 0 THEN parts.n = parts.done ELSE g.finished END AS finished,
       parts.n    AS parts,
       parts.done AS parts_finished,
       g.priority,
       s.series_name::text AS series,
       g.series_position   AS series_slot,
       total.games         AS series_total,
       -- Only a game with nothing startable counts as blocked. A split game
       -- whose part 1 is available is playable even though parts 2 and 3 are
       -- not -- reporting their blocker here would call it blocked when it is
       -- exactly the thing you should go and play.
       CASE WHEN u.playable_units = 0 THEN u.first_blocker END AS blocked_by,
       u.next_up,
       (u.playable_units > 0)              AS playable,
       coalesce(tagged.tags, '{}'::text[]) AS tags,
       g.notes
FROM custom.game_completion_times g
LEFT JOIN custom.series s ON s.id = g.series_id
CROSS JOIN LATERAL (
    SELECT count(*) AS n, count(*) FILTER (WHERE p.finished) AS done
    FROM custom.game_part p WHERE p.game_id = g.id
) parts
CROSS JOIN LATERAL (
    SELECT count(*) FILTER (WHERE x.playable) AS playable_units,
           (array_agg(x.unit_name ORDER BY x.part_position)
                FILTER (WHERE x.playable))[1]     AS next_up,
           (array_agg(x.blocked_by ORDER BY x.part_position)
                FILTER (WHERE NOT x.finished))[1] AS first_blocker
    FROM custom.v_unit x WHERE x.game_id = g.id
) u
-- ON g.series_id IS NOT NULL, so a game in no series gets NULL rather than a
-- meaningless series_total of 0.
LEFT JOIN LATERAL (
    SELECT count(*) AS games
    FROM custom.game_completion_times c
    WHERE c.series_id = g.series_id
) total ON g.series_id IS NOT NULL
LEFT JOIN LATERAL (
    SELECT array_agg(t.tag_name::text ORDER BY t.tag_name) AS tags
    FROM custom.game_tag_link l
    JOIN custom.tag t ON t.id = l.tag_id
    WHERE l.game_id = g.id
) tagged ON true;


-- -----------------------------------------------------------------------------
-- 3. Functions (take arguments)
--
-- All return SETOF custom.game_completion_times, i.e. a full table row. That
-- means no column types are declared anywhere, so adding or retyping a column
-- on the table never breaks these -- and you still pick the columns you want
-- at the call site:
--     SELECT id, game_name FROM custom.game_search('mass');
-- -----------------------------------------------------------------------------

-- Substring search on name, case-insensitive.
--     SELECT id, game_name, finished, notes FROM custom.game_search('a');
CREATE OR REPLACE FUNCTION custom.game_search(q text)
    RETURNS SETOF custom.game_completion_times
    LANGUAGE sql
    STABLE
AS $$
    SELECT g.*
    FROM custom.game_completion_times g
    WHERE g.game_name ILIKE '%' || q || '%'
    ORDER BY g.game_name;
$$;

COMMENT ON FUNCTION custom.game_search(text) IS
    'Case-insensitive substring search on game_name.';


-- The same search, but returning the full card: tags, series slot, play-order
-- position, and whether the game is startable.
--     SELECT * FROM custom.game_info('yakuza');
--
-- game_search() is left alone rather than widened, because it returns SETOF the
-- table -- no column types declared, so it survives any change to the table.
-- This one has to name its columns, so it is a second function instead of a
-- breaking change to the first.
CREATE OR REPLACE FUNCTION custom.game_info(q text)
    RETURNS TABLE (
        id           int,
        game_name    text,
        finished     boolean,
        priority     int,
        tags         text[],
        series       text,
        series_slot  int,
        series_total bigint,
        blocked_by   text,
        playable     boolean,
        hours        numeric,
        notes        text)
    LANGUAGE sql
    STABLE
AS $$
    SELECT v.id,
           v.game_name::text,
           v.finished,
           v.priority,
           v.tags,
           v.series,
           v.series_slot,
           v.series_total,
           v.blocked_by,
           v.playable,
           v.hours_average,
           v.notes::text
    FROM custom.v_game v
    WHERE v.game_name ILIKE '%' || q || '%'
    ORDER BY v.game_name;
$$;

COMMENT ON FUNCTION custom.game_info(text) IS
    'Name search returning the full card: tags, series slot, play order.';


-- Pick one random game you are allowed to start, from a length tier.
--     SELECT id, game_name FROM custom.game_random('short');
--     SELECT id, game_name FROM custom.game_random('medium');
--     SELECT id, game_name FROM custom.game_random('long');
--     SELECT id, game_name FROM custom.game_random();          -- any tier
--     SELECT id, game_name FROM custom.game_random('any', ARRAY['VR']);
--     SELECT id, game_name FROM custom.game_random('short', ARRAY['PC','co-op']);
--
-- Two gates beyond length:
--   * it draws from v_game_playable, so a game with an unfinished predecessor
--     in its series can never come up;
--   * p_tags, when given, requires ALL the listed tags (AND, not OR), matched
--     case-insensitively.
--
-- Dropped rather than replaced: the old signature was game_random(text), and
-- adding a defaulted parameter creates a second function instead of replacing
-- the first, which would make game_random('short') ambiguous.
DROP FUNCTION IF EXISTS custom.game_random(text);
CREATE OR REPLACE FUNCTION custom.game_random(p_size text DEFAULT 'any',
                                              p_tags text[] DEFAULT NULL)
    RETURNS SETOF custom.game_completion_times
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    want_tier int;
    size text := p_size;
BEGIN
    want_tier := CASE lower(size)
                     WHEN 'short'  THEN 1
                     WHEN 'medium' THEN 2
                     WHEN 'long'   THEN 3
                     WHEN 'any'    THEN NULL
                 END;

    -- CASE with no matching branch also yields NULL, so distinguish a real
    -- 'any' from a typo rather than silently widening the search.
    IF want_tier IS NULL AND lower(size) <> 'any' THEN
        RAISE EXCEPTION
            'game_random: size must be short, medium, long or any -- got %', size
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    RETURN QUERY
    SELECT g.*
    FROM custom.v_game_playable g
    JOIN custom.v_game_tiers r ON r.id = g.id
    WHERE (want_tier IS NULL OR r.tier = want_tier)
      -- "has every requested tag", expressed as "has no requested tag it is
      -- missing". Inlined rather than calling game_by_tag(), which would
      -- re-run the whole set function once per candidate row.
      AND (p_tags IS NULL
           OR NOT EXISTS (
               SELECT 1
               FROM unnest(p_tags) AS want(tag_name)
               WHERE NOT EXISTS (
                   SELECT 1
                   FROM custom.game_tag_link l
                   JOIN custom.tag t ON t.id = l.tag_id
                   WHERE l.game_id = g.id
                     AND lower(t.tag_name) = lower(btrim(want.tag_name)))))
    ORDER BY random()
    LIMIT 1;
END;
$$;

COMMENT ON FUNCTION custom.game_random(text, text[]) IS
    'One random playable game from a length tier (short|medium|long|any), '
    'optionally requiring all of the given tags. Skips mid-series entries.';


-- Roll for something to play, series-aware, and show its working.
--     SELECT * FROM custom.game_roll('short');
--     SELECT * FROM custom.game_roll('any', ARRAY['VR']);
--
-- Where game_random() *excludes* mid-series games from the pool, this one
-- *redirects*: it draws from every unfinished game, and if the draw lands on
-- Yakuza 5 it hands you Yakuza 0 instead. start_name is what to play,
-- drawn_name is what the dice actually said, and redirected tells them apart.
--
-- The two are genuinely different, not stylistic:
--
--   * Weighting. Excluding makes a six-game series one entry in the pool.
--     Redirecting makes it six, so a long series comes up six times as often --
--     which is the honest answer if you think of the series as six games you
--     still have to get through.
--
--   * The tier and tag filters apply to the DRAW, not to what you end up with.
--     Roll 'long' and land on Yakuza 5, and you will be sent to Yakuza 0, which
--     may well be a medium. Roll ARRAY['VR'] and the same applies: the entry
--     that matched VR is not necessarily the one you are told to start. Use
--     game_random() when the filter has to hold for the game you actually play.
--
-- Games with no recorded hours are not in the pool at all -- v_game_tiers drops
-- them. custom.v_game_stats.missing_hours counts how many that is.
-- Return type changed when tags, play order and series_total were added, and
-- CREATE OR REPLACE cannot change a return type -- hence the drop.
DROP FUNCTION IF EXISTS custom.game_roll(text, text[]);
CREATE OR REPLACE FUNCTION custom.game_roll(p_size text DEFAULT 'any',
                                            p_tags text[] DEFAULT NULL)
    RETURNS TABLE (
        start_name     text,   -- the part, when the thing to play is inside a collection
        owned_as       text,   -- the row you actually own
        start_hours    numeric,
        start_priority int,
        start_tags     text[],
        series         text,
        series_slot    int,
        series_total   bigint,
        redirected     boolean,
        drawn_name     text,
        start_game_id  int,
        start_part_id  int)
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    want_tier int;
BEGIN
    want_tier := CASE lower(p_size)
                     WHEN 'short'  THEN 1
                     WHEN 'medium' THEN 2
                     WHEN 'long'   THEN 3
                     WHEN 'any'    THEN NULL
                 END;

    IF want_tier IS NULL AND lower(p_size) <> 'any' THEN
        RAISE EXCEPTION
            'game_roll: size must be short, medium, long or any -- got %', p_size
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    RETURN QUERY
    WITH drawn AS (
        SELECT u.game_id, u.part_id, u.unit_name, u.series_id,
               u.series_position, u.part_position
        FROM custom.v_game_unit u
        JOIN custom.v_game_tiers r
          ON r.game_id = u.game_id
         AND r.part_id IS NOT DISTINCT FROM u.part_id
        WHERE u.finished = false
          AND (want_tier IS NULL OR r.tier = want_tier)
          AND (p_tags IS NULL
               OR NOT EXISTS (
                   SELECT 1
                   FROM unnest(p_tags) AS want(tag_name)
                   WHERE NOT EXISTS (
                       SELECT 1
                       FROM custom.game_tag_link l
                       JOIN custom.tag t ON t.id = l.tag_id
                       WHERE l.game_id = u.game_id
                         AND lower(t.tag_name) = lower(btrim(want.tag_name)))))
        ORDER BY random()
        LIMIT 1
    ),
    -- head is the earliest unfinished entry of the drawn game's series. It is
    -- the drawn game itself when that was already the head, and no rows at all
    -- when the game is in no series -- hence the coalesce back to d.
    chosen AS (
        SELECT d.unit_name                    AS drawn_name,
               coalesce(head.game_id, d.game_id) AS game_id,
               CASE WHEN head.game_id IS NOT NULL THEN head.part_id
                    ELSE d.part_id END        AS part_id,
               head.game_id IS NOT NULL       AS was_redirected
        FROM drawn d
        LEFT JOIN LATERAL (
            SELECT e.game_id, e.part_id
            FROM custom.v_game_unit e
            WHERE e.finished = false
              AND ((d.series_id IS NOT NULL
                    AND e.series_id = d.series_id
                    AND (e.series_position, e.part_position) < (d.series_position, d.part_position))
                OR (e.game_id = d.game_id AND e.part_position < d.part_position))
            ORDER BY e.series_position, e.part_position
            LIMIT 1
        ) head ON true
    )
    -- Everything reported about the unit you are being sent to comes from
    -- v_unit, so this function never has to restate what a game "is".
    SELECT u.unit_name,
           u.game_name,
           u.hours,
           u.priority,
           coalesce(tg.tags, '{}'::text[]),
           u.series,
           u.series_position,
           tot.games,
           c.was_redirected,
           c.drawn_name,
           u.game_id,
           u.part_id
    FROM chosen c
    JOIN custom.v_unit u
      ON u.game_id = c.game_id
     AND u.part_id IS NOT DISTINCT FROM c.part_id
    LEFT JOIN LATERAL (
        SELECT count(*) AS games
        FROM custom.game_completion_times x
        WHERE x.series_id = u.series_id
    ) tot ON u.series_id IS NOT NULL
    LEFT JOIN LATERAL (
        SELECT array_agg(t.tag_name::text ORDER BY t.tag_name) AS tags
        FROM custom.game_tag_link l
        JOIN custom.tag t ON t.id = l.tag_id
        WHERE l.game_id = u.game_id
    ) tg ON true;
END;
$$;

COMMENT ON FUNCTION custom.game_roll(text, text[]) IS
    'Roll for a game; if the draw lands mid-series, redirect to that series'' '
    'first unfinished entry. Filters apply to the draw, not the redirect.';


-- Roll from an explicit hours range instead of a tier.
--     SELECT * FROM custom.game_roll_range(2, 6);
--     SELECT * FROM custom.game_roll_range(20, NULL);              -- 20h and up
--     SELECT * FROM custom.game_roll_range(NULL, 4, ARRAY['VR']);  -- under 4h, VR
--
-- Why this exists alongside game_roll(): three NTILE buckets answer "give me
-- something shortish", but not "I have four hours tonight". The tiers also move
-- as you finish things, so "short" is not a stable promise about length. A range
-- is.
--
-- Bounds are inclusive and either may be NULL for "unbounded that side", which
-- is how the top of the slider on /roll means "no maximum" -- the pool runs to
-- 700+ hours and a literal upper stop would exclude the longest game.
--
-- Unlike game_roll() this does NOT redirect, because it cannot need to:
-- v_roll_pool is playable units only, and "playable" already excludes anything
-- standing behind an unfinished predecessor. So the range and the tags hold for
-- the game you are actually told to start, which is the whole point of saying
-- how much time you have. (game_roll() draws from the same playable pool via
-- its v_game_tiers join, so its redirect is in practice already unreachable --
-- left alone here rather than changed underneath its callers.)
--
-- Tags are AND, matching game_by_tag() and game_roll(): ARRAY['PC','co-op']
-- means both.
DROP FUNCTION IF EXISTS custom.game_roll_range(numeric, numeric, text[]);
CREATE OR REPLACE FUNCTION custom.game_roll_range(p_min   numeric  DEFAULT NULL,
                                                  p_max   numeric  DEFAULT NULL,
                                                  p_tags  text[]   DEFAULT NULL)
    RETURNS TABLE (
        start_name     text,   -- the part, when the thing to play is in a collection
        owned_as       text,   -- the row you actually own
        start_hours    numeric,
        start_priority int,
        start_tags     text[],
        series         text,
        series_slot    int,
        series_total   bigint,
        pool_size      bigint, -- how many units the filter matched, before the draw
        start_game_id  int,
        start_part_id  int)
    LANGUAGE plpgsql
    VOLATILE
AS $$
BEGIN
    IF p_min IS NOT NULL AND p_max IS NOT NULL AND p_min > p_max THEN
        RAISE EXCEPTION
            'game_roll_range: min (%) is above max (%)', p_min, p_max
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    RETURN QUERY
    WITH pool AS (
        SELECT r.*
        FROM custom.v_roll_pool r
        WHERE (p_min IS NULL OR r.hours >= p_min)
          AND (p_max IS NULL OR r.hours <= p_max)
          AND (p_tags IS NULL
               OR NOT EXISTS (
                   SELECT 1
                   FROM unnest(p_tags) AS want(tag_name)
                   WHERE NOT EXISTS (
                       SELECT 1
                       FROM unnest(r.tags) AS has(tag_name)
                       WHERE lower(has.tag_name) = lower(btrim(want.tag_name)))))
    ),
    -- Counted over the whole matched pool, not just the drawn row, so the caller
    -- can tell "1 of 12" from "1 of 1" -- and gets 0 rows back when nothing
    -- matched at all rather than a silent empty pick.
    sized AS (SELECT count(*) AS n FROM pool)
    SELECT p.unit_name,
           p.game_name,
           p.hours,
           p.priority,
           p.tags,
           p.series,
           p.series_position,
           tot.games,
           sized.n,
           p.game_id,
           p.part_id
    FROM pool p
    CROSS JOIN sized
    LEFT JOIN LATERAL (
        SELECT count(*) AS games
        FROM custom.game_completion_times x
        WHERE x.series_id = p.series_id
    ) tot ON p.series_id IS NOT NULL
    ORDER BY random()
    LIMIT 1;
END;
$$;

COMMENT ON FUNCTION custom.game_roll_range(numeric, numeric, text[]) IS
    'Roll a playable unit whose length falls in [p_min, p_max] (NULL = open '
    'that side) and which carries all of p_tags. No series redirect: the pool '
    'is playable units, so the range holds for what you are told to play.';


-- Insert a game and hand back the stored row.
--     SELECT * FROM custom.game_add('Hollow Knight', 25, 40, 60);
--     SELECT * FROM custom.game_add('Hollow Knight', 25, 40, 60, 'metroidvania', 3);
--
-- The three hours_* columns are NOT NULL on the table, so they are required
-- arguments -- an earlier version defaulted them to NULL, which could only
-- ever fail.
--
-- hours_average is deliberately absent from the column list. It is a generated
-- column:
--     GENERATED ALWAYS AS
--         (round(((hours_main + hours_main_extra + hours_completionist) / 3.0), 2))
--         STORED
-- Postgres fills it, and naming it in an INSERT raises
--     ERROR: cannot insert a non-DEFAULT value into column "hours_average"
DROP FUNCTION IF EXISTS custom.game_add(text, numeric, numeric, numeric, text);
DROP FUNCTION IF EXISTS custom.game_add(text, numeric, numeric, numeric, text, int);
CREATE OR REPLACE FUNCTION custom.game_add(
    p_game_name           text,
    p_hours_main          numeric,
    p_hours_main_extra    numeric,
    p_hours_completionist numeric,
    p_notes               text   DEFAULT NULL,
    p_priority            int    DEFAULT NULL,
    p_tags                text[] DEFAULT NULL,
    p_series              text   DEFAULT NULL,
    p_series_position     int    DEFAULT NULL
)
    RETURNS SETOF custom.game_completion_times
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_id        int;
    v_series_id int;
    v_tag       text;
BEGIN
    -- The table's CHECK would catch this too, but with a constraint name
    -- instead of an explanation.
    IF (p_series IS NULL) <> (p_series_position IS NULL) THEN
        RAISE EXCEPTION
            'game_add: pass both p_series and p_series_position, or neither'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    IF p_series IS NOT NULL THEN
        v_series_id := custom.series_id(p_series);
    END IF;

    INSERT INTO custom.game_completion_times
        (game_name, hours_main, hours_main_extra, hours_completionist,
         notes, priority, series_id, series_position)
    VALUES
        (p_game_name, p_hours_main, p_hours_main_extra, p_hours_completionist,
         p_notes, p_priority, v_series_id, p_series_position)
    RETURNING id INTO v_id;

    IF p_tags IS NOT NULL THEN
        FOREACH v_tag IN ARRAY p_tags LOOP
            IF btrim(v_tag) <> '' THEN
                INSERT INTO custom.game_tag_link (game_id, tag_id)
                VALUES (v_id, custom.tag_id(v_tag))
                ON CONFLICT DO NOTHING;
            END IF;
        END LOOP;
    END IF;

    RETURN QUERY
    SELECT g.* FROM custom.game_completion_times g WHERE g.id = v_id;
END;
$$;

COMMENT ON FUNCTION custom.game_add(text, numeric, numeric, numeric, text, int, text[], text, int) IS
    'Insert a game, optionally with tags and a series slot. hours_average is '
    'generated by the table, never passed in.';


-- -----------------------------------------------------------------------------
-- 4. Priority management
-- -----------------------------------------------------------------------------

-- Resolve a game name to its id. Tries an exact case-insensitive match first,
-- then falls back to substring. Refuses to guess when the name is ambiguous --
-- silently picking one of several matches would set the priority on the wrong
-- game and you would never see it happen.
CREATE OR REPLACE FUNCTION custom.game_id(p_name text)
    RETURNS int
    LANGUAGE plpgsql
    STABLE
AS $$
DECLARE
    v_id      int;
    v_matches int;
BEGIN
    SELECT count(*), min(g.id) INTO v_matches, v_id
    FROM custom.game_completion_times g
    WHERE g.game_name ILIKE p_name;

    IF v_matches = 0 THEN
        SELECT count(*), min(g.id) INTO v_matches, v_id
        FROM custom.game_completion_times g
        WHERE g.game_name ILIKE '%' || p_name || '%';
    END IF;

    IF v_matches = 0 THEN
        RAISE EXCEPTION 'game_id: nothing matches %', quote_literal(p_name)
            USING ERRCODE = 'no_data_found';
    ELSIF v_matches > 1 THEN
        RAISE EXCEPTION 'game_id: % matches % games -- %',
            quote_literal(p_name), v_matches,
            (SELECT string_agg(g.game_name, ' | ' ORDER BY g.game_name)
             FROM custom.game_completion_times g
             WHERE g.game_name ILIKE '%' || p_name || '%')
            USING ERRCODE = 'cardinality_violation';
    END IF;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION custom.game_id(text) IS
    'Resolve a game name to its id; raises on no match or an ambiguous match.';


-- Set a game's priority outright. Does not touch any other row, so this can
-- create a tie -- that is fine, and game_renumber() cleans it up.
--     SELECT id, game_name, priority FROM custom.game_prioritize('Yakuza 0', 1);
CREATE OR REPLACE FUNCTION custom.game_prioritize(p_name text, p_priority int)
    RETURNS SETOF custom.game_completion_times
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_id int := custom.game_id(p_name);
BEGIN
    RETURN QUERY
    UPDATE custom.game_completion_times g
       SET priority = p_priority
     WHERE g.id = v_id
    RETURNING g.*;
END;
$$;

COMMENT ON FUNCTION custom.game_prioritize(text, int) IS
    'Set one game''s priority, leaving every other row alone.';


-- Insert a game AT a position, pushing everything at or below that number down
-- by one. Use this when you want a game to land third without renumbering the
-- rest by hand.
--     SELECT id, game_name, priority FROM custom.game_prioritize_at('Elden Ring', 2);
CREATE OR REPLACE FUNCTION custom.game_prioritize_at(p_name text, p_priority int)
    RETURNS SETOF custom.game_completion_times
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_id int := custom.game_id(p_name);
BEGIN
    UPDATE custom.game_completion_times
       SET priority = priority + 1
     WHERE priority >= p_priority
       AND id <> v_id;

    RETURN QUERY
    UPDATE custom.game_completion_times g
       SET priority = p_priority
     WHERE g.id = v_id
    RETURNING g.*;
END;
$$;

COMMENT ON FUNCTION custom.game_prioritize_at(text, int) IS
    'Set a priority and shift everything at or below it down by one.';


-- Drop a game out of the ranking without deleting it.
CREATE OR REPLACE FUNCTION custom.game_unprioritize(p_name text)
    RETURNS SETOF custom.game_completion_times
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_id int := custom.game_id(p_name);
BEGIN
    RETURN QUERY
    UPDATE custom.game_completion_times g
       SET priority = NULL
     WHERE g.id = v_id
    RETURNING g.*;
END;
$$;

COMMENT ON FUNCTION custom.game_unprioritize(text) IS
    'Clear a game''s priority (row is kept, just unranked).';


-- Compact the ranking to a dense 1..n, preserving current order and breaking
-- ties by name. Returns only the rows it actually changed.
--     SELECT id, game_name, priority FROM custom.game_renumber();
CREATE OR REPLACE FUNCTION custom.game_renumber()
    RETURNS SETOF custom.game_completion_times
    LANGUAGE plpgsql
    VOLATILE
AS $$
BEGIN
    RETURN QUERY
    WITH ranked AS (
        SELECT g.id,
               row_number() OVER (ORDER BY g.priority, g.game_name) AS rn
        FROM custom.game_completion_times g
        WHERE g.priority IS NOT NULL
    )
    UPDATE custom.game_completion_times g
       SET priority = r.rn
      FROM ranked r
     WHERE g.id = r.id
       AND g.priority IS DISTINCT FROM r.rn
    RETURNING g.*;
END;
$$;

COMMENT ON FUNCTION custom.game_renumber() IS
    'Renumber priorities to a gapless 1..n, keeping current order.';


-- -----------------------------------------------------------------------------
-- 5. Tag management
--
-- Every function here resolves games by name through custom.game_id(), so it
-- raises rather than guessing when a name is ambiguous.
-- -----------------------------------------------------------------------------

-- Resolve a tag name to its id, creating the tag if it is new.
-- Pass p_create => false to require that the tag already exists, which is what
-- you want when filtering (a typo should return nothing, not invent a tag).
CREATE OR REPLACE FUNCTION custom.tag_id(p_tag text, p_create boolean DEFAULT true)
    RETURNS int
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_id  int;
    v_tag text := btrim(p_tag);
BEGIN
    IF v_tag = '' THEN
        RAISE EXCEPTION 'tag_id: tag name is empty'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT t.id INTO v_id
    FROM custom.tag t
    WHERE lower(t.tag_name) = lower(v_tag);

    IF v_id IS NULL AND p_create THEN
        INSERT INTO custom.tag (tag_name) VALUES (v_tag) RETURNING id INTO v_id;
    ELSIF v_id IS NULL THEN
        RAISE EXCEPTION 'tag_id: no tag named %', quote_literal(v_tag)
            USING ERRCODE = 'no_data_found';
    END IF;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION custom.tag_id(text, boolean) IS
    'Resolve a tag name to its id, creating it unless p_create => false.';


-- Attach one or more tags to a game. Re-running is harmless.
--     SELECT * FROM custom.game_tag_add('Yakuza 0', 'PC', 'long');
--     SELECT * FROM custom.game_tag_add('Beat Saber', VARIADIC ARRAY['VR','PC']);
--
-- Output columns are qualified as v.* below because RETURNS TABLE names are
-- also visible as identifiers inside the body; an unqualified "id" would be
-- ambiguous.
CREATE OR REPLACE FUNCTION custom.game_tag_add(p_name text, VARIADIC p_tags text[])
    RETURNS TABLE (id int, game_name text, tags text[])
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_id  int := custom.game_id(p_name);
    v_tag text;
BEGIN
    FOREACH v_tag IN ARRAY p_tags LOOP
        IF btrim(v_tag) <> '' THEN
            INSERT INTO custom.game_tag_link (game_id, tag_id)
            VALUES (v_id, custom.tag_id(v_tag))
            ON CONFLICT DO NOTHING;
        END IF;
    END LOOP;

    RETURN QUERY
    SELECT v.id, v.game_name::text, v.tags
    FROM custom.v_game_tags v
    WHERE v.id = v_id;
END;
$$;

COMMENT ON FUNCTION custom.game_tag_add(text, text[]) IS
    'Attach tags to a game, creating any that do not exist yet.';


-- Detach tags from a game. The tag itself survives -- it is still on other
-- games. Use custom.tag_prune() to clear out ones nothing uses.
--     SELECT * FROM custom.game_tag_remove('Yakuza 0', 'VR');
CREATE OR REPLACE FUNCTION custom.game_tag_remove(p_name text, VARIADIC p_tags text[])
    RETURNS TABLE (id int, game_name text, tags text[])
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_id int := custom.game_id(p_name);
BEGIN
    DELETE FROM custom.game_tag_link l
    USING custom.tag t
    WHERE l.tag_id  = t.id
      AND l.game_id = v_id
      AND lower(t.tag_name) IN (SELECT lower(btrim(x)) FROM unnest(p_tags) AS x);

    RETURN QUERY
    SELECT v.id, v.game_name::text, v.tags
    FROM custom.v_game_tags v
    WHERE v.id = v_id;
END;
$$;

COMMENT ON FUNCTION custom.game_tag_remove(text, text[]) IS
    'Detach tags from a game; the tags themselves are kept.';


-- Games carrying ALL of the given tags.
--     SELECT id, game_name FROM custom.game_by_tag('PC', 'co-op');
CREATE OR REPLACE FUNCTION custom.game_by_tag(VARIADIC p_tags text[])
    RETURNS SETOF custom.game_completion_times
    LANGUAGE sql
    STABLE
AS $$
    SELECT g.*
    FROM custom.game_completion_times g
    WHERE NOT EXISTS (
        SELECT 1
        FROM unnest(p_tags) AS want(tag_name)
        WHERE NOT EXISTS (
            SELECT 1
            FROM custom.game_tag_link l
            JOIN custom.tag t ON t.id = l.tag_id
            WHERE l.game_id = g.id
              AND lower(t.tag_name) = lower(btrim(want.tag_name))))
    ORDER BY g.game_name;
$$;

COMMENT ON FUNCTION custom.game_by_tag(text[]) IS
    'Games carrying every one of the given tags (AND).';


-- Games carrying ANY of the given tags.
--     SELECT id, game_name FROM custom.game_by_any_tag('VR', 'Handheld');
CREATE OR REPLACE FUNCTION custom.game_by_any_tag(VARIADIC p_tags text[])
    RETURNS SETOF custom.game_completion_times
    LANGUAGE sql
    STABLE
AS $$
    SELECT g.*
    FROM custom.game_completion_times g
    WHERE EXISTS (
        SELECT 1
        FROM custom.game_tag_link l
        JOIN custom.tag t ON t.id = l.tag_id
        WHERE l.game_id = g.id
          AND lower(t.tag_name) IN (SELECT lower(btrim(x)) FROM unnest(p_tags) AS x))
    ORDER BY g.game_name;
$$;

COMMENT ON FUNCTION custom.game_by_any_tag(text[]) IS
    'Games carrying at least one of the given tags (OR).';


-- Fix a tag everywhere at once. This is the reason tags are a table: every
-- game keeps its link, only the name changes.
--     SELECT custom.tag_rename('handheld', 'Handheld');
CREATE OR REPLACE FUNCTION custom.tag_rename(p_from text, p_to text)
    RETURNS int
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_id int := custom.tag_id(p_from, false);
BEGIN
    UPDATE custom.tag SET tag_name = btrim(p_to) WHERE id = v_id;
    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION custom.tag_rename(text, text) IS
    'Rename a tag in place, keeping every game link.';


-- Delete tags no game uses. Returns the names it removed.
CREATE OR REPLACE FUNCTION custom.tag_prune()
    RETURNS TABLE (tag_name text)
    LANGUAGE sql
    VOLATILE
AS $$
    DELETE FROM custom.tag t
    WHERE NOT EXISTS (SELECT 1 FROM custom.game_tag_link l WHERE l.tag_id = t.id)
    RETURNING t.tag_name::text;
$$;

COMMENT ON FUNCTION custom.tag_prune() IS
    'Delete tags with no games attached; returns what it deleted.';


-- -----------------------------------------------------------------------------
-- 6. Series management
-- -----------------------------------------------------------------------------

-- Resolve a series name to its id, creating it if new. Same p_create rule as
-- custom.tag_id().
CREATE OR REPLACE FUNCTION custom.series_id(p_series text, p_create boolean DEFAULT true)
    RETURNS int
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_id     int;
    v_series text := btrim(p_series);
BEGIN
    IF v_series = '' THEN
        RAISE EXCEPTION 'series_id: series name is empty'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    SELECT s.id INTO v_id
    FROM custom.series s
    WHERE lower(s.series_name) = lower(v_series);

    IF v_id IS NULL AND p_create THEN
        INSERT INTO custom.series (series_name) VALUES (v_series) RETURNING id INTO v_id;
    ELSIF v_id IS NULL THEN
        RAISE EXCEPTION 'series_id: no series named %', quote_literal(v_series)
            USING ERRCODE = 'no_data_found';
    END IF;

    RETURN v_id;
END;
$$;

COMMENT ON FUNCTION custom.series_id(text, boolean) IS
    'Resolve a series name to its id, creating it unless p_create => false.';


-- Put a game into a series at a position. Creates the series on first use.
--     SELECT id, game_name, series_position FROM custom.game_series_set('Yakuza 0', 'Yakuza', 1);
--     SELECT id, game_name, series_position FROM custom.game_series_set('Yakuza Kiwami', 'Yakuza', 2);
--
-- Positions do not have to be dense or unique; only their relative order is
-- read. Numbering a six-game series 10, 20, 30 leaves room to slot in a
-- prequel later without touching the others.
CREATE OR REPLACE FUNCTION custom.game_series_set(p_name text, p_series text, p_position int)
    RETURNS SETOF custom.game_completion_times
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_id        int := custom.game_id(p_name);
    v_series_id int := custom.series_id(p_series);
BEGIN
    RETURN QUERY
    UPDATE custom.game_completion_times g
       SET series_id       = v_series_id,
           series_position = p_position
     WHERE g.id = v_id
    RETURNING g.*;
END;
$$;

COMMENT ON FUNCTION custom.game_series_set(text, text, int) IS
    'Place a game in a series at a position, creating the series if needed.';


-- Take a game back out of its series. Both columns clear together, as the
-- table's CHECK requires.
CREATE OR REPLACE FUNCTION custom.game_series_clear(p_name text)
    RETURNS SETOF custom.game_completion_times
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_id int := custom.game_id(p_name);
BEGIN
    RETURN QUERY
    UPDATE custom.game_completion_times g
       SET series_id       = NULL,
           series_position = NULL
     WHERE g.id = v_id
    RETURNING g.*;
END;
$$;

COMMENT ON FUNCTION custom.game_series_clear(text) IS
    'Remove a game from its series (the row is kept).';


-- Build a whole series in one call, in the order you list the games. Each name
-- goes through game_id(), so an ambiguous or missing name aborts the entire
-- call rather than leaving half a series recorded.
--     SELECT * FROM custom.series_order('Yakuza', 'Yakuza 0', 'Yakuza Kiwami', 'Yakuza 2');
CREATE OR REPLACE FUNCTION custom.series_order(p_series text, VARIADIC p_names text[])
    RETURNS SETOF custom.game_completion_times
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_series_id int := custom.series_id(p_series);
    v_ids       int[] := '{}';
    v_name      text;
BEGIN
    -- Resolve every name before writing anything.
    FOREACH v_name IN ARRAY p_names LOOP
        v_ids := v_ids || custom.game_id(v_name);
    END LOOP;

    RETURN QUERY
    UPDATE custom.game_completion_times g
       SET series_id       = v_series_id,
           series_position = o.rn
      FROM unnest(v_ids) WITH ORDINALITY AS o(id, rn)
     WHERE g.id = o.id
    RETURNING g.*;
END;
$$;

COMMENT ON FUNCTION custom.series_order(text, text[]) IS
    'Assign a whole series in one call: positions follow argument order.';


-- -----------------------------------------------------------------------------
-- 7. Splitting and finishing
-- -----------------------------------------------------------------------------

-- Declare the games inside a collection you own as a single product.
--     SELECT * FROM custom.game_split('Mass Effect Legendary Edition',
--                                     'Mass Effect', 'Mass Effect 2', 'Mass Effect 3');
--
-- The collection stays exactly one row in game_completion_times. The parts are
-- what the roll draws and what blocking runs over, so you can finish ME1 and
-- have ME2 come up next without the table ever claiming you bought three games.
--
-- Re-running replaces the list. Parts carry progress, so survivors are matched
-- by name (case-insensitively) and keep their finished flag and hours -- adding
-- a fourth entry does not reset the three you had played.
--
-- The OUT parameters are prefixed o_ because RETURNS TABLE names are visible as
-- identifiers inside the body, and a bare "part_name" would be ambiguous
-- against custom.game_part.part_name.
DROP FUNCTION IF EXISTS custom.game_split(text, text[]);
CREATE OR REPLACE FUNCTION custom.game_split(p_name text, VARIADIC p_parts text[])
    RETURNS TABLE (o_part_id  int,
                   o_game     text,
                   o_position int,
                   o_part     text,
                   o_hours    numeric,
                   o_finished boolean)
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_id   int := custom.game_id(p_name);
    v_part text;
    v_rn   int := 0;
BEGIN
    IF array_length(p_parts, 1) IS NULL OR array_length(p_parts, 1) < 2 THEN
        RAISE EXCEPTION 'game_split: a split needs at least two parts'
            USING ERRCODE = 'invalid_parameter_value';
    END IF;

    CREATE TEMP TABLE _keep ON COMMIT DROP AS
        SELECT lower(p.part_name) AS k, p.finished AS fin, p.hours AS hrs
        FROM custom.game_part p WHERE p.game_id = v_id;

    DELETE FROM custom.game_part p WHERE p.game_id = v_id;

    FOREACH v_part IN ARRAY p_parts LOOP
        IF btrim(v_part) = '' THEN
            RAISE EXCEPTION 'game_split: part name is empty'
                USING ERRCODE = 'invalid_parameter_value';
        END IF;
        v_rn := v_rn + 1;
        INSERT INTO custom.game_part (game_id, part_position, part_name, hours, finished)
        SELECT v_id, v_rn, btrim(v_part), k.hrs, coalesce(k.fin, false)
        FROM (SELECT 1) d
        LEFT JOIN _keep k ON k.k = lower(btrim(v_part));
    END LOOP;

    DROP TABLE _keep;

    RETURN QUERY
    SELECT p.id, g.game_name::text, p.part_position, p.part_name::text, p.hours, p.finished
    FROM custom.game_part p
    JOIN custom.game_completion_times g ON g.id = p.game_id
    WHERE p.game_id = v_id
    ORDER BY p.part_position;
END;
$$;

COMMENT ON FUNCTION custom.game_split(text, text[]) IS
    'Declare the games inside one owned collection; keeps progress on re-split.';


-- Undo a split. The collection goes back to being one unit; the row itself is
-- untouched. Returns how many parts were removed.
CREATE OR REPLACE FUNCTION custom.game_unsplit(p_name text)
    RETURNS int
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_id int := custom.game_id(p_name);
    v_n  int;
BEGIN
    DELETE FROM custom.game_part WHERE game_id = v_id;
    GET DIAGNOSTICS v_n = ROW_COUNT;
    RETURN v_n;
END;
$$;

COMMENT ON FUNCTION custom.game_unsplit(text) IS
    'Remove a game''s parts, making it a single unit again.';


-- Mark a whole game finished (or not).
--     SELECT id, game_name, finished FROM custom.game_finish('Alan Wake');
--     SELECT id, game_name, finished FROM custom.game_finish('Alan Wake', false);
--
-- On a split game this sets every part, because the parent's state is derived
-- from them -- setting the parent flag alone would be ignored by every view.
CREATE OR REPLACE FUNCTION custom.game_finish(p_name text, p_finished boolean DEFAULT true)
    RETURNS SETOF custom.game_completion_times
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_id int := custom.game_id(p_name);
BEGIN
    UPDATE custom.game_part SET finished = p_finished WHERE game_id = v_id;

    RETURN QUERY
    UPDATE custom.game_completion_times g
       SET finished = p_finished
     WHERE g.id = v_id
    RETURNING g.*;
END;
$$;

COMMENT ON FUNCTION custom.game_finish(text, boolean) IS
    'Mark a game finished; on a split game, every part with it.';


-- Mark ONE part of a split game finished (or not).
--     SELECT * FROM custom.part_finish('Mass Effect Legendary Edition', 'Mass Effect');
--
-- Exact match first, then substring -- otherwise 'Mass Effect' would match all
-- three parts whose names contain it and silently finish the whole trilogy. An
-- ambiguous substring raises and lists the candidates.
DROP FUNCTION IF EXISTS custom.part_finish(text, text, boolean);
CREATE OR REPLACE FUNCTION custom.part_finish(p_name text, p_part text,
                                              p_finished boolean DEFAULT true)
    RETURNS TABLE (o_part_id  int,
                   o_game     text,
                   o_position int,
                   o_part     text,
                   o_finished boolean)
    LANGUAGE plpgsql
    VOLATILE
AS $$
DECLARE
    v_id   int := custom.game_id(p_name);
    v_part int;
    v_n    int;
BEGIN
    SELECT count(*), min(p.id) INTO v_n, v_part
    FROM custom.game_part p
    WHERE p.game_id = v_id AND lower(p.part_name) = lower(btrim(p_part));

    IF v_n = 0 THEN
        SELECT count(*), min(p.id) INTO v_n, v_part
        FROM custom.game_part p
        WHERE p.game_id = v_id
          AND lower(p.part_name) LIKE '%' || lower(btrim(p_part)) || '%';
    END IF;

    IF v_n = 0 THEN
        RAISE EXCEPTION 'part_finish: no part of % matches %',
            quote_literal(p_name), quote_literal(p_part)
            USING ERRCODE = 'no_data_found';
    ELSIF v_n > 1 THEN
        RAISE EXCEPTION 'part_finish: % matches % parts of % -- %',
            quote_literal(p_part), v_n, quote_literal(p_name),
            (SELECT string_agg(p.part_name, ' | ' ORDER BY p.part_position)
             FROM custom.game_part p
             WHERE p.game_id = v_id
               AND lower(p.part_name) LIKE '%' || lower(btrim(p_part)) || '%')
            USING ERRCODE = 'cardinality_violation';
    END IF;

    UPDATE custom.game_part p SET finished = p_finished WHERE p.id = v_part;

    -- Keep the parent flag agreeing with its parts, so anything reading the
    -- table directly (NocoDB, ad-hoc SQL) still sees the truth.
    UPDATE custom.game_completion_times g
       SET finished = (SELECT count(*) = count(*) FILTER (WHERE p.finished)
                       FROM custom.game_part p WHERE p.game_id = v_id)
     WHERE g.id = v_id;

    RETURN QUERY
    SELECT p.id, g.game_name::text, p.part_position, p.part_name::text, p.finished
    FROM custom.game_part p
    JOIN custom.game_completion_times g ON g.id = p.game_id
    WHERE p.game_id = v_id
    ORDER BY p.part_position;
END;
$$;

COMMENT ON FUNCTION custom.part_finish(text, text, boolean) IS
    'Mark one part of a split game finished; re-derives the parent flag.';
