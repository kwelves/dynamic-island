// ==WindhawkMod==
// @id              dynamic-island-tray-bridge-dev
// @name            Dynamic Island TopBar: tray bridge (dev)
// @description     Copies notification area (tray) icons from Explorer to the Dynamic Island TopBar. Read-only: Explorer keeps handling every icon as usual.
// @version         0.1.0
// @author          Erkin
// @include         explorer.exe
// @compilerOptions -luser32 -lgdi32
// @license         MIT
// ==/WindhawkMod==

// ==WindhawkModReadme==
/*
# Dynamic Island TopBar: tray bridge

Companion of the Dynamic Island TopBar mod. Inside Explorer it only *watches*
the messages programs send to the taskbar's notification area
(`Shell_NotifyIcon` → `WM_COPYDATA` to `Shell_TrayWnd`) and copies each icon
(id, tooltip, state and its picture) to the bar window. It never changes,
blocks or answers those messages; Explorer handles them exactly as before.

How it stays small and safe:
- one `WH_CALLWNDPROC` hook on the taskbar's thread, which can only observe;
- every buffer is size-checked before it is read;
- the icon picture is copied while the sender is still waiting (it may destroy
  the icon right after), everything else is sent to the bar from a separate
  thread with a timeout, so neither Explorer nor the program waits for the bar;
- the queue is bounded; on unload the hook is removed first.
*/
// ==/WindhawkModReadme==

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <cstring>
#include <deque>
#include <mutex>
#include <vector>

namespace {

// ── Wire format shared with the bar (dynamic-island-for-windows.wh.cpp, namespace Tray) ──
constexpr ULONG_PTR kCopyDataId = 0x52544944;  // 'DITR'
constexpr uint32_t kMagic = 0x31544944;        // 'DIT1'
constexpr uint32_t kHello = 0xFFFFFFFF;        // message: the bridge (re)started, please re-request icons
constexpr int kMaxIconPx = 64;

#pragma pack(push, 1)
struct Packet {
    uint32_t magic;
    uint32_t size;      // whole packet, header + pixels
    uint32_t message;   // NIM_* or kHello
    uint32_t flags;     // NIF_*
    uint64_t hwnd;
    uint32_t uid;
    uint32_t callbackMessage;
    uint32_t state;
    uint32_t stateMask;
    uint32_t version;   // NIM_SETVERSION
    GUID guid;
    wchar_t tip[128];
    uint32_t iconW;     // 0: no picture follows
    uint32_t iconH;
    // iconW * iconH premultiplied BGRA pixels follow
};
#pragma pack(pop)

// ── What programs send to Shell_TrayWnd (bitness-independent: handles are 32-bit) ──
#pragma pack(push, 4)
struct NotifyIconData32 {
    DWORD cbSize;
    DWORD hWnd;
    UINT uID;
    UINT uFlags;
    UINT uCallbackMessage;
    DWORD hIcon;
    WCHAR szTip[128];
    DWORD dwState;
    DWORD dwStateMask;
    WCHAR szInfo[256];
    UINT uTimeoutOrVersion;
    WCHAR szInfoTitle[64];
    DWORD dwInfoFlags;
    GUID guidItem;
    DWORD hBalloonIcon;
};
struct ShellTrayData {
    DWORD magic;
    DWORD dwMessage;
    NotifyIconData32 nid;
};
#pragma pack(pop)

constexpr size_t kMaxQueue = 256;

HWND g_tray = nullptr;
HHOOK g_hook = nullptr;
HANDLE g_thread = nullptr;
HANDLE g_wake = nullptr;
std::atomic<bool> g_stop{false};
std::atomic<int> g_inHook{0};
std::mutex g_queueMutex;
std::deque<std::vector<uint8_t>> g_queue;

// Draws the icon on black and on white: the difference gives alpha for any
// icon type (32-bit, masked, monochrome), the black pass is the premultiplied colour.
bool Rasterize(HICON icon, std::vector<uint8_t>& out, uint32_t* w, uint32_t* h) {
    ICONINFO info = {};
    if (!GetIconInfo(icon, &info)) return false;
    BITMAP bm = {};
    int cx = 0, cy = 0;
    if (info.hbmColor && GetObjectW(info.hbmColor, sizeof(bm), &bm)) {
        cx = bm.bmWidth;
        cy = bm.bmHeight;
    } else if (info.hbmMask && GetObjectW(info.hbmMask, sizeof(bm), &bm)) {
        cx = bm.bmWidth;
        cy = bm.bmHeight / 2;
    }
    if (info.hbmColor) DeleteObject(info.hbmColor);
    if (info.hbmMask) DeleteObject(info.hbmMask);
    if (cx <= 0 || cy <= 0) return false;
    if (cx > kMaxIconPx || cy > kMaxIconPx) cx = cy = kMaxIconPx;

    BITMAPINFO bi = {};
    bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
    bi.bmiHeader.biWidth = cx;
    bi.bmiHeader.biHeight = -cy;
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB;
    HDC dc = CreateCompatibleDC(nullptr);
    if (!dc) return false;
    void* bits[2] = {};
    HBITMAP bmp[2] = {CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits[0], nullptr, 0),
                      CreateDIBSection(dc, &bi, DIB_RGB_COLORS, &bits[1], nullptr, 0)};
    bool ok = bmp[0] && bmp[1] && bits[0] && bits[1];
    if (ok) {
        const size_t bytes = static_cast<size_t>(cx) * cy * 4;
        memset(bits[0], 0x00, bytes);
        memset(bits[1], 0xFF, bytes);
        for (int i = 0; i < 2 && ok; ++i) {
            HGDIOBJ old = SelectObject(dc, bmp[i]);
            ok = DrawIconEx(dc, 0, 0, icon, cx, cy, 0, nullptr, DI_NORMAL) != FALSE;
            SelectObject(dc, old);
        }
        GdiFlush();
        if (ok) {
            out.resize(bytes);
            const uint8_t* black = static_cast<const uint8_t*>(bits[0]);
            const uint8_t* white = static_cast<const uint8_t*>(bits[1]);
            for (size_t p = 0; p < bytes; p += 4) {
                int a = 255 - (static_cast<int>(white[p + 1]) - static_cast<int>(black[p + 1]));
                a = a < 0 ? 0 : a > 255 ? 255 : a;
                const uint8_t b = black[p], g = black[p + 1], r = black[p + 2];
                const int peak = b > g ? (b > r ? b : r) : (g > r ? g : r);
                if (a < peak) a = peak;  // premultiplied: no channel above alpha
                out[p] = b;
                out[p + 1] = g;
                out[p + 2] = r;
                out[p + 3] = static_cast<uint8_t>(a);
            }
            *w = static_cast<uint32_t>(cx);
            *h = static_cast<uint32_t>(cy);
        }
    }
    for (HBITMAP b : bmp) {
        if (b) DeleteObject(b);
    }
    DeleteDC(dc);
    return ok;
}

