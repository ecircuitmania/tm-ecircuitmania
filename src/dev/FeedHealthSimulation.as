// Dev-only: simulates an MLFeed stall, to test FeedHealthCheck.
//
// Never shipped: the release workflow leaves src/dev/ out of the package, so
// call anything declared here only from inside an #if DEV block.
#if DEV

[Setting category="Dev" name="Simulate MLFeed stall (feed health test)"]
bool S_DevSimulateFeedStall = false;

// The StartTime MLFeed listed for each player, by login, when the simulated stall began.
dictionary devFrozenFeedStartTimes;

// DevSimulatedFeedStartTime returns the player's StartTime from when the simulated stall began, or the live one while the simulation is off.
int DevSimulatedFeedStartTime(const string &in login, int startTime) {
    if (!S_DevSimulateFeedStall) {
        if (devFrozenFeedStartTimes.GetSize() > 0) devFrozenFeedStartTimes.DeleteAll();
        return startTime;
    }
    if (!devFrozenFeedStartTimes.Exists(login)) devFrozenFeedStartTimes[login] = startTime;
    return int(devFrozenFeedStartTimes[login]);
}

// MLFeed's UpdateNonce when the simulated stall began, so the simulated feed also stops receiving events.
bool devUpdateNonceFrozen = false;
uint devFrozenUpdateNonce = 0;

// DevSimulatedUpdateNonce returns MLFeed's UpdateNonce from when the simulated stall began, or the live one while the simulation is off.
uint DevSimulatedUpdateNonce(uint nonce) {
    if (!S_DevSimulateFeedStall) {
        devUpdateNonceFrozen = false;
        return nonce;
    }
    if (!devUpdateNonceFrozen) {
        devFrozenUpdateNonce = nonce;
        devUpdateNonceFrozen = true;
    }
    return devFrozenUpdateNonce;
}
#endif
