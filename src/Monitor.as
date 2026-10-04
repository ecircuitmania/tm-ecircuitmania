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
    // Rounds started on this map; the round being raced has this number.
    int currentRound = 0;
    // The round being raced, from going Active until its end of round.
    RoundTracker@ roundTracker;
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
    }

    // Update follows the race state, tracks the round being raced and checks MLFeed's health, every frame while monitoring.
    void Update() {
        if (NewMapThisFrame) OnNewMap();
        auto newState = CalculateState();
        if (newState != currentState) {
            UpdateState(currentState, newState);
        }
        if (currentState == RaceState::Active) {
            roundTracker.WatchRace(MLFeed::GetRaceData_V4());
            roundTracker.localFinishVerdict.WatchRace(roundTracker);
        }
        feedHealth.Update();
#if DEV
        DevWatchScores(this);
#endif
    }

    // OnNewMap starts the round count again, dropping a round that never ended on the previous map.
    void OnNewMap() {
        currentRound = 0;
        @roundTracker = null;
        // Racing on the new map then starts its first round, even if the state was already Active.
        currentState = RaceState::NoMap;
    }

    // CalculateState works out the race state from MLFeed's rules times and the UI sequence.
    RaceState CalculateState() {
        if (!IsPlaygroundLoaded) return RaceState::NoMap;
        auto raceData = MLFeed::GetRaceData_V4();
        if (raceData.Rules_StartTime < 0 || (raceData.Rules_EndTime > 0 && raceData.Rules_StartTime >= raceData.Rules_EndTime)) return RaceState::NoRound_or_Warmup;
        if (raceData.WarmupActive) return RaceState::NoRound_or_Warmup;
        auto game = cast<CGameManiaPlanet>(GetApp());
        if (game.CurrentPlayground.GameTerminals.Length == 0) return RaceState::NoRound_or_Warmup;
        int uiSequence = int(game.CurrentPlayground.GameTerminals[0].UISequence_Current);
        if (uiSequence == int(CGamePlaygroundUIConfig::EUISequence::EndRound)
            || uiSequence == int(CGamePlaygroundUIConfig::EUISequence::UIInteraction)) return RaceState::EndRound_or_Similar;
        if (uiSequence == int(CGamePlaygroundUIConfig::EUISequence::Playing)
            || uiSequence == int(CGamePlaygroundUIConfig::EUISequence::Finish)) return RaceState::Active;
        if (uiSequence == int(CGamePlaygroundUIConfig::EUISequence::Podium)) return RaceState::Podium;
        return RaceState::NoRound_or_Warmup;
    }

    // UpdateState monitors the race state and calls handlers depending on the new state.
    void UpdateState(RaceState previousState, RaceState newState) {
#if DEV
        DevTraceState(this, previousState, newState);
#endif
        currentState = newState;
        if (newState == RaceState::Active) OnGoingActive();
        if (newState == RaceState::EndRound_or_Similar && previousState == RaceState::Active) OnEndRound();
    }

    // OnGoingActive starts a new round, unless racing resumes in a round that hasn't ended.
    void OnGoingActive() {
        // Racing that stops without an end of round (a warmup starting, or a brief blip) doesn't end the round.
        if (roundTracker !is null) return;
        currentRound++;
        @roundTracker = RoundTracker(currentRound, GetLocalLogin());
    }

    // OnEndRound starts the report for the round that just ended.
    void OnEndRound() {
        // Captured now: the report waits for the server, and must not pick up the next map's values.
        roundTracker.mapUid = mapUid;
        roundTracker.timestamp = Time::Stamp;
#if DEV
        DevTraceEndRound(roundTracker);
#endif
        startnew(CoroutineFuncUserdata(ReportRound), roundTracker);
        @roundTracker = null;
    }

    // ReportRound waits for the server's verdict on the round, then ranks it and sends it to ECM.
    void ReportRound(ref@ endedRoundReference) {
        RoundTracker@ endedRound = cast<RoundTracker>(endedRoundReference);
        bool scoreCommitSeen = WaitForScoreCommit(endedRound);
        endedRound.localFinishVerdict.Decide(scoreCommitSeen, endedRound.LocalFinishShown());
        auto rankedResults = endedRound.RankedResults();
        auto payload = MakeRoundEndPayload(rankedResults, endedRound.number, endedRound.mapUid, endedRound.timestamp);
#if DEV
        DevTraceRoundReport(this, endedRound, scoreCommitSeen, rankedResults, payload);
#endif
        roundEndMessagesSent++;
        ECMResponse@ response = SendRoundEnd(apiKey, matchId, Json::Write(payload));
        lastRequestStatus = response.status;
        if (response.success) {
            roundEndMessagesSucceeded++;
            lastSuccessMessage = response.message;
        } else {
            roundEndMessagesFailed++;
            lastError = response.message;
        }
    }

    // WaitForScoreCommit keeps re-reading the ended round until the server's score commit, so the server's corrections to the runner's times are picked up, and reports whether the commit was seen.
    bool WaitForScoreCommit(RoundTracker@ endedRound) {
        ScoreCommitWatch@ commitWatch = ScoreCommitWatch(MLFeed::GetRaceData_V4());
        // The server commits before it ends the end-of-round sequence, so once the round has moved on, no commit is coming.
        // If monitoring stopped or we left the server, Update() no longer runs and currentState would never change.
        while (raceMonitor is this && currentState == RaceState::EndRound_or_Similar) {
            // Checked before reading: the commit resets round points.
            if (commitWatch.Committed()) return true;
            endedRound.WatchEndOfRound();
            endedRound.localFinishVerdict.WatchEndOfRound(endedRound);
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
