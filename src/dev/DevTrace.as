// Dev-only tracing.
// Every line is printed to Openplanet.log prefixed with [ECMTRACE] as one JSON object.
//
// Never shipped: the release workflow leaves src/dev/ out of the package, so
// call anything declared here only from inside an #if DEV block.
#if DEV

// DevTrace prints one trace event to Openplanet.log as a JSON line.
void DevTrace(const string &in eventName, Json::Value@ data) {
    data["event"] = eventName;
    data["now"] = Time::Now;
    data["gameTime"] = MLFeed::GameTime;
    print("[ECMTRACE] " + Json::Write(data));
}

// DevNotify shows a notification and logs it.
void DevNotify(const string &in message) {
    UI::ShowNotification(Meta::ExecutingPlugin().Name, message);
    trace("Notified: " + message);
}

[Setting category="Dev" name="Dry run (never send HTTP requests)"]
bool S_DevDryRun = true;

// DevDryRun reports whether a request should be skipped instead of sent to ECM, and logs it if so.
bool DevDryRun(const string &in url, const string &in payload) {
    if (S_DevDryRun) {
        print("DRY RUN, not sent: " + url);
        print("Payload: " + payload);
        return true;
    }
    return false;
}

// DevTraceState logs a race state change and shows it as a notification.
void DevTraceState(RaceMonitor@ monitor, RaceState previousState, RaceState newState) {
    auto traceData = DevRaceJson();
    traceData["from"] = tostring(previousState);
    traceData["to"] = tostring(newState);
    traceData["roundsEnded"] = mapRoundsEnded;
    DevTrace("state", traceData);
    DevNotify(tostring(newState) + ", prior: " + tostring(previousState));
}

// DevTraceRoundStart logs the round's new Rules_StartTime next to every listed player's StartTime and spawn status.
void DevTraceRoundStart(RoundTracker@ roundTracker, const MLFeed::HookRaceStatsEventsBase_V4@ raceData) {
    auto traceData = Json::Object();
    traceData["roundsEnded"] = mapRoundsEnded;
    traceData["rulesStartTime"] = roundTracker.startTime;
    traceData["previousEndRoundTime"] = roundTracker.previousEndRoundTime;
    auto players = Json::Array();
    for (uint i = 0; i < raceData.SortedPlayers_Race.Length; i++) {
        players.Add(DevRunJson(cast<MLFeed::PlayerCpInfo_V4>(raceData.SortedPlayers_Race[i])));
    }
    traceData["players"] = players;
    DevTrace("roundStart", traceData);
}

// DevTraceEndRound logs the round's Rules_StartTime next to each roster entry and each listed player left out of the roster, before the commit.
void DevTraceEndRound(RoundTracker@ roundTracker) {
    auto traceData = Json::Object();
    traceData["round"] = roundTracker.number;
    traceData["rulesStartTime"] = roundTracker.startTime;
    traceData["previousEndRoundTime"] = roundTracker.previousEndRoundTime;
    traceData["driverSeen"] = roundTracker.driverSeen;
    traceData["driversLeftOut"] = roundTracker.DriversLeftOut();
    auto roster = Json::Array();
    for (uint i = 0; i < roundTracker.entries.Length; i++) {
        auto entry = roundTracker.entries[i];
        auto entryData = DevPlayerJson(entry.player);
        entryData["runStartTime"] = int(entry.runStartTime);
        entryData["thisRound"] = roundTracker.IsThisRound(entry);
        entryData["spectatingAtEndRound"] = entry.spectating;
        roster.Add(entryData);
    }
    traceData["roster"] = roster;
    // A driver of this round listed here was left out, e.g. because their run started before Rules_StartTime.
    auto notInRoster = Json::Array();
    auto raceData = MLFeed::GetRaceData_V4();
    for (uint i = 0; i < raceData.SortedPlayers_Race.Length; i++) {
        auto player = cast<MLFeed::PlayerCpInfo_V4>(raceData.SortedPlayers_Race[i]);
        if (roundTracker.entryLoginIds.Find(player.LoginMwId.Value) < 0) notInRoster.Add(DevRunJson(player));
    }
    traceData["notInRoster"] = notInRoster;
    DevTrace("endRound", traceData);
}

