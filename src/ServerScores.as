// Server-synced score data.
//
// The game copies each player's score record from the server to every client.
// RoundPoints and PrevRaceTimes on that record are written by the server's game
// mode, so they reflect what the server decided, not this client's prediction.

CSmArenaScore@ GetServerScore(const MLFeed::PlayerCpInfo_V4@ player) {
    if (player is null) return null;
    auto smp = player.FindCSmPlayer();
    if (smp is null) return null;
    auto sp = cast<CSmScriptPlayer>(smp.ScriptAPI);
    if (sp is null) return null;
    return sp.Score;
}

// The plugin runner's login comes from Openplanet's built-in GetLocalLogin().
