// Detects when MLFeed stops receiving race data. MLHook drops a plugin's feed
// if handling one event takes more than 1 ms, and stops routing events entirely
// in its "panic mode"; either way MLFeed goes quiet and every round we send
// would be empty or incomplete.
//
// We compare MLFeed against values the engine itself syncs to this client.
// Most of the script player (CSmScriptPlayer: RaceWaypointTimes, SpawnStatus,
// CurrentRaceTime) is only filled server-side, and other players' in-race
// state isn't sent to us at all, so only these are usable:
//   - every player's StartTime: changes whenever a player starts a new run;
//   - every player's Score.RoundPoints: changes as the mode awards points;
//   - the local player's respawn landmark: changes at each checkpoint.
// While the feed works these agree with MLFeed within a frame or two. If they
// disagree for several seconds, the feed has stopped.

// FeedPlayerView is MLFeed's view of one player, as far as the checks below need it.
class FeedPlayerView {
    int startTime;
    int roundPoints;
    uint cpCount;
}

// FeedHealthCheck warns the user when MLFeed stops receiving race data.
class FeedHealthCheck {
    uint CheckEveryMs = 500;
    uint FailAfterMs = 3000;
    uint RecoverAfterMs = 3000;
    // A run must have been going this long before its StartTime is compared.
    int StartGraceMs = 1000;
    uint NoLandmark = 0xFFFFFFFF;

    bool unhealthy = false;
    string detail;
    bool notified = false;

    uint lastCheck = 0;
    // MLFeed's values at the last check, and when the stall was detected. A
    // stalled feed can briefly agree with the engine again (e.g. when round
    // points reset to 0, or while a map loads and MLFeed lists nobody), so
    // recovery also needs MLFeed itself to have moved, with players listed.
    string feedFingerprint;
    string stalledFingerprint;
    uint mismatchSince = 0;
    uint okSince = 0;

    // Local player's checkpoints as seen by the engine, for the current run.
    int localRunStart = -1;
    uint localLastLandmark = 0xFFFFFFFF;
    uint localLandmarkChanges = 0;

    // Update checks the feed every CheckEveryMs. Call every frame while monitoring, in any state:
    // the checks only compare MLFeed with the engine, so they hold during warmup and between rounds too.
    void Update() {
        MaybeNotify();
        if (Time::Now - lastCheck < CheckEveryMs) return;
        lastCheck = Time::Now;

        TrackLocalLandmarks();
        string issue = FindMismatch();
        if (issue.Length > 0) {
            okSince = 0;
            if (mismatchSince == 0) mismatchSince = Time::Now;
            if (!unhealthy && Time::Now - mismatchSince >= FailAfterMs) {
                unhealthy = true;
                notified = false;
                detail = issue;
                stalledFingerprint = feedFingerprint;
                warn("MLFeed is not receiving race data: " + issue);
            }
        } else {
            mismatchSince = 0;
            if (unhealthy) {
                if (feedFingerprint.Length == 0 || feedFingerprint == stalledFingerprint) {
                    okSince = 0;
                    return;
                }
                if (okSince == 0) okSince = Time::Now;
                if (Time::Now - okSince >= RecoverAfterMs) {
                    unhealthy = false;
                    detail = "";
                    print("MLFeed race data is flowing again.");
                    NotifySuccess("MLFeed race data is flowing again.");
                }
            }
        }
    }

    // FindLocalCSmPlayer returns the engine's player object for this client, or null.
    CSmPlayer@ FindLocalCSmPlayer() {
        auto playground = GetApp().CurrentPlayground;
        if (playground is null) return null;
        string login = GetLocalLogin();
        for (uint i = 0; i < playground.Players.Length; i++) {
            auto enginePlayer = cast<CSmPlayer>(playground.Players[i]);
            if (enginePlayer is null) continue;
            auto scriptPlayer = cast<CSmScriptPlayer>(enginePlayer.ScriptAPI);
            if (scriptPlayer !is null && scriptPlayer.Login == login) return enginePlayer;
        }
        return null;
    }

    // TrackLocalLandmarks counts the checkpoints the local player passes, from the engine's respawn landmark.
    void TrackLocalLandmarks() {
        auto enginePlayer = FindLocalCSmPlayer();
        if (enginePlayer is null) return;
        uint landmarkIndex = enginePlayer.CurrentLaunchedRespawnLandmarkIndex;
        if (enginePlayer.StartTime != localRunStart) {
            // New run: the landmark is the start line.
            localRunStart = enginePlayer.StartTime;
            localLastLandmark = landmarkIndex;
            localLandmarkChanges = 0;
            return;
        }
        if (landmarkIndex == NoLandmark || landmarkIndex == localLastLandmark) return;
        if (localLastLandmark != NoLandmark) localLandmarkChanges++;
        localLastLandmark = landmarkIndex;
    }

