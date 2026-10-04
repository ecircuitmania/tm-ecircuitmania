// Where round results come from: every player's result is read from MLFeed,
// and the server has the final say.
// - Other players: their checkpoint and finish times only reach this client
//   after the server has validated them, so MLFeed's view of them is the server's.
// - The plugin runner: this client records its own checkpoints and finish at once,
//   before the server has seen them, so MLFeed first shows a guess.
//   - Times: the game later corrects them to the server's. RoundEntry.ReadResult
//     re-reads until the server's score commit, so the corrected time is the one sent.
//   - The finish itself is never corrected: a finish the server rejected still
//     shows as one. It only counts if the server's score record (CSmArenaScore)
//     confirms it, through PrevRaceTimes or RoundPoints depending on the mode.
//     The score commit is spotted by round points being folded into the totals, so
//     in a mode without round points no commit is seen and the runner's finish is
//     always kept. See LocalFinishVerdict.

// RoundTracker follows one round from going Active until its report is sent: who drove in it, and their results.
// A run belongs to the round if it started at or after both the round's start as the server's rules give it
// (MLFeed's Rules_StartTime, read while the round is Active) and the map's previous end of round, which holds
// whatever the mode does with Rules_StartTime. Earlier runs, such as a spectator's last run, belong to earlier
// rounds. Nadeo's round modes spawn players with the mode's StartTime, so a round's runs should start exactly at
// Rules_StartTime; the roundStart and endRound dev traces log both, to check it.
class RoundTracker {
    // Set at EndRound, for the report: the round's number on this map, the map, and when it ended.
    int number = 0;
    string mapUid;
    int64 timestamp = 0;
    // MLFeed::GameTime at the map's previous end of round, 0 if none was seen.
    int previousEndRoundTime;
    // The round's Rules_StartTime, -1 until read while the round is Active. A later one means the round was
    // restarted without an end, so the runs before it no longer count.
    int startTime = -1;
    // Whether MLFeed showed anyone spawned, since the previous end of round, while the round was Active.
    bool driverSeen = false;
    string localLogin;
    // Everyone seen driving this round while it was Active, with their login IDs in entryLoginIds.
    // Runs later found to be from an earlier round stay listed, and IsThisRound tells them apart.
    array<RoundEntry@> entries;
    uint[] entryLoginIds;
    RoundEntry@ localEntry;
    LocalFinishVerdict localFinishVerdict;

    // RoundTracker starts tracking a round on a map whose previous end of round was at previousEndRoundTime.
    RoundTracker(int previousEndRoundTime, const string &in localLogin) {
        this.previousEndRoundTime = previousEndRoundTime;
        this.localLogin = localLogin;
    }

    // WatchRace adds everyone MLFeed shows driving this round and re-reads their results, every frame while the round is Active.
    void WatchRace(const MLFeed::HookRaceStatsEventsBase_V4@ raceData) {
        if (raceData.Rules_StartTime > startTime) {
            startTime = raceData.Rules_StartTime;
#if DEV
            DevTraceRoundStart(this, raceData);
#endif
        }
        for (uint i = 0; i < raceData.SortedPlayers_Race.Length; i++) {
            auto player = cast<MLFeed::PlayerCpInfo_V4>(raceData.SortedPlayers_Race[i]);
            if (player.IsSpawned && int(player.StartTime) >= previousEndRoundTime) driverSeen = true;
            // Only positive evidence of driving counts: spawned, or past a checkpoint, in a run that started with this round.
            bool driving = player.IsSpawned || player.CpCount > 0;
            if (!driving || !StartedThisRound(player.StartTime)) continue;
            int index = entryLoginIds.Find(player.LoginMwId.Value);
            if (index < 0) {
                RoundEntry@ newEntry = RoundEntry(player);
                entries.InsertLast(newEntry);
                entryLoginIds.InsertLast(player.LoginMwId.Value);
                if (player.Login == localLogin) @localEntry = newEntry;
                continue;
            }
            auto entry = entries[uint(index)];
            // A rejoin gets a new MLFeed object, and a round restarted without an end gets new runs.
            // A finish in this round is kept, even if the mode lets the player drive again before the end of round.
            bool newRun = entry.player !is player || entry.runStartTime != player.StartTime;
            if (newRun && !(IsThisRound(entry) && entry.result.Finished)) entry.StartRun(player);
        }
        for (uint i = 0; i < entries.Length; i++) {
            entries[i].ReadResult();
            // Only read while the round is Active, so the report sees who was spectating at EndRound.
            if (entries[i].RunIsCurrent) entries[i].spectating = entries[i].player.RequestsSpectate;
        }
    }

