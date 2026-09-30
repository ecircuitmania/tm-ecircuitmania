// Dev-only tracing for reproducing round-end issues.
// Every line is printed to Openplanet.log prefixed with [ECMTRACE] as one JSON object.
// No behaviour change: in release builds these functions do nothing.

void DevTrace(const string &in ev, Json::Value@ data) {
#if DEV
    data["ev"] = ev;
    data["now"] = Time::Now;
    data["gt"] = MLFeed::GameTime;
    print("[ECMTRACE] " + Json::Write(data));
#endif
}

#if DEV
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
