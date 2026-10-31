#define UNICODE
#define _UNICODE
#include <windows.h>
#include <shellapi.h>
#include <stdio.h>
#include <stdlib.h>
#include <wchar.h>
#define TITLE L"StockPilot v1.1"
static WCHAR g_ps[MAX_PATH];
static void find_ps(void) {
    WCHAR w[MAX_PATH]; GetWindowsDirectoryW(w, MAX_PATH);
    swprintf(g_ps, MAX_PATH, L"%ls\\System32\\WindowsPowerShell\\v1.0\\powershell.exe", w);
}
static void install_dir(WCHAR *out, WCHAR *game) {
    WCHAR prof[MAX_PATH] = L"", la[MAX_PATH] = L"";
    GetEnvironmentVariableW(L"USERPROFILE", prof, MAX_PATH);
    GetEnvironmentVariableW(L"LOCALAPPDATA", la, MAX_PATH);
    swprintf(game, MAX_PATH, L"%ls\\AppData\\LocalLow\\Conradical Games\\Screen Stocks", prof);
    /* NOT inside LocalLow: Windows starts programs from there in low-trust mode (no Temp, no browsers) */
    swprintf(out, MAX_PATH, L"%ls\\Programs\\StockPilot", la);
}
static BOOL is_arm64(void) {
    typedef BOOL (WINAPI *P)(HANDLE, USHORT *, USHORT *);
    P f = (P)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "IsWow64Process2");
    USHORT pm = 0, nm = 0;
    return f && f(GetCurrentProcess(), &pm, &nm) && nm == 0xAA64;
}
static BOOL make_dirs(const WCHAR *path) {           /* mkdir -p */
    WCHAR tmp[MAX_PATH]; wcsncpy(tmp, path, MAX_PATH - 1); tmp[MAX_PATH - 1] = 0;
    for (WCHAR *p = tmp + 3; *p; p++) if (*p == L'\\') { *p = 0; CreateDirectoryW(tmp, NULL); *p = L'\\'; }
    return CreateDirectoryW(tmp, NULL) || GetLastError() == ERROR_ALREADY_EXISTS;
}
static BOOL write_file(const WCHAR *path, const unsigned char *data, DWORD len) {
    HANDLE h = CreateFileW(path, GENERIC_WRITE, 0, NULL, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (h == INVALID_HANDLE_VALUE) return FALSE;
    DWORD w = 0; BOOL ok = WriteFile(h, data, len, &w, NULL) && w == len;
    CloseHandle(h); return ok;
}
/* run a command with no window, wait for it, optionally capture its output */
static DWORD run_hidden(const WCHAR *cmdline, char *out, DWORD outsz) {
    SECURITY_ATTRIBUTES sa = { sizeof(sa), NULL, TRUE }; HANDLE rd = NULL, wr = NULL;
    STARTUPINFOW si; PROCESS_INFORMATION pi; ZeroMemory(&si, sizeof si); si.cb = sizeof si;
    if (out) { out[0] = 0; if (!CreatePipe(&rd, &wr, &sa, 0)) out = NULL; else { SetHandleInformation(rd, HANDLE_FLAG_INHERIT, 0); si.dwFlags = STARTF_USESTDHANDLES; si.hStdOutput = wr; si.hStdError = wr; } }
    WCHAR *cl = _wcsdup(cmdline);
    BOOL ok = CreateProcessW(NULL, cl, NULL, NULL, out ? TRUE : FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi);
    free(cl);
    if (out) CloseHandle(wr);
    if (!ok) { if (out) CloseHandle(rd); return (DWORD)-1; }
    if (out) {
        DWORD n = 0, tot = 0; char buf[512];
        while (ReadFile(rd, buf, sizeof buf, &n, NULL) && n) { if (tot + n < outsz - 1) { memcpy(out + tot, buf, n); tot += n; } }
        out[tot] = 0; CloseHandle(rd);
        for (int i = (int)tot - 1; i >= 0 && (out[i] == '\r' || out[i] == '\n' || out[i] == ' '); i--) out[i] = 0;
    }
    WaitForSingleObject(pi.hProcess, 120000);
    DWORD code = 0; GetExitCodeProcess(pi.hProcess, &code);
    CloseHandle(pi.hProcess); CloseHandle(pi.hThread);
    return code;
}
static void fail(const WCHAR *what) {
    WCHAR msg[1024], err[512] = L"";
    FormatMessageW(FORMAT_MESSAGE_FROM_SYSTEM | FORMAT_MESSAGE_IGNORE_INSERTS, NULL, GetLastError(), 0, err, 512, NULL);
    swprintf(msg, 1024, L"%ls\n\n%ls", what, err);
    MessageBoxW(NULL, msg, TITLE, MB_ICONERROR);
}
