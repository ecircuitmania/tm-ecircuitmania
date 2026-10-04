// IsDevMode reports whether Openplanet is in developer mode, which shows the URL override below.
bool IsDevMode() {
    return Meta::IsDeveloperMode();
}

[Setting name="Player Round Full Data URL" if="IsDevMode"]
string Setting_PlayerRoundFullDataUrl = "https://us-central1-fantasy-trackmania.cloudfunctions.net/match-addRound?matchId=";
