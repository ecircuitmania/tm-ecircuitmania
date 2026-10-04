// Dev-only self-checks, run on plugin load.
//
// Never shipped: the release workflow leaves src/dev/ out of the package, so
// call anything declared here only from inside an #if DEV block.
#if DEV

RoundResult@ TestRoundResult(const string &in webServicesUserId, int finishTime, const string &in cpTimesCsv, int points = 0) {
    int[] cpTimes;
    auto parts = cpTimesCsv.Split(",");
    for (uint i = 0; i < parts.Length; i++) cpTimes.InsertLast(Text::ParseInt(parts[i]));
    return RoundResult(webServicesUserId, webServicesUserId, finishTime, cpTimes, points);
}

// Quick self-check run on plugin load in dev builds.
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
        auto left = TestRoundResult("left", 20000, "5000,9000,20000", 0);
        left.MaybeMarkDnf();
        array<RoundResult@> results;
        results.InsertLast(left);
        results.InsertLast(TestRoundResult("dnf", -1, "5000,8000", 0));
        SortRoundResults(results);
        if (left.Finished || results[0].webServicesUserId != "dnf") { failed++; warn("RoundResult test 5 failed: MaybeMarkDnf"); }
    }

    if (failed == 0) print("RoundResult tests: all passed");
    else warn("RoundResult tests: " + failed + " failed");
}
#endif
