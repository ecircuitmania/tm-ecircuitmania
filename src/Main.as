[Setting hidden]
bool g_Window = false;


const string PluginName = Meta::ExecutingPlugin().Name;
const string MenuIconColor = "\\$4d8";
const string PluginIcon = Icons::Circle + Icons::Upload;
const string MenuTitle = MenuIconColor + PluginIcon + "\\$z " + PluginName;


UI::Texture@ logo;

void Main() {
#if DEV
    // This only runs in developer mode, for sanity checking changes. Does not block CI or release.
    RunRoundResultTests();
#endif
    yield();
    @logo = UI::LoadTexture("src/logo.png");
    Meta::StartWithRunContext(Meta::RunContext::AfterScripts, UpdateEarlyLoop);
}

void UpdateEarlyLoop() {
    while (true) {
        UpdateEarly();
        yield();
    }
}

RaceMonitor@ raceMonitor;
FeedHealthCheck feedHealth;
bool IsPlaygroundLoaded;
uint lastMapMwId = 0;
string mapUid;
bool NewMapThisFrame = false;

void UpdateEarly() {
    auto game = GetApp();
    if (raceMonitor !is null && !IsInServer()) {
        print("On menu, stopping monitoring.");
        @raceMonitor = null;
    }

    IsPlaygroundLoaded = game.Editor is null && game.RootMap !is null && game.CurrentPlayground !is null;

    NewMapThisFrame = false;
    if (IsPlaygroundLoaded) {
        if (game.RootMap.Id.Value != lastMapMwId) {
            lastMapMwId = game.RootMap.Id.Value;
            mapUid = game.RootMap.MapInfo.MapUid;
            NewMapThisFrame = lastMapMwId > 0;
        }
    } else {
        lastMapMwId = 0;
        mapUid = "";
    }
    if (NewMapThisFrame) {
        ResetMapRounds();
        feedHealth.OnNewMap();
    }

    if (IsPlaygroundLoaded && IsInServer()) feedHealth.Update(raceMonitor !is null || matchIdApiKeyInput.Length > 0);

    if (raceMonitor !is null) {
        raceMonitor.Update();
    }
}

void RenderMenu() {
    if (UI::MenuItem(MenuTitle, "", g_Window)) {
        g_Window = !g_Window;
    }
}

void RenderInterface() {
    if (!g_Window) return;
    UI::SetNextWindowSize(400, 300, UI::Cond::FirstUseEver);
    if (UI::Begin(PluginName, g_Window)) {
        DrawLogo();
        UI::PushItemWidth(Math::Max(UI::GetContentRegionAvail().x * .3, 100));
        if (!IsPlaygroundLoaded) {
            DrawNoMap();
        } else if (raceMonitor is null) {
            DrawNoMonitor();
        } else {
            raceMonitor.DrawWindowInner();
        }
        UI::PopItemWidth();
    }
    UI::End();
}

void DrawLogo() {
    if (logo is null) {
        UI::Dummy(vec2(0, 60));
    } else {
        auto availableWidth = UI::GetContentRegionAvail().x;
        auto size = vec2(180);
        auto logoSize = logo.GetSize();
        size.y = size.x * (logoSize.y / logoSize.x);
        auto leftPadding = (availableWidth - size.x) / 2.;
        UI::Dummy(vec2(leftPadding, 10));
        UI::SameLine();
        UI::Image(logo, size);
    }
}

void DrawNoMap() {
    UI::AlignTextToFramePadding();
    UI::Text("No map loaded.");
    if (raceMonitor !is null) {
        DrawStopMonitoringButton();
    }
}

void DrawStopMonitoringButton() {
    UI::Separator();
    if (UI::Button("Stop Monitoring")) {
        @raceMonitor = null;
    }
}

string matchIdApiKeyInput;
string lastMatchIdApiKey;

void DrawNoMonitor() {
    UI::Text("Not currently monitoring.");
    UI::Separator();
    feedHealth.DrawBanner();
    // Unused, but only this InputText overload compiles with the Password flag.
    bool changed;
    matchIdApiKeyInput = UI::InputText("Paste API Key", matchIdApiKeyInput, changed, UI::InputTextFlags::Password);
    if (lastMatchIdApiKey.Length > 0) {
        UI::SameLine();
        if (UI::Button("Use Last")) matchIdApiKeyInput = lastMatchIdApiKey;
    }
    auto parts = matchIdApiKeyInput.Split("_");
    bool valid = parts.Length == 2;
    if (!valid) {
        string error = "Empty Input. Please paste API Key";
        if (matchIdApiKeyInput.Length > 0) error = "Invalid input. Expected 1 underscore but found " + (int(parts.Length) - 1);
        UI::TextWrapped("\\$f80 " + Icons::ExclamationTriangle + "\\$z " + error);
    }
    UI::Separator();
    bool feedChecking = valid && !feedHealth.stalled && !feedHealth.ReadyToStart;
    if (feedChecking) UI::TextDisabled("Checking MLFeed is receiving race data...");
    UI::BeginDisabled(!valid || !IsInServer() || !feedHealth.ReadyToStart);
    if (UI::Button("Start Monitoring")) {
        @raceMonitor = RaceMonitor(parts[0], parts[1]);
        lastMatchIdApiKey = matchIdApiKeyInput;
        matchIdApiKeyInput = "";
    }
    UI::EndDisabled();
}

void NotifyError(const string &in message) {
    warn(message);
    UI::ShowNotification(Meta::ExecutingPlugin().Name + ": Error", message, vec4(.9, .3, .1, .3), 15000);
}

bool IsInServer() {
    CTrackManiaNetwork@ network = cast<CTrackManiaNetwork>(GetApp().Network);
    CGameCtnNetServerInfo@ serverInfo = cast<CGameCtnNetServerInfo>(network.ServerInfo);
    return serverInfo.JoinLink != "";
}
