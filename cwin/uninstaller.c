#include "common.h"
#include "payload_uninstall.h"
int WINAPI wWinMain(HINSTANCE h, HINSTANCE p, LPWSTR a, int n) {
    WCHAR dir[MAX_PATH], game[MAX_PATH], work[MAX_PATH], ps1[MAX_PATH], cmd[4096], self[MAX_PATH], msg[1024];
    char out[512];
    if (MessageBoxW(NULL,
        L"Remove StockPilot?\n\nThis stops the bot, switches the game's mod support off and deletes StockPilot, "
        L"your rules and saved chart / profit data.\n\nYour custom skins are kept.",
        L"Uninstall StockPilot", MB_YESNO | MB_ICONQUESTION) != IDYES) return 0;
    install_dir(dir, game);
    DWORD sz = sizeof dir;
    WCHAR reg[MAX_PATH];
    if (RegGetValueW(HKEY_CURRENT_USER, L"Software\\StockPilot", L"InstallDir", RRF_RT_REG_SZ, NULL, reg, &sz) == ERROR_SUCCESS && reg[0]) wcscpy(dir, reg);
    find_ps();
    WCHAR la[MAX_PATH] = L""; GetEnvironmentVariableW(L"LOCALAPPDATA", la, MAX_PATH);
    swprintf(work, MAX_PATH, L"%ls\\StockPilot-uninstall", la);
    make_dirs(work);
    swprintf(ps1, MAX_PATH, L"%ls\\uninstall.ps1", work);
    if (!write_file(ps1, uninstall_ps1, sizeof uninstall_ps1)) { fail(L"Couldn't write uninstall.ps1."); return 1; }
    swprintf(cmd, 4096, L"\"%ls\" -NoProfile -ExecutionPolicy Bypass -File \"%ls\" -InstallDir \"%ls\"", g_ps, ps1, dir);
    DWORD code = run_hidden(cmd, out, sizeof out);
    if (code == 3) {
        swprintf(msg, 1024, L"Screen Stocks is still open (%hs). It may be shrunk into a corner of your screen.\n\n"
            L"Yes = close the game for me and finish uninstalling.\nNo = keep the game open and leave mod support on.\nCancel = stop.", out);
        int r = MessageBoxW(NULL, msg, L"Uninstall StockPilot", MB_YESNOCANCEL | MB_ICONWARNING);
        if (r == IDCANCEL) { DeleteFileW(ps1); RemoveDirectoryW(work); return 0; }
        if (r == IDYES) {
            swprintf(cmd, 4096, L"\"%ls\" -NoProfile -ExecutionPolicy Bypass -File \"%ls\" -InstallDir \"%ls\" -CloseGame", g_ps, ps1, dir);
            code = run_hidden(cmd, out, sizeof out);
            if (code == 3) MessageBoxW(NULL, L"Couldn't close Screen Stocks, so mod support was left on. Everything else will be removed.", L"Uninstall StockPilot", MB_ICONWARNING);
        }
        if (code == 3 || r == IDNO) {
            swprintf(cmd, 4096, L"\"%ls\" -NoProfile -ExecutionPolicy Bypass -File \"%ls\" -InstallDir \"%ls\" -SkipModOff", g_ps, ps1, dir);
            code = run_hidden(cmd, out, sizeof out);
        }
    }
    DeleteFileW(ps1); RemoveDirectoryW(work);
    if (code == (DWORD)-1) { fail(L"Couldn't start PowerShell to remove StockPilot."); return 1; }
    MessageBoxW(NULL, L"StockPilot was removed.", L"Uninstall StockPilot", MB_ICONINFORMATION);
    /* remove the install folder, and this Uninstall.exe if it lives there, a moment after we exit */
    GetModuleFileNameW(NULL, self, MAX_PATH);
    size_t dl = wcslen(dir);
    if (_wcsnicmp(self, dir, dl) == 0 && self[dl] == L'\\') {
        WCHAR sys[MAX_PATH]; GetSystemDirectoryW(sys, MAX_PATH);
        swprintf(cmd, 4096, L"\"%ls\\cmd.exe\" /c ping -n 3 127.0.0.1 >nul & del /f /q \"%ls\" & rmdir \"%ls\"", sys, self, dir);
        STARTUPINFOW si; PROCESS_INFORMATION pi; ZeroMemory(&si, sizeof si); si.cb = sizeof si;
        if (CreateProcessW(NULL, cmd, NULL, NULL, FALSE, CREATE_NO_WINDOW, NULL, NULL, &si, &pi)) { CloseHandle(pi.hProcess); CloseHandle(pi.hThread); }
    } else RemoveDirectoryW(dir);
    return 0;
}
