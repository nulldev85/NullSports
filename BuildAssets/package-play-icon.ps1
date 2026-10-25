# Package the approved raster artwork at the asset catalog's exact sizes.
# No symbol is redrawn here. Apple supplies each icon's outer corner mask.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$repoRoot = Split-Path -Parent $PSScriptRoot
$masters = Join-Path $PSScriptRoot 'PlayIcon'
$phone = Join-Path $repoRoot 'iPhone/Assets.xcassets/LineupAppIcon.appiconset'
$television = Join-Path $repoRoot 'Lineup/Assets.xcassets/Lineup App Icon & Top Shelf Image.brandassets'

function New-Canvas([int]$Width, [int]$Height, [bool]$Opaque) {
    $format = if ($Opaque) { [Drawing.Imaging.PixelFormat]::Format24bppRgb } else { [Drawing.Imaging.PixelFormat]::Format32bppArgb }
    return [Drawing.Bitmap]::new($Width, $Height, $format)
}

function New-Graphics([Drawing.Bitmap]$Canvas) {
    $graphics = [Drawing.Graphics]::FromImage($Canvas)
    $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
    $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    return $graphics
}

function Save-Canvas([Drawing.Bitmap]$Canvas, [string]$Path) {
    $Canvas.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
    Write-Output ("{0}x{1} {2}" -f $Canvas.Width, $Canvas.Height, $Path.Substring($repoRoot.Length + 1))
}

function Write-Phone([Drawing.Image]$Image, [string]$Name) {
    $canvas = New-Canvas 1024 1024 $true
    $graphics = New-Graphics $canvas
    try {
        $graphics.Clear([Drawing.Color]::Black)
        $graphics.DrawImage($Image, [Drawing.Rectangle]::new(0, 0, 1024, 1024))
        Save-Canvas $canvas (Join-Path $phone $Name)
    } finally { $graphics.Dispose(); $canvas.Dispose() }
}

function Write-TV([Drawing.Image]$Mark, [int]$Width, [int]$Height, [string]$Stack, [string]$Suffix) {
    $background = New-Canvas $Width $Height $true
    $middle = New-Canvas $Width $Height $false
    $foreground = New-Canvas $Width $Height $false
    $bg = New-Graphics $background
    $glow = New-Graphics $middle
    $fg = New-Graphics $foreground
    $field = [Drawing.Drawing2D.LinearGradientBrush]::new(
        [Drawing.Rectangle]::new(0, 0, $Width, $Height),
        [Drawing.Color]::FromArgb(9, 9, 10), [Drawing.Color]::FromArgb(2, 2, 3),
        [Drawing.Drawing2D.LinearGradientMode]::Vertical)
    $haloPath = [Drawing.Drawing2D.GraphicsPath]::new()
    $haloPath.AddEllipse([single]($Width * 0.19), [single](-$Height * 0.04), [single]($Width * 0.62), [single]($Height * 1.08))
    $halo = [Drawing.Drawing2D.PathGradientBrush]::new($haloPath)
    $halo.CenterColor = [Drawing.Color]::FromArgb(112, 158, 0, 37)
    $halo.SurroundColors = @([Drawing.Color]::FromArgb(0, 0, 0, 0))
    try {
        $bg.FillRectangle($field, 0, 0, $Width, $Height)
        $glow.Clear([Drawing.Color]::Transparent)
        $glow.FillPath($halo, $haloPath)
        $fg.Clear([Drawing.Color]::Transparent)
        # Uniform scaling preserves the triangle's proportions in the 5:3 tile.
        $edge = [single]($Height * 1.25)
        $fg.DrawImage($Mark, [Drawing.RectangleF]::new(($Width - $edge) / 2, ($Height - $edge) / 2, $edge, $edge))
        $base = Join-Path $television ($Stack + '.imagestack')
        Save-Canvas $background (Join-Path $base ("Background.imagestacklayer/Content.imageset/Background{0}.png" -f $Suffix))
        Save-Canvas $middle (Join-Path $base ("Middle.imagestacklayer/Content.imageset/Middle{0}.png" -f $Suffix))
        Save-Canvas $foreground (Join-Path $base ("Foreground.imagestacklayer/Content.imageset/Foreground{0}.png" -f $Suffix))
    } finally {
        $halo.Dispose(); $haloPath.Dispose(); $field.Dispose()
        $bg.Dispose(); $glow.Dispose(); $fg.Dispose()
        $background.Dispose(); $middle.Dispose(); $foreground.Dispose()
    }
}

function Write-Banner([Drawing.Image]$Artwork, [int]$Width, [int]$Height, [string]$Folder, [string]$Suffix) {
    $canvas = New-Canvas $Width $Height $true
    $graphics = New-Graphics $canvas
    try {
        $graphics.Clear([Drawing.Color]::FromArgb(7, 7, 8))
        $edge = [single]($Height * 0.95)
        $graphics.DrawImage($Artwork, [Drawing.RectangleF]::new(($Width - $edge) / 2, ($Height - $edge) / 2, $edge, $edge))
        $filename = $Folder.Replace(' ', '') + $Suffix + '.png'
        Save-Canvas $canvas (Join-Path $television ($Folder + '.imageset/' + $filename))
    } finally { $graphics.Dispose(); $canvas.Dispose() }
}

$color = [Drawing.Image]::FromFile((Join-Path $masters 'icon-color.png'))
$tinted = [Drawing.Image]::FromFile((Join-Path $masters 'icon-tinted.png'))
$mark = [Drawing.Image]::FromFile((Join-Path $masters 'play-mark.png'))
try {
    Write-Phone $color 'LineupAppIcon.png'
    Write-Phone $color 'LineupAppIcon-Dark.png'
    Write-Phone $tinted 'LineupAppIcon-Tinted.png'
    Write-TV $mark 400 240 'App Icon - Small' ''
    Write-TV $mark 800 480 'App Icon - Small' '@2x'
    Write-TV $mark 1280 768 'App Icon - Large' ''
    Write-Banner $color 1920 720 'Top Shelf Image' ''
    Write-Banner $color 3840 1440 'Top Shelf Image' '@2x'
    Write-Banner $color 2320 720 'Top Shelf Image Wide' ''
    Write-Banner $color 4640 1440 'Top Shelf Image Wide' '@2x'
} finally { $color.Dispose(); $tinted.Dispose(); $mark.Dispose() }
