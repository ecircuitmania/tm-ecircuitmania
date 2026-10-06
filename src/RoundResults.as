class RoundResult {
    string webServicesUserId;
    string name;
    // -1 for a DNF.
    int finishTime = -1;
    // Without MLFeed's leading 0. For a finish, the last entry is the finish itself.
    int[] cpTimes;
    int points = 0;

    RoundResult(const string &in webServicesUserId, const string &in name, int finishTime, const int[] &in cpTimes, int points) {
        this.webServicesUserId = webServicesUserId;
        this.name = name;
        this.finishTime = finishTime;
        this.cpTimes = cpTimes;
        this.points = points;
    }

    bool get_Finished() const { return finishTime >= 0; }

    int get_LastCpTime() const { return cpTimes.Length == 0 ? -1 : cpTimes[cpTimes.Length - 1]; }

    // Drops the finish crossing, so the DNF ranks by the checkpoints before it.
    void MaybeMarkDnf() {
        if (Finished && cpTimes.Length > 0) cpTimes.RemoveLast();
        finishTime = -1;
    }
}

RoundResult@ RoundResultFromPlayer(const MLFeed::PlayerCpInfo_V4@ player) {
    int[] cpTimes;
    auto feedCpTimes = player.CpTimes;
    // MLFeed's CpTimes has a leading 0 for the start.
    for (uint i = 1; i < feedCpTimes.Length; i++) cpTimes.InsertLast(feedCpTimes[i]);
    // MLFeed's IsFinished compares against the map's checkpoint count, which it zeroes when the map unloads.
    int finishTime = (player.IsFinished && player.CpCount > 0) ? player.LastCpTime : -1;
    return RoundResult(player.WebServicesUserId, player.Name, finishTime, cpTimes, player.Points);
}

// Nadeo's tiebreak order.
bool RoundResultLess(const RoundResult@ first, const RoundResult@ second) {
    if (first.Finished != second.Finished) return first.Finished;

    if (first.Finished) {
        if (first.finishTime != second.finishTime) return first.finishTime < second.finishTime;
        // Then earlier checkpoints, latest first, skipping the finish itself.
        int firstIndex = int(first.cpTimes.Length) - 2;
        int secondIndex = int(second.cpTimes.Length) - 2;
        while (firstIndex >= 0 && secondIndex >= 0) {
            if (first.cpTimes[firstIndex] != second.cpTimes[secondIndex]) return first.cpTimes[firstIndex] < second.cpTimes[secondIndex];
            firstIndex--;
            secondIndex--;
        }
    } else {
        if (first.cpTimes.Length != second.cpTimes.Length) return first.cpTimes.Length > second.cpTimes.Length;
        if (first.LastCpTime != second.LastCpTime) return first.LastCpTime < second.LastCpTime;
    }

    if (first.points != second.points) return first.points > second.points;
    return first.name < second.name;
}

void SortRoundResults(array<RoundResult@>@ results) {
    for (uint i = 1; i < results.Length; i++) {
        auto item = results[i];
        int slot = int(i) - 1;
        while (slot >= 0 && RoundResultLess(item, results[uint(slot)])) {
            @results[uint(slot + 1)] = results[uint(slot)];
            slot--;
        }
        @results[uint(slot + 1)] = item;
    }
}