// DevRunJson describes a player's current run as MLFeed shows it: StartTime, spawn status, checkpoints and spectating.
Json::Value@ DevRunJson(const MLFeed::PlayerCpInfo_V4@ player) {
    auto traceData = Json::Object();
    traceData["name"] = player.Name;
    traceData["startTime"] = int(player.StartTime);
    traceData["spawnStatus"] = tostring(player.SpawnStatus);
    traceData["cpCount"] = player.CpCount;
    traceData["requestsSpectate"] = player.RequestsSpectate;
    return traceData;
}

// DevTraceRoundDropped logs a round in progress that was dropped without being reported, and why.
void DevTraceRoundDropped(RoundTracker@ roundTracker, const string &in reason) {
    auto traceData = Json::Object();
    traceData["roundsEnded"] = mapRoundsEnded;
    traceData["rulesStartTime"] = roundTracker.startTime;
    traceData["reason"] = reason;
    DevTrace("roundDropped", traceData);
}

dictionary devIgnoredReadsLogged;

// DevTraceIgnoredRead logs, once per run, a read of MLFeed that would have moved a result backwards.
void DevTraceIgnoredRead(RoundEntry@ entry, RoundResult@ ignored) {
    string key = entry.player.Login + "/" + entry.runStartTime;
    if (devIgnoredReadsLogged.Exists(key)) return;
    devIgnoredReadsLogged[key] = true;
    auto traceData = DevPlayerJson(entry.player);
    traceData["keptCpCount"] = entry.result.cpTimes.Length;
    traceData["keptFinishTime"] = entry.result.finishTime;
    traceData["ignoredCpCount"] = ignored.cpTimes.Length;
    traceData["ignoredFinishTime"] = ignored.finishTime;
    DevTrace("ignoredRead", traceData);
}

// DevTraceRoundReport logs how the round's report was decided, and what was sent.
void DevTraceRoundReport(RaceMonitor@ monitor, RoundTracker@ roundTracker, bool scoreCommitSeen, array<RoundResult@>@ rankedResults, Json::Value@ payload) {
    auto traceData = Json::Object();
    traceData["round"] = roundTracker.number;
    traceData["rulesStartTime"] = roundTracker.startTime;
    traceData["scoreCommitSeen"] = scoreCommitSeen;
    traceData["stateAfterWait"] = tostring(monitor.currentState);
    traceData["stillMonitoring"] = raceMonitor is monitor;

    auto verdict = Json::Object();
    verdict["finishShown"] = roundTracker.LocalFinishShown();
    verdict["haveSample"] = roundTracker.localFinishVerdict.haveSample;
    verdict["sampledRoundPoints"] = roundTracker.localFinishVerdict.sampledRoundPoints;
    verdict["sampledPreviousRaceTimes"] = roundTracker.localFinishVerdict.sampledPreviousRaceTimes;
    verdict["roundPointsSignal"] = roundTracker.localFinishVerdict.roundPointsSignal;
    verdict["previousRaceTimesSignal"] = roundTracker.localFinishVerdict.previousRaceTimesSignal;
    verdict["serverConfirmed"] = roundTracker.localFinishVerdict.serverConfirmed;
    verdict["rejected"] = roundTracker.localFinishVerdict.rejected;
    if (roundTracker.localEntry !is null) verdict["local"] = DevPlayerJson(roundTracker.localEntry.player);
    traceData["localFinish"] = verdict;

    auto roster = Json::Array();
    for (uint i = 0; i < roundTracker.entries.Length; i++) {
        auto entry = roundTracker.entries[i];
        auto entryData = Json::Object();
        entryData["name"] = entry.player.Name;
        entryData["runStartTime"] = int(entry.runStartTime);
        entryData["thisRound"] = roundTracker.IsThisRound(entry);
        entryData["spectatingAtEndRound"] = entry.spectating;
        entryData["cpCount"] = entry.result.cpTimes.Length;
        entryData["finishTime"] = entry.result.finishTime;
        roster.Add(entryData);
    }
    traceData["roster"] = roster;

    auto ranked = Json::Array();
    for (uint i = 0; i < rankedResults.Length; i++) {
        auto rankedEntry = Json::Object();
        rankedEntry["position"] = int(i + 1);
        rankedEntry["name"] = rankedResults[i].name;
        rankedEntry["finishTime"] = rankedResults[i].finishTime;
        rankedEntry["cpCount"] = rankedResults[i].cpTimes.Length;
        ranked.Add(rankedEntry);
    }
    traceData["ranked"] = ranked;
    traceData["payload"] = payload;
    DevTrace("roundReport", traceData);
}

