// FeedHealthCheck warns when MLFeed stops receiving race data. The MLHook -> MLFeed chain can break while
// both plugins look fine: MLHook drops slow hooks and has a "panic mode", turning MLHook off and on removes
// MLFeed's page, and turning MLFeed off and on leaves its hook unregistered.
//
// MLFeed's UpdateNonce moves whenever it handles an event. Once it has been quiet for QuietMs, we ask its
// page to resend every player's state. MissesToStall unanswered requests in a row mean it has stalled.
class FeedHealthCheck {
    uint QuietMs = 3000;
    uint AnswerWithinMs = 2000;
    uint MissesToStall = 3;
    // More than one, as MLFeed also moves its nonce once by itself when a map loads.
    uint AnswersToRecover = 2;

    bool stalled = false;
    bool notified = false;
    uint lastNonce = 0;
    // 0 until MLFeed is heard from while the check is active.
    uint lastActivityAt = 0;
    // 0 when no request is awaiting an answer.
    uint requestSentAt = 0;
    uint holdRequestsUntil = 0;
    uint missedRequests = 0;
    uint answersWhileStalled = 0;

    // Needs a recent answer, so monitoring can't start on a stalled MLFeed before a request has gone unanswered.
    bool get_ReadyToStart() const {
        return !stalled && lastActivityAt > 0 && Time::Now - lastActivityAt < QuietMs + AnswerWithinMs;
    }

    // Gives the new map's ManiaLink pages time to start.
    void OnNewMap() {
        holdRequestsUntil = Time::Now + QuietMs;
        requestSentAt = 0;
        missedRequests = 0;
        answersWhileStalled = 0;
    }

    void Update(bool active) {
        MaybeNotify();
        auto raceData = MLFeed::GetRaceData_V4();
        if (raceData is null) return;
        bool moved = raceData.UpdateNonce != lastNonce;
        lastNonce = raceData.UpdateNonce;
        if (!active) {
            lastActivityAt = 0;
            requestSentAt = 0;
            missedRequests = 0;
            answersWhileStalled = 0;
            return;
        }
        if (stalled) {
            WatchForRecovery(moved);
            return;
        }
        if (moved) {
            lastActivityAt = Time::Now;
            requestSentAt = 0;
            missedRequests = 0;
            return;
        }
        if (requestSentAt > 0) {
            if (Time::Now - requestSentAt < AnswerWithinMs) return;
            requestSentAt = 0;
            missedRequests++;
            if (missedRequests < MissesToStall) return;
            stalled = true;
            notified = false;
            answersWhileStalled = 0;
            warn("MLFeed is not receiving race data: it didn't answer " + missedRequests + " requests for player states in a row.");
            return;
        }
        if (lastActivityAt > 0 && Time::Now - lastActivityAt < QuietMs) return;
        SendRequest();
    }

    void WatchForRecovery(bool moved) {
        if (requestSentAt == 0) {
            SendRequest();
            return;
        }
        if (moved) {
            requestSentAt = 0;
            holdRequestsUntil = Time::Now + 500;
            answersWhileStalled++;
            if (answersWhileStalled < AnswersToRecover) return;
            stalled = false;
            lastActivityAt = Time::Now;
            print("MLFeed is receiving race data again.");
            UI::ShowNotification(Meta::ExecutingPlugin().Name, "MLFeed is receiving race data again.", vec4(.4, .7, .1, .3), 10000);
            return;
        }
        if (Time::Now - requestSentAt < AnswerWithinMs) return;
        requestSentAt = 0;
        answersWhileStalled = 0;
        holdRequestsUntil = Time::Now + QuietMs;
    }

    void SendRequest() {
        if (Time::Now < holdRequestsUntil) return;
        // MLFeed's page only starts once the playground has players.
        auto playground = GetApp().CurrentPlayground;
        if (playground is null || playground.Players.Length == 0) return;
        MLHook::Queue_MessageManialinkPlayground("RaceStats", {"SendAllPlayerStates"});
        requestSentAt = Time::Now;
    }

    // Waits until the runner's car is off track, so it doesn't pop up mid-run.
    void MaybeNotify() {
        if (!stalled || notified || LocalPlayerIsRacing()) return;
        notified = true;
        NotifyError("MLFeed has stopped receiving race data, so ECM match data is incomplete.\n"
            + "Reload \"MLFeed: Race Data\" in Openplanet's Plugin Manager (or restart the game), then start monitoring again.");
    }

    bool LocalPlayerIsRacing() {
        auto playground = GetApp().CurrentPlayground;
        if (playground is null) return false;
        string login = GetLocalLogin();
        for (uint i = 0; i < playground.Players.Length; i++) {
            auto enginePlayer = cast<CSmPlayer>(playground.Players[i]);
            if (enginePlayer is null) continue;
            auto scriptPlayer = cast<CSmScriptPlayer>(enginePlayer.ScriptAPI);
            if (scriptPlayer !is null && scriptPlayer.Login == login) return scriptPlayer.IsEntityStateAvailable;
        }
        return false;
    }

    void DrawBanner() {
        if (!stalled) return;
        UI::PushStyleColor(UI::Col::Text, vec4(1, .35, .25, 1));
        UI::TextWrapped(Icons::ExclamationTriangle + " MLFeed has stopped receiving race data, so ECM match data is incomplete.");
        UI::PopStyleColor();
        UI::TextWrapped("Reload \"MLFeed: Race Data\" in Openplanet's Plugin Manager (or restart the game), then start monitoring again.");
        UI::Separator();
    }
}
