enum ServerVerdict {
    // The client backup is used; noVerdictReason says why.
    None,
    Confirmed,
    Rejected
}

// The server never corrects a finish it rejected, so the plugin runner's finish is checked against score
// records. While the runner is still racing, 500 ms after the first other finish, their "not finished"
// round points and PrevRaceTimes are sampled. A change from that sample before the score commit confirms
// the finish, but only through a signal another finisher showed this round. No confirmation by the commit
// means rejected. With no sample (the runner finished first or alone, so can't have been timed out), no
// signal, or no commit seen, there's no verdict and the client backup is used.
class ServerVerdictOnOwnFinish {
    // Gives the server's update time to reach this client.
    uint SampleDelayMs = 500;
    uint firstOtherFinishAt = 0;
    // The runner's "not finished" values, e.g. 0 round points in Throttle Cup, -20 in Throttle reverse cup.
    bool haveSample = false;
    int sampledRoundPoints = 0;
    string sampledPreviousRaceTimes;
    dictionary previousRaceTimesWhileRacing;
    bool roundPointsSignal = false;
    bool previousRaceTimesSignal = false;
    bool serverConfirmed = false;
    string noVerdictReason;

    void WatchRace(RoundTracker@ round) {
        WatchOtherPlayers(round);
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
        WatchOtherPlayers(round);
        // A sample means the runner is in this round.
        if (!haveSample || serverConfirmed) return;
        auto score = GetServerScore(round.pluginRunnerEntry.player);
        if (score !is null) serverConfirmed = ServerConfirms(score.RoundPoints, PreviousRaceTimesText(score));
    }

    void WatchOtherPlayers(RoundTracker@ round) {
        for (uint i = 0; i < round.entries.Length; i++) {
            auto entry = round.entries[i];
            if (entry is round.pluginRunnerEntry || !round.IsThisRound(entry)) continue;
            bool finished = entry.result.Finished;
            if (finished && firstOtherFinishAt == 0) firstOtherFinishAt = Time::Now;
            string key = RunKey(entry);
            // A finisher is read for the signals once there's a sample; a racing player only until remembered.
            if (finished ? !haveSample : previousRaceTimesWhileRacing.Exists(key)) continue;
            auto score = GetServerScore(entry.player);
            if (score is null) continue;
            string previousRaceTimes = PreviousRaceTimesText(score);
            if (!finished) {
                previousRaceTimesWhileRacing[key] = previousRaceTimes;
                continue;
            }
            // Never seen racing: count it as unchanged, so it can't show a signal.
            string whileRacing = previousRaceTimes;
            if (previousRaceTimesWhileRacing.Exists(key)) previousRaceTimesWhileRacing.Get(key, whileRacing);
            LearnFromFinisher(score.RoundPoints, whileRacing, previousRaceTimes);
        }
    }

    void LearnFromFinisher(int roundPoints, const string &in previousRaceTimesWhileRacing, const string &in previousRaceTimes) {
        if (roundPoints != sampledRoundPoints) roundPointsSignal = true;
        if (previousRaceTimes.Length > 0 && previousRaceTimes != previousRaceTimesWhileRacing) previousRaceTimesSignal = true;
    }

    bool ServerConfirms(int roundPoints, const string &in previousRaceTimes) {
        // Round points of 0 are the commit resetting them, not a confirmation; PrevRaceTimes can still hold an earlier round's times.
        return (roundPointsSignal && roundPoints != sampledRoundPoints && roundPoints != 0)
            || (previousRaceTimesSignal && previousRaceTimes.Length > 0 && previousRaceTimes != sampledPreviousRaceTimes);
    }

    ServerVerdict Decide(bool scoreCommitSeen) {
        if (serverConfirmed) return ServerVerdict::Confirmed;
        if (!haveSample) noVerdictReason = "no sample: the plugin runner finished first, alone, or within 500 ms of the first other finish";
        else if (!roundPointsSignal && !previousRaceTimesSignal) noVerdictReason = "no finish signal from this round's other finishers";
        else if (!scoreCommitSeen) noVerdictReason = "the server's score commit wasn't seen";
        else return ServerVerdict::Rejected;
        return ServerVerdict::None;
    }
}

string RunKey(RoundEntry@ entry) {
    return entry.player.Login + "/" + entry.runStartTime;
}
