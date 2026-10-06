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

// Kept outside the monitor, so restarting monitoring doesn't renumber the map's rounds.
int mapRoundsEnded = 0;

void ResetMapRounds() {
    mapRoundsEnded = 0;
}

class RaceMonitor {
    string matchId;
    string apiKey;
    RaceState currentState = RaceState::NoMap;
    RoundTracker@ roundTracker;

    uint roundEndMessagesSent = 0;
    uint roundEndMessagesSucceeded = 0;
    uint roundEndMessagesFailed = 0;
    int lastRequestStatus = 0;
    string lastSuccessMessage = "";
    string lastError = "";

    RaceMonitor(const string &in matchId, const string &in apiKey) {
        this.matchId = matchId;
        this.apiKey = apiKey;
    }

    void Update() {
        if (NewMapThisFrame) OnNewMap();
        auto newState = CalculateState();
        if (newState != currentState) {
            UpdateState(currentState, newState);
        }
        auto raceData = MLFeed::GetRaceData_V4();
        // A round interrupted by a warmup never ends.
        if (raceData.WarmupActive && roundTracker !is null) {
#if DEV
            DevTraceRoundDropped(roundTracker, "warmup started");
#endif
            @roundTracker = null;
        }
        if (currentState == RaceState::Active) {
            roundTracker.WatchRace(raceData);
        }
#if DEV
        DevWatchScores(this);
#endif
    }

    void OnNewMap() {
        @roundTracker = null;
        // Racing on the new map then starts its first round, even if the state was already Active.
        currentState = RaceState::NoMap;
    }

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

    void UpdateState(RaceState previousState, RaceState newState) {
#if DEV
        DevTraceState(this, previousState, newState);
#endif
        currentState = newState;
        if (newState == RaceState::Active) OnGoingActive();
        if (newState == RaceState::EndRound_or_Similar && roundTracker !is null) OnEndRound();
    }

    void OnGoingActive() {
        // Racing that stops without an end of round, such as a brief blip, doesn't end the round.
        if (roundTracker !is null) return;
        @roundTracker = RoundTracker(GetLocalLogin());
    }

    void OnEndRound() {
        mapRoundsEnded++;
        // Captured now: the report waits for the server, and must not pick up the next round's or map's values.
        roundTracker.number = mapRoundsEnded;
        roundTracker.mapUid = mapUid;
        roundTracker.timestamp = Time::Stamp;
#if DEV
        DevTraceEndRound(roundTracker);
#endif
        startnew(CoroutineFuncUserdata(ReportRound), roundTracker);
        @roundTracker = null;
    }

    void ReportRound(ref@ endedRoundReference) {
        RoundTracker@ endedRound = cast<RoundTracker>(endedRoundReference);
        bool scoreCommitSeen = WaitForScoreCommit(endedRound);
        endedRound.ApplyServerVerdictOnOwnFinish(scoreCommitSeen);
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

    // Re-reads the ended round until the score commit, so the server's corrections to the runner's times are picked up.
    bool WaitForScoreCommit(RoundTracker@ endedRound) {
        auto raceData = MLFeed::GetRaceData_V4();
        ScoreCommitWatch@ commitWatch = ScoreCommitWatch(raceData);
        // Stop once no commit can come: the round moved on, monitoring stopped (currentState no longer updates),
        // or MLFeed reset its data for another map.
        while (raceMonitor is this && currentState == RaceState::EndRound_or_Similar && raceData.Map == endedRound.mapUid) {
            // Checked before reading: the commit resets round points.
            if (commitWatch.Committed()) return true;
            endedRound.WatchEndOfRound();
            yield();
        }
        return false;
    }

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

    void DrawRequestsInfo() {
        UI::Text("Rounds Ended On This Map: " + mapRoundsEnded);
        UI::Text("RoundEnd Messages Sent: " + roundEndMessagesSent);
        UI::Text("RoundEnd Messages Succeeded: " + roundEndMessagesSucceeded);
        UI::Text("RoundEnd Messages Failed: " + roundEndMessagesFailed);
        UI::Text("Last Request Status: " + lastRequestStatus);
        UI::Text("Last Success Message: " + lastSuccessMessage);
        UI::Text("Last Error: " + lastError);
    }

    void DrawCurrentState() {
        UI::AlignTextToFramePadding();
        UI::Text("Current State: " + tostring(currentState));
        UI::AlignTextToFramePadding();
        UI::Text("ECM ID: " + matchId);
        DrawStopMonitoringButton();
    }
}
