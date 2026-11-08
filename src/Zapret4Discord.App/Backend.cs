using System;
using System.Collections.Generic;
using System.ComponentModel;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.ServiceProcess;
using System.Text;
using System.Threading.Tasks;
using System.Web.Script.Serialization;

namespace Zapret4Discord;

internal sealed class BackendState
{
    public bool Installed { get; set; }
    public bool Running { get; set; }
    public bool Transitioning { get; set; }
    public bool SettingsValid { get; set; }
    public bool Enabled { get; set; }
    public string EngineVersion { get; set; } = "zapret2 v1.0.7";
    public string Strategy { get; set; } = "";
    public int ExcludedVpnTargets { get; set; }
    public string? ReadError { get; set; }
    public string ManagerVersion { get; set; } = "";
    public int HostsCorrectCount { get; set; }
    public string NetworkFingerprint { get; set; } = "";
    public bool SupportsProfiles => Version.TryParse(ManagerVersion, out var version) && version >= new Version(1, 1, 0);
}

internal sealed class ProbeItem
{
    public string Url { get; set; } = "";
    public string TLS { get; set; } = "";
    public bool Success { get; set; }
    public int HttpCode { get; set; }
    public string Detail { get; set; } = "";
}

internal sealed class PayloadFile
{
    public string Path { get; set; } = "";
    public string SHA256 { get; set; } = "";
}

