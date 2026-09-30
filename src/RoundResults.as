// Round-end ranking.
//
// Positions used to be assigned in the order this client *noticed* each finish,
// which depends on network latency, not on race time. Instead we collect every
// player's final result when the round ends and sort by race time, using
// Nadeo's tiebreak: race time, then previous checkpoint times (latest first),
// then points, then name. Players without a finish come after all finishers,
// ranked by checkpoints reached, then time at their last checkpoint.

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
}

// Build a RoundResult from MLFeed's current view of a player.
// Call at round end: by then MLFeed holds the server-corrected times.
RoundResult@ RoundResultFromPlayer(const MLFeed::PlayerCpInfo_V4@ player, bool forceDnf = false) {
    int[] cps;
    auto raw = player.CpTimes;
    // MLFeed's CpTimes has a leading 0 for the start.
    for (uint i = 1; i < raw.Length; i++) cps.InsertLast(raw[i]);
    int ft = (!forceDnf && player.IsFinished) ? player.LastCpTime : -1;
    RoundResult@ rr = RoundResult(player.WebServicesUserId, player.Name, ft, cps, player.Points);
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

#if DEV
RoundResult@ TestRR(const string &in wsid, int finishTime, const string &in cps, int points = 0) {
    int[] arr;
    auto parts = cps.Split(",");
    for (uint i = 0; i < parts.Length; i++) arr.InsertLast(Text::ParseInt(parts[i]));
    return RoundResult(wsid, wsid, finishTime, arr, points);
}

// Quick self-check run on plugin load in dev builds.
void RunRoundResultTests() {
    uint failed = 0;

    // 1. Detection order must not matter: slower player noticed first.
    {
        array<RoundResult@> r;
        r.InsertLast(TestRR("nix", 16700, "11470,16700", 0));
        r.InsertLast(TestRR("dawg", 16070, "4140,16070", 0));
        SortRoundResults(r);
        if (r[0].wsid != "dawg") { failed++; warn("RoundResult test 1 failed: faster finisher not first"); }
    }
    // 2. Equal finish time: better previous checkpoint wins.
    {
        array<RoundResult@> r;
        r.InsertLast(TestRR("a", 20000, "5000,12000,20000", 0));
        r.InsertLast(TestRR("b", 20000, "5500,11900,20000", 0));
        SortRoundResults(r);
        if (r[0].wsid != "b") { failed++; warn("RoundResult test 2 failed: previous CP tiebreak"); }
    }
    // 3. Finishers ahead of non-finishers; non-finishers by CPs then time.
    {
        array<RoundResult@> r;
        r.InsertLast(TestRR("dnf2", -1, "5000", 0));
        r.InsertLast(TestRR("dnf1", -1, "5000,9000", 0));
        r.InsertLast(TestRR("fin", 30000, "5000,9000,30000", 0));
        SortRoundResults(r);
        if (r[0].wsid != "fin" || r[1].wsid != "dnf1" || r[2].wsid != "dnf2") { failed++; warn("RoundResult test 3 failed: DNF ordering"); }
    }
    // 4. Full tie falls back to points, then name.
    {
        array<RoundResult@> r;
        r.InsertLast(TestRR("z", 10000, "10000", 5));
        r.InsertLast(TestRR("y", 10000, "10000", 5));
        r.InsertLast(TestRR("x", 10000, "10000", 9));
        SortRoundResults(r);
        if (r[0].wsid != "x" || r[1].wsid != "y" || r[2].wsid != "z") { failed++; warn("RoundResult test 4 failed: points/name tiebreak"); }
    }

    if (failed == 0) print("RoundResult tests: all passed");
    else warn("RoundResult tests: " + failed + " failed");
}
#endif
