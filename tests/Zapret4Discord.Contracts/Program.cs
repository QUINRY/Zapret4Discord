using System;
using System.Linq;
using System.Reflection;
using System.Windows.Forms;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        var assembly = Assembly.Load("Zapret4Discord");
        if (args.Contains("--fingerprint"))
        {
            Console.WriteLine(assembly.GetType("Zapret4Discord.ProfileStore", true)!.GetMethod("NetworkFingerprint")!.Invoke(null, null));
            return 0;
        }
        var type = assembly.GetType("Zapret4Discord.MainForm", true)!;
        var failed = 0;
        var resultType = assembly.GetType("Zapret4Discord.ProfileCheckResult", true)!;
        var result = Activator.CreateInstance(resultType, true)!;
        void Set(string key, object value) => resultType.GetProperty(key)!.SetValue(result, value);
        var now = DateTimeOffset.UtcNow;
        bool Fresh(string network = "network-a", string revision = "revision-a") => (bool)resultType.GetMethod("IsFresh")!.Invoke(result, new object[] { network, revision, now })!;
        Set("State", "passed"); Set("Passed", true); Set("CheckedUtc", now.ToString("o"));
        Set("NetworkFingerprint", "network-a"); Set("CatalogRevision", "revision-a");
        Check(Fresh(), "A recent successful check on this network can be green", ref failed);
        Check(!Fresh("network-b"), "Changing the network invalidates prior green results", ref failed);
        Check(!Fresh("network-a", "revision-b"), "Changing the profile recipe invalidates prior results", ref failed);
        Set("CheckedUtc", now.AddMinutes(-16).ToString("o"));
        Check(!Fresh(), "Expired results cannot stay green or red", ref failed);
        Set("CheckedUtc", now.ToString("o")); Set("State", "cancelled");
        Check(!Fresh(), "Cancelled checks cannot be treated as a measured failure", ref failed);
        Set("State", "failed"); Set("Passed", false);
        Check(Fresh(), "A recent measured failure can be red", ref failed);
        using var form = (Form)Activator.CreateInstance(type, true)!;
        form.ShowInTaskbar = false;
        form.Opacity = 0;
        form.Show();
        Application.DoEvents();
        var icon = (NotifyIcon)type.GetField("tray", BindingFlags.NonPublic | BindingFlags.Instance)!.GetValue(form)!;
        form.Close();
        Application.DoEvents();
        Check(!form.IsDisposed && !form.Visible && icon.Visible, "X hides the window and preserves its tray icon", ref failed);
        if (!form.IsDisposed)
        {
            var labels = icon.ContextMenuStrip.Items.OfType<ToolStripMenuItem>().Select(item => item.Text.Replace("&", "")).ToArray();
            Check(labels.Contains("Başlat") && labels.Contains("Durdur") && labels.Contains("Çıkış"), "Tray exposes separate Start, Stop and Exit actions", ref failed);
            icon.ContextMenuStrip.Items.OfType<ToolStripMenuItem>().First(item => item.Text.Contains("Pencereyi aç")).PerformClick();
            Application.DoEvents();
            Check(form.Visible && !form.IsDisposed, "Tray Open restores the hidden window", ref failed);
            var exit = icon.ContextMenuStrip.Items.OfType<ToolStripMenuItem>().FirstOrDefault(item => item.Text == "Çıkış");
            if (exit != null)
            {
                exit.PerformClick();
                Application.DoEvents();
                Check(form.IsDisposed && !icon.Visible, "Tray Exit disposes the window and icon", ref failed);
            }
        }
        Console.WriteLine(failed == 0 ? "ALL UI AND FRESHNESS CONTRACTS PASSED" : $"{failed} CONTRACT(S) FAILED");
        return failed == 0 ? 0 : 1;
    }

    private static void Check(bool condition, string name, ref int failed)
    {
        Console.WriteLine((condition ? "PASS " : "FAIL ") + name);
        if (!condition) failed++;
    }
}
