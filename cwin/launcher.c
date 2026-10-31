#define _WIN32_WINNT 0x0A00
#include <winsock2.h>
#include "common.h"
/*
 * StockPilot.exe
 *   (no args)      start the bot if needed, wait for it, open its window and bring it to the front
 *   /background    start the bot silently (used at Windows startup)
 *   /pin on|off    keep the StockPilot window on top of other windows (or not)
 * The window is opened HERE (a normal program the user clicked), not by the hidden PowerShell
 * process, because Windows / security software may block or hide windows started from that.
 */
static WCHAR g_dir[MAX_PATH];

typedef struct { int count; int mode; } EnumCtx;     /* mode: 0 count, 1 front+top, 2 front, 3 untop */
static BOOL is_panel_title(const WCHAR *t) {
    if (wcsstr(t, L"Setup") || wcsstr(t, L"Uninstall")) return FALSE;
    return wcscmp(t, L"StockPilot") == 0 || wcsncmp(t, L"StockPilot ", 12) == 0 || wcsncmp(t, L"127.0.0.1:", 10) == 0;
}
static BOOL CALLBACK enum_cb(HWND h, LPARAM lp) {
    EnumCtx *c = (EnumCtx *)lp;
    if (!IsWindowVisible(h)) return TRUE;
    WCHAR t[256]; GetWindowTextW(h, t, 256);
    if (!is_panel_title(t)) return TRUE;
    c->count++;
    if (c->mode == 1 || c->mode == 2) {
        if (IsIconic(h)) ShowWindow(h, SW_RESTORE);
        SetWindowPos(h, HWND_TOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        if (c->mode == 2) SetWindowPos(h, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_SHOWWINDOW);
        BringWindowToTop(h); SetForegroundWindow(h);
    } else if (c->mode == 3) {
        SetWindowPos(h, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
    }
    return TRUE;
}
static int panel_windows(int mode) { EnumCtx c = { 0, mode }; EnumWindows(enum_cb, (LPARAM)&c); return c.count; }

static BOOL want_on_top(void) {
    WCHAR p[MAX_PATH]; swprintf(p, MAX_PATH, L"%ls\\SSPanelData\\settings.json", g_dir);
    HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) return TRUE;
    char buf[256] = { 0 }; DWORD n = 0; ReadFile(h, buf, sizeof buf - 1, &n, NULL); CloseHandle(h);
    return strstr(buf, "\"onTop\":false") == NULL;
}
static int read_port(void) {
    WCHAR p[MAX_PATH]; swprintf(p, MAX_PATH, L"%ls\\SSPanelData\\port.txt", g_dir);
    HANDLE h = CreateFileW(p, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING, 0, NULL);
    if (h == INVALID_HANDLE_VALUE) return 0;
    char buf[16] = { 0 }; DWORD n = 0; ReadFile(h, buf, sizeof buf - 1, &n, NULL); CloseHandle(h);
    return atoi(buf);
}
static BOOL port_alive(int port) {
    if (port <= 0) return FALSE;
    SOCKET s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP); if (s == INVALID_SOCKET) return FALSE;
    struct sockaddr_in a; ZeroMemory(&a, sizeof a); a.sin_family = AF_INET; a.sin_port = htons((u_short)port); a.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    BOOL ok = connect(s, (struct sockaddr *)&a, sizeof a) == 0;
    closesocket(s); return ok;
}
static BOOL file_exists(const WCHAR *p) { return GetFileAttributesW(p) != INVALID_FILE_ATTRIBUTES; }

