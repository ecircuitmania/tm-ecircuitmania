// Dev-only self-checks, run on plugin load. Omitted from release builds.

void RunDevTests() {
#if DEV
    RunRoundResultTests();
#endif
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
    // 5. A finish marked DNF ranks by the CPs before it, not with the finish as an extra CP.
    {
        auto left = TestRR("left", 20000, "5000,9000,20000", 0);
        left.MaybeMarkDnf();
        array<RoundResult@> r;
        r.InsertLast(left);
        r.InsertLast(TestRR("dnf", -1, "5000,8000", 0));
        SortRoundResults(r);
        if (left.Finished || r[0].wsid != "dnf") { failed++; warn("RoundResult test 5 failed: MaybeMarkDnf"); }
    }

    if (failed == 0) print("RoundResult tests: all passed");
    else warn("RoundResult tests: " + failed + " failed");
}
#endif
