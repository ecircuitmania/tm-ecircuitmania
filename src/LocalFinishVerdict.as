// LocalFinishVerdict decides, for one round, whether the plugin runner's own finish counts.
// Only the runner's finish needs this; see "Where round results come from" in RoundTracker.as.
//
// The rule: sample the runner's round points (and the PrevRaceTimes snapshot) while they're still
// racing, at least 500 ms after the first other finish. At the end of the wait, if MLFeed shows the
// runner finished and a sample exists, the finish counts only if a server confirmation was seen
// before the commit (round points moved off the sample and not 0, or PrevRaceTimes changed);
// otherwise mark it a DNF. Keep MLFeed's view when there's no sample (the runner finished first or
// alone) or when no commit was seen.
//
// A runner who finishes first or alone can't have been timed out: the finish timeout only starts
// after the first validated finish. Known limitation: in a mode that doesn't fill PrevRaceTimes and
// gives some finishers the same round points as non-finishers, a late runner finish that scores that
// value is sent as a DNF.
class LocalFinishVerdict {
    // Wait this long after the first other finish before sampling, so the server's update has reached this client.
    uint SampleDelayMs = 500;
    // The runner's run that the sample belongs to.
    uint runStartTime = 0;
    uint firstOtherFinishAt = 0;
    // The runner's score record while still racing: this round's "not finished" values
    // (observed: 0 round points in Throttle Cup, -20 in Throttle reverse cup).
    bool haveSample = false;
    int sampledRoundPoints = 0;
    string sampledPreviousRaceTimes;
    // Whether a server confirmation was seen before the score commit.
    bool serverConfirmed = false;
    // The verdict: the finish MLFeed shows doesn't count, so the runner is sent as a DNF.
    bool rejected = false;

    // WatchRace samples the runner's "not finished" values while they're still racing, every frame while the round is Active.
    void WatchRace(RoundTracker@ roundTracker) {
        auto localEntry = roundTracker.localEntry;
        if (localEntry is null || !roundTracker.IsThisRound(localEntry)) return;
        if (localEntry.runStartTime != runStartTime) StartRun(localEntry.runStartTime);
        if (haveSample || localEntry.result.Finished) return;
        if (firstOtherFinishAt == 0) {
            if (roundTracker.OtherPlayerFinished()) firstOtherFinishAt = Time::Now;
            return;
        }
        if (Time::Now - firstOtherFinishAt < SampleDelayMs) return;
        auto score = GetServerScore(localEntry.player);
        if (score is null) return;
        sampledRoundPoints = score.RoundPoints;
        sampledPreviousRaceTimes = PreviousRaceTimesText(score);
        haveSample = true;
    }

    // WatchEndOfRound looks for the server's confirmation of the runner's finish, every frame of the end-of-round wait.
    void WatchEndOfRound(RoundTracker@ roundTracker) {
        auto localEntry = roundTracker.localEntry;
        if (!haveSample || serverConfirmed || localEntry is null || !roundTracker.IsThisRound(localEntry)) return;
        auto score = GetServerScore(localEntry.player);
        if (score is null) return;
        serverConfirmed = ServerConfirms(score.RoundPoints, PreviousRaceTimesText(score));
    }

    // ServerConfirms reports whether the runner's score record, holding these values, confirms a finish since the sample.
    bool ServerConfirms(int roundPoints, const string &in previousRaceTimes) {
        // Not 0 either: that's the commit resetting round points, not a confirmation.
        if (roundPoints != sampledRoundPoints && roundPoints != 0) return true;
        // PrevRaceTimes can still hold an earlier round's times, so it has to have changed.
        return previousRaceTimes.Length > 0 && previousRaceTimes != sampledPreviousRaceTimes;
    }

    // Decide records the verdict once the end-of-round wait is over.
    void Decide(bool scoreCommitSeen, bool finishShown) {
        rejected = scoreCommitSeen && finishShown && haveSample && !serverConfirmed;
    }

    // StartRun forgets an earlier run's evidence when the runner's run changes, as in a round restarted without an end.
    void StartRun(uint runStartTime) {
        this.runStartTime = runStartTime;
        firstOtherFinishAt = 0;
        haveSample = false;
        serverConfirmed = false;
    }
}