static BOOL open_browser(const WCHAR *url) {
    WCHAR pf[MAX_PATH] = L"", pf86[MAX_PATH] = L"", la[MAX_PATH] = L"", cand[8][MAX_PATH], args[1024];
    GetEnvironmentVariableW(L"ProgramFiles", pf, MAX_PATH);
    GetEnvironmentVariableW(L"ProgramFiles(x86)", pf86, MAX_PATH);
    GetEnvironmentVariableW(L"LOCALAPPDATA", la, MAX_PATH);
    int nc = 0;
    swprintf(cand[nc++], MAX_PATH, L"%ls\\Google\\Chrome\\Application\\chrome.exe", pf);
    swprintf(cand[nc++], MAX_PATH, L"%ls\\Google\\Chrome\\Application\\chrome.exe", pf86);
    swprintf(cand[nc++], MAX_PATH, L"%ls\\Google\\Chrome\\Application\\chrome.exe", la);
    swprintf(cand[nc++], MAX_PATH, L"%ls\\Microsoft\\Edge\\Application\\msedge.exe", pf86);
    swprintf(cand[nc++], MAX_PATH, L"%ls\\Microsoft\\Edge\\Application\\msedge.exe", pf);
    swprintf(cand[nc++], MAX_PATH, L"%ls\\BraveSoftware\\Brave-Browser\\Application\\brave.exe", pf);
    swprintf(cand[nc++], MAX_PATH, L"%ls\\BraveSoftware\\Brave-Browser\\Application\\brave.exe", la);
    /* window size in the browser's own units (DIPs) */
    RECT wa; SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
    double sc = GetDpiForSystem() / 96.0; if (sc < 1) sc = 1;
    int aw = (int)((wa.right - wa.left) / sc), ah = (int)((wa.bottom - wa.top) / sc);
    int w = aw - 40 < 1240 ? aw - 40 : 1240, hgt = ah - 40 < 800 ? ah - 40 : 800;
    int x = (int)(wa.left / sc) + (aw - w) / 2, y = (int)(wa.top / sc) + (ah - hgt) / 2;
    swprintf(args, 1024, L"--app=%ls --window-size=%d,%d --window-position=%d,%d", url, w, hgt, x, y);
    for (int i = 0; i < nc; i++) {
        if (!file_exists(cand[i])) continue;
        if ((INT_PTR)ShellExecuteW(NULL, L"open", cand[i], args, NULL, SW_SHOWNORMAL) <= 32) continue;
        for (int t = 0; t < 40; t++) { Sleep(250); if (panel_windows(0)) return TRUE; }   /* up to 10 s */
    }
    /* last resort: a normal tab in the default browser */
    if ((INT_PTR)ShellExecuteW(NULL, L"open", url, NULL, NULL, SW_SHOWNORMAL) > 32) {
        for (int t = 0; t < 40; t++) { Sleep(250); if (panel_windows(0)) return TRUE; }
        return TRUE;
    }
    return FALSE;
}

int WINAPI wWinMain(HINSTANCE hi, HINSTANCE hp, LPWSTR a, int n) {
    WCHAR ps1[MAX_PATH], cmd[2048], url[64], logp[MAX_PATH], msg[1024];
    GetModuleFileNameW(NULL, g_dir, MAX_PATH);
    WCHAR *slash = wcsrchr(g_dir, L'\\'); if (slash) *slash = 0;
    BOOL bg = a && wcsstr(a, L"/background") != NULL;
    if (a && wcsstr(a, L"/pin")) { panel_windows(wcsstr(a, L"off") ? 3 : 1); return 0; }

    AllowSetForegroundWindow(ASFW_ANY);
    if (!bg && panel_windows(want_on_top() ? 1 : 2)) return 0;      /* already open: just bring it to the front */

    swprintf(ps1, MAX_PATH, L"%ls\\StockPilot.ps1", g_dir);
    if (!file_exists(ps1)) { MessageBoxW(NULL, L"StockPilot.ps1 is missing. Please run StockPilot-Setup.exe again.", TITLE, MB_ICONERROR); return 1; }
    find_ps();
    swprintf(cmd, 2048, L"\"%ls\" -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"%ls\" -NoOpen%ls", g_ps, ps1, bg ? L" -Background" : L"");
    STARTUPINFOW si; PROCESS_INFORMATION pi; ZeroMemory(&si, sizeof si); si.cb = sizeof si;
    if (!CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, g_dir, &si, &pi)) { fail(L"Couldn't start PowerShell to run StockPilot."); return 1; }
    CloseHandle(pi.hThread);
    if (bg) { CloseHandle(pi.hProcess); return 0; }

    /* wait until the bot's local page answers (a new copy, or the one already running) */
    WSADATA wd; WSAStartup(MAKEWORD(2, 2), &wd);
    int port = 0; BOOL up = FALSE;
    for (int t = 0; t < 100 && !up; t++) {        /* up to ~25 s */
        port = read_port();
        if (port_alive(port)) { up = TRUE; break; }
        Sleep(250);
    }
    CloseHandle(pi.hProcess);
    swprintf(logp, MAX_PATH, L"%ls\\SSPanelData\\log.txt", g_dir);
    if (!up) {
        swprintf(msg, 1024, L"StockPilot started but its window couldn't be opened (the bot's local page isn't answering).\n\n"
            L"Try restarting your PC. If it keeps happening, send this file to whoever helps you:\n%ls", logp);
        MessageBoxW(NULL, msg, TITLE, MB_ICONWARNING);
        WSACleanup(); return 1;
    }
    WSACleanup();
    if (panel_windows(want_on_top() ? 1 : 2)) return 0;
    swprintf(url, 64, L"http://127.0.0.1:%d/", port);
    if (!open_browser(url)) {
        swprintf(msg, 1024, L"StockPilot is running, but no browser could be opened.\n\nOpen this address in any browser:\n%ls", url);
        MessageBoxW(NULL, msg, TITLE, MB_ICONWARNING);
        return 1;
    }
    for (int t = 0; t < 20 && !panel_windows(want_on_top() ? 1 : 2); t++) Sleep(250);
    return 0;
}
