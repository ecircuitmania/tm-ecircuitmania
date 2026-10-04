// RoundTracker follows one round from going Active until its report is sent:
// who took part, and what the server said about the plugin runner's own finish.
class RoundTracker {
    // Set when the round ends, so the report can't pick up the next round's values.
    int number = 0;
    string mapUid;
    // Runs that started before this game time are leftovers (e.g. from warmup) and don't count.
    uint startGameTime;
    string localLogin;
    // Everyone who raced this round, by login.
    array<RoundEntry@> entries;
    uint[] entryLoginIds;
    RoundEntry@ localEntry;
    LocalFinishCheck localFinish;

    // RoundTracker starts tracking a round whose runs start at or after startGameTime.
    RoundTracker(uint startGameTime, const string &in localLogin, ServerFinishSignals@ finishSignals) {
        this.startGameTime = startGameTime;
        this.localLogin = localLogin;
        @localFinish.signals = finishSignals;
    }

    // Track adds every player racing this round and re-reads every result. Call every frame while the round is Active.
    void Track(const MLFeed::HookRaceStatsEventsBase_V4@ raceData) {
        for (uint i = 0; i < raceData.SortedPlayers_Race.Length; i++) {
            auto player = cast<MLFeed::PlayerCpInfo_V4>(raceData.SortedPlayers_Race[i]);
            // Not past the start yet, or a run from before this round.
            if (player.CpCount == 0 || player.StartTime < startGameTime) continue;
            int index = entryLoginIds.Find(player.LoginMwId.Value);
            if (index < 0) {
                RoundEntry@ entry = RoundEntry(player);
                entries.InsertLast(entry);
                entryLoginIds.InsertLast(player.LoginMwId.Value);
                if (player.Login == localLogin) @localEntry = entry;
            } else if (entries[uint(index)].player !is player || entries[uint(index)].runStartTime != player.StartTime) {
                // A rejoin gets a new MLFeed object; a restart gets a new start time.
                entries[uint(index)].StartRun(player);
            }
        }
        RefreshEntries();
        localFinish.Track(localEntry, entries);
    }

    // Refresh re-reads the runs already tracked, without taking new ones. Call every frame after the round has ended.
    void Refresh() {
        RefreshEntries();
        localFinish.Watch(localEntry, entries);
    }

    // RefreshEntries re-reads every entry's result from MLFeed.
    void RefreshEntries() {
        for (uint i = 0; i < entries.Length; i++) entries[i].Refresh();
    }

    // RankedResults returns everyone who took part, ranked, with the server's verdict applied to the plugin runner's own result.
    array<RoundResult@>@ RankedResults(ServerVerdict verdict) {
        array<RoundResult@> results;
        for (uint i = 0; i < entries.Length; i++) {
            auto entry = entries[i];
            RoundResult@ result = entry.result;
            if (entry is localEntry) {
                if (verdict == ServerVerdict::Finished && !result.Finished) {
                    warn("Local finish confirmed by server but no longer shown locally; using the first-seen time " + localFinish.firstSeenFinish.finishTime);
                }
                @result = ApplyServerVerdict(result, localFinish.firstSeenFinish, verdict);
            }
            // Gave up to spectate before finishing.
            if (entry.spectating && !result.Finished) continue;
            results.InsertLast(result);
        }
        SortRoundResults(results);
        return results;
    }
}

// RoundEntry is one player's run in a round, with its result as last read while that run was current.
// MLFeed keeps one object per player and stops updating it when the player leaves,
// so a player who left keeps the last state we read: their finish if the server
// had relayed it, otherwise a DNF ranked by the checkpoints they reached.
class RoundEntry {
    const MLFeed::PlayerCpInfo_V4@ player;
    uint runStartTime;
    RoundResult@ result;
    bool spectating = false;

    // RoundEntry starts tracking the player's current run.
    RoundEntry(const MLFeed::PlayerCpInfo_V4@ player) {
        StartRun(player);
    }

    // StartRun switches to the player's current run.
    void StartRun(const MLFeed::PlayerCpInfo_V4@ player) {
        @this.player = player;
        runStartTime = player.StartTime;
        Refresh();
    }

    // Refresh re-reads the result while this run is still the player's current one.
    // Once the player starts another run (the next round) we keep what we last read.
    void Refresh() {
        if (player.StartTime != runStartTime) return;
        @result = RoundResultFromPlayer(player);
        spectating = player.RequestsSpectate;
    }
}