    // GetFeedView returns MLFeed's view of a player.
    FeedPlayerView@ GetFeedView(const MLFeed::PlayerCpInfo_V4@ feedPlayer) {
        FeedPlayerView view;
        view.startTime = feedPlayer.StartTime;
        view.roundPoints = feedPlayer.RoundPoints;
        view.cpCount = feedPlayer.CpCount;
#if DEV
        return DevSimulatedFeedView(feedPlayer.Login, @view);
#else
        return view;
#endif
    }

    // FindMismatch returns the first disagreement between the engine and MLFeed, or "".
    string FindMismatch() {
        auto playground = GetApp().CurrentPlayground;
        if (playground is null) return "";
        auto raceData = MLFeed::GetRaceData_V4();
        if (raceData is null) return "MLFeed returned no race data";
        int gameTime = MLFeed::GameTime;
        string localLogin = GetLocalLogin();
        array<string> fingerprint;
        string issue;

        for (uint i = 0; i < playground.Players.Length; i++) {
            auto enginePlayer = cast<CSmPlayer>(playground.Players[i]);
            if (enginePlayer is null) continue;
            auto scriptPlayer = cast<CSmScriptPlayer>(enginePlayer.ScriptAPI);
            if (scriptPlayer is null) continue;

            const MLFeed::PlayerCpInfo_V4@ feedPlayer = null;
            for (uint feedIndex = 0; feedIndex < raceData.SortedPlayers_Race.Length; feedIndex++) {
                auto candidate = cast<MLFeed::PlayerCpInfo_V4>(raceData.SortedPlayers_Race[feedIndex]);
                if (candidate.Login == scriptPlayer.Login) { @feedPlayer = candidate; break; }
            }
            string name = scriptPlayer.Login;
            if (scriptPlayer.User !is null) name = scriptPlayer.User.Name;
            bool isLocal = scriptPlayer.Login == localLogin;

            if (feedPlayer is null) {
                // Players joining or leaving, or a map loading, can briefly be
                // missing from either side. But if MLFeed doesn't list the
                // local player while they pass checkpoints, it isn't updating.
                if (issue.Length == 0 && isLocal && enginePlayer.StartTime == localRunStart && localLandmarkChanges > 0) {
                    issue = name + " has passed " + localLandmarkChanges + " checkpoints, MLFeed doesn't list them";
                }
                continue;
            }
            auto feed = GetFeedView(feedPlayer);
            fingerprint.InsertLast(scriptPlayer.Login + ":" + feed.startTime + ":" + feed.roundPoints + ":" + feed.cpCount);
            if (issue.Length > 0) continue;

            // 1. Someone started a new run that MLFeed never saw.
            if (enginePlayer.StartTime > feed.startTime && gameTime - enginePlayer.StartTime >= StartGraceMs) {
                issue = name + " started a new run, MLFeed still shows the previous one";
            }
            // 2. The mode awarded round points that MLFeed never saw.
            else if (enginePlayer.Score !is null && enginePlayer.Score.RoundPoints != feed.roundPoints) {
                issue = name + " has " + enginePlayer.Score.RoundPoints + " round points, MLFeed shows " + feed.roundPoints;
            }
            // 3. The local player passed checkpoints that MLFeed never saw.
            else if (isLocal && enginePlayer.StartTime == localRunStart
                && feed.startTime == enginePlayer.StartTime && localLandmarkChanges > feed.cpCount) {
                issue = name + " has passed " + localLandmarkChanges + " checkpoints, MLFeed shows " + feed.cpCount;
            }
        }
        // Player order can change (e.g. after a map reload), so sort.
        fingerprint.SortAsc();
        feedFingerprint = Text::Join(fingerprint, ";");
        return issue;
    }

    // MaybeNotify shows the loud notification, once per incident.
    // A driver gets it when they're not racing, so it doesn't pop up mid-run; a spectator gets it straight away.
    void MaybeNotify() {
        if (!unhealthy || notified) return;
        if (LocalPlayerIsRacing()) return;
        notified = true;
        NotifyError("MLFeed has stopped receiving race data, so ECM match data is incomplete.\n"
            + "Reload \"MLFeed: Race Data\" in Openplanet's Plugin Manager (or restart the game), then start monitoring again.");
    }

    // LocalPlayerIsRacing reports whether the local car is on track; the engine only has its state then.
    bool LocalPlayerIsRacing() {
        auto enginePlayer = FindLocalCSmPlayer();
        if (enginePlayer is null) return false;
        auto scriptPlayer = cast<CSmScriptPlayer>(enginePlayer.ScriptAPI);
        return scriptPlayer !is null && scriptPlayer.IsEntityStateAvailable;
    }

    // DrawBanner draws the warning banner in the plugin window while the feed is stalled.
    void DrawBanner() {
        if (!unhealthy) return;
        UI::PushStyleColor(UI::Col::Text, vec4(1, .35, .25, 1));
        UI::TextWrapped(Icons::ExclamationTriangle + " MLFeed has stopped receiving race data. Match data for this round is incomplete.");
        UI::PopStyleColor();
        UI::TextWrapped("Reload \"MLFeed: Race Data\" in Openplanet's Plugin Manager (or restart the game), then start monitoring again.");
        UI::TextDisabled(detail);
        UI::Separator();
    }
}
