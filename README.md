# ECM Match Data

An Openplanet plugin for Trackmania that reports each round of a match to
eCircuitMania (ECM).

## Using it

1. Install the dependencies: **MLHook** and **MLFeed: Race Data**.
2. Join the match's server and open **ECM Match Data** from the Openplanet menu.
3. Paste the key ECM gives you, in the form `<matchId>_<apiKey>`, and press
   **Start Monitoring**. **Use Last** fills in the previous key.

Monitoring stops when you press **Stop Monitoring** or leave the server. The
window shows the race state, the round count and how the last requests went.

## What it sends

One message per round, sent to ECM's round-end endpoint after the round ends
and the server has given its verdict: when the server commits the round's
scores, or when the round moves on without that (next round, podium, map
change, or monitoring stopped). Each message has the round number, the map,
a timestamp, and every player who drove that round:

- `ubisoftUid`: the player's Ubisoft account ID;
- `finishTime`: their race time in milliseconds, or `-1` for a DNF;
- `position`: their place in the round.

Only players with evidence of driving that round are included: seen spawned,
or past a checkpoint, in a run that started at or after both the round's start
as the server gives it and the map's previous end of round. Spectators are left
out, and so is a player who switched to spectator before finishing. ECM counts
a player missing from a round as a DNF. If players drove in a round but none of
their runs counts for it, the round isn't sent, since ECM would count them all
as DNFs; an error notification says so instead.

Players are ranked like the game does: finishers by race time, then by their
previous checkpoint times (latest first), then points, then name. DNFs come
after them, by checkpoints reached, then time at the last checkpoint; a player
who never reached a checkpoint ranks last.

Rounds are numbered by the plugin, counting from the start of each map. The
count survives restarting monitoring (as the MLFeed warning asks you to), but
rounds that end while monitoring is stopped aren't counted, and starting to
monitor mid-map counts from that point. Warmup is never reported.

## How results are built

Every player's result comes from MLFeed, and the server has the final say.

- **Other players**: their checkpoint and finish times only reach your game
  after the server has accepted them, so they're already the server's.
- **You, the player running the plugin**: your game records your own
  checkpoints and finish straight away, before the server has seen them, so at
  first they're a guess.
  - Your **times** are later corrected to the server's. The plugin keeps
    reading them until the server commits the round's scores, so the corrected
    time is the one sent.
  - Your **finish** is never corrected: a finish the server rejected, for
    example because it came after the finish timeout, still shows as one. So if
    you finish more than half a second after the first other player, your
    finish only counts if the server's score record confirms it, through your
    round points or your previous race times, before the server commits the
    round's scores. The plugin learns which of the two the mode uses from the
    other finishers' score records. If the server never confirms your finish,
    you're sent as a DNF. When the plugin can't tell, it keeps your finish as
    your game shows it: in a mode where the other finishers show neither, or in
    a mode without round points, where the score commit can't be seen.

## MLFeed warning

MLHook can stop delivering events to MLFeed, for example when a plugin's event
handling takes too long. MLFeed then stops updating and the rounds sent to ECM
are incomplete. The plugin compares MLFeed with the game: if a player's current
run is missing from MLFeed for 3 seconds, a red warning appears in the window,
and an error notification pops up once your car isn't on track. Reload
"MLFeed: Race Data" in Openplanet's Plugin Manager (or restart the game), then
start monitoring again.

## Developing

`./build.sh dev` copies the plugin into Openplanet's Plugins folder with the
`DEV` define set (see the script for `PLUGINS_DIR`). Dev builds:

- run self-tests for the ranking and the finish verdict on load;
- have a **Dry run** setting, on by default, that logs requests instead of
  sending them;
- log `[ECMTRACE]` JSON lines to `Openplanet.log` for state changes, score
  changes and each round's report;
- have a **Simulate MLFeed stall** setting to test the warning.

Dev-only code lives in `src/dev/` and is left out of release packages. In
Openplanet's developer mode, the settings also show the round-end URL so it can
be pointed at a test server.

Releases are built by GitHub Actions on every push to `master` whose
`info.toml` version doesn't have a tag yet.

## License

Public domain; see [LICENSE](LICENSE).
