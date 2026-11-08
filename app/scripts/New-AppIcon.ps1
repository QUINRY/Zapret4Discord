# Generate the application's geometric icon at native Windows icon sizes.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$workspace = Split-Path -Parent $PSScriptRoot
$assets = Join-Path $workspace 'assets'
New-Item -ItemType Directory -Path $assets -Force | Out-Null
$images = foreach ($size in @(16,24,32,48,64,128,256)) {
    $bitmap = [Drawing.Bitmap]::new($size, $size)
    $graphics = [Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([Drawing.Color]::FromArgb(20,23,31))
    $margin = [single]($size * 0.12)
    $accent = [Drawing.SolidBrush]::new([Drawing.Color]::FromArgb(135,165,255))
    $graphics.FillEllipse($accent, $margin, $margin, $size - 2 * $margin, $size - 2 * $margin)
    $pen = [Drawing.Pen]::new([Drawing.Color]::FromArgb(20,23,31), [single]($size * 0.085))
    $pen.StartCap = [Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [Drawing.Drawing2D.LineCap]::Round
    $points = [Drawing.PointF[]]@([Drawing.PointF]::new($size * 0.36,$size * 0.34),[Drawing.PointF]::new($size * 0.64,$size * 0.34),[Drawing.PointF]::new($size * 0.36,$size * 0.66),[Drawing.PointF]::new($size * 0.64,$size * 0.66))
    $graphics.DrawLines($pen, $points)
    $stream = [IO.MemoryStream]::new()
    $bitmap.Save($stream, [Drawing.Imaging.ImageFormat]::Png)
    $bytes = $stream.ToArray()
    $stream.Dispose(); $pen.Dispose(); $accent.Dispose(); $graphics.Dispose(); $bitmap.Dispose()
    [pscustomobject]@{Size=$size;Bytes=$bytes}
}
$file = [IO.File]::Create((Join-Path $assets 'app.ico'))
$writer = [IO.BinaryWriter]::new($file)
try {
    $writer.Write([uint16]0); $writer.Write([uint16]1); $writer.Write([uint16]$images.Count)
    $offset = [uint32](6 + 16 * $images.Count)
    foreach ($entry in $images) {
        $dimension = if ($entry.Size -eq 256) { 0 } else { $entry.Size }
        $writer.Write([byte]$dimension); $writer.Write([byte]$dimension); $writer.Write([byte]0); $writer.Write([byte]0)
        $writer.Write([uint16]1); $writer.Write([uint16]32); $writer.Write([uint32]$entry.Bytes.Length); $writer.Write($offset)
        $offset += $entry.Bytes.Length
    }
    foreach ($entry in $images) { $writer.Write([byte[]]$entry.Bytes) }
} finally { $writer.Dispose(); $file.Dispose() }
