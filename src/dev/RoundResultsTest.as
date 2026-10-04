// Dev-only self-checks, run on plugin load.
//
// Never shipped: the release workflow leaves src/dev/ out of the package, so
// call anything declared here only from inside an #if DEV block.
#if DEV

// TestRoundResult builds a result whose name and ID are both webServicesUserId, from comma-separated checkpoint times.
RoundResult@ TestRoundResult(const string &in webServicesUserId, int finishTime, const string &in cpTimesCsv, int points = 0) {
    int[] cpTimes;
    auto parts = cpTimesCsv.Split(",");
    for (uint i = 0; i < parts.Length; i++) cpTimes.InsertLast(Text::ParseInt(parts[i]));
    return RoundResult(webServicesUserId, webServicesUserId, finishTime, cpTimes, points);
}

// RunRoundResultTests checks the ranking and the server-verdict handling, and logs any failure.
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
        rejected.MaybeMarkDnf();
        array<RoundResult@> results;
        results.InsertLast(rejected);
        results.InsertLast(TestRoundResult("dnf", -1, "5000,8000", 0));
        SortRoundResults(results);
        if (rejected.Finished || results[0].webServicesUserId != "dnf") { failed++; warn("RoundResult test 5 failed: MaybeMarkDnf"); }
    }
    // 6. A DNF verdict drops the finish this client showed.
    {
        auto shown = TestRoundResult("local", 20450, "11448,20450", 0);
        auto result = ApplyServerVerdict(shown, TestRoundResult("local", 20129, "11448,20129", 0), ServerVerdict::Dnf);
        if (result.Finished || result.cpTimes.Length != 1) { failed++; warn("RoundResult test 6 failed: DNF verdict"); }
    }
    // 7. A finish the server confirmed but this client no longer shows uses the first-seen run, which still ends with its finish.
    {
        auto shown = TestRoundResult("local", -1, "6860", 0);
        auto result = ApplyServerVerdict(shown, TestRoundResult("local", 9807, "6860,9807", 0), ServerVerdict::Finished);
        if (result.finishTime != 9807 || result.LastCpTime != result.finishTime) { failed++; warn("RoundResult test 7 failed: confirmed finish not shown"); }
    }
    // 8. A confirmed finish this client shows keeps MLFeed's final time; no verdict changes nothing.
    {
        auto shown = TestRoundResult("local", 10130, "6860,10130", 0);
        auto firstSeen = TestRoundResult("local", 9807, "6860,9807", 0);
        auto confirmed = ApplyServerVerdict(shown, firstSeen, ServerVerdict::Finished);
        auto unknown = ApplyServerVerdict(shown, firstSeen, ServerVerdict::Unknown);
        if (confirmed.finishTime != 10130 || unknown.finishTime != 10130) { failed++; warn("RoundResult test 8 failed: confirmed or unknown verdict"); }
    }

    if (failed == 0) print("RoundResult tests: all passed");
    else warn("RoundResult tests: " + failed + " failed");
}
#endif
