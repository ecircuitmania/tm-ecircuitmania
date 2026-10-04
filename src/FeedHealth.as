// FeedHealthCheck warns when MLFeed stops receiving race data. MLHook drops a plugin's feed if
// handling one event takes more than 1 ms, and stops routing events entirely in its "panic mode";
// either way MLFeed goes quiet and the rounds we send are incomplete.
//
// The check: every player the engine shows in a run that started at least StartGraceMs ago must be
// listed by MLFeed with the same StartTime. Spectators don't start runs, so their stale StartTimes
// still match. MLFeed only hears of a StartTime with an event about checkpoints, respawns, spawn status
// or best times, so a run it hasn't heard of yet also mismatches; but a stalled feed receives no events
// at all. So the feed counts as stopped once a mismatch has lasted FailAfterMs with MLFeed's
// UpdateNonce unchanged, and the warning then stays up until monitoring is restarted.
class FeedHealthCheck {
    uint CheckEveryMs = 500;
    uint FailAfterMs = 3000;
    // A run must have been going this long before its StartTime is compared, so MLFeed has had time to see it.
    int StartGraceMs = 1000;

    bool stalled = false;
    bool notified = false;
    uint lastCheck = 0;
    uint mismatchSince = 0;
    // MLFeed's UpdateNonce when the mismatch clock last started. MLFeed also bumps it when it resets for a
    // new map, which only restarts the clock.
    uint mismatchNonce = 0;

    // Update compares MLFeed with the engine every CheckEveryMs, and marks the feed stalled once a mismatch has lasted FailAfterMs without MLFeed receiving anything.
    void Update() {
        MaybeNotify();
        if (stalled || Time::Now - lastCheck < CheckEveryMs) return;
        lastCheck = Time::Now;
        auto raceData = MLFeed::GetRaceData_V4();
        string mismatch = FindMismatch(raceData);
        if (mismatch.Length == 0) {
            mismatchSince = 0;
            return;
        }
        uint nonce = FeedUpdateNonce(raceData);
        if (mismatchSince == 0 || nonce != mismatchNonce) {
            mismatchSince = Time::Now;
            mismatchNonce = nonce;
            return;
        }
        if (Time::Now - mismatchSince < FailAfterMs) return;
        stalled = true;
        warn("MLFeed is not receiving race data: " + mismatch);
    }

    // FeedUpdateNonce returns MLFeed's UpdateNonce, which moves whenever MLFeed handles an event.
    uint FeedUpdateNonce(const MLFeed::HookRaceStatsEventsBase_V4@ raceData) {
        uint nonce = 0;
        if (raceData !is null) nonce = raceData.UpdateNonce;
#if DEV
        nonce = DevSimulatedUpdateNonce(nonce);
#endif
        return nonce;
    }

    // FindMismatch describes the first player whose current run MLFeed hasn't seen, or returns "" if MLFeed agrees with the engine.
    string FindMismatch(const MLFeed::HookRaceStatsEventsBase_V4@ raceData) {
        auto playground = GetApp().CurrentPlayground;
        if (playground is null) return "";
        if (raceData is null) return "MLFeed returned no race data";
        int gameTime = MLFeed::GameTime;
        for (uint i = 0; i < playground.Players.Length; i++) {
            auto enginePlayer = cast<CSmPlayer>(playground.Players[i]);
            if (enginePlayer is null) continue;
            auto scriptPlayer = cast<CSmScriptPlayer>(enginePlayer.ScriptAPI);
            if (scriptPlayer is null) continue;
            int engineStartTime = enginePlayer.StartTime;
            // No run yet, or one too recent for MLFeed to have reported.
            if (engineStartTime <= 0 || gameTime - engineStartTime < StartGraceMs) continue;
            int feedStartTime = FeedStartTime(raceData, scriptPlayer.Login);
            if (feedStartTime == engineStartTime) continue;
            string name = scriptPlayer.Login;
            if (scriptPlayer.User !is null) name = scriptPlayer.User.Name;
            if (feedStartTime < 0) return name + " is in a run, but MLFeed doesn't list them";
            return name + " started a run at " + engineStartTime + ", MLFeed shows " + feedStartTime;
        }
        return "";
    }

    // FeedStartTime returns the StartTime MLFeed lists for the player, or -1 if MLFeed doesn't list them.
    int FeedStartTime(const MLFeed::HookRaceStatsEventsBase_V4@ raceData, const string &in login) {
        for (uint i = 0; i < raceData.SortedPlayers_Race.Length; i++) {
            auto feedPlayer = cast<MLFeed::PlayerCpInfo_V4>(raceData.SortedPlayers_Race[i]);
            if (feedPlayer.Login != login) continue;
            int startTime = feedPlayer.StartTime;
#if DEV
            startTime = DevSimulatedFeedStartTime(login, startTime);
#endif
            return startTime;
        }
        return -1;
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
