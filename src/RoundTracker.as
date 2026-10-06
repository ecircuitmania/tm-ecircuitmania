// Two watchers, because a match is often recorded by one of its own players, and no spectators.
// RoundTracker reads every result from MLFeed. A client shows other players' cars only as the server
// relays them, so their results are the server's. The plugin runner's own car is this client's own
// simulation: the server corrects its times, but a finish that reached the server after the finish
// timeout isn't corrected, just not counted, so it still shows here. That decision only reaches this
// client through the runner's score record, as round points (it carries no times in the modes tested);
// ServerVerdictOnOwnFinish reads it.

class RoundTracker {
    // Set at EndRound.
    int number = 0;
    string mapUid;
    int64 timestamp = 0;
    // -1 until read. A later one means the round restarted without an end.
    int startTime = -1;
    string pluginRunnerLogin;
    // Can hold runs from earlier rounds; IsThisRound tells them apart.
    array<RoundEntry@> entries;
    uint[] entryLoginIds;
    RoundEntry@ pluginRunnerEntry;
    ServerVerdictOnOwnFinish@ serverVerdictOnOwnFinish = ServerVerdictOnOwnFinish();
    ServerVerdict ownFinishVerdict = ServerVerdict::None;
    bool clientBackupUsed = false;

    RoundTracker(const string &in pluginRunnerLogin) {
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
        return startTime >= 0 && runStart >= startTime;
    }

    bool IsThisRound(RoundEntry@ entry) {
        return StartedThisRound(entry.runStartTime);
    }

    bool PluginRunnerFinishShown() {
        return pluginRunnerEntry !is null && IsThisRound(pluginRunnerEntry) && pluginRunnerEntry.result.Finished;
    }

    void ApplyServerVerdictOnOwnFinish(bool scoreCommitSeen) {
        if (!PluginRunnerFinishShown()) return;
        ownFinishVerdict = serverVerdictOnOwnFinish.Decide(scoreCommitSeen);
        if (ownFinishVerdict == ServerVerdict::Rejected) pluginRunnerEntry.result.MaybeMarkDnf();
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