    // WatchEndOfRound re-reads results during the end-of-round wait, keeping the roster and spectators as they were at EndRound.
    void WatchEndOfRound() {
        for (uint i = 0; i < entries.Length; i++) entries[i].ReadResult();
    }

    // StartedThisRound reports whether a run with this MLFeed StartTime started with this round rather than an earlier one.
    bool StartedThisRound(uint runStartTime) {
        // MLFeed stores the game's signed start times as uint, so an unset -1 becomes the largest uint: compare as int.
        int runStart = int(runStartTime);
        return startTime >= 0 && runStart >= startTime && runStart >= previousEndRoundTime;
    }

    // IsThisRound reports whether the entry's run started with this round rather than an earlier one.
    bool IsThisRound(RoundEntry@ entry) {
        return StartedThisRound(entry.runStartTime);
    }

    // DriversLeftOut reports whether players drove this round but none of their runs counts for it, as when a mode's Rules_StartTime comes after its spawns.
    bool DriversLeftOut() {
        if (!driverSeen) return false;
        for (uint i = 0; i < entries.Length; i++) {
            if (IsThisRound(entries[i])) return false;
        }
        return true;
    }

    // LocalFinishShown reports whether MLFeed shows the plugin runner finishing this round.
    bool LocalFinishShown() {
        return localEntry !is null && IsThisRound(localEntry) && localEntry.result.Finished;
    }

    // OtherPlayerFinished reports whether MLFeed shows anyone but the plugin runner finishing this round.
    bool OtherPlayerFinished() {
        for (uint i = 0; i < entries.Length; i++) {
            if (entries[i] !is localEntry && IsThisRound(entries[i]) && entries[i].result.Finished) return true;
        }
        return false;
    }

    // RankedResults returns this round's drivers, ranked, with the server's verdict on the plugin runner's finish applied.
    array<RoundResult@>@ RankedResults() {
        array<RoundResult@> results;
        for (uint i = 0; i < entries.Length; i++) {
            auto entry = entries[i];
            if (!IsThisRound(entry)) continue;
            RoundResult@ result = entry.result;
            if (entry is localEntry && localFinishVerdict.rejected) {
                @result = result.Copy();
                result.MarkDnf();
            }
            // Switched to spectator before finishing: left out, which ECM counts as a DNF.
            if (entry.spectating && !result.Finished) continue;
            results.InsertLast(result);
        }
        SortRoundResults(results);
        return results;
    }
}

// RoundEntry is one player's run, as last read from MLFeed.
// MLFeed keeps one object per player and stops updating it when they leave, so a leaver keeps their
// last state: a finish if the server relayed it, otherwise a DNF at the checkpoints they reached.
class RoundEntry {
    const MLFeed::PlayerCpInfo_V4@ player;
    uint runStartTime;
    RoundResult@ result;
    bool spectating = false;

    // RoundEntry starts following the player's current run.
    RoundEntry(const MLFeed::PlayerCpInfo_V4@ player) {
        StartRun(player);
    }

    // StartRun switches to the player's current run, which the next ReadResult reads.
    void StartRun(const MLFeed::PlayerCpInfo_V4@ player) {
        @this.player = player;
        runStartTime = player.StartTime;
        @result = null;
    }

    // get_RunIsCurrent reports whether MLFeed still shows this run as the player's current one.
    bool get_RunIsCurrent() {
        return player.StartTime == runStartTime;
    }

    // ReadResult re-reads the run's result from MLFeed, never moving it backwards; a read with the same checkpoints but corrected times is taken.
    void ReadResult() {
        if (!RunIsCurrent) return;
        RoundResult@ latest = RoundResultFromPlayer(player);
        if (result !is null && MovesBackwards(result, latest)) {
#if DEV
            DevTraceIgnoredRead(this, latest);
#endif
            return;
        }
        @result = latest;
    }
}

// MovesBackwards reports whether a newer read of the same run undoes progress: fewer checkpoints, or a finish no longer counted.
// MLFeed's IsFinished depends on the map's checkpoint and lap counts, which it can change under a run already read.
bool MovesBackwards(const RoundResult@ kept, const RoundResult@ latest) {
    return latest.cpTimes.Length < kept.cpTimes.Length || (kept.Finished && !latest.Finished);
}
