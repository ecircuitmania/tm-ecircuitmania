// RaceState is the phase of the race, from MLFeed's rules times and the UI sequence.
enum RaceState {
    NoMap,
    // Invalid game time, intro UI sequence, warmup, etc.
    NoRound_or_Warmup,
    // EndRound or UIInteraction UI sequence
    EndRound_or_Similar,
    // Playing or Finish UI sequence: players are racing
    Active,
    Podium
}

// RaceMonitor follows the race on the current server and sends each round's results to ECM.
class RaceMonitor {
    string matchId;
    string apiKey;
    RaceState currentState = RaceState::NoMap;
    int currentRound = 0;
    // Time::Now of the last frame spent Active.
    uint lastActiveAt = 0;
    // The round being raced, from going Active until the next round starts.
    RoundTracker@ roundTracker;
    ServerFinishSignals@ finishSignals;
    FeedHealthCheck feedHealth;

    uint roundEndMessagesSent = 0;
    uint roundEndMessagesSucceeded = 0;
    uint roundEndMessagesFailed = 0;
    int lastRequestStatus = 0;
    string lastSuccessMessage = "";
    string lastError = "";

    // RaceMonitor starts monitoring for the given ECM match.
    RaceMonitor(const string &in matchId, const string &in apiKey) {
        this.matchId = matchId;
        this.apiKey = apiKey;
        @finishSignals = ServerFinishSignals();
    }

    // Update follows the race state and tracks the current round. Call every frame while monitoring.
    void Update() {
        auto newState = CalculateState();
        if (newState != currentState) {
            UpdateState(currentState, newState);
        }
        if (NewMapThisFrame) OnNewMap();
        if (currentState == RaceState::Active) {
            lastActiveAt = Time::Now;
            if (roundTracker !is null) roundTracker.Track(MLFeed::GetRaceData_V4());
        }
        feedHealth.Update();
#if DEV
        DevWatchScores(this);
#endif
    }

    // OnNewMap restarts the round count and forgets what the previous map's game mode signals.
    void OnNewMap() {
        currentRound = 0;
        finishSignals.Reset();
    }

    // CalculateState works out the race state from MLFeed's rules times and the UI sequence.
    RaceState CalculateState() {
        if (!IsPlaygroundLoaded) return RaceState::NoMap;
        auto raceData = MLFeed::GetRaceData_V4();
        if (raceData.Rules_StartTime < 0 || (raceData.Rules_EndTime > 0 && raceData.Rules_StartTime >= raceData.Rules_EndTime)) return RaceState::NoRound_or_Warmup;
        if (raceData.WarmupActive) return RaceState::NoRound_or_Warmup;
        auto game = cast<CGameManiaPlanet>(GetApp());
        auto uiSequence = int(game.CurrentPlayground.GameTerminals[0].UISequence_Current);
        if (IsEndRoundUISequence(uiSequence)) return RaceState::EndRound_or_Similar;
        if (IsPlayingUISequence(uiSequence)) return RaceState::Active;
        if (IsPodiumUISequence(uiSequence)) return RaceState::Podium;
        return RaceState::NoRound_or_Warmup;
    }

    // UpdateState monitors the race state and calls handlers depending on the new state.
    void UpdateState(RaceState previousState, RaceState newState) {
#if DEV
        DevTraceState(this, previousState, newState);
#endif
        currentState = newState;
        switch (newState) {
            case RaceState::NoMap: return;
            case RaceState::NoRound_or_Warmup: {
                OnWarmup(previousState);
                return;
            }
            case RaceState::EndRound_or_Similar: {
                OnEndRound(previousState);
                return;
            }
            case RaceState::Active: {
                OnGoingActive(previousState);
                return;
            }
            case RaceState::Podium: return;
        }
    }

    // OnWarmup takes back the round number when racing stops without an end of round.
    void OnWarmup(RaceState previousState) {
        if (previousState == RaceState::Active && Time::Now - lastActiveAt < 2000) {
            // ignore this round, probably just before warmup
            currentRound = Math::Max(0, currentRound - 1);
        }
    }

    // OnGoingActive starts tracking a new round.
    void OnGoingActive(RaceState previousState) {
        if (previousState == RaceState::NoMap) {
            currentRound = 0;
        }
        currentRound++;
        // Runs that started before the round went Active are leftovers, e.g. from warmup.
        // Coming from NoMap we didn't see the round start (monitoring began mid-round, or
        // the map just loaded and MLFeed has only this map's runs), so every run counts.
        uint startGameTime = 0;
        if (previousState != RaceState::NoMap) startGameTime = MLFeed::GameTime;
        @roundTracker = RoundTracker(startGameTime, GetLocalLogin(), finishSignals);
    }