internal static class Backend
{
    public const string ServiceName = "ZapretDiscordOnly";
    public static readonly string Root = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData), ServiceName);
    public static readonly string Payload = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "payload");
    public static readonly string InstalledScript = Path.Combine(Root, "Manage-DiscordOnly.ps1");
    private static string PowerShell => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\WindowsPowerShell\v1.0\powershell.exe");

    public static BackendState ReadState()
    {
        var state = new BackendState();
        try
        {
            using var service = new ServiceController(ServiceName);
            var status = service.Status;
            state.Installed = true;
            state.Running = status == ServiceControllerStatus.Running;
            state.Transitioning = status == ServiceControllerStatus.StartPending || status == ServiceControllerStatus.StopPending;
        }
        catch (InvalidOperationException error)
        {
            if (!(error.InnerException is Win32Exception win32) || win32.NativeErrorCode != 1060)
                state.ReadError = "Servis durumu okunamadı.";
        }
        catch (Win32Exception) { state.ReadError = "Servis durumu okunamadı."; }

        try
        {
            var path = Path.Combine(Root, "settings.json");
            if (File.Exists(path))
            {
                var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(ProfileStore.ReadText(path));
                state.Enabled = data.TryGetValue("Enabled", out var enabled) && enabled is bool flag && flag;
                state.Strategy = data.TryGetValue("Strategy", out var strategy) ? Convert.ToString(strategy) ?? "" : "";
                state.EngineVersion = data.TryGetValue("EngineVersion", out var version) ? Convert.ToString(version) ?? "" : "";
                state.SettingsValid = state.Strategy.Length > 0 && File.Exists(InstalledScript);
                state.ManagerVersion = data.TryGetValue("ManagerVersion", out var managerVersion) ? Convert.ToString(managerVersion) ?? "" : "";
            }
            var scopeFile = Path.Combine(Root, "scope.json");
            if (File.Exists(scopeFile))
            {
                var scope = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(ProfileStore.ReadText(scopeFile));
                if (scope.TryGetValue("VpnExcluded", out var addresses) && addresses is System.Collections.ICollection list)
                    state.ExcludedVpnTargets = list.Count;
            }
            var hostsState = Path.Combine(Root, "hosts-state.json");
            if (File.Exists(hostsState))
            {
                var data = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(ProfileStore.ReadText(hostsState));
                if (data.TryGetValue("CorrectCount", out var count)) state.HostsCorrectCount = Convert.ToInt32(count);
            }
            state.NetworkFingerprint = ProfileStore.NetworkFingerprint();
        }
        catch (IOException) { state.ReadError = "Ayarlar yenileniyor."; }
        catch (UnauthorizedAccessException) { state.ReadError = "Ayarlar okunamadı."; }
        catch (ArgumentException) { state.ReadError = "Ayar dosyası okunamadı; kurulum onarılabilir."; }
        return state;
    }

    public static async Task RunActionAsync(string action, string profileId = "", ProfileCheckSession? check = null)
    {
        if (!new[] { "Start", "Stop", "Refresh", "Setup", "Tune", "TestProfiles", "SelectProfile" }.Contains(action))
            throw new ArgumentException("Desteklenmeyen işlem.", nameof(action));
        var script = action == "Setup" ? Path.Combine(Payload, "Manage-DiscordOnly.ps1") : InstalledScript;
        if (!File.Exists(script)) throw new IOException("Program dosyaları bulunamadı. Setup dosyasını yeniden çalıştır.");
        await Task.Run(() =>
        {
            try
            {
                var parameters = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -Action " + action;
                if (profileId.Length > 0)
                {
                    if (!System.Text.RegularExpressions.Regex.IsMatch(profileId, "^[a-z0-9-]+$")) throw new ArgumentException("Geçersiz profil.");
                    parameters += " -ProfileId " + Quote(profileId);
                }
                if (check != null) parameters += " -OperationId " + check.Id + " -CancelFile " + Quote(check.CancellationFile);
                var info = new ProcessStartInfo(PowerShell)
                {
                    Arguments = parameters,
                    UseShellExecute = true,
                    Verb = "runas",
                    WindowStyle = ProcessWindowStyle.Hidden,
                    WorkingDirectory = Path.GetDirectoryName(script)!
                };
                using var process = Process.Start(info) ?? throw new IOException("Yönetim işlemi başlatılamadı.");
                process.WaitForExit();
                if (process.ExitCode != 0)
                    throw new IOException("İşlem tamamlanamadı. Ayrıntılar bölümündeki günlüğü kontrol et.");
            }
            catch (Win32Exception error) when (error.NativeErrorCode == 1223)
            {
                throw new OperationCanceledException("Yönetici onayı iptal edildi.");
            }
        });
    }

    public static async Task<ProbeItem[]> ProbeAsync()
    {
        var script = File.Exists(InstalledScript) ? InstalledScript : Path.Combine(Payload, "Manage-DiscordOnly.ps1");
        if (!File.Exists(script)) throw new IOException("Bağlantı denetimi dosyası bulunamadı.");
        var info = new ProcessStartInfo(PowerShell)
        {
            Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File " + Quote(script) + " -Action Probe",
            UseShellExecute = false,
            CreateNoWindow = true,
            RedirectStandardOutput = true,
            RedirectStandardError = true,
            StandardOutputEncoding = Encoding.UTF8,
            StandardErrorEncoding = Encoding.UTF8
        };
        using var process = Process.Start(info) ?? throw new IOException("Bağlantı denetimi başlatılamadı.");
        var outputTask = process.StandardOutput.ReadToEndAsync();
        var errorTask = process.StandardError.ReadToEndAsync();
        var exited = await Task.Run(() => process.WaitForExit(75000));
        if (!exited)
        {
            process.Kill();
            await Task.Run(() => process.WaitForExit());
            throw new IOException("Bağlantı denetimi zaman aşımına uğradı.");
        }
        var output = await outputTask;
        await errorTask;
        if (process.ExitCode != 0) throw new IOException("Bağlantı denetimi tamamlanamadı.");
        var results = new JavaScriptSerializer().Deserialize<ProbeItem[]>(output.Trim('\uFEFF', '\r', '\n', ' '));
        if (results == null || results.Length == 0) throw new IOException("Bağlantı denetimi sonuç döndürmedi.");
        return results;
    }

    public static string StrategyName(string strategy)
    {
        var known = ProfileStore.ReadCatalog().Profiles.FirstOrDefault(profile => profile.Id == strategy);
        if (known != null) return known.Name;
        if (strategy.StartsWith("turkey-", StringComparison.Ordinal)) return "Türkiye profili";
        return string.IsNullOrWhiteSpace(strategy) ? "Henüz seçilmedi" : "Uyumlu profil";
    }

    public static void OpenDiscord()
    {
        var launcher = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), @"Discord\Discord.exe");
        if (File.Exists(launcher)) Process.Start(new ProcessStartInfo(launcher) { UseShellExecute = true });
        else Process.Start(new ProcessStartInfo("https://discord.com/app") { UseShellExecute = true });
    }

    public static void OpenLog()
    {
        var log = Path.Combine(Root, @"logs\management.log");
        if (!File.Exists(log)) throw new IOException("Henüz bir günlük oluşturulmadı.");
        Process.Start(new ProcessStartInfo("notepad.exe", Quote(log)) { UseShellExecute = true });
    }

    public static string ReadHostsPreview()
    {
        var installed = Path.Combine(Root, "discord-hosts.txt");
        var path = File.Exists(installed) ? installed : Path.Combine(Payload, "discord-hosts.txt");
        return ProfileStore.ReadText(path).Trim();
    }

    internal static SelfTestResult SelfTest()
    {
        var state = ReadState();
        var verified = new List<string>();
        var manifest = Path.Combine(Payload, "verified-files.json");
        if (File.Exists(manifest))
        {
            var files = new JavaScriptSerializer().Deserialize<PayloadFile[]>(File.ReadAllText(manifest));
            foreach (var entry in files.Where(f => f.Path.StartsWith("runtime/", StringComparison.Ordinal)))
            {
                var file = Path.GetFullPath(Path.Combine(Payload, entry.Path));
                if (!file.StartsWith(Path.GetFullPath(Payload) + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase))
                    throw new IOException("Geçersiz paket yolu.");
                using var sha = SHA256.Create();
                using var stream = File.OpenRead(file);
                var hash = BitConverter.ToString(sha.ComputeHash(stream)).Replace("-", "");
                if (!hash.Equals(entry.SHA256, StringComparison.OrdinalIgnoreCase)) throw new IOException("Paket doğrulaması başarısız: " + entry.Path);
                verified.Add(entry.Path);
            }
        }
        return new SelfTestResult { Passed = state.Installed && state.SettingsValid && state.SupportsProfiles && state.HostsCorrectCount == 11 && verified.Count == 7, State = state, VerifiedFiles = verified.ToArray() };
    }

    private static string Quote(string value) => "\"" + value.Replace("\"", "") + "\"";
}

internal sealed class SelfTestResult
{
    public bool Passed { get; set; }
    public BackendState State { get; set; } = new BackendState();
    public string[] VerifiedFiles { get; set; } = Array.Empty<string>();
}
