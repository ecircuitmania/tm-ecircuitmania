// Dev-only self-tests, run on plugin load.
#if DEV

RoundResult@ TestRoundResult(const string &in webServicesUserId, int finishTime, const string &in cpTimesCsv, int points = 0) {
    int[] cpTimes;
    if (cpTimesCsv.Length > 0) {
        auto parts = cpTimesCsv.Split(",");
        for (uint i = 0; i < parts.Length; i++) cpTimes.InsertLast(Text::ParseInt(parts[i]));
    }
    return RoundResult(webServicesUserId, webServicesUserId, finishTime, cpTimes, points);
}

string TestVerdict(bool scoreCommitSeen, bool haveSample, bool signalSeen, bool serverConfirmed) {
    ServerVerdictOnOwnFinish verdict;
    verdict.haveSample = haveSample;
    verdict.roundPointsSignal = signalSeen;
    verdict.serverConfirmed = serverConfirmed;
    auto outcome = verdict.Decide(scoreCommitSeen);
    if (outcome == ServerVerdict::Confirmed) return "confirmed";
    if (outcome == ServerVerdict::Rejected) return "rejected";
    return "none: " + verdict.noVerdictReason;
}

bool TestConfirms(int sampledRoundPoints, const string &in sampledPreviousRaceTimes, bool roundPointsSignal, bool previousRaceTimesSignal, int roundPoints, const string &in previousRaceTimes) {
    ServerVerdictOnOwnFinish verdict;
    verdict.sampledRoundPoints = sampledRoundPoints;
    verdict.sampledPreviousRaceTimes = sampledPreviousRaceTimes;
    verdict.roundPointsSignal = roundPointsSignal;
    verdict.previousRaceTimesSignal = previousRaceTimesSignal;
    return verdict.ServerConfirms(roundPoints, previousRaceTimes);
}

string TestSignals(int sampledRoundPoints, int roundPoints, const string &in previousRaceTimesWhileRacing, const string &in previousRaceTimes) {
    ServerVerdictOnOwnFinish verdict;
    verdict.sampledRoundPoints = sampledRoundPoints;
    verdict.LearnFromFinisher(roundPoints, previousRaceTimesWhileRacing, previousRaceTimes);
    string signals = "";
    if (verdict.roundPointsSignal) signals += "round points";
    if (verdict.previousRaceTimesSignal) signals += "previous race times";
    return signals;
}