void Enqueue(std::vector<uint8_t>&& packet) {
    {
        std::lock_guard lock(g_queueMutex);
        if (g_queue.size() >= kMaxQueue) g_queue.pop_front();  // the bar is not keeping up: drop the oldest
        g_queue.push_back(std::move(packet));
    }
    SetEvent(g_wake);
}

std::vector<uint8_t> MakePacket(uint32_t message, const NotifyIconData32* nid) {
    std::vector<uint8_t> pixels;
    uint32_t w = 0, h = 0;
    if (nid && (nid->uFlags & NIF_ICON) && nid->hIcon) {
        if (!Rasterize(reinterpret_cast<HICON>(static_cast<uintptr_t>(nid->hIcon)), pixels, &w, &h)) {
            pixels.clear();
            w = h = 0;
        }
    }
    std::vector<uint8_t> buffer(sizeof(Packet) + pixels.size());
    Packet p = {};
    p.magic = kMagic;
    p.size = static_cast<uint32_t>(buffer.size());
    p.message = message;
    if (nid) {
        p.flags = nid->uFlags;
        p.hwnd = nid->hWnd;
        p.uid = nid->uID;
        p.callbackMessage = nid->uCallbackMessage;
        p.state = nid->dwState;
        p.stateMask = nid->dwStateMask;
        p.version = nid->uTimeoutOrVersion;
        p.guid = nid->guidItem;
        memcpy(p.tip, nid->szTip, sizeof(p.tip));
        p.tip[127] = 0;
    }
    p.iconW = w;
    p.iconH = h;
    memcpy(buffer.data(), &p, sizeof(p));
    if (!pixels.empty()) memcpy(buffer.data() + sizeof(p), pixels.data(), pixels.size());
    return buffer;
}

