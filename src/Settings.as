bool IsDevMode() {
    return Meta::IsDeveloperMode();
}

[Setting name="Player Round Full Data URL" if="IsDevMode"]
string Setting_PlayerRoundFullDataUrl = "https://us-central1-fantasy-trackmania.cloudfunctions.net/match-addRound?matchId=";
