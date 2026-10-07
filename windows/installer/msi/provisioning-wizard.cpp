// SPDX-License-Identifier: Apache-2.0
// Native UI; developer conversion is delegated to the portable C command.
#include <windows.h>
#include <commctrl.h>
#include <shlobj.h>
#include <shellapi.h>
#include <sddl.h>
#include <bcrypt.h>
#include <string>
#include <vector>
#include <stdexcept>
#include "config.h"
#pragma comment(linker,"/manifestdependency:\"type='win32' name='Microsoft.Windows.Common-Controls' version='6.0.0.0' processorArchitecture='amd64' publicKeyToken='6595b64144ccf1df' language='*'\"")

static std::wstring folder(REFKNOWNFOLDERID id) {
    PWSTR path = nullptr;
    if (FAILED(SHGetKnownFolderPath(id,0,nullptr,&path))) throw std::runtime_error("Known folder unavailable");
    std::wstring result(path); CoTaskMemFree(path); return result;
}
static std::wstring dataRoot() { return folder(FOLDERID_ProgramData) + L"\\Izuma\\EdgeCore" EDGE_FOLDER_SUFFIX; }
static std::wstring payload() { return folder(FOLDERID_ProgramFilesX64) + L"\\Izuma\\EdgeMsiPayload" EDGE_FOLDER_SUFFIX L"\\" EDGE_VERSION; }
static bool exists(const std::wstring& path, bool directory = false) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    if (attributes == INVALID_FILE_ATTRIBUTES) {
        if (GetLastError() == ERROR_FILE_NOT_FOUND || GetLastError() == ERROR_PATH_NOT_FOUND) return false;
        throw std::runtime_error("Identity storage unavailable");
    }
    if (attributes & FILE_ATTRIBUTE_REPARSE_POINT) throw std::runtime_error("Reparse point in service data");
    if (directory != !!(attributes & FILE_ATTRIBUTE_DIRECTORY)) throw std::runtime_error("Unexpected service data member");
    if (!directory) {
        WIN32_FILE_ATTRIBUTE_DATA info{};
        if (!GetFileAttributesExW(path.c_str(),GetFileExInfoStandard,&info) || (!info.nFileSizeHigh && !info.nFileSizeLow)) throw std::runtime_error("Empty identity member");
    }
    return true;
}
static void safeParents(const std::wstring& path) {
    if (path.size() < 3 || path[1] != L':' || path[2] != L'\\' || path.find_first_of(L"\"\r\n",3) != std::wstring::npos) throw std::runtime_error("Expected a local path");
    for (size_t i = 3; i < path.size(); ++i) if (path[i] == L'\\') (void)exists(path.substr(0,i),true);
}
static bool populated(const std::wstring& path) {
    if (!exists(path,true)) return false;
    WIN32_FIND_DATAW entry{};
    const HANDLE search = FindFirstFileW((path+L"\\*").c_str(),&entry);
    if (search == INVALID_HANDLE_VALUE) {
        if (GetLastError() == ERROR_FILE_NOT_FOUND) return false;
        throw std::runtime_error("Cannot inspect service data");
    }
    bool found = false;
    do {
        if (!wcscmp(entry.cFileName,L".") || !wcscmp(entry.cFileName,L"..")) continue;
        if (entry.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) { FindClose(search); throw std::runtime_error("Reparse point in identity storage"); }
        if (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            try { (void)populated(path+L"\\"+entry.cFileName); }
            catch (...) { FindClose(search); throw; }
        }
        found = true;
    } while (FindNextFileW(search,&entry));
    const DWORD error = GetLastError(); FindClose(search);
    if (error != ERROR_NO_MORE_FILES) throw std::runtime_error("Incomplete identity enumeration");
    return found;
}
static std::wstring storageName(const char* name) {
    unsigned char hash[32]{};
    BCRYPT_ALG_HANDLE alg = nullptr;
    if (BCryptOpenAlgorithmProvider(&alg,BCRYPT_SHA256_ALGORITHM,nullptr,0) < 0) throw std::runtime_error("Hash unavailable");
    const auto result = BCryptHash(alg,nullptr,0,reinterpret_cast<PUCHAR>(const_cast<char*>(name)),static_cast<ULONG>(strlen(name)),hash,sizeof(hash));
    BCryptCloseAlgorithmProvider(alg,0);
    if (result < 0) throw std::runtime_error("Hash failed");
    static const wchar_t alphabet[] = L"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789#_";
    std::wstring text;
    for (size_t i = 0; i < 6; i += 3) {
        const unsigned value = (static_cast<unsigned>(hash[i])<<16) | (static_cast<unsigned>(hash[i+1])<<8) | hash[i+2];
        text += alphabet[(value>>18)&63]; text += alphabet[(value>>12)&63]; text += alphabet[(value>>6)&63]; text += alphabet[value&63];
    }
    return text;
}
struct Service { std::wstring command; DWORD state; };
static SC_HANDLE openService(DWORD access) {
    SC_HANDLE manager = OpenSCManagerW(nullptr,nullptr,SC_MANAGER_CONNECT);
    if (!manager) throw std::runtime_error("Service manager unavailable");
    SC_HANDLE service = OpenServiceW(manager,EDGE_SERVICE_NAME,access);
    CloseServiceHandle(manager);
    if (!service) throw std::runtime_error("Installed service unavailable");
    return service;
}
static Service serviceInfo(SC_HANDLE service) {
    DWORD size = 0; QueryServiceConfigW(service,nullptr,0,&size);
    std::vector<BYTE> config(size);
    if (!size || !QueryServiceConfigW(service,reinterpret_cast<LPQUERY_SERVICE_CONFIGW>(config.data()),size,&size)) { throw std::runtime_error("Service configuration unavailable"); }
    const auto* info = reinterpret_cast<LPQUERY_SERVICE_CONFIGW>(config.data());
    Service result{info->lpBinaryPathName,0};
    if (_wcsicmp(info->lpServiceStartName,L"NT AUTHORITY\\LocalService") || result.command.find(L"--data-dir \""+dataRoot()+L"\\state\"") == std::wstring::npos || result.command.find(L"--service-name " EDGE_SERVICE_NAME L" ") == std::wstring::npos) { throw std::runtime_error("Service ownership mismatch"); }
    SERVICE_STATUS status{};
    if (!QueryServiceStatus(service,&status)) { throw std::runtime_error("Service status unavailable"); }
    result.state = status.dwCurrentState; return result;
}
static Service serviceInfo() {
    SC_HANDLE service = openService(SERVICE_QUERY_CONFIG | SERVICE_QUERY_STATUS);
    try { const auto result = serviceInfo(service); CloseServiceHandle(service); return result; }
    catch (...) { CloseServiceHandle(service); throw; }
}
// Codes are also used by credential-free release qualification.
enum class Identity { Empty = 0, Existing = 10, Pending = 11, Retained = 12, Unavailable = 13 };
static Identity inspect() {
    const auto root = dataRoot(); const auto state = root+L"\\state";
    safeParents(state); if (!exists(root,true) || !exists(state,true)) throw std::runtime_error("Installed service data unavailable");
    const auto service = serviceInfo();
    const bool retained = populated(state);
    const auto working = state+L"\\mcc_config\\WORKING\\";
    safeParents(working);
    const bool endpoint = exists(working+storageName("CfgParam_mbed.EndpointName"));
    const bool bootstrap = exists(working+storageName("Cert_mbed.BootstrapDeviceCert")) && exists(working+storageName("PrvKey_mbed.BootstrapDevicePrivateKey"));
    const bool operational = exists(working+storageName("Cert_mbed.LwM2MDeviceCert")) && exists(working+storageName("PrvKey_mbed.LwM2MDevicePrivateKey"));
    if (endpoint && (bootstrap || operational)) return Identity::Existing;
    if (service.command.find(L"--cbor-conf") != std::wstring::npos || service.command.find(L"--json-conf") != std::wstring::npos ||
        exists(root+L"\\provisioning-import.json") || exists(root+L"\\provisioning-import.json.pending")) return Identity::Pending;
    if (retained || service.command.find(L"--reset-storage") != std::wstring::npos) return Identity::Retained;
    if (service.state != SERVICE_STOPPED) return Identity::Unavailable;
    return Identity::Empty;
}
// Reuse the configured identity without importing credentials or changing SCM configuration.
// Both the desktop wizard and credential-free qualification call this path.
static void resume() {
    const auto identity = inspect();
    if (identity != Identity::Existing && identity != Identity::Pending) throw std::runtime_error("No configured identity to resume");
    SC_HANDLE service = openService(SERVICE_QUERY_CONFIG | SERVICE_QUERY_STATUS | SERVICE_START);
    try {
        (void)serviceInfo(service); // Recheck ownership on the handle being started.
        const ULONGLONG deadline = GetTickCount64()+30000;
        bool started = false;
        for (;;) {
            SERVICE_STATUS status{};
            if (!QueryServiceStatus(service,&status)) throw std::runtime_error("Service status unavailable");
            if (status.dwCurrentState == SERVICE_RUNNING) break;
            if (GetTickCount64() >= deadline) throw std::runtime_error("Service startup timed out");
            if (status.dwCurrentState == SERVICE_STOPPED) {
                if (started) throw std::runtime_error("Service stopped during startup");
                if (!StartServiceW(service,0,nullptr) && GetLastError() != ERROR_SERVICE_ALREADY_RUNNING) throw std::runtime_error("Service could not start");
                started = true;
            } else if (status.dwCurrentState != SERVICE_START_PENDING && status.dwCurrentState != SERVICE_STOP_PENDING) {
                throw std::runtime_error("Service state needs attention");
            }
            Sleep(200);
        }
        CloseServiceHandle(service);
    } catch (...) { CloseServiceHandle(service); throw; }
}
static void message(const wchar_t* title, const wchar_t* body, PCWSTR icon = TD_INFORMATION_ICON) {
    int button = 0;
    if (FAILED(TaskDialog(nullptr,nullptr,L"Izuma Edge provisioning",title,body,TDCBF_OK_BUTTON,icon,&button))) MessageBoxW(nullptr,body,title,MB_OK | MB_ICONINFORMATION);
}
static std::wstring choose(bool developer) {
    IFileOpenDialog* dialog = nullptr;
    if (FAILED(CoCreateInstance(CLSID_FileOpenDialog,nullptr,CLSCTX_INPROC_SERVER,IID_PPV_ARGS(&dialog)))) throw std::runtime_error("File picker unavailable");
    const COMDLG_FILTERSPEC dev[] = {{L"Developer credential C files",L"*.c"},{L"All files",L"*.*"}};
    const COMDLG_FILTERSPEC prod[] = {{L"Provisioning bundles",L"*.cbor;*.json"},{L"All files",L"*.*"}};
    dialog->SetTitle(developer ? L"Select developer credentials" : L"Select production bundle");
    dialog->SetFileTypes(2,developer ? dev : prod);
    dialog->SetOptions(FOS_FORCEFILESYSTEM | FOS_FILEMUSTEXIST | FOS_PATHMUSTEXIST | FOS_DONTADDTORECENT);
    const HRESULT show = dialog->Show(nullptr);
    if (show == HRESULT_FROM_WIN32(ERROR_CANCELLED)) { dialog->Release(); return {}; }
    IShellItem* item = nullptr; PWSTR path = nullptr;
    if (FAILED(show) || FAILED(dialog->GetResult(&item)) || FAILED(item->GetDisplayName(SIGDN_FILESYSPATH,&path))) {
        if (item) item->Release();
        dialog->Release(); throw std::runtime_error("File selection failed");
    }
    std::wstring result(path); CoTaskMemFree(path); item->Release(); dialog->Release(); safeParents(result);
    if (!exists(result)) throw std::runtime_error("Input file unavailable");
    return result;
}
static std::wstring quote(const std::wstring& value) {
    std::wstring result = L"\""; size_t slash = 0;
    for (wchar_t ch : value) {
        if (ch == L'\\') { ++slash; continue; }
        result.append(ch == L'"' ? slash*2+1 : slash,L'\\'); slash = 0; result += ch;
    }
    result.append(slash*2,L'\\'); return result+L"\"";
}
static bool run(const std::wstring& file, const std::vector<std::wstring>& args) {
    safeParents(file); if (!exists(file)) throw std::runtime_error("Installed command missing");
    std::wstring command = quote(file);
    for (const auto& arg : args) command += L" "+quote(arg);
    if (command.size() >= 32767) throw std::runtime_error("Command too long");
    STARTUPINFOW startup{}; startup.cb = sizeof(startup); PROCESS_INFORMATION process{};
    if (!CreateProcessW(file.c_str(),command.data(),nullptr,nullptr,FALSE,CREATE_NO_WINDOW,nullptr,payload().c_str(),&startup,&process)) throw std::runtime_error("Command could not start");
    CloseHandle(process.hThread); const DWORD wait = WaitForSingleObject(process.hProcess,INFINITE); DWORD exit = 1;
    const BOOL result = GetExitCodeProcess(process.hProcess,&exit); CloseHandle(process.hProcess);
    return wait == WAIT_OBJECT_0 && result && exit == 0;
}
static std::wstring privateStage() {
    GUID id{}; wchar_t name[40];
    if (FAILED(CoCreateGuid(&id)) || !StringFromGUID2(id,name,40)) throw std::runtime_error("Unique directory unavailable");
    const auto path = dataRoot()+L"\\config\\developer-conversion-"+name;
    safeParents(path); PSECURITY_DESCRIPTOR sd = nullptr;
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)",SDDL_REVISION_1,&sd,nullptr)) throw std::runtime_error("Private permissions unavailable");
    SECURITY_ATTRIBUTES sa{sizeof(sa),sd,FALSE}; const BOOL made = CreateDirectoryW(path.c_str(),&sa); LocalFree(sd);
    if (!made) throw std::runtime_error("Private directory unavailable"); return path;
}
static bool provision(const std::wstring& input, bool developer, bool startService = true) {
    if (inspect() != Identity::Empty) throw std::runtime_error("Existing state must be preserved");
    std::wstring stage, bundle = input; bool result = false;
    try {
        if (developer) {
            stage = privateStage(); bundle = stage+L"\\provisioning.cbor";
            if (!run(payload()+L"\\core\\bin\\edge-provision.exe",{L"convert-developer",L"--input",input,L"--output",bundle})) throw std::runtime_error("Developer conversion failed");
        }
        wchar_t system[MAX_PATH]{};
        if (!GetSystemDirectoryW(system,MAX_PATH)) throw std::runtime_error("System directory unavailable");
        std::vector<std::wstring> arguments{
            L"-NoProfile",L"-NonInteractive",L"-ExecutionPolicy",L"Bypass",L"-File",payload()+L"\\core\\scripts\\provision-service.ps1",
            L"-ServiceName",EDGE_SERVICE_NAME,L"-DataDirectory",dataRoot(),L"-ProvisioningFile",bundle,
            L"-ProvisioningMode",developer ? L"developer" : L"production"};
        if (startService) arguments.push_back(L"-Start");
        result = run(std::wstring(system)+L"\\WindowsPowerShell\\v1.0\\powershell.exe",arguments);
    } catch (...) {
        if (!stage.empty()) { DeleteFileW(bundle.c_str()); RemoveDirectoryW(stage.c_str()); }
        throw;
    }
    if (!stage.empty()) { DeleteFileW(bundle.c_str()); RemoveDirectoryW(stage.c_str()); }
    return result;
}
static void wizard(bool startService) {
    for (;;) {
        const auto identity = inspect();
        if (identity == Identity::Existing || identity == Identity::Pending) {
            const wchar_t* title = identity == Identity::Existing ? L"Existing device identity found" : L"Provisioning is already configured";
            if (!startService) {
                message(title,L"Izuma Edge will reuse the existing identity or configured bundle. Automatic service startup was skipped to preserve your installation options."); return;
            }
            try {
                resume();
                message(title,identity == Identity::Existing
                    ? L"The Izuma Edge service is running and will continue to use the existing device identity. No new provisioning file is needed."
                    : L"The Izuma Edge service is running with its existing provisioning bundle. Bootstrap completes when cloud connectivity is available.");
            } catch (...) {
                message(title,L"The existing identity or configured bundle was preserved, but Edge Core could not be started. Use Start Edge Core in the monitor or ask an administrator to inspect the service logs.",TD_WARNING_ICON);
            }
            return;
        }
        if (identity != Identity::Empty) { message(L"Existing device state needs attention",L"Device state was preserved, but a complete identity could not be confirmed. New provisioning will not replace it. An administrator can inspect the service before continuing.",TD_WARNING_ICON); return; }
        const TASKDIALOG_BUTTON buttons[] = {
            {101,L"Production flow\nI have a production bundle"},
            {102,L"Developer flow\nI have a developer credential C file"},
            {103,L"Don't provision right now\nKeep the service installed and stopped"}};
        TASKDIALOGCONFIG dialog{}; dialog.cbSize = sizeof(dialog); dialog.dwFlags = TDF_USE_COMMAND_LINKS | TDF_ALLOW_DIALOG_CANCELLATION | TDF_SIZE_TO_CONTENT;
        dialog.pszWindowTitle = L"Izuma Edge provisioning"; dialog.pszMainInstruction = L"Set up this device's identity";
        dialog.pszContent = L"Installation is complete. No existing device identity was found. Choose how to provision this device.";
        dialog.cButtons = 3; dialog.pButtons = buttons; dialog.nDefaultButton = 103; dialog.pszMainIcon = TD_INFORMATION_ICON;
        int selected = 103;
        if (FAILED(TaskDialogIndirect(&dialog,&selected,nullptr,nullptr))) throw std::runtime_error("Provisioning dialog unavailable");
        if (selected != 101 && selected != 102) { message(L"Provisioning deferred",L"Izuma Edge is installed. The service will remain stopped until an administrator supplies provisioning credentials."); return; }
        const bool developer = selected == 102; const auto input = choose(developer);
        if (input.empty()) continue;
        try {
            if (!provision(input,developer,startService)) throw std::runtime_error("Provisioning activation failed");
            message(L"Provisioning configured",startService
                ? L"The bundle was imported and the Izuma Edge service started. Cloud bootstrap completes when connectivity is available."
                : L"The bundle was imported. Automatic service startup was skipped to preserve your installation options."); return;
        } catch (...) {
            message(L"Provisioning could not be completed",L"Check that the selected file is a valid provisioning bundle or portal developer credential file, then try again. Installation is complete and existing state was preserved. If a bundle was already configured, an administrator can inspect the provisioning journal.",TD_WARNING_ICON);
        }
    }
}
int WINAPI wWinMain(HINSTANCE,HINSTANCE,PWSTR,int) {
    const HRESULT com = CoInitializeEx(nullptr,COINIT_APARTMENTTHREADED);
    if (FAILED(com)) return static_cast<int>(Identity::Unavailable);
    int argc = 0; LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(),&argc);
    const bool inspection = argv && argc == 2 && !wcscmp(argv[1],L"--inspect");
    const bool import = argv && argc == 3 && (!wcscmp(argv[1],L"--developer") || !wcscmp(argv[1],L"--production"));
    const bool developer = import && !wcscmp(argv[1],L"--developer");
    const bool resuming = argv && argc == 2 && !wcscmp(argv[1],L"--resume");
    const bool keepStopped = argv && argc == 2 && !wcscmp(argv[1],L"--keep-stopped");
    const std::wstring input = import ? argv[2] : L"";
    const bool headless = argc > 1 && !keepStopped;
    if (argv) LocalFree(argv);
    int result = 0;
    try {
        if (inspection) result = static_cast<int>(inspect());
        else if (import) result = provision(input,developer) ? 0 : 1;
        else if (resuming) resume();
        else if (headless) result = 2;
        else {
            SID_IDENTIFIER_AUTHORITY authority = SECURITY_NT_AUTHORITY; PSID admin = nullptr; BOOL elevated = FALSE;
            if (!AllocateAndInitializeSid(&authority,2,SECURITY_BUILTIN_DOMAIN_RID,DOMAIN_ALIAS_RID_ADMINS,0,0,0,0,0,0,&admin)) throw std::runtime_error("Administrator check failed");
            const BOOL checked = CheckTokenMembership(nullptr,admin,&elevated); FreeSid(admin);
            if (!checked || !elevated) throw std::runtime_error("Administrator access needed");
            wizard(!keepStopped);
        }
    } catch (...) {
        result = static_cast<int>(Identity::Unavailable);
        if (!headless) message(L"Provisioning needs administrator attention",L"Installation is complete, but the service or its private identity storage could not be checked. Existing state was preserved. An administrator can run provisioning later.",TD_WARNING_ICON);
    }
    CoUninitialize(); return result;
}
