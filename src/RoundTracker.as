// Other players' results only reach this client once the server has validated them. The plugin runner's
// own are the client's guess: the server later corrects their times, but not a finish it rejected, which
// ServerVerdictOnOwnFinish settles from the score records.

// A run belongs to the round if it started at or after both the round's Rules_StartTime and the map's
// previous end of round, whatever the mode does with Rules_StartTime.
class RoundTracker {
    // Set at EndRound.
    int number = 0;
    string mapUid;
    int64 timestamp = 0;
    int previousEndRoundTime;
    // -1 until read. A later one means the round restarted without an end.
    int startTime = -1;
    bool driverSeen = false;
    string pluginRunnerLogin;
    // Can hold runs from earlier rounds; IsThisRound tells them apart.
    array<RoundEntry@> entries;
    uint[] entryLoginIds;
    RoundEntry@ pluginRunnerEntry;
    ServerVerdictOnOwnFinish@ serverVerdictOnOwnFinish = ServerVerdictOnOwnFinish();
    ServerVerdict ownFinishVerdict = ServerVerdict::None;
    bool clientBackupUsed = false;

    RoundTracker(int previousEndRoundTime, const string &in pluginRunnerLogin) {
        this.previousEndRoundTime = previousEndRoundTime;
        this.pluginRunnerLogin = pluginRunnerLogin;
    }

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
            // Only positive evidence of driving counts, so spectators stay out.
            bool driving = player.IsSpawned || player.CpCount > 0;
            if (!driving || !StartedThisRound(player.StartTime)) continue;
            int index = entryLoginIds.Find(player.LoginMwId.Value);
            if (index < 0) {
                RoundEntry@ newEntry = RoundEntry(player);
                entries.InsertLast(newEntry);
                entryLoginIds.InsertLast(player.LoginMwId.Value);
                if (player.Login == pluginRunnerLogin) @pluginRunnerEntry = newEntry;
                continue;
            }
            auto entry = entries[uint(index)];
            // A rejoin or a restarted round means a new run, but a finish in this round is kept.
            bool newRun = entry.player !is player || entry.runStartTime != player.StartTime;
            if (!newRun || (IsThisRound(entry) && entry.result.Finished)) continue;
            entry.StartRun(player);
            // The server's evidence belongs to one run of the plugin runner.
            if (entry is pluginRunnerEntry) @serverVerdictOnOwnFinish = ServerVerdictOnOwnFinish();
        }
        for (uint i = 0; i < entries.Length; i++) {
            entries[i].ReadResult();
            // Only read while the round is Active, so the report sees who was spectating at EndRound.
            if (entries[i].RunIsCurrent) entries[i].spectating = entries[i].player.RequestsSpectate;
        }
    }

    void WatchEndOfRound() {
        for (uint i = 0; i < entries.Length; i++) entries[i].ReadResult();
    }

    bool StartedThisRound(uint runStartTime) {
        // MLFeed stores the game's signed start times as uint, so an unset -1 becomes the largest uint: compare as int.
        int runStart = int(runStartTime);
        return startTime >= 0 && runStart >= startTime && runStart >= previousEndRoundTime;
    }

    bool IsThisRound(RoundEntry@ entry) {
        return StartedThisRound(entry.runStartTime);
    }

    bool DriversLeftOut() {
        if (!driverSeen) return false;
        for (uint i = 0; i < entries.Length; i++) {
            if (IsThisRound(entries[i])) return false;
        }
        return true;
    }

    bool PluginRunnerFinishShown() {
        return pluginRunnerEntry !is null && IsThisRound(pluginRunnerEntry) && pluginRunnerEntry.result.Finished;
    }

    void ApplyServerVerdictOnOwnFinish(bool scoreCommitSeen) {
        if (!PluginRunnerFinishShown()) return;
        ownFinishVerdict = serverVerdictOnOwnFinish.Decide(scoreCommitSeen);
        if (ownFinishVerdict == ServerVerdict::Rejected) pluginRunnerEntry.result.MarkDnf();
        if (ownFinishVerdict == ServerVerdict::None) UseClientBackup(serverVerdictOnOwnFinish.noVerdictReason);
    }

    void UseClientBackup(const string &in reason) {
        clientBackupUsed = true;
        print("Round " + number + ": client backup used for the plugin runner's finish, as the server gave no verdict (" + reason + ").");
    }

    array<RoundResult@>@ RankedResults() {
        array<RoundResult@> results;
        for (uint i = 0; i < entries.Length; i++) {
            auto entry = entries[i];
            if (!IsThisRound(entry)) continue;
            // Switched to spectator before finishing: left out, which ECM counts as a DNF.
            if (entry.spectating && !entry.result.Finished) continue;
            results.InsertLast(entry.result);
        }
        SortRoundResults(results);
        return results;
    }
}

// MLFeed stops updating a player who leaves, so a leaver keeps their last state.
class RoundEntry {
    const MLFeed::PlayerCpInfo_V4@ player;
    uint runStartTime;
    RoundResult@ result;
    bool spectating = false;

    RoundEntry(const MLFeed::PlayerCpInfo_V4@ player) {
        StartRun(player);
    }

    void StartRun(const MLFeed::PlayerCpInfo_V4@ player) {
        @this.player = player;
        runStartTime = player.StartTime;
        @result = null;
    }

    bool get_RunIsCurrent() {
        return player.StartTime == runStartTime;
    }

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

// MLFeed's IsFinished depends on the map's checkpoint and lap counts, which it can change under a run already read.
bool MovesBackwards(const RoundResult@ kept, const RoundResult@ latest) {
    return latest.cpTimes.Length < kept.cpTimes.Length || (kept.Finished && !latest.Finished);
}
