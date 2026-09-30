enum RaceState {
    NoMap,
    // Invalid game time, intro ui seq, warmup, etc.
    NoRound_or_Warmup,
    // EndRound, UISequence
    EndRound_or_Similar,
    // Playing, Finish, ppl are racing
    Active,
    Podium
}


class RaceMonitor {
    uint lastMapMwId = uint(-1);
    int currRound = 0;
    bool KeepRunning = true;
    RaceState currState = RaceState::NoMap;
    string matchId;
    string apiKey;

    RaceMonitor(const string &in matchId, const string &in apiKey) {
        this.matchId = matchId;
        this.apiKey = apiKey;
    }

    ~RaceMonitor() {
        Shutdown();
    }

    void Shutdown() {
        KeepRunning = false;
    }

    array<const MLFeed::PlayerCpInfo_V4@> startedPlayers;
    uint[] startedPlayerLoginIds;
    array<const MLFeed::PlayerCpInfo_V4@> finishedPlayers;
    uint[] finishedPlayerLoginIds;

    void ClearFinishedPlayers() {
        finishedPlayers.RemoveRange(0, finishedPlayers.Length);
        finishedPlayerLoginIds.RemoveRange(0, finishedPlayerLoginIds.Length);
        startedPlayers.RemoveRange(0, startedPlayers.Length);
        startedPlayerLoginIds.RemoveRange(0, startedPlayerLoginIds.Length);
    }

    void ClearFinishedPlayers_Delayed() {
        yield();
        ClearFinishedPlayers();
    }

    bool HasPlayerFinished(uint loginIdVal) {
        return finishedPlayerLoginIds.Find(loginIdVal) >= 0;
    }

    void Update() {
        auto newState = CalcState();
        if (newState != currState) {
            UpdateState(currState, newState);
        }
        if (NewMapThisFrame) OnNewMap();
        if (currState == RaceState::Active) {
            UpdateActive();
        }
    }

    void OnNewMap() {
        ClearFinishedPlayers();
        currRound = 0;
    }

    RaceState CalcState() {
        if (!IsPgLoaded) return RaceState::NoMap;
        auto rd = MLFeed::GetRaceData_V4();
        if (rd.Rules_StartTime < 0 || (rd.Rules_EndTime > 0 && rd.Rules_StartTime >= rd.Rules_EndTime)) return RaceState::NoRound_or_Warmup;
        if (rd.WarmupActive) return RaceState::NoRound_or_Warmup;
        auto app = cast<CGameManiaPlanet>(GetApp());
        auto seq = int(app.CurrentPlayground.GameTerminals[0].UISequence_Current);
        if (IsEndRoundUISeq(seq)) return RaceState::EndRound_or_Similar;
        if (IsPlayingUISeq(seq)) return RaceState::Active;
        if (IsPodiumUISeq(seq)) return RaceState::Podium;
        return RaceState::NoRound_or_Warmup;
    }


    void UpdateState(RaceState old, RaceState new) {
        DevTraceState(this, old, new);
        currState = new;
        switch (new) {
            case RaceState::NoMap: return;
            case RaceState::NoRound_or_Warmup: {
                OnWarmup(old);
                return;
            }
            case RaceState::EndRound_or_Similar: {
                OnEndRound(old);
                return;
            }
            case RaceState::Active: {
                OnGoingActive(old);
                return;
            }
            case RaceState::Podium: {
                OnPodium(old);
                return;
            }
        }
    }

    void OnWarmup(RaceState prior) {
        if (prior == RaceState::Active) {
            if (Time::Now - lastWentActive < 2000) {
                // ignore this round, probably just before warmup
                currRound = Math::Max(0, currRound - 1);
            }
        }
        Dev_Notify("OnWarmup, prior: " + tostring(prior));
    }

    uint lastWentActive;
    uint activeStartTime = 0;
    
    void UpdateActive() {
        lastWentActive = Time::Now;
        auto rd = MLFeed::GetRaceData_V4();
        for (uint i = 0; i < rd.SortedPlayers_Race.Length; i++) {
            auto player = cast<MLFeed::PlayerCpInfo_V4>(rd.SortedPlayers_Race[i]);
            if (player.IsSpawned && player.IsFinished && !HasPlayerFinished(player.LoginMwId.Value)) {
                AddPlayerFinish(player);
            }
        }
    }

