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
    traceData["round"] = monitor.currentRound;
    DevTrace("state", traceData);
    DevNotify(tostring(newState) + ", prior: " + tostring(previousState));
}

// DevTraceRoundReport logs how a round's report was decided, and what was sent.
void DevTraceRoundReport(RaceMonitor@ monitor, RoundTracker@ round, bool committed, ServerVerdict verdict, array<RoundResult@>@ rankedResults, Json::Value@ payload) {
    auto traceData = Json::Object();
    traceData["round"] = round.number;
    traceData["scoreCommitSeen"] = committed;
    traceData["stateAfterWait"] = tostring(monitor.currentState);
    traceData["stillMonitoring"] = g_monitor is monitor;
    traceData["localVerdict"] = tostring(verdict);

    auto localFinish = Json::Object();
    localFinish["firstSeenFinishTime"] = round.localFinish.firstSeenFinish is null ? -1 : round.localFinish.firstSeenFinish.finishTime;
    localFinish["haveUnfinishedRoundPoints"] = round.localFinish.haveUnfinishedRoundPoints;
    localFinish["unfinishedRoundPoints"] = round.localFinish.unfinishedRoundPoints;
    localFinish["serverConfirmed"] = round.localFinish.serverConfirmed;
    localFinish["roundPointsSignal"] = round.localFinish.signals.roundPoints;
    localFinish["prevRaceTimesSignal"] = round.localFinish.signals.prevRaceTimes;
    if (round.localEntry !is null) localFinish["local"] = DevPlayerJson(round.localEntry.player);
    traceData["localFinish"] = localFinish;

    auto ranked = Json::Array();
    for (uint i = 0; i < rankedResults.Length; i++) {
        auto rankedEntry = Json::Object();
        rankedEntry["position"] = int(i + 1);
        rankedEntry["name"] = rankedResults[i].name;
        rankedEntry["finishTime"] = rankedResults[i].finishTime;
        rankedEntry["roundPoints"] = rankedResults[i].roundPoints;
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
        string prevRaceTimes = "";
        for (uint timeIndex = 0; timeIndex < score.PrevRaceTimes.Length; timeIndex++) {
            prevRaceTimes += (timeIndex > 0 ? "," : "") + score.PrevRaceTimes[timeIndex];
        }
        string summary = "[" + prevRaceTimes + "] roundPoints=" + score.RoundPoints;
        string lastSummary;
        if (devScoresSeen.Get(player.Login, lastSummary) && lastSummary == summary) continue;
        devScoresSeen[player.Login] = summary;
        auto traceData = Json::Object();
        traceData["round"] = monitor.currentRound;
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
    traceData["startTime"] = player.StartTime;
    traceData["raceRank"] = player.RaceRank;
    traceData["roundPoints"] = player.RoundPoints;
    traceData["points"] = player.Points;
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
    auto prevRaceTimes = Json::Array();
    for (uint i = 0; i < score.PrevRaceTimes.Length; i++) prevRaceTimes.Add(score.PrevRaceTimes[i]);
    traceData["serverPrevRaceTimes"] = prevRaceTimes;
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
