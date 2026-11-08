using System;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace Zapret4Discord;

internal static class Program
{
    internal const string AppMutex = @"Local\Zapret4Discord.UI";
    private const int RestoreMessage = 0x8001;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr FindWindow(string? className, string windowName);
    [DllImport("user32.dll")]
    private static extern bool PostMessage(IntPtr window, int message, IntPtr wParam, IntPtr lParam);

    [STAThread]
    private static int Main(string[] args)
    {
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);
        if (args.Contains("--exit-for-update"))
        {
            var window = FindWindow(null, "Zapret4Discord");
            if (window != IntPtr.Zero) PostMessage(window, 0x8002, IntPtr.Zero, IntPtr.Zero);
            return 0;
        }
        if (args.Contains("--self-test"))
        {
            try
            {
                var result = Backend.SelfTest();
                Console.WriteLine(new JavaScriptSerializer().Serialize(result));
                return result.Passed ? 0 : 1;
            }
            catch (Exception error)
            {
                Console.WriteLine(new JavaScriptSerializer().Serialize(new { Passed = false, Error = error.Message }));
                return 1;
            }
        }

        using var mutex = new Mutex(true, AppMutex, out var firstInstance);
        if (!firstInstance)
        {
            var window = FindWindow(null, "Zapret4Discord");
            if (window != IntPtr.Zero) PostMessage(window, RestoreMessage, IntPtr.Zero, IntPtr.Zero);
            return 0;
        }

        Application.ThreadException += (_, e) => MessageBox.Show(e.Exception.Message, "Zapret4Discord", MessageBoxButtons.OK, MessageBoxIcon.Error);
        Application.Run(new MainForm());
        return 0;
    }
}