    void AddPlayerFinish(const MLFeed::PlayerCpInfo_V4@ player) {
        DevTraceDetect(this, player);
        if (HasPlayerFinished(player.LoginMwId.Value)) {
            Dev_Notify("Player already finished: " + player.Login);
            return;
        }
        // Ignore players who spawned before we went active (warmup players)
        if (player.StartTime < activeStartTime) {
            Dev_Notify("Player spawned during warmup, ignoring: " + player.Login);
            return;
        }
        // Don't capture player data during warmup (round 0)
        if (currRound == 0) {
            return;
        }
        finishedPlayers.InsertLast(player);
        finishedPlayerLoginIds.InsertLast(player.LoginMwId.Value);
        startnew(CoroutineFuncUserdata(SendPlayerFinish), player);
    }

    void SendPlayerFinish(ref@ pref) {
        MLFeed::PlayerCpInfo_V4@ player = cast<MLFeed::PlayerCpInfo_V4>(pref);
        PlayerFinishMsgs_Sent++;
        ECMResponse@ r = AddOnPlayerFinishReq(apiKey, matchId, Json::Write(MakePlayerFinishPayload(player.WebServicesUserId, player.IsFinished ? player.LastCpTime : -1, currRound, mapUid)));
        if (r.success) {
            PlayerFinishMsgs_Succeeded++;
            lastSuccessMsg = r.message;
        } else {
            PlayerFinishMsgs_Failed++;
            lastError = r.message;
        }
    }

    void OnGoingActive(RaceState prior) {
        if (prior != RaceState::Active) {
            if (prior == RaceState::NoMap) {
                currRound = 0;
            }
            currRound++;
            // Record when we went active to filter out warmup spawns
            activeStartTime = MLFeed::GameTime;
        }
        Dev_Notify("OnGoingActive, prior: " + tostring(prior));
        startnew(CoroutineFunc(CacheStartedPlayers_Delayed));
    }

    void CacheStartedPlayers_Delayed() {
        auto start = Time::Now;
        while (currState == RaceState::Active && Time::Now < start + 2000) {
            yield();
        }
        if (currState != RaceState::Active) return;

        auto rd = MLFeed::GetRaceData_V4();
        for (uint i = 0; i < rd.SortedPlayers_Race.Length; i++) {
            auto player = cast<MLFeed::PlayerCpInfo_V4>(rd.SortedPlayers_Race[i]);
            if (startedPlayerLoginIds.Find(player.LoginMwId.Value) >= 0) continue;
            if (player.SpawnStatus == MLFeed::SpawnStatus::NotSpawned) continue;
            startedPlayers.InsertLast(player);
            startedPlayerLoginIds.InsertLast(player.LoginMwId.Value);
        }
    }

    void OnEndRound(RaceState prior) {
        DevTraceEndRound(this, prior);
        if (prior == RaceState::Active) {
            startnew(CoroutineFunc(SendOnRoundEnd));
        } else {
        }
        startnew(CoroutineFunc(ClearFinishedPlayers_Delayed));
        Dev_Notify("OnEndRound, prior: " + tostring(prior));
    }

    void OnPodium(RaceState prior) {
        Dev_Notify("OnPodium, prior: " + tostring(prior));
    }



    uint RoundEndMsgs_Sent = 0;
    uint RoundEndMsgs_Succeeded = 0;
    uint RoundEndMsgs_Failed = 0;

    uint PlayerFinishMsgs_Sent = 0;
    uint PlayerFinishMsgs_Succeeded = 0;
    uint PlayerFinishMsgs_Failed = 0;

    uint lastReqStatus = 0;
    string lastSuccessMsg = "";
    string lastError = "";

    void SendOnRoundEnd() {
        RoundEndMsgs_Sent++;
        auto payload = GetRoundEndPayload();
        DevTraceRoundEndPayload(this, payload);
        ECMResponse@ r = AddOnEndRoundReq(apiKey, matchId, Json::Write(payload));
        if (r.success) {
            RoundEndMsgs_Succeeded++;
            lastSuccessMsg = r.message;
        } else {
            RoundEndMsgs_Failed++;
            lastError = r.message;
        }
    }