void RunRoundResultTests() {
    uint failed = 0;

    // 1. Detection order must not matter: slower player noticed first.
    {
        array<RoundResult@> results;
        results.InsertLast(TestRoundResult("nix", 16700, "11470,16700", 0));
        results.InsertLast(TestRoundResult("dawg", 16070, "4140,16070", 0));
        SortRoundResults(results);
        if (results[0].webServicesUserId != "dawg") { failed++; warn("RoundResult test 1 failed: faster finisher not first"); }
    }
    // 2. Equal finish time: better previous checkpoint wins.
    {
        array<RoundResult@> results;
        results.InsertLast(TestRoundResult("a", 20000, "5000,12000,20000", 0));
        results.InsertLast(TestRoundResult("b", 20000, "5500,11900,20000", 0));
        SortRoundResults(results);
        if (results[0].webServicesUserId != "b") { failed++; warn("RoundResult test 2 failed: previous CP tiebreak"); }
    }
    // 3. Finishers ahead of non-finishers; non-finishers by CPs then time.
    {
        array<RoundResult@> results;
        results.InsertLast(TestRoundResult("dnf2", -1, "5000", 0));
        results.InsertLast(TestRoundResult("dnf1", -1, "5000,9000", 0));
        results.InsertLast(TestRoundResult("fin", 30000, "5000,9000,30000", 0));
        SortRoundResults(results);
        if (results[0].webServicesUserId != "fin" || results[1].webServicesUserId != "dnf1" || results[2].webServicesUserId != "dnf2") { failed++; warn("RoundResult test 3 failed: DNF ordering"); }
    }
    // 4. Full tie falls back to points, then name.
    {
        array<RoundResult@> results;
        results.InsertLast(TestRoundResult("z", 10000, "10000", 5));
        results.InsertLast(TestRoundResult("y", 10000, "10000", 5));
        results.InsertLast(TestRoundResult("x", 10000, "10000", 9));
        SortRoundResults(results);
        if (results[0].webServicesUserId != "x" || results[1].webServicesUserId != "y" || results[2].webServicesUserId != "z") { failed++; warn("RoundResult test 4 failed: points/name tiebreak"); }
    }
    // 5. A finish marked DNF ranks by the CPs before it, not with the finish as an extra CP.
    {
        auto rejected = TestRoundResult("rejected", 20000, "5000,9000,20000", 0);
        rejected.MarkDnf();
        array<RoundResult@> results;
        results.InsertLast(rejected);
        results.InsertLast(TestRoundResult("dnf", -1, "5000,8000", 0));
        SortRoundResults(results);
        if (rejected.Finished || results[0].webServicesUserId != "dnf") { failed++; warn("RoundResult test 5 failed: MarkDnf"); }
    }
    // 6. A DNF that never reached checkpoint 1 ranks after DNFs that did.
    {
        array<RoundResult@> results;
        results.InsertLast(TestRoundResult("afk", -1, "", 0));
        results.InsertLast(TestRoundResult("dnf", -1, "5000", 0));
        results.InsertLast(TestRoundResult("fin", 30000, "5000,30000", 0));
        SortRoundResults(results);
        if (results[0].webServicesUserId != "fin" || results[1].webServicesUserId != "dnf" || results[2].webServicesUserId != "afk") { failed++; warn("RoundResult test 6 failed: 0-checkpoint DNF ordering"); }
    }
    // 7. A rejected finish loses its finish crossing, so it ranks by the checkpoints reached before it.
    {
        auto rejected = TestRoundResult("runner", 20450, "11448,20450", 0);
        rejected.MarkDnf();
        if (rejected.Finished || rejected.cpTimes.Length != 1) { failed++; warn("RoundResult test 7 failed: rejected finish"); }
    }
    // 8. The server's verdict on the runner's finish.
    {
        bool passed = TestVerdict(true, true, true, true) == "confirmed"
            && TestVerdict(false, true, true, true) == "confirmed"
            && TestVerdict(true, true, true, false) == "rejected"
            && TestVerdict(true, false, true, false).StartsWith("none: no sample")
            && TestVerdict(true, true, false, false).StartsWith("none: no finish signal")
            && TestVerdict(false, true, true, false).StartsWith("none: the server's score commit");
        if (!passed) { failed++; warn("RoundResult test 8 failed: server verdict on own finish"); }
    }
    // 9. Confirmation only through a signal this round showed.
    {
        bool passed = TestConfirms(-20, "", true, false, -2, "")
            && TestConfirms(0, "", true, false, 6, "")
            && !TestConfirms(0, "", true, false, 0, "")
            && !TestConfirms(-20, "", true, false, 0, "")
            && !TestConfirms(-20, "", true, false, -20, "")
            && !TestConfirms(-20, "", false, true, -2, "")
            && TestConfirms(0, "", false, true, 0, "5000,9000")
            && TestConfirms(0, "4000,8000", false, true, 0, "5000,9000")
            && !TestConfirms(0, "4000,8000", false, true, 0, "4000,8000")
            && !TestConfirms(0, "", true, false, 0, "5000,9000");
        if (!passed) { failed++; warn("RoundResult test 9 failed: server confirmation"); }
    }
    // 10. Signals from another finisher.
    {
        bool passed = TestSignals(-20, -1, "", "") == "round points"
            && TestSignals(0, 0, "", "") == ""
            && TestSignals(0, 0, "4000,8000", "5000,9000") == "previous race times"
            && TestSignals(0, 0, "4000,8000", "4000,8000") == ""
            && TestSignals(0, 0, "4000,8000", "") == "";
        if (!passed) { failed++; warn("RoundResult test 10 failed: finish signals"); }
    }
    // 11. Which runs count for the round.
    {
        RoundTracker@ tracker = RoundTracker(30000, "");
        bool passed = !tracker.StartedThisRound(60000);
        // A mode that sets Rules_StartTime once per map: last round's runs stay out, this round's count.
        tracker.startTime = 1000;
        passed = passed && !tracker.StartedThisRound(2000) && tracker.StartedThisRound(60000) && !tracker.StartedThisRound(uint(-1));
        // A mode whose Rules_StartTime comes after its spawns: nothing counts.
        tracker.startTime = 60001;
        passed = passed && !tracker.StartedThisRound(60000) && tracker.StartedThisRound(60001);
        if (!passed) { failed++; warn("RoundResult test 11 failed: runs counted for the round"); }
    }
    // 12. Drivers seen but none counted: the round isn't sent.
    {
        RoundTracker@ tracker = RoundTracker(0, "");
        bool passed = !tracker.DriversLeftOut();
        tracker.driverSeen = true;
        passed = passed && tracker.DriversLeftOut();
        if (!passed) { failed++; warn("RoundResult test 12 failed: drivers left out"); }
    }
    // 13. Re-reads only move a run forward, but take corrected times.
    {
        auto finished = TestRoundResult("p", 20000, "5000,20000", 0);
        bool passed = MovesBackwards(finished, TestRoundResult("p", -1, "5000,20000", 0))
            && MovesBackwards(finished, TestRoundResult("p", -1, "5000", 0))
            && !MovesBackwards(finished, TestRoundResult("p", 20130, "5000,20130", 0))
            && !MovesBackwards(TestRoundResult("p", -1, "5000", 0), TestRoundResult("p", -1, "5000,9000", 0));
        if (!passed) { failed++; warn("RoundResult test 13 failed: forward-only reads"); }
    }

    if (failed == 0) print("RoundResult tests: all passed");
    else warn("RoundResult tests: " + failed + " failed");
}
#endif
