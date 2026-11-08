using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

namespace Zapret4Discord;

internal static class Theme
{
    public static readonly Color Background = Color.FromArgb(18, 21, 28);
    public static readonly Color Surface = Color.FromArgb(27, 32, 42);
    public static readonly Color Border = Color.FromArgb(47, 55, 70);
    public static readonly Color Text = Color.FromArgb(239, 243, 250);
    public static readonly Color Muted = Color.FromArgb(164, 175, 194);
    public static readonly Color Accent = Color.FromArgb(145, 173, 255);
    public static readonly Color Green = Color.FromArgb(124, 221, 180);
    public static readonly Color Red = Color.FromArgb(244, 127, 139);
    public static readonly Color Amber = Color.FromArgb(244, 193, 118);
    public static Font Font(float size, FontStyle style = FontStyle.Regular) => new Font("Segoe UI", size, style, GraphicsUnit.Point);

    public static GraphicsPath Round(RectangleF rect, float radius)
    {
        var path = new GraphicsPath();
        var d = radius * 2;
        path.AddArc(rect.X, rect.Y, d, d, 180, 90);
        path.AddArc(rect.Right - d, rect.Y, d, d, 270, 90);
        path.AddArc(rect.Right - d, rect.Bottom - d, d, d, 0, 90);
        path.AddArc(rect.X, rect.Bottom - d, d, d, 90, 90);
        path.CloseFigure();
        return path;
    }
}

internal sealed class Card : Panel
{
    public Card()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
        BackColor = Theme.Surface;
        Padding = new Padding(20);
    }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.Clear(Parent?.BackColor ?? Theme.Background);
        using var path = Theme.Round(new RectangleF(0.5f, 0.5f, Width - 1f, Height - 1f), 14f * DeviceDpi / 96f);
        using var brush = new SolidBrush(Theme.Surface);
        using var pen = new Pen(Theme.Border);
        e.Graphics.FillPath(brush, path);
        e.Graphics.DrawPath(pen, path);
        base.OnPaint(e);
    }
}

internal sealed class ActionButton : Button
{
    public bool Primary { get; set; }
    private bool hover;
    public ActionButton()
    {
        FlatStyle = FlatStyle.Flat;
        FlatAppearance.BorderSize = 0;
        Font = Theme.Font(10f, FontStyle.Bold);
        Cursor = Cursors.Hand;
        UseVisualStyleBackColor = false;
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
    }
    protected override void OnMouseEnter(EventArgs e) { hover = true; Invalidate(); base.OnMouseEnter(e); }
    protected override void OnMouseLeave(EventArgs e) { hover = false; Invalidate(); base.OnMouseLeave(e); }
    protected override void OnEnabledChanged(EventArgs e) { Invalidate(); base.OnEnabledChanged(e); }
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        e.Graphics.Clear(Parent?.BackColor ?? Theme.Background);
        var fill = Primary ? Theme.Accent : Theme.Surface;
        if (!Enabled) fill = Color.FromArgb(42, 49, 63);
        else if (hover) fill = ControlPaint.Light(fill, Primary ? 0.12f : 0.08f);
        using var path = Theme.Round(new RectangleF(0.5f, 0.5f, Width - 1f, Height - 1f), 9f * DeviceDpi / 96f);
        using var brush = new SolidBrush(fill);
        using var pen = new Pen(Primary ? fill : Theme.Border);
        e.Graphics.FillPath(brush, path);
        e.Graphics.DrawPath(pen, path);
        var foreground = !Enabled ? Theme.Muted : Primary ? Theme.Background : Theme.Text;
        TextRenderer.DrawText(e.Graphics, Text, Font, ClientRectangle, foreground, TextFormatFlags.HorizontalCenter | TextFormatFlags.VerticalCenter | TextFormatFlags.SingleLine);
        if (Focused && ShowFocusCues)
        {
            var focus = Rectangle.Inflate(ClientRectangle, -5, -5);
            ControlPaint.DrawFocusRectangle(e.Graphics, focus, foreground, fill);
        }
    }
}

internal sealed class BrandMark : Control
{
    public BrandMark() => SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer | ControlStyles.UserPaint, true);
    protected override void OnPaint(PaintEventArgs e)
    {
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var fill = new SolidBrush(Theme.Accent);
        e.Graphics.FillEllipse(fill, 1, 1, Width - 2, Height - 2);
        using var pen = new Pen(Theme.Background, Width * 0.09f) { StartCap = LineCap.Round, EndCap = LineCap.Round, LineJoin = LineJoin.Round };
        e.Graphics.DrawLines(pen, new[] { new PointF(Width * .32f, Height * .30f), new PointF(Width * .68f, Height * .30f), new PointF(Width * .32f, Height * .70f), new PointF(Width * .68f, Height * .70f) });
    }
}
