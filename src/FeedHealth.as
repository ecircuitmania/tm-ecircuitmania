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

#if DEV
[Setting category="Dev" name="Simulate MLFeed stall (feed health test)"]
bool S_DevSimulateFeedStall = false;
#endif

// MLFeed's view of one player, as far as the checks below need it.
class FeedPlayerView {
    int startTime;
    int roundPoints;
    uint cpCount;
}

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

#if DEV
    dictionary frozenFeed; // login -> FeedPlayerView, for the simulated stall
#endif

    // Call every frame while monitoring, in any state: the checks only compare
    // MLFeed with the engine, so they hold during warmup and between rounds too.
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

    CSmPlayer@ FindLocalCSmPlayer() {
        auto pg = GetApp().CurrentPlayground;
        if (pg is null) return null;
        string login = GetLocalLogin();
        for (uint i = 0; i < pg.Players.Length; i++) {
            auto smp = cast<CSmPlayer>(pg.Players[i]);
            if (smp is null) continue;
            auto sp = cast<CSmScriptPlayer>(smp.ScriptAPI);
            if (sp !is null && sp.Login == login) return smp;
        }
        return null;
    }

    // Count the checkpoints the local player passes, from the engine's respawn landmark.
    void TrackLocalLandmarks() {
        auto smp = FindLocalCSmPlayer();
        if (smp is null) return;
        uint lm = smp.CurrentLaunchedRespawnLandmarkIndex;
        if (smp.StartTime != localRunStart) {
            // New run: the landmark is the start line.
            localRunStart = smp.StartTime;
            localLastLandmark = lm;
            localLandmarkChanges = 0;
            return;
        }
        if (lm == NoLandmark || lm == localLastLandmark) return;
        if (localLastLandmark != NoLandmark) localLandmarkChanges++;
        localLastLandmark = lm;
    }

    FeedPlayerView@ GetFeedView(const MLFeed::PlayerCpInfo_V4@ p) {
        FeedPlayerView v;
        v.startTime = p.StartTime;
        v.roundPoints = p.RoundPoints;
        v.cpCount = p.CpCount;
#if DEV
        // Simulated stall: MLFeed keeps reporting what it had when the stall began.
        if (S_DevSimulateFeedStall) {
            FeedPlayerView@ frozen;
            if (frozenFeed.Get(p.Login, @frozen)) return frozen;
            frozenFeed.Set(p.Login, @v);
        } else if (frozenFeed.GetSize() > 0) {
            frozenFeed.DeleteAll();
        }
#endif
        return v;
    }

    // The first disagreement between the engine and MLFeed, or "".
    string FindMismatch() {
        auto pg = GetApp().CurrentPlayground;
        if (pg is null) return "";
        auto rd = MLFeed::GetRaceData_V4();
        if (rd is null) return "MLFeed returned no race data";
        int gameTime = MLFeed::GameTime;
        string localLogin = GetLocalLogin();
        array<string> fingerprint;
        string issue;

        for (uint i = 0; i < pg.Players.Length; i++) {
            auto smp = cast<CSmPlayer>(pg.Players[i]);
            if (smp is null) continue;
            auto sp = cast<CSmScriptPlayer>(smp.ScriptAPI);
            if (sp is null) continue;

            const MLFeed::PlayerCpInfo_V4@ p = null;
            for (uint j = 0; j < rd.SortedPlayers_Race.Length; j++) {
                auto candidate = cast<MLFeed::PlayerCpInfo_V4>(rd.SortedPlayers_Race[j]);
                if (candidate.Login == sp.Login) { @p = candidate; break; }
            }
            string name = sp.Login;
            if (sp.User !is null) name = sp.User.Name;
            bool isLocal = sp.Login == localLogin;

            if (p is null) {
                // Players joining or leaving, or a map loading, can briefly be
                // missing from either side. But if MLFeed doesn't list the
                // local player while they pass checkpoints, it isn't updating.
                if (issue.Length == 0 && isLocal && smp.StartTime == localRunStart && localLandmarkChanges > 0) {
                    issue = name + " has passed " + localLandmarkChanges + " checkpoints, MLFeed doesn't list them";
                }
                continue;
            }
            auto feed = GetFeedView(p);
            fingerprint.InsertLast(sp.Login + ":" + feed.startTime + ":" + feed.roundPoints + ":" + feed.cpCount);
            if (issue.Length > 0) continue;

            // 1. Someone started a new run that MLFeed never saw.
            if (smp.StartTime > feed.startTime && gameTime - smp.StartTime >= StartGraceMs) {
                issue = name + " started a new run, MLFeed still shows the previous one";
            }
            // 2. The mode awarded round points that MLFeed never saw.
            else if (smp.Score !is null && smp.Score.RoundPoints != feed.roundPoints) {
                issue = name + " has " + smp.Score.RoundPoints + " round points, MLFeed shows " + feed.roundPoints;
            }
            // 3. The local player passed checkpoints that MLFeed never saw.
            else if (isLocal && smp.StartTime == localRunStart
                && feed.startTime == smp.StartTime && localLandmarkChanges > feed.cpCount) {
                issue = name + " has passed " + localLandmarkChanges + " checkpoints, MLFeed shows " + feed.cpCount;
            }
        }
        // Player order can change (e.g. after a map reload), so sort.
        fingerprint.SortAsc();
        feedFingerprint = Text::Join(fingerprint, ";");
        return issue;
    }

    // Loud notification, once per incident. A driver gets it when they're not
    // racing, so it doesn't pop up mid-run; a spectator gets it straight away.
    void MaybeNotify() {
        if (!unhealthy || notified) return;
        if (LocalPlayerIsRacing()) return;
        notified = true;
        NotifyError("MLFeed has stopped receiving race data, so ECM match data is incomplete.\n"
            + "Reload \"MLFeed: Race Data\" in Openplanet's Plugin Manager (or restart the game), then start monitoring again.");
    }

    // The engine only has the local car's state while it is on track.
    bool LocalPlayerIsRacing() {
        auto smp = FindLocalCSmPlayer();
        if (smp is null) return false;
        auto sp = cast<CSmScriptPlayer>(smp.ScriptAPI);
        return sp !is null && sp.IsEntityStateAvailable;
    }

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
