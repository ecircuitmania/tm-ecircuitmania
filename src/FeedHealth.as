// FeedHealthCheck warns when MLFeed stops receiving race data. MLFeed hears about the race through
// MLHook, which routes events from MLFeed's ManiaLink page to MLFeed's hook. That chain can break while
// both plugins still look fine: MLHook drops a hook whose event handling takes more than 1 ms, and stops
// routing in its "panic mode"; turning MLHook off and on removes MLFeed's page; turning MLFeed off and on
// leaves its hook unregistered. Either way MLFeed goes quiet and the rounds we send are incomplete.
//
// The check is a round trip through that whole chain. MLFeed's UpdateNonce moves whenever MLFeed handles
// an event, so while anyone is racing it moves all the time and nothing is sent. Once MLFeed has been
// quiet for QuietMs, we ask its page to resend every player's state (the same request MLFeed makes when
// it starts), which answers with events for every player, spawned or not. If MissesToStall requests in a
// row go unanswered, the feed has stopped: a warning shows, and Start Monitoring is disabled. While
// stalled we keep asking, and AnswersToRecover answers in a row clear the warning. One answer isn't
// enough, as MLFeed also moves its nonce once by itself when a map loads.
//
// The check only runs while it matters: while monitoring, or while a key is entered to start. Otherwise
// it sends nothing and only notes MLFeed's nonce. Start Monitoring also waits for MLFeed to have been
// heard from recently, so a stall can't slip through by starting before a request has gone unanswered.
class FeedHealthCheck {
    // How long MLFeed must go without events before we ask it for some.
    uint QuietMs = 3000;
    // How long MLFeed has to answer a request.
    uint AnswerWithinMs = 2000;
    // Unanswered requests in a row before the feed counts as stopped.
    uint MissesToStall = 3;
    // Answered requests in a row before a stopped feed counts as working again.
    uint AnswersToRecover = 2;

    bool stalled = false;
    bool notified = false;
    uint lastNonce = 0;
    // When MLFeed last handled an event since the check became active, or 0 if it hasn't.
    uint lastActivityAt = 0;
    // When the request now awaiting an answer was sent, or 0 if none is.
    uint requestSentAt = 0;
    // No request is sent before this time (a map has just loaded, or we're spacing out requests).
    uint holdRequestsUntil = 0;
    uint missedRequests = 0;
    uint answersWhileStalled = 0;

    // ReadyToStart reports whether MLFeed has been heard from recently enough to start monitoring.
    bool get_ReadyToStart() const {
        return !stalled && lastActivityAt > 0 && Time::Now - lastActivityAt < QuietMs + AnswerWithinMs;
    }

    // OnNewMap gives the new map's ManiaLink pages time to start before we ask MLFeed anything.
    void OnNewMap() {
        holdRequestsUntil = Time::Now + QuietMs;
        requestSentAt = 0;
        missedRequests = 0;
        answersWhileStalled = 0;
    }

    // Update runs every frame while we're in a server. When not active, it only notes MLFeed's nonce.
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

    // WatchForRecovery keeps asking a stalled MLFeed for player states, and clears the stall once it answers AnswersToRecover times in a row.
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

    // SendRequest asks MLFeed's page to resend every player's state, unless requests are on hold or the playground has no players yet.
    void SendRequest() {
        if (Time::Now < holdRequestsUntil) return;
        // MLFeed's page only starts once the playground has players, so there's nothing to ask before then.
        auto playground = GetApp().CurrentPlayground;
        if (playground is null || playground.Players.Length == 0) return;
        MLHook::Queue_MessageManialinkPlayground("RaceStats", {"SendAllPlayerStates"});
        requestSentAt = Time::Now;
    }

    // MaybeNotify shows the error notification once per incident, waiting until the runner's car is off track so it doesn't pop up mid-run.
    void MaybeNotify() {
        if (!stalled || notified || LocalPlayerIsRacing()) return;
        notified = true;
        NotifyError("MLFeed has stopped receiving race data, so ECM match data is incomplete.\n"
            + "Reload \"MLFeed: Race Data\" in Openplanet's Plugin Manager (or restart the game), then start monitoring again.");
    }

    // LocalPlayerIsRacing reports whether the plugin runner's car is on track, which is the only time the engine has its state.
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

    // DrawBanner draws the warning in the plugin window once the feed has stalled.
    void DrawBanner() {
        if (!stalled) return;
        UI::PushStyleColor(UI::Col::Text, vec4(1, .35, .25, 1));
        UI::TextWrapped(Icons::ExclamationTriangle + " MLFeed has stopped receiving race data, so ECM match data is incomplete.");
        UI::PopStyleColor();
        UI::TextWrapped("Reload \"MLFeed: Race Data\" in Openplanet's Plugin Manager (or restart the game), then start monitoring again.");
        UI::Separator();
    }
}
