// What the server decided, read from each player's score record. The engine
// copies the record from the server to every client, and the server's game
// mode writes RoundPoints and PrevRaceTimes, so they reflect the server's
// decisions rather than this client's prediction.

// GetServerScore returns the player's server-synced score record, or null if the player isn't in the playground.
CSmArenaScore@ GetServerScore(const MLFeed::PlayerCpInfo_V4@ player) {
    if (player is null) return null;
    auto enginePlayer = player.FindCSmPlayer();
    if (enginePlayer is null) return null;
    auto scriptPlayer = cast<CSmScriptPlayer>(enginePlayer.ScriptAPI);
    if (scriptPlayer is null) return null;
    return scriptPlayer.Score;
}

// PreviousRaceTimesText returns the score record's PrevRaceTimes as text, so it can be compared later.
string PreviousRaceTimesText(CSmArenaScore@ score) {
    string text = "";
    for (uint i = 0; i < score.PrevRaceTimes.Length; i++) text += (i > 0 ? "," : "") + score.PrevRaceTimes[i];
    return text;
}

// ScoreCommitWatch spots the server's end-of-round score commit, where round points are folded into totals (observed about 3 s after EndRound in Throttle).
class ScoreCommitWatch {
    // MLFeed keeps one object per player, and FindCSmPlayer looks the player up
    // each time, so these handles stay valid to read from.
    array<const MLFeed::PlayerCpInfo_V4@> players;
    int[] pointsAtStart;
    int[] roundPointsAtStart;

    // ScoreCommitWatch records every listed player's server totals now, before the commit.
    ScoreCommitWatch(const MLFeed::HookRaceStatsEventsBase_V4@ raceData) {
        for (uint i = 0; i < raceData.SortedPlayers_Race.Length; i++) {
            auto player = cast<MLFeed::PlayerCpInfo_V4>(raceData.SortedPlayers_Race[i]);
            auto score = GetServerScore(player);
            if (score is null) continue;
            players.InsertLast(player);
            pointsAtStart.InsertLast(score.Points);
            roundPointsAtStart.InsertLast(score.RoundPoints);
        }
    }

    // Committed reports whether the commit has happened: someone's total changed, or their round points were reset to 0.
    bool Committed() {
        for (uint i = 0; i < players.Length; i++) {
            auto score = GetServerScore(players[i]);
            if (score is null) continue;
            if (score.Points != pointsAtStart[i]) return true;
            if (roundPointsAtStart[i] != 0 && score.RoundPoints == 0) return true;
        }
        return false;
    }
}
