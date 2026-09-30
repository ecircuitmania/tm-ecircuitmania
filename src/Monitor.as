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

    // The plugin runner's own finish is shown on this client before the server
    // validates it. With a bad connection the server can still turn it into a
    // timeout, or validate it only after the round ends here. We track it so the
    // round-end results can wait for the server's verdict. See ConfirmLocalFinish.
    string localLogin;
    bool localFinishSeen = false;
    int localProvisionalTime = -1;
    // Round points the plugin runner held while still racing, captured shortly
    // after the first other player finished (the server's "not finished" value
    // for this round, e.g. 0 in Cup, -20 in reverse cup).
    uint firstOtherFinishAt = 0;
    bool haveUnfinishedRef = false;
    int localUnfinishedRoundPoints = 0;
    // Per map: seen the server confirm other players' finishes via round points
    // or PrevRaceTimes? If not, this mode gives us no signal and we don't wait.
    bool roundPointsSignalSeen = false;
    bool prevRaceSignalSeen = false;

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
        DevWatchScores(this);
    }

    void OnNewMap() {
        ClearFinishedPlayers();
        currRound = 0;
        roundPointsSignalSeen = false;
        prevRaceSignalSeen = false;
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
        TrackLocalFinish(rd);
    }

    const MLFeed::PlayerCpInfo_V4@ FindLocalPlayer(const MLFeed::HookRaceStatsEventsBase_V4@ rd) {
        if (localLogin.Length == 0) return null;
        for (uint i = 0; i < rd.SortedPlayers_Race.Length; i++) {
            auto player = cast<MLFeed::PlayerCpInfo_V4>(rd.SortedPlayers_Race[i]);
            if (player.Login == localLogin) return player;
        }
        return null;
    }

    // Wait this long after the first other finish before reading the "not
    // finished" value, so the server's update has reached this client.
    uint UnfinishedRefDelayMs = 500;

    void TrackLocalFinish(const MLFeed::HookRaceStatsEventsBase_V4@ rd) {
        if (localFinishSeen) return;
        auto localPlayer = FindLocalPlayer(rd);
        if (localPlayer is null) return;
        if (localPlayer.IsFinished && localPlayer.StartTime >= activeStartTime) {
            // If this happens before we captured the "not finished" value, we
            // can't tell a confirmation apart, so the result is left as is.
            localFinishSeen = true;
            localProvisionalTime = localPlayer.LastCpTime;
            return;
        }
        if (haveUnfinishedRef) return;
        if (firstOtherFinishAt == 0) {
            for (uint i = 0; i < rd.SortedPlayers_Race.Length; i++) {
                auto player = cast<MLFeed::PlayerCpInfo_V4>(rd.SortedPlayers_Race[i]);
                if (player.Login == localLogin) continue;
                if (!player.IsFinished || player.StartTime < activeStartTime) continue;
                firstOtherFinishAt = Time::Now;
                break;
            }
            return;
        }
        if (Time::Now - firstOtherFinishAt < UnfinishedRefDelayMs) return;
        auto sc = GetServerScore(localPlayer);
        if (sc is null) return;
        localUnfinishedRoundPoints = sc.RoundPoints;
        haveUnfinishedRef = true;
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
        // The per-player message is not sent here. A finish seen mid-round can be
        // provisional (the local player's own time, before the server confirms it),
        // so per-player messages are sent at round end from the same results as the
        // round-end message. See SendOnRoundEnd.
    }

    void SendPlayerFinish(ref@ pref) {
        RoundResult@ result = cast<RoundResult>(pref);
        DevTracePlayerFinishSend(this, result);
        PlayerFinishMsgs_Sent++;
        ECMResponse@ r = AddOnPlayerFinishReq(apiKey, matchId, Json::Write(MakePlayerFinishPayload(result.wsid, result.finishTime, result.round, mapUid)));
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
            localLogin = GetLocalLogin();
            localFinishSeen = false;
            localProvisionalTime = -1;
            firstOtherFinishAt = 0;
            haveUnfinishedRef = false;
            localUnfinishedRoundPoints = 0;
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
        // Build the round's results once, then send every message from them,
        // so per-player and round-end messages always agree.
        // Captured now: waiting for the server below must not pick up the next round's number.
        int round = currRound;
        auto results = BuildRoundResults();
        ConfirmLocalFinish(results);
        for (uint i = 0; i < results.Length; i++) results[i].round = round;

        // Per-player messages for confirmed finishers, started first so they
        // go out ahead of the round-end message as before.
        for (uint i = 0; i < results.Length; i++) {
            if (!results[i].Finished) continue;
            startnew(CoroutineFuncUserdata(SendPlayerFinish), results[i]);
        }
        yield();

        RoundEndMsgs_Sent++;
        auto payload = MakeRoundEndPayloadFromResults(results, round);
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

    // Everyone who took part in the round, with final times read now, ranked.
    array<RoundResult@>@ BuildRoundResults() {
        auto rd = MLFeed::GetRaceData_V4();
        array<RoundResult@> results;
        uint[] seen = finishedPlayerLoginIds;
        for (uint i = 0; i < finishedPlayers.Length; i++) {
            results.InsertLast(RoundResultFromPlayer(finishedPlayers[i]));
        }
        for (uint i = 0; i < rd.SortedPlayers_Race.Length; i++) {
            auto player = cast<MLFeed::PlayerCpInfo_V4>(rd.SortedPlayers_Race[i]);
            if (player.RequestsSpectate) continue;
            if (player.CpCount == 0) continue;
            if (seen.Find(player.LoginMwId.Value) >= 0) continue;
            results.InsertLast(RoundResultFromPlayer(player));
            seen.InsertLast(player.LoginMwId.Value);
        }
        for (uint i = 0; i < startedPlayers.Length; i++) {
            auto player = startedPlayers[i];
            if (player.RequestsSpectate) continue;
            if (player.CpCount == 0) continue;
            if (seen.Find(player.LoginMwId.Value) >= 0) continue;
            results.InsertLast(RoundResultFromPlayer(player, true));
            seen.InsertLast(player.LoginMwId.Value);
        }

        // Rank by race time with Nadeo's tiebreak, not by detection order.
        SortRoundResults(results);
        return results;
    }

    // Upper bound on waiting for the server to commit the round's scores.
    uint ScoreCommitTimeoutMs = 5000;

    // The plugin runner's own finish can still be provisional at EndRound: the
    // server may validate it a moment later, or reject it as a timeout. Wait for
    // the server's end-of-round score commit (round points folded into totals),
    // and use the server's round points / PrevRaceTimes to decide finish vs DNF.
    // Other players' results come from the server already and are left as is.
    void ConfirmLocalFinish(array<RoundResult@>@ results) {
        // Only needed when this client showed its own finish after we learned
        // the server's "not finished" value (i.e. near the end of the round).
        if (!localFinishSeen || !haveUnfinishedRef) return;
        auto rd = MLFeed::GetRaceData_V4();
        auto localPlayer = FindLocalPlayer(rd);
        if (localPlayer is null) return;
        // Copied: the next round resets the members while we wait.
        int unfinishedRp = localUnfinishedRoundPoints;
        int provisionalTime = localProvisionalTime;
        string myLogin = localLogin;

        // Does this mode signal finishes through the score record? Check with the
        // other finishers, whose results are always server-confirmed.
        for (uint i = 0; i < results.Length; i++) {
            auto p = FindPlayerByWsid(rd, results[i].wsid);
            if (p is null || p.Login == myLogin || !results[i].Finished) continue;
            auto sc = GetServerScore(p);
            if (sc is null) continue;
            if (sc.PrevRaceTimes.Length > 0) prevRaceSignalSeen = true;
            if (sc.RoundPoints != unfinishedRp) roundPointsSignalSeen = true;
        }
        if (!roundPointsSignalSeen && !prevRaceSignalSeen) {
            DevTraceLocalGate(this, "no server signal in this mode, keeping EndRound result", localPlayer, false, 0);
            return;
        }

        // Snapshot totals so we can see the server's score commit.
        string[] logins;
        int[] pointsAtEnd;
        int[] roundPointsAtEnd;
        for (uint i = 0; i < rd.SortedPlayers_Race.Length; i++) {
            auto p = cast<MLFeed::PlayerCpInfo_V4>(rd.SortedPlayers_Race[i]);
            auto sc = GetServerScore(p);
            if (sc is null) continue;
            logins.InsertLast(p.Login);
            pointsAtEnd.InsertLast(sc.Points);
            roundPointsAtEnd.InsertLast(sc.RoundPoints);
        }

        bool confirmed = false;
        bool committed = false;
        uint start = Time::Now;
        while (true) {
            // Stop at the server's commit, before reading this frame's values:
            // the commit resets round points, which must not count as a confirmation.
            for (uint i = 0; i < logins.Length && !committed; i++) {
                auto p = FindPlayerByLogin(rd, logins[i]);
                auto sc = GetServerScore(p);
                if (sc is null) continue;
                if (sc.Points != pointsAtEnd[i]) committed = true;
                else if (roundPointsAtEnd[i] != 0 && sc.RoundPoints == 0) committed = true;
            }
            if (committed) break;

            auto lsc = GetServerScore(localPlayer);
            if (lsc !is null && !confirmed) {
                if (prevRaceSignalSeen && lsc.PrevRaceTimes.Length > 0) confirmed = true;
                if (roundPointsSignalSeen && lsc.RoundPoints != unfinishedRp && lsc.RoundPoints != 0) confirmed = true;
            }
            if (Time::Now - start > ScoreCommitTimeoutMs) break;
            if (currState != RaceState::EndRound_or_Similar) break;
            yield();
        }

        DevTraceLocalGate(this, committed ? "score commit" : "stopped before commit", localPlayer, confirmed, Time::Now - start);
        if (!committed) {
            // No commit seen: keep what we had at EndRound rather than guess.
            return;
        }

        // Replace the plugin runner's entry with the server's verdict.
        RoundResult@ updated;
        if (confirmed) {
            @updated = RoundResultFromPlayer(localPlayer);
            if (!updated.Finished) {
                warn("Local finish confirmed by server but not yet shown locally; using the first-seen time " + provisionalTime);
                updated.finishTime = provisionalTime;
            }
        } else {
            @updated = RoundResultFromPlayer(localPlayer, true);
        }
        bool replaced = false;
        for (uint i = 0; i < results.Length; i++) {
            if (results[i].wsid == updated.wsid) {
                @results[i] = updated;
                replaced = true;
                break;
            }
        }
        if (!replaced && confirmed) results.InsertLast(updated);
        SortRoundResults(results);
    }

    const MLFeed::PlayerCpInfo_V4@ FindPlayerByLogin(const MLFeed::HookRaceStatsEventsBase_V4@ rd, const string &in login) {
        for (uint i = 0; i < rd.SortedPlayers_Race.Length; i++) {
            auto player = cast<MLFeed::PlayerCpInfo_V4>(rd.SortedPlayers_Race[i]);
            if (player.Login == login) return player;
        }
        return null;
    }

    const MLFeed::PlayerCpInfo_V4@ FindPlayerByWsid(const MLFeed::HookRaceStatsEventsBase_V4@ rd, const string &in wsid) {
        for (uint i = 0; i < rd.SortedPlayers_Race.Length; i++) {
            auto player = cast<MLFeed::PlayerCpInfo_V4>(rd.SortedPlayers_Race[i]);
            if (player.WebServicesUserId == wsid) return player;
        }
        return null;
    }

    Json::Value@ MakeRoundEndPayloadFromResults(array<RoundResult@>@ results, int round) {
        PlayerFinishData@[] players;
        for (uint i = 0; i < results.Length; i++) {
            players.InsertLast(PlayerFinishData(results[i].wsid, results[i].finishTime, i + 1));
        }
        DevTraceRankedResults(this, results);
        return MakeRoundEndPayload(players, round, mapUid);
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
