// What the server decided, read from each player's score record. The engine
// copies the record from the server to every client, and the server's game
// mode writes RoundPoints and PrevRaceTimes, so they reflect the server's
// decisions rather than this client's prediction.

// ServerVerdict is the server's verdict on the plugin runner's own finish. See LocalFinishCheck.
enum ServerVerdict {
    // No verdict: nothing to decide, this mode gives no signal, or no score commit was seen.
    Unknown,
    Finished,
    Dnf
}

// GetServerScore returns the player's server-synced score record, or null if the player isn't in the playground.
CSmArenaScore@ GetServerScore(const MLFeed::PlayerCpInfo_V4@ player) {
    if (player is null) return null;
    auto enginePlayer = player.FindCSmPlayer();
    if (enginePlayer is null) return null;
    auto scriptPlayer = cast<CSmScriptPlayer>(enginePlayer.ScriptAPI);
    if (scriptPlayer is null) return null;
    return scriptPlayer.Score;
}

// ServerFinishSignals is how this map's game mode shows a validated finish in the score record.
// It is learned from other players' finishes, which only reach this client once the server has validated them.
class ServerFinishSignals {
    // Round points move off the round's "not finished" value (Throttle Cup and reverse cup, Nadeo Rounds).
    bool roundPoints = false;
    // PrevRaceTimes is filled (stock Nadeo modes; Throttle leaves it empty).
    bool prevRaceTimes = false;

    // get_AnySeen reports whether either signal has been seen on this map.
    bool get_AnySeen() const { return roundPoints || prevRaceTimes; }

    // Reset forgets both signals, for a new map.
    void Reset() {
        roundPoints = false;
        prevRaceTimes = false;
    }
}

// ScoreCommitWatch spots the server's end-of-round score commit: round points folded into totals, about 3 s after EndRound.
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
