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

// The server's verdict on the plugin runner's own finish. See ConfirmLocalFinish.
enum ServerVerdict {
    // The score commit wasn't seen in time.
    Unknown,
    Finished,
    Dnf
}

class RaceMonitor {
    uint lastMapMwId = uint(-1);
    int currRound = 0;
    bool KeepRunning = true;
    RaceState currState = RaceState::NoMap;
    string matchId;
    string apiKey;

    RaceMonitor(const string&in matchId, const string&in apiKey) {
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
#if DEV
        DevWatchScores(this);
#endif
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
#if DEV
        DevTraceState(this, old, new);
#endif
        currState = new;
        switch(new) {
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
#if DEV
        DevTraceDetect(this, player);
#endif
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
        // Sent as soon as the finish is seen by this client, without verifying against the server's
        // view for accuracy. The full round data will be accurate and overwrite the client's view in case
        // of conflict.
        auto result = RoundResultFromPlayer(player);
        result.round = currRound;
        startnew(CoroutineFuncUserdata(SendPlayerFinish), result);
    }

    void SendPlayerFinish(ref@ pref) {
        RoundResult@ result = cast<RoundResult>(pref);
#if DEV
        DevTracePlayerFinishSend(this, result);
#endif
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
#if DEV
        DevTraceEndRound(this, prior);
#endif
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
        // Captured now: waiting for the server below must not pick up the next round's number.
        int round = currRound;
        auto results = BuildRoundResults();
        ConfirmLocalFinish(results);

        RoundEndMsgs_Sent++;
        auto payload = MakeRoundEndPayloadFromResults(results, round);
#if DEV
        DevTraceRoundEndPayload(this, payload);
#endif
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
            // No longer in the race list, so they left mid-round: never a finish.
            auto result = RoundResultFromPlayer(player);
            result.MaybeMarkDnf();
            results.InsertLast(result);
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

        LearnServerSignals(rd, results, localPlayer, unfinishedRp);
        if (!roundPointsSignalSeen && !prevRaceSignalSeen) {
#if DEV
            DevTraceLocalGate(this, "no server signal in this mode, keeping EndRound result", localPlayer, false, 0);
#endif
            return;
        }

        auto verdict = WaitForServerVerdict(rd, localPlayer, unfinishedRp);
        // No commit seen: keep what we had at EndRound rather than guess.
        if (verdict == ServerVerdict::Unknown) return;
        ApplyServerVerdict(results, localPlayer, verdict, provisionalTime);
    }

    // Does this mode signal finishes through the score record? Learned from the
    // other finishers, whose results are always server-confirmed.
    void LearnServerSignals(const MLFeed::HookRaceStatsEventsBase_V4@ rd, array<RoundResult@>@ results, const MLFeed::PlayerCpInfo_V4@ localPlayer, int unfinishedRp) {
        for (uint i = 0; i < results.Length; i++) {
            auto p = FindPlayerByWsid(rd, results[i].wsid);
            if (p is null || p.Login == localPlayer.Login || !results[i].Finished) continue;
            auto sc = GetServerScore(p);
            if (sc is null) continue;
            if (sc.PrevRaceTimes.Length > 0) prevRaceSignalSeen = true;
            if (sc.RoundPoints != unfinishedRp) roundPointsSignalSeen = true;
        }
    }

    // Wait for the server's score commit, watching until then for the server to
    // confirm the plugin runner's finish. Gives up after ScoreCommitTimeoutMs, or
    // once the round state moves on.
    ServerVerdict WaitForServerVerdict(const MLFeed::HookRaceStatsEventsBase_V4@ rd, const MLFeed::PlayerCpInfo_V4@ localPlayer, int unfinishedRp) {
        ScoreCommitWatch@ commit = ScoreCommitWatch(rd);
        bool confirmed = false;
        uint start = Time::Now;
        while (true) {
            // Checked before this frame's confirmation: the commit resets round points.
            if (commit.Committed()) {
#if DEV
                DevTraceLocalGate(this, "score commit", localPlayer, confirmed, Time::Now - start);
#endif
                return confirmed ? ServerVerdict::Finished : ServerVerdict::Dnf;
            }
            if (!confirmed) confirmed = ServerConfirmedFinish(localPlayer, unfinishedRp);
            if (Time::Now - start > ScoreCommitTimeoutMs) break;
            if (currState != RaceState::EndRound_or_Similar) break;
            yield();
        }
#if DEV
        DevTraceLocalGate(this, "stopped before commit", localPlayer, confirmed, Time::Now - start);
#endif
        return ServerVerdict::Unknown;
    }

    // Has the server confirmed the plugin runner's finish? Only meaningful before
    // the score commit.
    bool ServerConfirmedFinish(const MLFeed::PlayerCpInfo_V4@ localPlayer, int unfinishedRp) {
        auto sc = GetServerScore(localPlayer);
        if (sc is null) return false;
        if (prevRaceSignalSeen && sc.PrevRaceTimes.Length > 0) return true;
        // Not 0 either: that's the commit resetting round points, not a confirmation.
        return roundPointsSignalSeen && sc.RoundPoints != unfinishedRp && sc.RoundPoints != 0;
    }

    // Replace the plugin runner's EndRound entry with the server's verdict.
    void ApplyServerVerdict(array<RoundResult@>@ results, const MLFeed::PlayerCpInfo_V4@ localPlayer, ServerVerdict verdict, int provisionalTime) {
        RoundResult@ updated = RoundResultFromPlayer(localPlayer);
        if (verdict == ServerVerdict::Dnf) {
            updated.MaybeMarkDnf();
        } else if (!updated.Finished) {
            warn("Local finish confirmed by server but not yet shown locally; using the first-seen time " + provisionalTime);
            updated.finishTime = provisionalTime;
        }
        bool replaced = false;
        for (uint i = 0; i < results.Length; i++) {
            if (results[i].wsid == updated.wsid) {
                @results[i] = updated;
                replaced = true;
                break;
            }
        }
        if (!replaced && verdict == ServerVerdict::Finished) results.InsertLast(updated);
        SortRoundResults(results);
    }

    const MLFeed::PlayerCpInfo_V4@ FindPlayerByWsid(const MLFeed::HookRaceStatsEventsBase_V4@ rd, const string&in wsid) {
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
#if DEV
        DevTraceRankedResults(this, results);
#endif
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

// The player's score record, copied from the server to every client. Its
// RoundPoints and PrevRaceTimes are written by the server's game mode, so they
// reflect what the server decided, not this client's prediction.
CSmArenaScore@ GetServerScore(const MLFeed::PlayerCpInfo_V4@ player) {
    if (player is null) return null;
    auto smp = player.FindCSmPlayer();
    if (smp is null) return null;
    auto sp = cast<CSmScriptPlayer>(smp.ScriptAPI);
    if (sp is null) return null;
    return sp.Score;
}

// Every player's server totals at EndRound, to spot the server's end-of-round
// score commit: round points folded into totals, about 3 s after EndRound.
class ScoreCommitWatch {
    // MLFeed keeps one object per player, and FindCSmPlayer looks the player up
    // each time, so these handles stay valid to read from.
    array<const MLFeed::PlayerCpInfo_V4@> players;
    int[] pointsAtEnd;
    int[] roundPointsAtEnd;

    ScoreCommitWatch(const MLFeed::HookRaceStatsEventsBase_V4@ rd) {
        for (uint i = 0; i < rd.SortedPlayers_Race.Length; i++) {
            auto p = cast<MLFeed::PlayerCpInfo_V4>(rd.SortedPlayers_Race[i]);
            auto sc = GetServerScore(p);
            if (sc is null) continue;
            players.InsertLast(p);
            pointsAtEnd.InsertLast(sc.Points);
            roundPointsAtEnd.InsertLast(sc.RoundPoints);
        }
    }

    // The commit changes someone's total, or resets their round points to 0.
    bool Committed() {
        for (uint i = 0; i < players.Length; i++) {
            auto sc = GetServerScore(players[i]);
            if (sc is null) continue;
            if (sc.Points != pointsAtEnd[i]) return true;
            if (roundPointsAtEnd[i] != 0 && sc.RoundPoints == 0) return true;
        }
        return false;
    }
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
