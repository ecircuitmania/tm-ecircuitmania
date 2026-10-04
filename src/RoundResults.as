class RoundResult {
    string wsid;
    string name;
    // Final race time in ms, or -1 if the player did not finish.
    int finishTime = -1;
    // Checkpoint times in ms, index 0 is the first checkpoint (no leading zero).
    int[] cpTimes;
    int points = 0;
    // Server-assigned round points, kept for dev cross-checks only.
    int roundPoints = 0;

    RoundResult() {}

    RoundResult(const string &in wsid, const string &in name, int finishTime, const int[] &in cpTimes, int points) {
        this.wsid = wsid;
        this.name = name;
        this.finishTime = finishTime;
        this.cpTimes = cpTimes;
        this.points = points;
    }

    bool get_Finished() const { return finishTime >= 0; }
    int get_LastCpTime() const { return cpTimes.Length == 0 ? -1 : cpTimes[cpTimes.Length - 1]; }

    // For a finish MLFeed shows but the round doesn't count. The finish crossing
    // is dropped too, so the DNF ranks by the checkpoints reached before it.
    void MaybeMarkDnf() {
        if (Finished && cpTimes.Length > 0) cpTimes.RemoveLast();
        finishTime = -1;
    }
}

// Build a RoundResult from MLFeed's current view of a player.
// Call at round end: by then MLFeed holds the server-corrected times.
RoundResult@ RoundResultFromPlayer(const MLFeed::PlayerCpInfo_V4@ player) {
    int[] cps;
    auto raw = player.CpTimes;
    // MLFeed's CpTimes has a leading 0 for the start.
    for (uint i = 1; i < raw.Length; i++) cps.InsertLast(raw[i]);
    int finishTime = player.IsFinished ? player.LastCpTime : -1;
    RoundResult@ rr = RoundResult(player.WebServicesUserId, player.Name, finishTime, cps, player.Points);
    rr.roundPoints = player.RoundPoints;
    return rr;
}

// true if a should be ranked ahead of b
bool RoundResultLess(const RoundResult@ a, const RoundResult@ b) {
    if (a.Finished != b.Finished) return a.Finished;

    if (a.Finished) {
        if (a.finishTime != b.finishTime) return a.finishTime < b.finishTime;
        // Tiebreak on previous checkpoint times, latest checkpoint first.
        // The last entry is the finish itself, so start one before it.
        int ia = int(a.cpTimes.Length) - 2;
        int ib = int(b.cpTimes.Length) - 2;
        while (ia >= 0 && ib >= 0) {
            if (a.cpTimes[ia] != b.cpTimes[ib]) return a.cpTimes[ia] < b.cpTimes[ib];
            ia--;
            ib--;
        }
    } else {
        // No finish: more checkpoints is better, then earlier time at the last one.
        if (a.cpTimes.Length != b.cpTimes.Length) return a.cpTimes.Length > b.cpTimes.Length;
        if (a.LastCpTime != b.LastCpTime) return a.LastCpTime < b.LastCpTime;
    }

    if (a.points != b.points) return a.points > b.points;
    return a.name < b.name;
}

// Stable insertion sort; rounds have at most a few dozen players.
void SortRoundResults(array<RoundResult@>@ results) {
    for (uint i = 1; i < results.Length; i++) {
        auto item = results[i];
        int j = int(i) - 1;
        while (j >= 0 && RoundResultLess(item, results[uint(j)])) {
            @results[uint(j + 1)] = results[uint(j)];
            j--;
        }
        @results[uint(j + 1)] = item;
    }
}
