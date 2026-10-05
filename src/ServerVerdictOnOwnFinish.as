// ServerVerdict is the server's verdict on the plugin runner's own finish, read from score records.
enum ServerVerdict {
    // No verdict by the end of the round, so the client backup is used; noVerdictReason says why.
    None,
    Confirmed,
    Rejected
}

// ServerVerdictOnOwnFinish works out, for one round, the server's verdict on the plugin runner's own finish.
// Only the runner's finish needs it; see "Where round results come from" in RoundTracker.as.
//
// The rule: sample the runner's round points (and the PrevRaceTimes snapshot) while they're still
// racing, at least 500 ms after the first other finish. At the end of the wait, if MLFeed shows the
// runner finished and a sample exists, the finish counts only if a server confirmation was seen
// before the commit (round points moved off the sample and not 0, or PrevRaceTimes changed), and
// only through a signal this round's other finishers showed; otherwise mark it a DNF. With no sample
// (the runner finished first or alone), no commit seen, or no signal from another finisher, the
// server gave no verdict, and the client backup sends the client's own view.
//
// The signals, read from other finishers' score records before the commit: round points that differ
// from the runner's sample, or PrevRaceTimes written since they were racing (it can still hold an
// earlier round's times, so being non-empty isn't enough).
//
// A runner who finishes first or alone can't have been timed out: the finish timeout only starts
// after the first validated finish. Known limitations: in a mode that doesn't fill PrevRaceTimes and
// gives some finishers the same round points as non-finishers, a late runner finish that scores that
// value is sent as a DNF; and in a mode that changes non-finishers' round points before the commit,
// a rejected runner finish is counted.
class ServerVerdictOnOwnFinish {
    // Wait this long after the first other finish before sampling, so the server's update has reached this client.
    uint SampleDelayMs = 500;
    uint firstOtherFinishAt = 0;
    // The runner's score record while still racing: this round's "not finished" values
    // (observed: 0 round points in Throttle Cup, -20 in Throttle reverse cup).
    bool haveSample = false;
    int sampledRoundPoints = 0;
    string sampledPreviousRaceTimes;
    // Other players' PrevRaceTimes when first seen racing this round, by RunKey.
    dictionary previousRaceTimesWhileRacing;
    // The signals this round's other finishers showed.
    bool roundPointsSignal = false;
    bool previousRaceTimesSignal = false;
    // Whether a server confirmation was seen before the score commit.
    bool serverConfirmed = false;
    string noVerdictReason;

    // WatchRace samples the runner's "not finished" values while they're still racing, every frame while the round is Active.
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

    // WatchEndOfRound looks for the server's confirmation of the runner's finish, every frame of the end-of-round wait.
    void WatchEndOfRound(RoundTracker@ round) {
        WatchOtherPlayers(round);
        // A sample was taken from the runner's run in this round, so the runner is in it.
        if (!haveSample || serverConfirmed) return;
        auto score = GetServerScore(round.pluginRunnerEntry.player);
        if (score !is null) serverConfirmed = ServerConfirms(score.RoundPoints, PreviousRaceTimesText(score));
    }

    // WatchOtherPlayers notes the first other finish, other players' PrevRaceTimes when first seen racing, and once there's a sample, the signals finishers show.
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

    // LearnFromFinisher notes the signals one other finisher's score record shows.
    void LearnFromFinisher(int roundPoints, const string &in previousRaceTimesWhileRacing, const string &in previousRaceTimes) {
        if (roundPoints != sampledRoundPoints) roundPointsSignal = true;
        if (previousRaceTimes.Length > 0 && previousRaceTimes != previousRaceTimesWhileRacing) previousRaceTimesSignal = true;
    }

    // ServerConfirms reports whether the runner's score record, holding these values, confirms a finish through a signal this round showed.
    bool ServerConfirms(int roundPoints, const string &in previousRaceTimes) {
        // Round points of 0 are the commit resetting them, not a confirmation; PrevRaceTimes can still hold an earlier round's times.
        return (roundPointsSignal && roundPoints != sampledRoundPoints && roundPoints != 0)
            || (previousRaceTimesSignal && previousRaceTimes.Length > 0 && previousRaceTimes != sampledPreviousRaceTimes);
    }

    // Decide returns the server's verdict once the end-of-round wait is over; for None, noVerdictReason says why.
    ServerVerdict Decide(bool scoreCommitSeen) {
        if (serverConfirmed) return ServerVerdict::Confirmed;
        if (!haveSample) noVerdictReason = "no sample: the plugin runner finished first, alone, or within 500 ms of the first other finish";
        else if (!roundPointsSignal && !previousRaceTimesSignal) noVerdictReason = "no finish signal from this round's other finishers";
        else if (!scoreCommitSeen) noVerdictReason = "the server's score commit wasn't seen";
        else return ServerVerdict::Rejected;
        return ServerVerdict::None;
    }
}

// RunKey identifies a player's run, for values remembered per run.
string RunKey(RoundEntry@ entry) {
    return entry.player.Login + "/" + entry.runStartTime;
}
