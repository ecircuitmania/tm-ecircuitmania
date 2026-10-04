// Dev-only self-checks, run on plugin load.
//
// Never shipped: the release workflow leaves src/dev/ out of the package, so
// call anything declared here only from inside an #if DEV block.
#if DEV

// TestRoundResult builds a result whose name and ID are both webServicesUserId, from comma-separated checkpoint times.
RoundResult@ TestRoundResult(const string &in webServicesUserId, int finishTime, const string &in cpTimesCsv, int points = 0) {
    int[] cpTimes;
    if (cpTimesCsv.Length > 0) {
        auto parts = cpTimesCsv.Split(",");
        for (uint i = 0; i < parts.Length; i++) cpTimes.InsertLast(Text::ParseInt(parts[i]));
    }
    return RoundResult(webServicesUserId, webServicesUserId, finishTime, cpTimes, points);
}

// TestRejected returns the verdict on a finish, from the evidence gathered by the end of the wait.
bool TestRejected(bool scoreCommitSeen, bool finishShown, bool haveSample, bool signalSeen, bool serverConfirmed) {
    LocalFinishVerdict verdict;
    verdict.haveSample = haveSample;
    verdict.roundPointsSignal = signalSeen;
    verdict.serverConfirmed = serverConfirmed;
    verdict.Decide(scoreCommitSeen, finishShown);
    return verdict.rejected;
}

// TestConfirms reports whether a score record confirms a finish, given the sample and the signals this round showed.
bool TestConfirms(int sampledRoundPoints, const string &in sampledPreviousRaceTimes, bool roundPointsSignal, bool previousRaceTimesSignal, int roundPoints, const string &in previousRaceTimes) {
    LocalFinishVerdict verdict;
    verdict.sampledRoundPoints = sampledRoundPoints;
    verdict.sampledPreviousRaceTimes = sampledPreviousRaceTimes;
    verdict.roundPointsSignal = roundPointsSignal;
    verdict.previousRaceTimesSignal = previousRaceTimesSignal;
    return verdict.ServerConfirms(roundPoints, previousRaceTimes);
}

// TestSignals returns the signals one other finisher's score record shows, as "round points", "previous race times" or "".
string TestSignals(int sampledRoundPoints, int roundPoints, const string &in previousRaceTimesWhileRacing, const string &in previousRaceTimes) {
    LocalFinishVerdict verdict;
    verdict.sampledRoundPoints = sampledRoundPoints;
    verdict.LearnFromFinisher(roundPoints, previousRaceTimesWhileRacing, previousRaceTimes);
    string signals = "";
    if (verdict.roundPointsSignal) signals += "round points";
    if (verdict.previousRaceTimesSignal) signals += "previous race times";
    return signals;
}

// RunRoundResultTests checks the ranking and the plugin runner's verdict, and logs any failure.
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
    // 7. A rejected finish is marked on a copy, leaving the result read from MLFeed as it was.
    {
        auto shown = TestRoundResult("local", 20450, "11448,20450", 0);
        auto dnf = shown.Copy();
        dnf.MarkDnf();
        if (dnf.Finished || dnf.cpTimes.Length != 1 || !shown.Finished || shown.cpTimes.Length != 2) { failed++; warn("RoundResult test 7 failed: DNF on a copy"); }
    }
    // 8. The runner's finish is a DNF only when the commit was seen, a sample exists, other finishers showed a signal,
    //    and the server never confirmed it. Without a signal the server has no say we can read, so the finish stays.
    {
        bool passed = TestRejected(true, true, true, true, false)
            && !TestRejected(true, true, true, true, true)
            && !TestRejected(false, true, true, true, false)
            && !TestRejected(true, true, false, true, false)
            && !TestRejected(true, false, true, true, false)
            && !TestRejected(true, true, true, false, false);
        if (!passed) { failed++; warn("RoundResult test 8 failed: local finish verdict"); }
    }
    // 9. Confirmation, only through a signal this round showed: round points moved off the sample and not 0, or PrevRaceTimes changed.
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
    // 10. Signals from another finisher: round points off the runner's sample, or PrevRaceTimes written since they were racing.
    //     A mode that only awards points at the commit, or never writes PrevRaceTimes, shows neither.
    {
        bool passed = TestSignals(-20, -1, "", "") == "round points"
            && TestSignals(0, 0, "", "") == ""
            && TestSignals(0, 0, "4000,8000", "5000,9000") == "previous race times"
            && TestSignals(0, 0, "4000,8000", "4000,8000") == ""
            && TestSignals(0, 0, "4000,8000", "") == "";
        if (!passed) { failed++; warn("RoundResult test 10 failed: finish signals"); }
    }

    if (failed == 0) print("RoundResult tests: all passed");
    else warn("RoundResult tests: " + failed + " failed");
}
#endif