dictionary devScoresSeen;

// DevWatchScores logs every change to a player's server-synced score (PrevRaceTimes, RoundPoints) with the monitor state at that moment.
void DevWatchScores(RaceMonitor@ monitor) {
    auto raceData = MLFeed::GetRaceData_V4();
    for (uint i = 0; i < raceData.SortedPlayers_Race.Length; i++) {
        auto player = cast<MLFeed::PlayerCpInfo_V4>(raceData.SortedPlayers_Race[i]);
        auto score = GetServerScore(player);
        if (score is null) continue;
        string summary = "[" + PreviousRaceTimesText(score) + "] roundPoints=" + score.RoundPoints;
        string lastSummary;
        if (devScoresSeen.Get(player.Login, lastSummary) && lastSummary == summary) continue;
        devScoresSeen[player.Login] = summary;
        auto traceData = Json::Object();
        traceData["roundsEnded"] = mapRoundsEnded;
        traceData["state"] = tostring(monitor.currentState);
        traceData["name"] = player.Name;
        traceData["score"] = summary;
        traceData["mlFeed"] = "" + player.CpCount + " checkpoints, last at " + player.LastCpTime + (player.IsFinished ? ", finished" : "");
        DevTrace("scoreChange", traceData);
    }
}

// DevPlayerJson describes MLFeed's view of a player next to their server-synced score record.
Json::Value@ DevPlayerJson(const MLFeed::PlayerCpInfo_V4@ player) {
    auto traceData = Json::Object();
    traceData["login"] = player.Login;
    traceData["name"] = player.Name;
    traceData["webServicesUserId"] = player.WebServicesUserId;
    traceData["cpCount"] = player.CpCount;
    traceData["lastCpTime"] = player.LastCpTime;
    traceData["isFinished"] = player.IsFinished;
    traceData["spawnStatus"] = tostring(player.SpawnStatus);
    traceData["startTime"] = int(player.StartTime);
    traceData["raceRank"] = player.RaceRank;
    traceData["mlFeedRoundPoints"] = player.RoundPoints;
    traceData["mlFeedPoints"] = player.Points;
    traceData["requestsSpectate"] = player.RequestsSpectate;
    auto cpTimes = Json::Array();
    auto feedCpTimes = player.CpTimes;
    for (uint i = 0; i < feedCpTimes.Length; i++) cpTimes.Add(feedCpTimes[i]);
    traceData["cpTimes"] = cpTimes;
    // The server-synced score, which the in-game scoreboard reads.
    auto score = GetServerScore(player);
    if (score is null) {
        traceData["serverScoreMissing"] = true;
        return traceData;
    }
    traceData["serverRoundPoints"] = score.RoundPoints;
    traceData["serverPoints"] = score.Points;
    traceData["serverPreviousRaceTimes"] = PreviousRaceTimesText(score);
    auto bestRaceTimes = Json::Array();
    for (uint i = 0; i < score.BestRaceTimes.Length; i++) bestRaceTimes.Add(score.BestRaceTimes[i]);
    traceData["serverBestRaceTimes"] = bestRaceTimes;
    return traceData;
}

// DevRaceJson describes MLFeed's race-wide values and the UI sequence.
Json::Value@ DevRaceJson() {
    auto raceData = MLFeed::GetRaceData_V4();
    auto traceData = Json::Object();
    traceData["rulesStartTime"] = raceData.Rules_StartTime;
    traceData["rulesEndTime"] = raceData.Rules_EndTime;
    traceData["rulesGameTime"] = raceData.Rules_GameTime;
    traceData["warmup"] = raceData.WarmupActive;
    traceData["cpCount"] = raceData.CpCount;
    traceData["lapCount"] = raceData.LapCount;
    traceData["lapsNumber"] = raceData.LapsNb;
    traceData["cpsToFinish"] = raceData.CPsToFinish;
    traceData["map"] = mapUid;
    auto game = cast<CGameManiaPlanet>(GetApp());
    if (game.CurrentPlayground !is null && game.CurrentPlayground.GameTerminals.Length > 0) {
        traceData["uiSequence"] = tostring(game.CurrentPlayground.GameTerminals[0].UISequence_Current);
    }
    return traceData;
}
#endif
