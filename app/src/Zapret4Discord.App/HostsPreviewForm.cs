using System;
using System.Drawing;
using System.IO;
using System.Windows.Forms;

namespace Zapret4Discord;

internal sealed class HostsPreviewForm : Form
{
    public HostsPreviewForm()
    {
        Text = "Discord hosts kayıtları";
        AccessibleName = "Discord hosts kayıtlarının önizlemesi";
        BackColor = Theme.Background;
        ForeColor = Theme.Text;
        Font = Theme.Font(10f);
        ClientSize = new Size(532, 466);
        FormBorderStyle = FormBorderStyle.FixedDialog;
        MaximizeBox = false;
        MinimizeBox = false;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.CenterParent;
        AutoScaleDimensions = new SizeF(96f, 96f);
        AutoScaleMode = AutoScaleMode.Dpi;

        Controls.Add(new Label { Text = "Discord hosts kayıtları", Location = new Point(24, 20), Size = new Size(484, 34), Font = Theme.Font(17f, FontStyle.Bold), ForeColor = Theme.Text });
        Controls.Add(new Label
        {
            Text = "Bu 11 kayıt, Discord alan adlarını aşağıdaki IP adresleriyle eşler. Windows bu adları çözerken bu eşlemelerden yararlanır; Discord bağlantıları belirtilen adreslere yönelir.",
            Location = new Point(24, 67), Size = new Size(484, 69), ForeColor = Theme.Muted, Font = Theme.Font(9.5f)
        });
        var list = new TextBox
        {
            Location = new Point(24, 148), Size = new Size(484, 204), Multiline = true, ReadOnly = true,
            WordWrap = false, ScrollBars = ScrollBars.Both, BorderStyle = BorderStyle.FixedSingle,
            BackColor = Theme.Surface, ForeColor = Theme.Text, Font = new Font("Consolas", 10f),
            AccessibleName = "Programın doğruladığı 11 hosts eşlemesi", TabIndex = 0
        };
        try { list.Text = Backend.ReadHostsPreview().Replace("\r\n", "\n").Replace("\n", "\r\n"); }
        catch (IOException) { list.Text = "Kayıt listesi okunamadı. Tepsi menüsünden kurulumu onarabilirsin."; }
        catch (UnauthorizedAccessException) { list.Text = "Kayıt listesi okunamadı. Tepsi menüsünden kurulumu onarabilirsin."; }
        list.Select(0, 0);
        Controls.Add(list);
        Controls.Add(new Label
        {
            Text = "Program bu kayıtları kurulumda ve başlatırken doğrular, eksikleri ekler. DNS sunucuları ve diğer hosts kayıtları korunur. Bu pencere yalnızca önizlemedir; dosyayı değiştirmez.",
            Location = new Point(24, 365), Size = new Size(484, 53), ForeColor = Theme.Muted, Font = Theme.Font(9f)
        });
        var close = new ActionButton { Text = "Kapat", Location = new Point(376, 424), Size = new Size(132, 33), DialogResult = DialogResult.OK, TabIndex = 1 };
        Controls.Add(close);
        AcceptButton = close;
        CancelButton = close;
    }
}
