// MakeRoundEndPayload builds the round-end message from the ranked results; finishTime is -1 for a DNF.
Json::Value@ MakeRoundEndPayload(array<RoundResult@>@ rankedResults, int roundNumber, const string &in mapUid, int64 timestamp) {
    Json::Value@ payload = Json::Object();
    Json::Value@ playersArray = Json::Array();
    for (uint i = 0; i < rankedResults.Length; i++) {
        Json::Value@ player = Json::Object();
        player["ubisoftUid"] = rankedResults[i].webServicesUserId;
        player["finishTime"] = rankedResults[i].finishTime;
        player["position"] = int(i + 1);
        playersArray.Add(player);
    }
    payload["players"] = playersArray;
    payload["roundNum"] = roundNumber;
    payload["mapId"] = mapUid;
    payload["timestamp"] = timestamp;
    return payload;
}

// SendRoundEnd posts a round-end message to ECM and waits for the response.
ECMResponse@ SendRoundEnd(const string &in apiKey, const string &in matchId, const string &in payload) {
    string url = Setting_PlayerRoundFullDataUrl + matchId;
#if DEV
    if (DevDryRun(url, payload)) return ECMResponse(true, 0, "dry run");
#endif
    Net::HttpRequest@ request = Net::HttpRequest();
    request.Method = Net::HttpMethod::Post;
    request.Url = url;
    request.Body = payload;
    request.Headers["Authorization"] = apiKey;
    request.Headers["Content-Type"] = "application/json";
    request.Start();
    while (!request.Finished()) {
        yield();
    }
    int status = request.ResponseCode();
    string responseBody = request.String();
    print("Round end sent to " + url + ": status " + status + ", response " + responseBody + ", payload " + payload);
    return ECMResponse(status >= 200 && status < 300, status, responseBody);
}

// ECMResponse is the outcome of a request to ECM.
class ECMResponse {
    bool success;
    int status;
    string message;

    // ECMResponse records a request's outcome.
    ECMResponse(bool success, int status, const string &in message) {
        this.success = success;
        this.status = status;
        this.message = message;
    }
}