// LocalFinishCheck decides whether the server counted the plugin runner's own finish.
// This client shows its own finish before the server has validated it. With a bad
// connection the server can still reject it as a timeout, or validate it only after
// the round has ended here. Other players' finishes only reach this client once the
// server has validated them, so they need no check.
class LocalFinishCheck {
    ServerFinishSignals@ signals;
    // Wait this long after the first other finish before reading the "not
    // finished" value, so the server's update has reached this client.
    uint UnfinishedRoundPointsDelayMs = 500;
    uint firstOtherFinishAt = 0;
    // The plugin runner's round points while still racing, read shortly after the
    // first other finish: the server's "not finished" value for this round (e.g. 0
    // in Cup, -20 in reverse cup).
    bool haveUnfinishedRoundPoints = false;
    int unfinishedRoundPoints = 0;
    // The plugin runner's result when this client first showed their finish.
    RoundResult@ firstSeenFinish;
    // Whether the server confirmed that finish before its end-of-round score commit.
    bool serverConfirmed = false;

    // Track notes the plugin runner's finish and learns this round's "not finished" value. Call every frame while Active.
    void Track(RoundEntry@ localEntry, array<RoundEntry@>@ entries) {
        if (localEntry is null || NoteFinish(localEntry)) return;
        if (haveUnfinishedRoundPoints) return;
        if (firstOtherFinishAt == 0) {
            for (uint i = 0; i < entries.Length; i++) {
                if (entries[i] is localEntry || !entries[i].result.Finished) continue;
                firstOtherFinishAt = Time::Now;
                break;
            }
            return;
        }
        if (Time::Now - firstOtherFinishAt < UnfinishedRoundPointsDelayMs) return;
        auto score = GetServerScore(localEntry.player);
        if (score is null) return;
        unfinishedRoundPoints = score.RoundPoints;
        haveUnfinishedRoundPoints = true;
    }

    // Watch looks for the server's confirmation of the plugin runner's finish. Call every frame after the round has ended, until the score commit.
    void Watch(RoundEntry@ localEntry, array<RoundEntry@>@ entries) {
        if (localEntry is null) return;
        // The finish can first show up here when it lands on the frame the round ends.
        NoteFinish(localEntry);
        // Without the "not finished" value a confirmation can't be told apart.
        if (!haveUnfinishedRoundPoints) return;
        LearnSignals(localEntry, entries);
        if (firstSeenFinish !is null && !serverConfirmed) serverConfirmed = ServerConfirmedFinish(localEntry);
    }

    // NoteFinish records the plugin runner's result the first time it shows a finish, and reports whether one has been seen.
    bool NoteFinish(RoundEntry@ localEntry) {
        if (firstSeenFinish is null && localEntry.result.Finished) @firstSeenFinish = localEntry.result;
        return firstSeenFinish !is null;
    }

    // LearnSignals learns how this mode shows a validated finish, from the other finishers' score records.
    void LearnSignals(RoundEntry@ localEntry, array<RoundEntry@>@ entries) {
        for (uint i = 0; i < entries.Length; i++) {
            if (entries[i] is localEntry || !entries[i].result.Finished) continue;
            auto score = GetServerScore(entries[i].player);
            if (score is null) continue;
            if (score.PrevRaceTimes.Length > 0) signals.prevRaceTimes = true;
            if (score.RoundPoints != unfinishedRoundPoints) signals.roundPoints = true;
        }
    }

    // ServerConfirmedFinish reports whether the plugin runner's score record shows the finish. Only meaningful before the score commit.
    bool ServerConfirmedFinish(RoundEntry@ localEntry) {
        auto score = GetServerScore(localEntry.player);
        if (score is null) return false;
        if (signals.prevRaceTimes && score.PrevRaceTimes.Length > 0) return true;
        // Not 0 either: that's the commit resetting round points, not a confirmation.
        return signals.roundPoints && score.RoundPoints != unfinishedRoundPoints && score.RoundPoints != 0;
    }

    // Verdict returns the server's verdict on the plugin runner's finish, given whether the score commit was seen.
    ServerVerdict Verdict(bool committed) {
        if (!committed || firstSeenFinish is null || !haveUnfinishedRoundPoints || !signals.AnySeen) return ServerVerdict::Unknown;
        return serverConfirmed ? ServerVerdict::Finished : ServerVerdict::Dnf;
    }
}

// ApplyServerVerdict returns the plugin runner's result with the server's verdict on their finish applied, leaving its inputs unchanged.
RoundResult@ ApplyServerVerdict(RoundResult@ shown, RoundResult@ firstSeenFinish, ServerVerdict verdict) {
    if (verdict == ServerVerdict::Dnf) {
        RoundResult@ dnf = RoundResult(shown.webServicesUserId, shown.name, shown.finishTime, shown.cpTimes, shown.points);
        dnf.roundPoints = shown.roundPoints;
        dnf.MaybeMarkDnf();
        return dnf;
    } else if (verdict == ServerVerdict::Finished && !shown.Finished && firstSeenFinish !is null) {
        // The run as first shown still ends with its finish crossing.
        return firstSeenFinish;
    }
    return shown;
}
