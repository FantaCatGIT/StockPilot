#include "common.h"
#include "payload_setup.h"
int WINAPI wWinMain(HINSTANCE h, HINSTANCE p, LPWSTR a, int n) {
    WCHAR dir[MAX_PATH], game[MAX_PATH], path[MAX_PATH], cmd[4096];
    install_dir(dir, game);
    if (MessageBoxW(NULL,
        L"Install StockPilot v1.1?\n\n"
        L"Auto rules bot, live charts, daily profit and a calculator for Screen Stocks. "
        L"It uses the game's official mod support.\n\n"
        L"If an older version (or the old .bat bot) is running it will be closed. Your rules are kept.",
        L"StockPilot v1.1 Setup", MB_OKCANCEL | MB_ICONINFORMATION) != IDOK) return 0;
    find_ps();
    BOOL arm = is_arm64();
    if (!make_dirs(dir)) { fail(L"Couldn't create the StockPilot folder."); return 1; }
    swprintf(path, MAX_PATH, L"%ls\\setup.ps1", dir);
    if (!write_file(path, setup_ps1, sizeof setup_ps1)) { fail(L"Couldn't write setup.ps1."); return 1; }
    swprintf(cmd, 4096, L"\"%ls\" -NoProfile -ExecutionPolicy Bypass -File \"%ls\" -Phase pre -Dir \"%ls\" -Game \"%ls\"", g_ps, path, dir, game);
    run_hidden(cmd, NULL, 0);
    struct { const WCHAR *name; const unsigned char *data; DWORD len; } files[] = {
        { L"StockPilot.ps1", stockpilot_ps1, sizeof stockpilot_ps1 },
        { L"StockPilot.exe", arm ? stockpilot_exe_arm64 : stockpilot_exe, arm ? sizeof stockpilot_exe_arm64 : sizeof stockpilot_exe },
        { L"Uninstall.exe",   arm ? uninstall_exe_arm64 : uninstall_exe,   arm ? sizeof uninstall_exe_arm64 : sizeof uninstall_exe },
        { L"icon.ico",        icon_ico,        sizeof icon_ico },
    };
    for (int i = 0; i < 4; i++) {
        swprintf(path, MAX_PATH, L"%ls\\%ls", dir, files[i].name);
        BOOL ok = FALSE;
        for (int t = 0; t < 10 && !(ok = write_file(path, files[i].data, files[i].len)); t++) Sleep(500);
        if (!ok) { WCHAR m[600]; swprintf(m, 600, L"Couldn't write %ls.", path); fail(m); return 1; }
    }
    swprintf(path, MAX_PATH, L"%ls\\setup.ps1", dir);
    swprintf(cmd, 4096, L"\"%ls\" -NoProfile -ExecutionPolicy Bypass -File \"%ls\" -Phase post -Dir \"%ls\" -Game \"%ls\"", g_ps, path, dir, game);
    DWORD code = run_hidden(cmd, NULL, 0);
    DeleteFileW(path);
    if (code != 0) MessageBoxW(NULL, L"StockPilot is installed, but the shortcuts couldn't be created. You can start it from:\n%LOCALAPPDATA%\\Programs\\StockPilot\\StockPilot.exe", TITLE, MB_ICONWARNING);
    if (MessageBoxW(NULL, L"StockPilot is installed!\n\nClose Screen Stocks, start StockPilot (it turns mod support on), then open Screen Stocks again.\n\nStart StockPilot now?", L"StockPilot v1.1 Setup", MB_YESNO | MB_ICONINFORMATION) == IDYES) {
        swprintf(path, MAX_PATH, L"%ls\\StockPilot.exe", dir);
        ShellExecuteW(NULL, L"open", path, NULL, dir, SW_SHOWNORMAL);
    }
    return 0;
}
