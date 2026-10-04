// RoundResult is one player's result for a round, as ranked and sent to ECM.
class RoundResult {
    string webServicesUserId;
    string name;
    // Final race time in ms, or -1 if the player did not finish.
    int finishTime = -1;
    // Checkpoint times in ms, index 0 is the first checkpoint (no leading zero).
    // For a finish, the last entry is the finish itself.
    int[] cpTimes;
    int points = 0;
    // Server-assigned round points, kept for dev cross-checks only.
    int roundPoints = 0;

    // RoundResult creates a result from the values the ranking uses.
    RoundResult(const string &in webServicesUserId, const string &in name, int finishTime, const int[] &in cpTimes, int points) {
        this.webServicesUserId = webServicesUserId;
        this.name = name;
        this.finishTime = finishTime;
        this.cpTimes = cpTimes;
        this.points = points;
    }

    // get_Finished reports whether the player finished.
    bool get_Finished() const { return finishTime >= 0; }

    // get_LastCpTime returns the time at the last checkpoint reached, or -1 if none.
    int get_LastCpTime() const { return cpTimes.Length == 0 ? -1 : cpTimes[cpTimes.Length - 1]; }

    // MaybeMarkDnf records a DNF for a finish this client showed but the server didn't count.
    // The finish crossing is dropped too, so the DNF ranks by the checkpoints reached before it.
    void MaybeMarkDnf() {
        if (Finished && cpTimes.Length > 0) cpTimes.RemoveLast();
        finishTime = -1;
    }
}

// RoundResultFromPlayer builds a RoundResult from MLFeed's current view of a player.
RoundResult@ RoundResultFromPlayer(const MLFeed::PlayerCpInfo_V4@ player) {
    int[] cpTimes;
    auto feedCpTimes = player.CpTimes;
    // MLFeed's CpTimes has a leading 0 for the start.
    for (uint i = 1; i < feedCpTimes.Length; i++) cpTimes.InsertLast(feedCpTimes[i]);
    int finishTime = player.IsFinished ? player.LastCpTime : -1;
    RoundResult@ result = RoundResult(player.WebServicesUserId, player.Name, finishTime, cpTimes, player.Points);
    result.roundPoints = player.RoundPoints;
    return result;
}

// RoundResultLess reports whether first should be ranked ahead of second, following Nadeo's tiebreak order.
bool RoundResultLess(const RoundResult@ first, const RoundResult@ second) {
    if (first.Finished != second.Finished) return first.Finished;

    if (first.Finished) {
        if (first.finishTime != second.finishTime) return first.finishTime < second.finishTime;
        // Tiebreak on previous checkpoint times, latest checkpoint first.
        // The last entry is the finish itself, so start one before it.
        int firstIndex = int(first.cpTimes.Length) - 2;
        int secondIndex = int(second.cpTimes.Length) - 2;
        while (firstIndex >= 0 && secondIndex >= 0) {
            if (first.cpTimes[firstIndex] != second.cpTimes[secondIndex]) return first.cpTimes[firstIndex] < second.cpTimes[secondIndex];
            firstIndex--;
            secondIndex--;
        }
    } else {
        // No finish: more checkpoints is better, then earlier time at the last one.
        if (first.cpTimes.Length != second.cpTimes.Length) return first.cpTimes.Length > second.cpTimes.Length;
        if (first.LastCpTime != second.LastCpTime) return first.LastCpTime < second.LastCpTime;
    }

    if (first.points != second.points) return first.points > second.points;
    return first.name < second.name;
}

// SortRoundResults ranks results in place with a stable insertion sort; rounds have at most a few dozen players.
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