    Json::Value@ GetRoundEndPayload() {
        auto rd = MLFeed::GetRaceData_V4();
        PlayerFinishData@[] players;
        for (uint i = 0; i < finishedPlayers.Length; i++) {
            auto player = finishedPlayers[i];
            players.InsertLast(PlayerFinishData(player.WebServicesUserId, player.IsFinished ? player.LastCpTime : -1, i + 1));
        }
        auto nbFinished = players.Length;
        for (uint i = 0; i < rd.SortedPlayers_Race.Length; i++) {
            auto player = cast<MLFeed::PlayerCpInfo_V4>(rd.SortedPlayers_Race[i]);
            if (player.RequestsSpectate) continue;
            if (player.CpCount == 0) continue;
            if (finishedPlayerLoginIds.Find(player.LoginMwId.Value) >= 0) continue;
            players.InsertLast(PlayerFinishData(player.WebServicesUserId, player.IsFinished ? player.LastCpTime : -1, ++nbFinished));
            finishedPlayerLoginIds.InsertLast(player.LoginMwId.Value);
        }
        for (uint i = 0; i < startedPlayers.Length; i++) {
            auto player = startedPlayers[i];
            if (player.RequestsSpectate) continue;
            if (player.CpCount == 0) continue;
            if (finishedPlayerLoginIds.Find(player.LoginMwId.Value) >= 0) continue;
            players.InsertLast(PlayerFinishData(player.WebServicesUserId, -1, ++nbFinished));
            finishedPlayerLoginIds.InsertLast(player.LoginMwId.Value);
        }
        return MakeRoundEndPayload(players, currRound, mapUid);
    }


    void DrawWindowInner() {
        UI::AlignTextToFramePadding();
        UI::Text("Running Monitor");
        UI::Separator();
        DrawCurrentState();
        UI::Separator();
        UI::PushStyleColor(UI::Col::Header, vec4(0.260f, 0.590f, 0.980f, 0.304f) * .5);
        if (UI::CollapsingHeader("API Requests Info")) {
            DrawRequestsInfo();
        }
        UI::PopStyleColor();
    }

    void DrawRequestsInfo() {
        UI::Text("Current Round: " + currRound);
        UI::Text("RoundEnd Messages Sent: " + RoundEndMsgs_Sent);
        UI::Text("RoundEnd Messages Succeeded: " + RoundEndMsgs_Succeeded);
        UI::Text("RoundEnd Messages Failed: " + RoundEndMsgs_Failed);
        UI::Text("PlayerFinish Messages Sent: " + PlayerFinishMsgs_Sent);
        UI::Text("PlayerFinish Messages Succeeded: " + PlayerFinishMsgs_Succeeded);
        UI::Text("PlayerFinish Messages Failed: " + PlayerFinishMsgs_Failed);
        UI::Text("Last Request Status: " + lastReqStatus);
        UI::Text("Last Success Message: " + lastSuccessMsg);
        UI::Text("Last Error: " + lastError);
    }

    void DrawCurrentState() {
        UI::AlignTextToFramePadding();
        UI::Text("Current State: " + tostring(currState));
        UI::AlignTextToFramePadding();
        UI::Text("ECM ID: " + matchId);
        DrawStopMonitoringButton();
    }
}


uint GetMapMwIdValue() {
    auto map = GetApp().RootMap;
    if (map is null) return 0xFFFFFFFF;
    return map.Id.Value;
}



bool IsPlayingUISeq(int seq) {
    return seq == int(CGamePlaygroundUIConfig::EUISequence::Playing)
        || seq == int(CGamePlaygroundUIConfig::EUISequence::Finish);
}

bool IsPodiumUISeq(int seq) {
    return seq == int(CGamePlaygroundUIConfig::EUISequence::Podium);
}

bool IsEndRoundUISeq(int seq) {
    return seq == int(CGamePlaygroundUIConfig::EUISequence::EndRound)
        || seq == int(CGamePlaygroundUIConfig::EUISequence::UIInteraction);
}
