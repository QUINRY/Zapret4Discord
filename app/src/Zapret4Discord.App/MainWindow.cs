using System;
using System.Drawing;
using System.Linq;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace Zapret4Discord;

internal sealed class MainForm : Form
{
    private readonly Label stateTitle, stateDescription, stateDot, message;
    private readonly ActionButton toggle, openDiscord, checkAll, useProfile, checkProfile;
    private readonly LinkLabel footer;
    private readonly DataGridView profiles;
    private readonly LinkLabel pingHelp;
    private readonly ToolTip pingToolTip;
    private readonly NotifyIcon tray;
    private readonly ToolStripMenuItem trayStart, trayStop;
    private readonly Timer poll;
    private BackendState snapshot = new BackendState();
    private ProfileCatalog catalog = new ProfileCatalog();
    private ProfileCheckReport report = new ProfileCheckReport();
    private ProfileCheckSession? session;
    private bool busy, refreshing, forceExit, exitWhenIdle;
    private string operation = "";

    private const string GatewayPingHelp =
        "Buradaki Gateway Ping, Discord'un mesajlaşma ve bağlantı\n" +
        "yönetimi için kullandığı ağ geçidine yapılan WebSocket\n" +
        "ölçümüdür. Ses kanalı ayrı bir ses sunucusuna bağlanır;\n" +
        "ses verisi UDP üzerinden taşınır. Discord'daki ses pingi\n" +
        "bu ayrı bağlantıya aittir. Sunucu, bölge ve ağ yolu farklı\n" +
        "olabildiğinden iki değer doğrudan karşılaştırılmaz.\n\n" +
        "Örneğin burada 154 ms, ses kanalında 49 ms görmen normaldir.\n" +
        "Bu, sesinin 154 ms geciktiğini veya profilin ses pingini\n" +
        "yükselttiğini göstermez. Sesli görüşme gecikmesini\n" +
        "değerlendirirken Discord'un ses bağlantısında gösterdiği\n" +
        "değeri esas al.";

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr window, int attribute, ref int value, int length);

    public MainForm()
    {
        Text = "Zapret4Discord";
        AccessibleName = "Zapret4Discord bağlantı yöneticisi";
        Font = Theme.Font(10f);
        BackColor = Theme.Background;
        ForeColor = Theme.Text;
        ClientSize = new Size(582, 702);
        FormBorderStyle = FormBorderStyle.FixedSingle;
        MaximizeBox = false;
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleDimensions = new SizeF(96f, 96f);
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScroll = true;
        DoubleBuffered = true;
        Icon = Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application;

        Controls.Add(new BrandMark { Location = new Point(24, 25), Size = new Size(36, 36), TabStop = false });
        Controls.Add(TextLabel("Zapret4Discord", new Rectangle(73, 18, 380, 30), 18f, Theme.Text, FontStyle.Bold));
        Controls.Add(TextLabel("Discord’a özel bağlantı", new Rectangle(74, 51, 330, 22), 9.5f, Theme.Muted));
        Controls.Add(TextLabel("v1.1.4", new Rectangle(507, 29, 52, 22), 9f, Theme.Muted));

        var card = new Card { Location = new Point(24, 88), Size = new Size(534, 106), AccessibleName = "Bağlantı durumu" };
        stateTitle = TextLabel("Kontrol ediliyor", new Rectangle(18, 14, 477, 39), 24f, Theme.Text, FontStyle.Bold);
        stateDescription = TextLabel("Servis durumu okunuyor.", new Rectangle(20, 64, 492, 27), 9.5f, Theme.Muted);
        stateDot = TextLabel("●", new Rectangle(493, 17, 24, 26), 14f, Theme.Muted);
        card.Controls.AddRange(new Control[] { stateTitle, stateDescription, stateDot });
        Controls.Add(card);

        toggle = new ActionButton { Text = "Hazırlanıyor…", Location = new Point(24, 208), Size = new Size(338, 43), Primary = true, Enabled = false, TabIndex = 0 };
        toggle.Click += async (_, __) => await RunActionAsync(!snapshot.Installed || !snapshot.SettingsValid ? "Setup" : snapshot.Running ? "Stop" : "Start");
        openDiscord = new ActionButton { Text = "Discord’u aç", Location = new Point(374, 208), Size = new Size(184, 43), TabIndex = 1 };
        openDiscord.Click += (_, __) => { try { Backend.OpenDiscord(); } catch (Exception error) { SetMessage(error.Message, Theme.Amber); } };
        Controls.AddRange(new Control[] { toggle, openDiscord });

        Controls.Add(TextLabel("Bağlantı profilleri", new Rectangle(24, 274, 288, 28), 12f, Theme.Text, FontStyle.Bold));
        checkAll = new ActionButton { Text = "Tümünü kontrol et", Location = new Point(386, 270), Size = new Size(172, 33), TabIndex = 2 };
        checkAll.Click += async (_, __) => { if (session != null) CancelCheck(); else await CheckProfilesAsync(""); };
        Controls.Add(checkAll);
        Controls.Add(TextLabel("Yeşil: geçti   ·   Kırmızı: başarısız   ·   Gri: güncel test yok", new Rectangle(24, 309, 534, 21), 8.5f, Theme.Muted));

        profiles = new DataGridView
        {
            Location = new Point(24, 337), Size = new Size(534, 222), ReadOnly = true,
            AllowUserToAddRows = false, AllowUserToDeleteRows = false, AllowUserToResizeRows = false,
            AllowUserToResizeColumns = false, RowHeadersVisible = false, MultiSelect = false,
            SelectionMode = DataGridViewSelectionMode.FullRowSelect, AutoGenerateColumns = false,
            BackgroundColor = Theme.Surface, BorderStyle = BorderStyle.None, GridColor = Theme.Border,
            CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal, EnableHeadersVisualStyles = false,
            ColumnHeadersHeight = 29, ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.DisableResizing,
            RowTemplate = { Height = 29 }, TabIndex = 3, AccessibleName = "Profiller ve gerçek Discord erişim kontrolleri"
        };
        profiles.DefaultCellStyle = new DataGridViewCellStyle { BackColor = Theme.Surface, ForeColor = Theme.Text, SelectionBackColor = Color.FromArgb(43, 53, 74), SelectionForeColor = Theme.Text, Font = Theme.Font(9f), Padding = new Padding(6, 0, 0, 0) };
        profiles.ColumnHeadersDefaultCellStyle = new DataGridViewCellStyle { BackColor = Theme.Surface, ForeColor = Theme.Muted, Font = Theme.Font(8.5f, FontStyle.Bold), Padding = new Padding(6, 0, 0, 0), SelectionBackColor = Theme.Surface };
        profiles.Columns.Add(new DataGridViewTextBoxColumn { Name = "Profile", HeaderText = "PROFİL", AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill, SortMode = DataGridViewColumnSortMode.NotSortable });
        profiles.Columns.Add(new DataGridViewTextBoxColumn { Name = "Check", HeaderText = "ONLINE CHECK", Width = 120, SortMode = DataGridViewColumnSortMode.NotSortable });
        profiles.Columns.Add(new DataGridViewTextBoxColumn { Name = "Ping", HeaderText = "GATEWAY PING", Width = 160, SortMode = DataGridViewColumnSortMode.NotSortable });
        profiles.Columns["Ping"].HeaderCell.Style.Padding = new Padding(6, 0, 30, 0);
        profiles.Columns.Add(new DataGridViewTextBoxColumn { Name = "Time", HeaderText = "SON TEST", Width = 84, SortMode = DataGridViewColumnSortMode.NotSortable });
        profiles.SelectionChanged += (_, __) => RenderSelection();
        Controls.Add(profiles);

        pingHelp = new LinkLabel
        {
            Text = "(?)", Font = Theme.Font(8.5f, FontStyle.Bold), BackColor = Theme.Surface,
            LinkColor = Theme.Accent, ActiveLinkColor = Theme.Text, VisitedLinkColor = Theme.Accent,
            LinkBehavior = LinkBehavior.NeverUnderline, TextAlign = ContentAlignment.MiddleCenter,
            Cursor = Cursors.Help, TabStop = true, TabIndex = 0, AccessibleName = "Gateway Ping açıklaması",
            AccessibleDescription = GatewayPingHelp
        };
        pingToolTip = new ToolTip
        {
            ToolTipTitle = "Gateway Ping ve ses kanalı pingi", InitialDelay = 450,
            ReshowDelay = 100, AutoPopDelay = 30000, ShowAlways = true
        };
        pingToolTip.SetToolTip(pingHelp, GatewayPingHelp);
        pingHelp.LinkClicked += (_, __) => pingToolTip.Show(GatewayPingHelp, pingHelp, 0, pingHelp.Height + 6, 30000);
        pingHelp.MouseLeave += (_, __) => pingToolTip.Hide(pingHelp);
        profiles.Controls.Add(pingHelp);
        profiles.ColumnWidthChanged += (_, __) => PositionPingHelp();
        profiles.SizeChanged += (_, __) => PositionPingHelp();
        profiles.ColumnHeadersHeightChanged += (_, __) => PositionPingHelp();
        profiles.Scroll += (_, __) => PositionPingHelp();

        useProfile = new ActionButton { Text = "Seçili profili kullan", Location = new Point(24, 572), Size = new Size(261, 39), Primary = true, TabIndex = 4 };
        useProfile.Click += async (_, __) => { var profile = SelectedProfile; if (profile != null) await RunActionAsync("SelectProfile", profile.Id); };
        checkProfile = new ActionButton { Text = "Seçili profili kontrol et", Location = new Point(297, 572), Size = new Size(261, 39), TabIndex = 5 };
        checkProfile.Click += async (_, __) => { var profile = SelectedProfile; if (profile != null) await CheckProfilesAsync(profile.Id); };
        Controls.AddRange(new Control[] { useProfile, checkProfile });

        message = TextLabel("Kontrol sonrası Gateway Ping süreleri ms olarak gösterilir. Bitince önceki profil geri yüklenir.", new Rectangle(24, 626, 534, 43), 9f, Theme.Muted);
        Controls.Add(message);
        footer = new LinkLabel { Location = new Point(24, 677), Size = new Size(534, 22), Font = Theme.Font(8.3f), ForeColor = Theme.Muted, LinkColor = Theme.Accent, ActiveLinkColor = Theme.Text, VisitedLinkColor = Theme.Accent, LinkBehavior = LinkBehavior.HoverUnderline, TabIndex = 6 };
        footer.LinkClicked += (_, __) => { using var preview = new HostsPreviewForm(); preview.ShowDialog(this); };
        Controls.Add(footer);

        var menu = new ContextMenuStrip { BackColor = Theme.Surface, ForeColor = Theme.Text, Renderer = new ToolStripProfessionalRenderer(new DarkMenuColors()) };
        menu.Items.Add("Pencereyi aç", null, (_, __) => RestoreWindow());
        menu.Items.Add(new ToolStripSeparator());
        trayStart = new ToolStripMenuItem("Başlat");
        trayStart.Click += async (_, __) => await RunActionAsync(!snapshot.Installed || !snapshot.SettingsValid ? "Setup" : "Start");
        trayStop = new ToolStripMenuItem("Durdur");
        trayStop.Click += async (_, __) => await RunActionAsync("Stop");
        menu.Items.Add(trayStart);
        menu.Items.Add(trayStop);
        menu.Items.Add("Discord’u aç", null, (_, __) => openDiscord.PerformClick());
        menu.Items.Add("Günlüğü aç", null, (_, __) => { try { Backend.OpenLog(); } catch (Exception error) { SetMessage(error.Message, Theme.Amber); RestoreWindow(); } });
        menu.Items.Add("Kurulumu onar", null, async (_, __) => await RunActionAsync("Setup"));
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(new ToolStripMenuItem("Çıkış", null, (_, __) => RequestExit()) { ToolTipText = "Arayüzü kapatır. Erişimi kapatmak için önce Durdur’u seç." });
        tray = new NotifyIcon { Icon = Icon, Text = "Zapret4Discord", ContextMenuStrip = menu, Visible = true };
        tray.DoubleClick += (_, __) => RestoreWindow();
        Resize += (_, __) => { if (WindowState == FormWindowState.Minimized) Hide(); };
        FormClosing += (_, e) =>
        {
            if (!forceExit && e.CloseReason == CloseReason.UserClosing) { e.Cancel = true; Hide(); }
            else { session?.Cancel(); tray.Visible = false; }
        };
        poll = new Timer { Interval = 2000 };
        poll.Tick += async (_, __) => await RefreshStateAsync();
        Shown += async (_, __) =>
        {
            var workArea = Screen.FromControl(this).WorkingArea;
            if (Height > workArea.Height - 32) { Height = workArea.Height - 32; Top = workArea.Top + 16; }
            PositionPingHelp();
            poll.Start();
            await RefreshStateAsync();
        };
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        var dark = 1;
        try { DwmSetWindowAttribute(Handle, 20, ref dark, sizeof(int)); } catch (DllNotFoundException) { }
    }
    protected override void WndProc(ref Message m)
    {
        if (m.Msg == 0x8001) { RestoreWindow(); return; }
        if (m.Msg == 0x8002) { RequestExit(); return; }
        base.WndProc(ref m);
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { poll?.Dispose(); pingToolTip?.Dispose(); if (tray != null) { tray.Visible = false; tray.Dispose(); } }
        base.Dispose(disposing);
    }
    private static Label TextLabel(string text, Rectangle bounds, float size, Color color, FontStyle style = FontStyle.Regular) => new Label
    { Text = text, Bounds = bounds, Font = Theme.Font(size, style), ForeColor = color, BackColor = Color.Transparent, AutoSize = false, UseMnemonic = false };

    private void PositionPingHelp()
    {
        if (pingHelp == null) return;
        var header = profiles.GetCellDisplayRectangle(profiles.Columns["Ping"].Index, -1, true);
        var scale = profiles.DeviceDpi / 96f;
        var width = (int)Math.Ceiling(24 * scale);
        var inset = (int)Math.Ceiling(3 * scale);
        pingHelp.Visible = header.Width > width;
        if (!pingHelp.Visible) return;
        pingHelp.Bounds = new Rectangle(header.Right - width - inset, header.Top + inset, width, header.Height - inset * 2);
        pingHelp.BringToFront();
    }

    private ConnectionProfile? SelectedProfile => profiles.CurrentRow?.Tag as ConnectionProfile;
    private async Task RefreshStateAsync()
    {
        if (refreshing || IsDisposed) return;
        refreshing = true;
        try
        {
            var data = await Task.Run(() => new { State = Backend.ReadState(), Catalog = ProfileStore.ReadCatalog(), Report = ProfileStore.ReadReport() });
            if (IsDisposed) return;
            snapshot = data.State;
            report = data.Report;
            if (catalog.Revision != data.Catalog.Revision || profiles.Rows.Count != data.Catalog.Profiles.Length)
            {
                var selected = SelectedProfile?.Id ?? snapshot.Strategy;
                catalog = data.Catalog;
                profiles.Rows.Clear();
                foreach (var profile in catalog.Profiles) { var row = profiles.Rows[profiles.Rows.Add(profile.Name, "○ Kontrol edilmedi", "—", "—")]; row.Tag = profile; }
                var match = profiles.Rows.Cast<DataGridViewRow>().FirstOrDefault(row => ((ConnectionProfile)row.Tag).Id == selected);
                if (match != null) profiles.CurrentCell = match.Cells[0];
            }
            FinishOrRender();
        }
        catch (Exception error) { if (!IsDisposed) SetMessage("Durum okunamadı: " + error.Message, Theme.Amber); }
        finally { refreshing = false; }
    }

    private bool Checking => session != null || report.ScanState == "testing";
    private void RenderState()
    {
        var working = busy || Checking || snapshot.Transitioning;
        stateTitle.Text = Checking ? "Profil kontrolü" : busy ? "İşlem sürüyor" : snapshot.Running ? "Açık" : !snapshot.SettingsValid ? "Hazır değil" : "Kapalı";
        stateDescription.Text = Checking ? "Kontrol: " + report.CompletedCount + "/" + report.TotalCount + " · Önceki profil sonra geri yüklenir." : busy ? operation : snapshot.Running ? "Etkin profil: " + Backend.StrategyName(snapshot.Strategy) : snapshot.ReadError ?? "Discord erişimini açmak için başlat.";
        stateDot.ForeColor = working ? Theme.Accent : snapshot.Running ? Theme.Green : Theme.Muted;
        stateTitle.AccessibleName = "Servis durumu: " + stateTitle.Text;
        toggle.Text = busy ? "Lütfen bekle…" : !snapshot.SettingsValid ? "Kurulumu tamamla" : snapshot.Running ? "Bağlantıyı durdur" : "Discord erişimini aç";
        toggle.Enabled = !working;
        openDiscord.Enabled = !busy;
        trayStart.Enabled = !working && !snapshot.Running;
        trayStop.Enabled = !working && snapshot.Running;
        checkAll.Text = session != null ? "Kontrolü iptal et" : "Tümünü kontrol et";
        checkAll.Enabled = session != null || (!working && snapshot.SupportsProfiles);
        var hostsText = "Hosts: " + snapshot.HostsCorrectCount + "/11";
        var footerText = hostsText + "  ·  VPN hedefleri hariç  ·  Açılışta: " + (snapshot.Enabled ? "etkin" : "kapalı");
        if (footer.Text != footerText) { footer.Text = footerText; footer.LinkArea = new LinkArea(0, hostsText.Length); }
        tray.Text = Checking ? "Zapret4Discord — profil kontrolü" : snapshot.Running ? "Zapret4Discord — açık" : "Zapret4Discord — kapalı";
        foreach (DataGridViewRow row in profiles.Rows)
        {
            var profile = (ConnectionProfile)row.Tag;
            var result = report.Results.FirstOrDefault(item => item.ProfileId == profile.Id);
            var testing = report.ScanState == "testing" && report.CurrentProfileId == profile.Id;
            var fresh = result != null && result.IsFresh(snapshot.NetworkFingerprint, catalog.Revision, DateTimeOffset.UtcNow);
            var text = testing ? "◌ Test ediliyor" : fresh ? result!.Passed ? "● Çalışıyor" : "● Başarısız" : result == null ? "○ Test yok" : "○ Yenile";
            var color = testing ? Theme.Accent : fresh ? result!.Passed ? Theme.Green : Theme.Red : Theme.Muted;
            row.Cells[0].Value = profile.Name + (profile.Id == snapshot.Strategy ? " ✓" : "");
            row.Cells[0].ToolTipText = profile.ProviderHint + "\n" + profile.Description;
            row.Cells[1].Value = text;
            row.Cells[1].Style.ForeColor = row.Cells[1].Style.SelectionForeColor = color;
            row.Cells[1].ToolTipText = result == null ? "Bu bağlantıda henüz kontrol edilmedi." : (fresh ? "" : "Sonuç güncel değil. ") + result.State + " · " + (result.DurationMs / 1000.0).ToString("0.0") + " sn toplam test\n" + result.Error;
            var hasPing = fresh && result!.HasPing;
            row.Cells[2].Value = testing ? "…" : hasPing ? result!.PingMs!.Value.ToString("0.#") + " ms" : "—";
            row.Cells[2].Style.ForeColor = row.Cells[2].Style.SelectionForeColor = hasPing && !testing ? Theme.Text : Theme.Muted;
            row.Cells[2].ToolTipText = hasPing
                ? "Discord ağ geçidinin WebSocket gecikmesi; ses kanalı pingi değildir. Üç ölçümün ortanca değeri.\nÖlçümler: " + string.Join(", ", result!.PingSamplesMs.Select(value => value.ToString("0.#"))) + " ms"
                : !fresh ? "Güncel ping için profili kontrol et." : "Ping ölçümü alınamadı. " + result!.PingError;
            row.Cells[3].Value = result?.LocalTime ?? "—";
        }
        RenderSelection();
    }
    private void RenderSelection()
    {
        if (useProfile == null) return;
        var profile = SelectedProfile;
        useProfile.Enabled = checkProfile.Enabled = profile != null && !busy && !Checking && !snapshot.Transitioning && snapshot.SupportsProfiles;
    }
    private async Task RunActionAsync(string action, string profileId = "")
    {
        if (busy || Checking) return;
        busy = true;
        operation = action == "Stop" ? "Discord servisi durduruluyor." : action == "SelectProfile" ? "Seçtiğin profil etkinleştiriliyor." : "Discord servisi hazırlanıyor.";
        SetMessage("Windows yönetici onayı isteyebilir.", Theme.Muted);
        RenderState();
        try
        {
            await Backend.RunActionAsync(action, profileId);
            SetMessage(action == "Stop" ? "Durduruldu. Başlatana kadar kapalı kalır." : action == "SelectProfile" ? "Seçili profil etkin. Erişimi doğrulamak için kontrol edebilirsin." : "Hazır. Discord’u açabilirsin.", Theme.Green);
        }
        catch (Exception error) { SetMessage(error.Message, Theme.Amber); }
        finally { busy = false; await RefreshStateAsync(); FinishOrRender(); }
    }
    private async Task CheckProfilesAsync(string profileId)
    {
        if (busy || Checking) return;
        busy = true;
        session = new ProfileCheckSession();
        report = new ProfileCheckReport { OperationId = session.Id, ScanState = "starting", TotalCount = profileId.Length == 0 ? catalog.Profiles.Length : 1, Results = report.Results };
        SetMessage("Discord erişimi ve Gateway Ping ölçülüyor. Test sırasında bağlantı kısa süreli kesilebilir.", Theme.Muted);
        RenderState();
        try
        {
            await Backend.RunActionAsync("TestProfiles", profileId, session);
            report = ProfileStore.ReadReport();
            if (report.OperationId != session.Id) throw new InvalidOperationException("Kontrol sonucu bulunamadı.");
            var results = report.Results.Where(item => profileId.Length == 0 || item.ProfileId == profileId).ToArray();
            SetMessage(report.ScanState == "cancelled" ? "Kontrol iptal edildi. Önceki profil ve servis durumu geri yüklendi." : report.Restored && report.ScanState == "completed" ? results.Count(item => item.IsFresh(snapshot.NetworkFingerprint, catalog.Revision, DateTimeOffset.UtcNow) && item.Passed) + "/" + report.TotalCount + " profil geçti. Önceki seçim geri yüklendi; istediğin profili seçebilirsin." : "Kontrol tamamlanamadı. " + report.Error, report.Restored && report.ScanState == "completed" ? Theme.Green : Theme.Amber);
        }
        catch (Exception error) { SetMessage(error.Message, Theme.Amber); }
        finally { session.Dispose(); session = null; busy = false; await RefreshStateAsync(); FinishOrRender(); }
    }
    private void CancelCheck()
    {
        try { session?.Cancel(); SetMessage("İptal ediliyor. Sürmekte olan kontrol bitince önceki profil geri yüklenecek.", Theme.Amber); }
        catch (Exception error) { SetMessage(error.Message, Theme.Amber); }
    }
    private void RequestExit()
    {
        if (busy || session != null) { exitWhenIdle = true; CancelCheck(); SetMessage("İşlem tamamlanıp bağlantı geri yüklendikten sonra program kapanacak.", Theme.Amber); return; }
        forceExit = true;
        Close();
    }
    private void FinishOrRender() { if (IsDisposed) return; if (exitWhenIdle && !Checking) RequestExit(); else RenderState(); }
    private void SetMessage(string text, Color color) { if (IsDisposed) return; message.Text = text; message.ForeColor = color; message.AccessibleName = "İşlem sonucu: " + text; }
    private void RestoreWindow() { Show(); WindowState = FormWindowState.Normal; Activate(); }
}

internal sealed class DarkMenuColors : ProfessionalColorTable
{
    public override Color ToolStripDropDownBackground => Theme.Surface;
    public override Color ImageMarginGradientBegin => Theme.Surface;
    public override Color ImageMarginGradientMiddle => Theme.Surface;
    public override Color ImageMarginGradientEnd => Theme.Surface;
    public override Color MenuBorder => Theme.Border;
    public override Color MenuItemBorder => Theme.Border;
    public override Color MenuItemSelected => Color.FromArgb(45, 54, 72);
}
