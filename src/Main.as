[Setting hidden]
bool g_Window = false;


const string PluginName = Meta::ExecutingPlugin().Name;
const string MenuIconColor = "\\$4d8";
const string PluginIcon = Icons::Circle + Icons::Upload;
const string MenuTitle = MenuIconColor + PluginIcon + "\\$z " + PluginName;


UI::Texture@ logo;

void Main() {
    RunDevTests();
    yield();
    @logo = UI::LoadTexture("src/logo.png");
    Meta::StartWithRunContext(Meta::RunContext::AfterScripts, UpdateEarlyCoro);
}

void UpdateEarlyCoro() {
    while (true) {
        UpdateEarly();
        yield();
    }
}

RaceMonitor@ g_monitor;
bool IsEditor;
bool IsPgLoaded;
uint lastMapMwId = 0;
string mapUid;
bool MapLeftThisFrame = false;
bool NewMapThisFrame = false;

void UpdateEarly() {
    auto app = GetApp();
    if (g_monitor !is null && !IsInServer()) {
        print("On menu, stopping monitoring.");
        @g_monitor = null;
    }

    IsEditor = app.Editor !is null;
    IsPgLoaded = !IsEditor && app.RootMap !is null && app.CurrentPlayground !is null;

    if (IsPgLoaded) {
        if (app.RootMap.Id.Value != lastMapMwId) {
            MapLeftThisFrame = lastMapMwId > 0;
            lastMapMwId = app.RootMap.Id.Value;
            mapUid = app.RootMap.MapInfo.MapUid;
            NewMapThisFrame = lastMapMwId > 0;
        } else {
            MapLeftThisFrame = false;
            NewMapThisFrame = false;
        }
    } else {
        MapLeftThisFrame = lastMapMwId > 0;
        lastMapMwId = 0;
        NewMapThisFrame = false;
        mapUid = "";
    }

    if (g_monitor !is null) {
        g_monitor.Update();
    }
}

uint GetMapIdValue(CGameCtnChallenge@ map) {
    if (map is null) return 0;
    return map.Id.Value;
}

void RenderMenu() {
    if (UI::MenuItem(MenuTitle, "", g_Window)) {
        g_Window = !g_Window;
    }
}

void RenderInterface() {
    if (!g_Window) return;
    auto app = GetApp();
    UI::SetNextWindowSize(400, 300, UI::Cond::FirstUseEver);
    if (UI::Begin(PluginName, g_Window)) {
        DrawLogo();
        UI::PushItemWidth(Math::Max(UI::GetContentRegionAvail().x * .3, 100));
        if (!IsPgLoaded) {
            DrawNoMap();
        } else if (g_monitor is null) {
            DrawNoMonitor();
        } else {
            g_monitor.DrawWindowInner();
        }
        UI::PopItemWidth();
    }
    UI::End();
}

void DrawLogo() {
    if (logo is null) {
        UI::Dummy(vec2(0, 60));
    } else {
        auto w = UI::GetContentRegionAvail().x;
        auto size = vec2(180);
        auto fullSize = logo.GetSize();
        size.y = size.x * (fullSize.y / fullSize.x);
        auto pl = (w - size.x) / 2.;
        UI::Dummy(vec2(pl, 10));
        UI::SameLine();
        UI::Image(logo, size);
    }
}

void DrawEditApiKey() {

    // S_API_KEY = UI::InputText("API Key", S_API_KEY, UI::InputTextFlags::Password);
}

void DrawNoMap() {
    UI::AlignTextToFramePadding();
    UI::Text("No map loaded.");
    if (g_monitor !is null) {
        DrawStopMonitoringButton();
    }
}

void DrawStopMonitoringButton() {
    UI::Separator();
    if (UI::Button("Stop Monitoring")) {
        @g_monitor = null;
    }
}

string m_matchId_apiKey;
string matchId;
string apiKey;
bool validMIdApiKeyInput = false;
string midApiKeyError = "Empty Input. Please paste API Key";
string last_matchId_apiKey;

void DrawNoMonitor() {
    UI::Text("Not currently monitoring.");
    UI::Separator();
    bool changed;
    m_matchId_apiKey = UI::InputText("Paste API Key", m_matchId_apiKey, changed, UI::InputTextFlags::Password);
    bool useLast = false;
    if (last_matchId_apiKey.Length > 0) {
        UI::SameLine();
        useLast = UI::Button("Use Last");
    }
    if (useLast) {
        m_matchId_apiKey = last_matchId_apiKey;
        changed = true;
    }
    if (changed) {
        TryParseMIdApiKey();
    }
    if (!validMIdApiKeyInput) {
        UI::TextWrapped("\\$f80 " + Icons::ExclamationTriangle + "\\$z " + midApiKeyError);
    }
    UI::Separator();
    UI::BeginDisabled(!validMIdApiKeyInput || !IsInServer());
    if (UI::Button("Start Monitoring")) {
        TryParseMIdApiKey();
        if (validMIdApiKeyInput) {
            @g_monitor = RaceMonitor(matchId, apiKey);
            last_matchId_apiKey = m_matchId_apiKey;
            m_matchId_apiKey = "";
            TryParseMIdApiKey();
        } else {
            NotifyWarning("Invalid Match ID & API Key input.");
        }
    }
    UI::EndDisabled();
}

void TryParseMIdApiKey() {
    auto parts = m_matchId_apiKey.Split("_");
    if (parts.Length == 2) {
        matchId = parts[0];
        apiKey = parts[1];
        validMIdApiKeyInput = true;
        midApiKeyError = "";
    } else {
        validMIdApiKeyInput = false;
        midApiKeyError = "Invalid input. Expected 1 underscore but found " + (int(parts.Length) - 1);
    }
}









void Notify(const string &in msg) {
    UI::ShowNotification(Meta::ExecutingPlugin().Name, msg);
    trace("Notified: " + msg);
}
void Dev_Notify(const string &in msg) {
#if DEV
    UI::ShowNotification(Meta::ExecutingPlugin().Name, msg);
    trace("Notified: " + msg);
#endif
}

void NotifySuccess(const string &in msg) {
    UI::ShowNotification(Meta::ExecutingPlugin().Name, msg, vec4(.4, .7, .1, .3), 10000);
    trace("Notified: " + msg);
}

void NotifyError(const string &in msg) {
    warn(msg);
    UI::ShowNotification(Meta::ExecutingPlugin().Name + ": Error", msg, vec4(.9, .3, .1, .3), 15000);
}

void NotifyWarning(const string &in msg) {
    warn(msg);
    UI::ShowNotification(Meta::ExecutingPlugin().Name + ": Warning", msg, vec4(.9, .6, .2, .3), 15000);
}

dictionary warnDebounce;
void NotifyWarningDebounce(const string &in msg, uint ms) {
    warn(msg);
    bool showWarn = !warnDebounce.Exists(msg) || Time::Now - uint(warnDebounce[msg]) > ms;
    if (showWarn) {
        UI::ShowNotification(Meta::ExecutingPlugin().Name + ": Warning", msg, vec4(.9, .6, .2, .3), 15000);
        warnDebounce[msg] = Time::Now;
    }
}

bool IsInServer() {
    CTrackManiaNetwork@ Network = cast<CTrackManiaNetwork>(GetApp().Network);
    CGameCtnNetServerInfo@ ServerInfo = cast<CGameCtnNetServerInfo>(Network.ServerInfo);
    return ServerInfo.JoinLink != "";
}


void dev_warn(const string &in msg) {
#if DEV
    warn(msg);
#endif
}
