enum ServerVerdict {
    // The client backup is used; noVerdictReason says why.
    None,
    Confirmed,
    Rejected
}

// The server never corrects a finish it rejected, so the plugin runner's finish is checked against score
// records. While the runner is still racing, 500 ms after the first other finish, their "not finished"
// round points and PrevRaceTimes are sampled. A change from that sample before the score commit confirms
// the finish; no change by the commit means rejected. With no sample (the runner finished first or alone,
// so can't have been timed out) or no commit seen, there's no verdict and the client backup is used.
// Knockout writes no round points, so a driving runner's finish there is never verified.
class ServerVerdictOnOwnFinish {
    // Gives the server's update time to reach this client.
    uint SampleDelayMs = 500;
    uint firstOtherFinishAt = 0;
    // The runner's "not finished" values, e.g. 0 round points in Throttle Cup, -20 in Throttle reverse cup.
    bool haveSample = false;
    int sampledRoundPoints = 0;
    string sampledPreviousRaceTimes;
    bool serverConfirmed = false;
    string noVerdictReason;

    void WatchRace(RoundTracker@ round) {
        NoteFirstOtherFinish(round);
        auto runner = round.pluginRunnerEntry;
        if (runner is null || !round.IsThisRound(runner) || haveSample || runner.result.Finished) return;
        if (firstOtherFinishAt == 0 || Time::Now - firstOtherFinishAt < SampleDelayMs) return;
        auto score = GetServerScore(runner.player);
        if (score is null) return;
        sampledRoundPoints = score.RoundPoints;
        sampledPreviousRaceTimes = PreviousRaceTimesText(score);
        haveSample = true;
    }

    void WatchEndOfRound(RoundTracker@ round) {
        // A sample means the runner is in this round.
        if (!haveSample || serverConfirmed) return;
        auto score = GetServerScore(round.pluginRunnerEntry.player);
        if (score !is null) serverConfirmed = ServerConfirms(score.RoundPoints, PreviousRaceTimesText(score));
    }

    void NoteFirstOtherFinish(RoundTracker@ round) {
        if (firstOtherFinishAt > 0) return;
        for (uint i = 0; i < round.entries.Length; i++) {
            auto entry = round.entries[i];
            if (entry is round.pluginRunnerEntry || !round.IsThisRound(entry) || !entry.result.Finished) continue;
            firstOtherFinishAt = Time::Now;
            return;
        }
    }

    bool ServerConfirms(int roundPoints, const string &in previousRaceTimes) {
        // Round points of 0 are the commit resetting them, not a confirmation; PrevRaceTimes can still hold an earlier round's times.
        return (roundPoints != sampledRoundPoints && roundPoints != 0)
            || (previousRaceTimes.Length > 0 && previousRaceTimes != sampledPreviousRaceTimes);
    }

    ServerVerdict Decide(bool scoreCommitSeen) {
        if (serverConfirmed) return ServerVerdict::Confirmed;
        if (!haveSample) noVerdictReason = "no sample: the plugin runner finished first, alone, or within 500 ms of the first other finish";
        else if (!scoreCommitSeen) noVerdictReason = "the server's score commit wasn't seen";
        else return ServerVerdict::Rejected;
        return ServerVerdict::None;
    }
}