    // OnEndRound starts the report for the round that just ended.
    void OnEndRound(RaceState previousState) {
        // Round 0 is warmup and never reported.
        if (previousState != RaceState::Active || roundTracker is null || currentRound == 0) return;
        // Captured now: waiting for the server must not pick up the next round's values.
        roundTracker.number = currentRound;
        roundTracker.mapUid = mapUid;
        startnew(CoroutineFuncUserdata(ReportRound), roundTracker);
    }

    // ReportRound waits for the server's verdict on the round, then ranks it and sends it to ECM.
    void ReportRound(ref@ endedRoundRef) {
        RoundTracker@ endedRound = cast<RoundTracker>(endedRoundRef);
        bool committed = WaitForScoreCommit(endedRound);
        auto verdict = endedRound.localFinish.Verdict(committed);
        auto rankedResults = endedRound.RankedResults(verdict);
        auto payload = MakeRoundEndPayload(rankedResults, endedRound.number, endedRound.mapUid);
#if DEV
        DevTraceRoundReport(this, endedRound, committed, verdict, rankedResults, payload);
#endif
        roundEndMessagesSent++;
        ECMResponse@ response = AddOnEndRoundRequest(apiKey, matchId, Json::Write(payload));
        lastRequestStatus = response.status;
        if (response.success) {
            roundEndMessagesSucceeded++;
            lastSuccessMessage = response.message;
        } else {
            roundEndMessagesFailed++;
            lastError = response.message;
        }
    }

    // WaitForScoreCommit re-reads the ended round every frame until the server's end-of-round score commit, and reports whether it was seen.
    // There is no timeout: the wait also ends if the round moves on without a commit (next round, podium or map change) or monitoring stops.
    bool WaitForScoreCommit(RoundTracker@ endedRound) {
        ScoreCommitWatch@ commitWatch = ScoreCommitWatch(MLFeed::GetRaceData_V4());
        // The server commits before it ends the end-of-round sequence, so once the round
        // has moved on, no commit is coming. If monitoring stopped or we left the server,
        // Update() no longer runs and currentState would never change.
        while (g_monitor is this && currentState == RaceState::EndRound_or_Similar) {
            // Checked before re-reading: the commit resets round points.
            if (commitWatch.Committed()) return true;
            endedRound.Refresh();
            yield();
        }
        return false;
    }

    // DrawWindowInner draws the monitor's part of the plugin window.
    void DrawWindowInner() {
        UI::AlignTextToFramePadding();
        UI::Text("Running Monitor");
        UI::Separator();
        feedHealth.DrawBanner();
        DrawCurrentState();
        UI::Separator();
        UI::PushStyleColor(UI::Col::Header, vec4(0.260f, 0.590f, 0.980f, 0.304f) * .5);
        if (UI::CollapsingHeader("API Requests Info")) {
            DrawRequestsInfo();
        }
        UI::PopStyleColor();
    }

    // DrawRequestsInfo draws the round count and how the round-end requests went.
    void DrawRequestsInfo() {
        UI::Text("Current Round: " + currentRound);
        UI::Text("RoundEnd Messages Sent: " + roundEndMessagesSent);
        UI::Text("RoundEnd Messages Succeeded: " + roundEndMessagesSucceeded);
        UI::Text("RoundEnd Messages Failed: " + roundEndMessagesFailed);
        UI::Text("Last Request Status: " + lastRequestStatus);
        UI::Text("Last Success Message: " + lastSuccessMessage);
        UI::Text("Last Error: " + lastError);
    }

    // DrawCurrentState draws the race state, the ECM match ID and the stop button.
    void DrawCurrentState() {
        UI::AlignTextToFramePadding();
        UI::Text("Current State: " + tostring(currentState));
        UI::AlignTextToFramePadding();
        UI::Text("ECM ID: " + matchId);
        DrawStopMonitoringButton();
    }
}

// IsPlayingUISequence reports whether the UI sequence means players are racing.
bool IsPlayingUISequence(int uiSequence) {
    return uiSequence == int(CGamePlaygroundUIConfig::EUISequence::Playing)
        || uiSequence == int(CGamePlaygroundUIConfig::EUISequence::Finish);
}

// IsPodiumUISequence reports whether the UI sequence is the podium.
bool IsPodiumUISequence(int uiSequence) {
    return uiSequence == int(CGamePlaygroundUIConfig::EUISequence::Podium);
}

// IsEndRoundUISequence reports whether the UI sequence is an end of round.
bool IsEndRoundUISequence(int uiSequence) {
    return uiSequence == int(CGamePlaygroundUIConfig::EUISequence::EndRound)
        || uiSequence == int(CGamePlaygroundUIConfig::EUISequence::UIInteraction);
}
