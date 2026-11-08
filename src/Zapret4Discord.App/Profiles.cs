using System;
using System.Collections.Generic;
using System.Globalization;
using System.IO;
using System.Linq;
using System.Net.NetworkInformation;
using System.Security.Cryptography;
using System.Text;
using System.Web.Script.Serialization;

namespace Zapret4Discord;

internal sealed class ConnectionProfile
{
    public string Id { get; set; } = "";
    public string Name { get; set; } = "";
    public string ProviderHint { get; set; } = "";
    public string Description { get; set; } = "";
}

internal sealed class ProfileCatalog
{
    public int SchemaVersion { get; set; }
    public string Revision { get; set; } = "";
    public ConnectionProfile[] Profiles { get; set; } = Array.Empty<ConnectionProfile>();
}

internal sealed class ProfileCheckResult
{
    public string ProfileId { get; set; } = "";
    public string State { get; set; } = "";
    public bool Passed { get; set; }
    public string CheckedUtc { get; set; } = "";
    public string NetworkFingerprint { get; set; } = "";
    public string CatalogRevision { get; set; } = "";
    public long DurationMs { get; set; }
    public double? PingMs { get; set; }
    public double[] PingSamplesMs { get; set; } = Array.Empty<double>();
    public string PingError { get; set; } = "";
    public bool HasPing => PingMs.HasValue && PingMs.Value > 0 && !double.IsNaN(PingMs.Value) && !double.IsInfinity(PingMs.Value);
    public string Error { get; set; } = "";

    public bool IsFresh(string fingerprint, string revision, DateTimeOffset now)
    {
        if (State != "passed" && State != "failed") return false;
        if (fingerprint.Length == 0 || fingerprint != NetworkFingerprint || revision != CatalogRevision) return false;
        if (!DateTimeOffset.TryParse(CheckedUtc, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var checkedAt)) return false;
        var age = now - checkedAt;
        return age >= TimeSpan.FromSeconds(-5) && age <= TimeSpan.FromMinutes(15);
    }

    public string LocalTime => DateTimeOffset.TryParse(CheckedUtc, CultureInfo.InvariantCulture, DateTimeStyles.AssumeUniversal, out var time) ? time.ToLocalTime().ToString("HH:mm:ss") : "—";
}

internal sealed class ProfileCheckReport
{
    public int SchemaVersion { get; set; }
    public string OperationId { get; set; } = "";
    public string ScanState { get; set; } = "idle";
    public string CurrentProfileId { get; set; } = "";
    public int TotalCount { get; set; }
    public int CompletedCount { get; set; }
    public bool Restored { get; set; }
    public string Error { get; set; } = "";
    public ProfileCheckResult[] Results { get; set; } = Array.Empty<ProfileCheckResult>();
}

internal sealed class ProfileCheckSession : IDisposable
{
    public string Id { get; } = Guid.NewGuid().ToString("N");
    public string CancellationFile { get; }
    public ProfileCheckSession()
    {
        var directory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Zapret4Discord", "operations");
        Directory.CreateDirectory(directory);
        CancellationFile = Path.Combine(directory, "cancel-" + Id + ".txt");
    }
    public void Cancel() => File.WriteAllText(CancellationFile, "cancel", new UTF8Encoding(false));
    public void Dispose() { try { if (File.Exists(CancellationFile)) File.Delete(CancellationFile); } catch (IOException) { } catch (UnauthorizedAccessException) { } }
}

internal static class ProfileStore
{
    public static ProfileCatalog ReadCatalog()
    {
        foreach (var path in new[] { Path.Combine(Backend.Root, "profiles.json"), Path.Combine(Backend.Payload, "profiles.json") })
        {
            try
            {
                if (!File.Exists(path)) continue;
                var catalog = new JavaScriptSerializer().Deserialize<ProfileCatalog>(ReadText(path));
                if (catalog.SchemaVersion == 1 && catalog.Profiles.Length > 0) return catalog;
            }
            catch (IOException) { }
            catch (ArgumentException) { }
        }
        return new ProfileCatalog();
    }

    public static ProfileCheckReport ReadReport()
    {
        try
        {
            var path = Path.Combine(Backend.Root, "profile-checks.json");
            if (File.Exists(path)) return new JavaScriptSerializer().Deserialize<ProfileCheckReport>(ReadText(path)) ?? new ProfileCheckReport();
        }
        catch (IOException) { }
        catch (ArgumentException) { }
        return new ProfileCheckReport();
    }

    public static string ReadText(string path)
    {
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
        using var reader = new StreamReader(stream, Encoding.UTF8, true);
        return reader.ReadToEnd();
    }

    public static string NetworkFingerprint()
    {
        var lines = new List<string>();
        foreach (var nic in NetworkInterface.GetAllNetworkInterfaces())
        {
            if (nic.OperationalStatus != OperationalStatus.Up) continue;
            try
            {
                var properties = nic.GetIPProperties();
                var unicast = properties.UnicastAddresses.Select(address => address.Address.ToString().ToLowerInvariant()).OrderBy(text => text, StringComparer.Ordinal);
                var gateways = properties.GatewayAddresses.Select(address => address.Address.ToString().ToLowerInvariant()).OrderBy(text => text, StringComparer.Ordinal);
                var dns = properties.DnsAddresses.Select(address => address.ToString().ToLowerInvariant()).OrderBy(text => text, StringComparer.Ordinal);
                lines.Add(nic.Id.ToLowerInvariant() + ";" + string.Join(",", unicast) + ";" + string.Join(",", gateways) + ";" + string.Join(",", dns));
            }
            catch (NetworkInformationException) { }
        }
        var hosts = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.Windows), @"System32\drivers\etc\hosts");
        lines.Add("hosts;" + File.GetLastWriteTimeUtc(hosts).Ticks.ToString(CultureInfo.InvariantCulture));
        lines.Sort(StringComparer.Ordinal);
        using var hash = SHA256.Create();
        return BitConverter.ToString(hash.ComputeHash(Encoding.UTF8.GetBytes(string.Join("\n", lines)))).Replace("-", "").ToLowerInvariant();
    }
}
