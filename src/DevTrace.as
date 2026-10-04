// Dev-only tracing.
// Every line is printed to Openplanet.log prefixed with [ECMTRACE] as one JSON object.
//
// Never shipped: the release workflow leaves this file out of the package, so
// call anything declared here only from inside an #if DEV block.
#if DEV

void DevTrace(const string&in ev, Json::Value@ data) {
    data["ev"] = ev;
    data["now"] = Time::Now;
    data["gt"] = MLFeed::GameTime;
    print("[ECMTRACE] " + Json::Write(data));
}

[Setting category="Dev" name="Dry run (never send HTTP requests)"]
bool S_DevDryRun = true;

// True when the request should be skipped instead of sent to ECM.
bool DevDryRun(const string&in url, const string&in payload) {
    if (S_DevDryRun) {
        print("DRY RUN, not sent: " + url);
        print("Payload: " + payload);
        return true;
    }
    return false;
}

void DevTraceState(RaceMonitor@ m, RaceState old, RaceState new) {
    auto j = DevRaceJson();
    j["from"] = tostring(old);
    j["to"] = tostring(new);
    j["round"] = m.currRound;
    DevTrace("state", j);
}

dictionary devDetectLogged;

// Rejected finishes are re-detected every frame, so each is logged only once.
void DevTraceDetect(RaceMonitor@ m, const MLFeed::PlayerCpInfo_V4@ player) {
    string key = player.Login + "/" + m.currRound + "/" + player.StartTime;
    if (devDetectLogged.Exists(key)) return;
    devDetectLogged[key] = true;
    bool alreadyFinished = m.HasPlayerFinished(player.LoginMwId.Value);
    auto j = DevPlayerJson(player);
    j["round"] = m.currRound;
    j["activeStartTime"] = m.activeStartTime;
    j["alreadyFinished"] = alreadyFinished;
    j["accepted"] = !alreadyFinished && player.StartTime >= m.activeStartTime && m.currRound != 0;
    j["detectIndex"] = m.finishedPlayers.Length;
    DevTrace("detect", j);
}

void DevTraceEndRound(RaceMonitor@ m, RaceState prior) {
    auto j = Json::Object();
    j["round"] = m.currRound;
    j["prior"] = tostring(prior);
    j["players"] = DevAllPlayersJson();
    DevTrace("endRoundSnapshot", j);
    startnew(DevTraceEndRoundDelayed, m.currRound);
}

void DevTraceRoundEndPayload(RaceMonitor@ m, Json::Value@ payload) {
    auto j = Json::Object();
    j["round"] = m.currRound;
    j["payload"] = payload;
    DevTrace("roundEndPayload", j);
}

void DevTraceEndRoundDelayed(int64 round) {
    sleep(3000);
    auto j = Json::Object();
    j["round"] = int(round);
    j["players"] = DevAllPlayersJson();
    DevTrace("endRoundSnapshot3s", j);
}

Json::Value@ DevPlayerJson(const MLFeed::PlayerCpInfo_V4@ p) {
    auto j = Json::Object();
    j["login"] = p.Login;
    j["name"] = p.Name;
    j["wsid"] = p.WebServicesUserId;
    j["cpCount"] = p.CpCount;
    j["lastCp"] = p.LastCpTime;
    j["isFinished"] = p.IsFinished;
    j["spawn"] = tostring(p.SpawnStatus);
    j["startTime"] = p.StartTime;
    j["raceRank"] = p.RaceRank;
    j["roundPoints"] = p.RoundPoints;
    j["points"] = p.Points;
    j["spec"] = p.RequestsSpectate;
    auto cps = Json::Array();
    auto times = p.CpTimes;
    for (uint i = 0; i < times.Length; i++) cps.Add(times[i]);
    j["cpTimes"] = cps;
    // Server-synced score (what the in-game scoreboard reads)
    auto smp = p.FindCSmPlayer();
    if (smp !is null) {
        auto sp = cast<CSmScriptPlayer>(smp.ScriptAPI);
        if (sp !is null && sp.Score !is null) {
            auto sc = sp.Score;
            j["sc_roundPoints"] = sc.RoundPoints;
            j["sc_points"] = sc.Points;
            auto prev = Json::Array();
            for (uint i = 0; i < sc.PrevRaceTimes.Length; i++) prev.Add(sc.PrevRaceTimes[i]);
            j["sc_prevRaceTimes"] = prev;
            auto best = Json::Array();
            for (uint i = 0; i < sc.BestRaceTimes.Length; i++) best.Add(sc.BestRaceTimes[i]);
            j["sc_bestRaceTimes"] = best;
        } else {
            j["sc_missing"] = "no ScriptAPI/Score";
        }
    } else {
        j["sc_missing"] = "no CSmPlayer";
    }
    return j;
}

Json::Value@ DevAllPlayersJson() {
    auto rd = MLFeed::GetRaceData_V4();
    auto arr = Json::Array();
    for (uint i = 0; i < rd.SortedPlayers_Race.Length; i++) {
        arr.Add(DevPlayerJson(cast<MLFeed::PlayerCpInfo_V4>(rd.SortedPlayers_Race[i])));
    }
    return arr;
}

Json::Value@ DevRaceJson() {
    auto rd = MLFeed::GetRaceData_V4();
    auto j = Json::Object();
    j["rulesStart"] = rd.Rules_StartTime;
    j["rulesEnd"] = rd.Rules_EndTime;
    j["rulesGt"] = rd.Rules_GameTime;
    j["warmup"] = rd.WarmupActive;
    j["cpCount"] = rd.CpCount;
    j["lapCount"] = rd.LapCount;
    j["lapsNb"] = rd.LapsNb;
    j["cpsToFinish"] = rd.CPsToFinish;
    j["map"] = mapUid;
    auto app = cast<CGameManiaPlanet>(GetApp());
    if (app.CurrentPlayground !is null && app.CurrentPlayground.GameTerminals.Length > 0) {
        j["uiSeq"] = tostring(app.CurrentPlayground.GameTerminals[0].UISequence_Current);
    }
    return j;
}
#endif
