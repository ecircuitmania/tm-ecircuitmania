// Score records are synced from the server, so they show its decisions, not this client's prediction.

CSmArenaScore@ GetServerScore(const MLFeed::PlayerCpInfo_V4@ player) {
    if (player is null) return null;
    auto enginePlayer = player.FindCSmPlayer();
    if (enginePlayer is null) return null;
    auto scriptPlayer = cast<CSmScriptPlayer>(enginePlayer.ScriptAPI);
    if (scriptPlayer is null) return null;
    return scriptPlayer.Score;
}

string PreviousRaceTimesText(CSmArenaScore@ score) {
    string text = "";
    for (uint i = 0; i < score.PrevRaceTimes.Length; i++) text += (i > 0 ? "," : "") + score.PrevRaceTimes[i];
    return text;
}

// Spots the end-of-round score commit, when round points are folded into totals.
class ScoreCommitWatch {
    // MLFeed keeps one object per player, so these handles stay valid.
    array<const MLFeed::PlayerCpInfo_V4@> players;
    int[] pointsAtStart;
    int[] roundPointsAtStart;

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
