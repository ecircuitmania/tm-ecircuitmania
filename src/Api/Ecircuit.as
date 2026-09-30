Json::Value@ MakePlayerFinishPayload(const string &in wsid, int finishTime, int roundNum, const string &in mapUid) {
    Json::Value@ payload = Json::Object();
    payload["ubisoftUid"] = wsid;
    payload["finishTime"] = finishTime;
    payload["roundNum"] = roundNum;
    payload["mapId"] = mapUid;
    payload["timestamp"] = Time::Stamp;
    return payload;
}

class PlayerFinishData {
    string wsid;
    int finishTime;
    int position;
    PlayerFinishData(const string &in wsid, int finishTime, int position) {
        this.wsid = wsid;
        this.finishTime = finishTime;
        this.position = position;
    }
}

Json::Value@ MakeRoundEndPayload(array<PlayerFinishData@>@ players, int roundNum, const string &in mapUid) {
    Json::Value@ payload = Json::Object();
    Json::Value@ playersArray = Json::Array();
    for (uint i = 0; i < players.Length; i++) {
        Json::Value@ player = Json::Object();
        player["ubisoftUid"] = players[i].wsid;
        player["finishTime"] = players[i].finishTime;
        player["position"] = players[i].position;
        playersArray.Add(player);
    }
    payload["players"] = playersArray;
    payload["roundNum"] = roundNum;
    payload["mapId"] = mapUid;
    payload["timestamp"] = Time::Stamp;
    return payload;
}

ECMResponse@ AddOnPlayerFinishReq(const string &in apiKey, const string &in matchId, const string &in payload) {
    return MakeRequestEcircuit(apiKey, Setting_PlayerRoundTimesUrl + matchId, payload);
}

ECMResponse@ AddOnEndRoundReq(const string &in apiKey, const string &in matchId, const string &in payload) {
    return MakeRequestEcircuit(apiKey, Setting_PlayerRoundFullDataUrl + matchId, payload);
}


ECMResponse@ MakeRequestEcircuit(const string &in apiKey, const string &in url, const string &in payload) {
    if (DevDryRun(url, payload)) return ECMResponse(true, 0, "dry run");
    Net::HttpRequest@ req = Net::HttpRequest();
    req.Method = Net::HttpMethod::Post;
    req.Url = url;
    print("Req: " + url);
    req.Body = payload;
    print("Payload: " + payload);
    req.Headers["Authorization"] = apiKey;
    req.Headers["Content-Type"] = "application/json";
    req.Start();
    while (!req.Finished()) {
        yield();
    }
    string msg = req.String();
    int status = req.ResponseCode();
    if (status < 200 || status >= 300) {
        print("Status Code: " + status);
        print("Error: " + msg);
        return ECMResponse(false, status, msg);
    } else {
        print("Success: " + msg);
        return ECMResponse(true, status, msg);
    }
}

class ECMResponse {
    bool success;
    int status;
    string message;
    ECMResponse(bool success, int status, const string &in message) {
        this.success = success;
        this.status = status;
        this.message = message;
    }
}