// Observes only: never changes the message, always passes it on.
LRESULT CALLBACK CallWndProc(int code, WPARAM wParam, LPARAM lParam) {
    g_inHook.fetch_add(1);
    if (code == HC_ACTION && !g_stop.load(std::memory_order_relaxed)) {
        const CWPSTRUCT* msg = reinterpret_cast<const CWPSTRUCT*>(lParam);
        if (msg && msg->message == WM_COPYDATA && msg->hwnd == g_tray && msg->lParam) {
            const COPYDATASTRUCT* cds = reinterpret_cast<const COPYDATASTRUCT*>(msg->lParam);
            if (cds->dwData == 1 && cds->lpData && cds->cbData >= sizeof(ShellTrayData)) {
                const ShellTrayData* data = static_cast<const ShellTrayData*>(cds->lpData);
                switch (data->dwMessage) {
                    case NIM_ADD:
                    case NIM_MODIFY:
                    case NIM_DELETE:
                    case NIM_SETVERSION:
                        Enqueue(MakePacket(data->dwMessage, &data->nid));
                        break;
                }
            }
        }
    }
    const LRESULT result = CallNextHookEx(nullptr, code, wParam, lParam);
    g_inHook.fetch_sub(1);
    return result;
}

HWND FindBar() {
    return FindWindowW(L"Windhawk.DynamicIslandTopBar", nullptr);
}

void Send(HWND bar, const std::vector<uint8_t>& packet) {
    COPYDATASTRUCT cds = {};
    cds.dwData = kCopyDataId;
    cds.cbData = static_cast<DWORD>(packet.size());
    cds.lpData = const_cast<uint8_t*>(packet.data());
    DWORD_PTR result = 0;
    SendMessageTimeoutW(bar, WM_COPYDATA, 0, reinterpret_cast<LPARAM>(&cds), SMTO_ABORTIFHUNG | SMTO_NORMAL, 1000,
                        &result);
}

DWORD WINAPI SenderThread(void*) {
    // Explorer may still be starting: wait for its taskbar (only the shell
    // process ever gets one; other explorer.exe processes give up after a minute).
    for (int i = 0; i < 120 && !g_stop.load(); ++i) {
        HWND tray = FindWindowW(L"Shell_TrayWnd", nullptr);
        DWORD pid = 0;
        const DWORD tid = tray ? GetWindowThreadProcessId(tray, &pid) : 0;
        if (tray && pid == GetCurrentProcessId()) {
            g_tray = tray;
            HMODULE self = nullptr;
            GetModuleHandleExW(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                               reinterpret_cast<LPCWSTR>(&CallWndProc), &self);
            g_hook = SetWindowsHookExW(WH_CALLWNDPROC, CallWndProc, self, tid);
            if (!g_hook) {
                Wh_Log(L"SetWindowsHookExW failed (%lu)", GetLastError());
                return 0;
            }
            Wh_Log(L"Watching Shell_TrayWnd %p", tray);
            break;
        }
        if (tray) return 0;  // the taskbar lives in another explorer.exe
        WaitForSingleObject(g_wake, 500);
    }
    if (!g_hook) return 0;

    Enqueue(MakePacket(kHello, nullptr));
    HWND bar = nullptr;
    while (!g_stop.load()) {
        WaitForSingleObject(g_wake, INFINITE);
        for (;;) {
            std::vector<uint8_t> packet;
            {
                std::lock_guard lock(g_queueMutex);
                if (g_queue.empty() || g_stop.load()) break;
                packet = std::move(g_queue.front());
                g_queue.pop_front();
            }
            if (!bar || !IsWindow(bar)) bar = FindBar();
            if (bar) Send(bar, packet);  // no bar: the packet is dropped, the bar re-requests icons on start
        }
    }
    return 0;
}

}  // namespace

BOOL Wh_ModInit() {
    g_wake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!g_wake) return FALSE;
    g_thread = CreateThread(nullptr, 0, SenderThread, nullptr, 0, nullptr);
    return g_thread != nullptr;
}

void Wh_ModUninit() {
    g_stop.store(true);
    if (g_hook) UnhookWindowsHookEx(g_hook);  // first: no new hook calls
    g_hook = nullptr;
    for (int i = 0; i < 100 && g_inHook.load() > 0; ++i) Sleep(10);  // let a running call finish
    if (g_wake) SetEvent(g_wake);
    if (g_thread) {
        WaitForSingleObject(g_thread, 3000);
        CloseHandle(g_thread);
    }
    if (g_wake) CloseHandle(g_wake);
    g_thread = g_wake = nullptr;
}
