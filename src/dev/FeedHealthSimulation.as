// Dev-only: simulates an MLFeed stall, to test FeedHealthCheck.
//
// Never shipped: the release workflow leaves src/dev/ out of the package, so
// call anything declared here only from inside an #if DEV block.
#if DEV

[Setting category="Dev" name="Simulate MLFeed stall (feed health test)"]
bool S_DevSimulateFeedStall = false;

// MLFeed's view of each player, by login, when the simulated stall began.
dictionary devFrozenFeedViews;

// DevSimulatedFeedView returns the player's view from when the simulated stall began, or the live view while the simulation is off.
FeedPlayerView@ DevSimulatedFeedView(const string &in login, FeedPlayerView@ view) {
    if (!S_DevSimulateFeedStall) {
        if (devFrozenFeedViews.GetSize() > 0) devFrozenFeedViews.DeleteAll();
        return view;
    }
    FeedPlayerView@ frozen;
    if (devFrozenFeedViews.Get(login, @frozen)) return frozen;
    devFrozenFeedViews.Set(login, @view);
    return view;
}
#endif
