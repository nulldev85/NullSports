# Package the approved three-bar raster artwork without redrawing the symbol.
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$repoRoot = Split-Path -Parent $PSScriptRoot
$masters = Join-Path $PSScriptRoot 'LineupIcon'
$phone = Join-Path $repoRoot 'iPhone/Assets.xcassets/LineupAppIcon.appiconset'
$television = Join-Path $repoRoot 'Lineup/Assets.xcassets/Lineup App Icon & Top Shelf Image.brandassets'

function Write-Image([Drawing.Image]$Image, [int]$Width, [int]$Height,
                     [string]$Path, [bool]$Opaque, [double]$Scale = 1, [bool]$Grayscale = $false) {
    $format = if ($Opaque) { [Drawing.Imaging.PixelFormat]::Format24bppRgb } else { [Drawing.Imaging.PixelFormat]::Format32bppArgb }
    $canvas = [Drawing.Bitmap]::new($Width, $Height, $format)
    $graphics = [Drawing.Graphics]::FromImage($canvas)
    try {
        $graphics.CompositingQuality = [Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.PixelOffsetMode = [Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $graphics.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
        if ($Opaque) { $graphics.Clear([Drawing.Color]::FromArgb(28, 28, 30)) }
        else { $graphics.Clear([Drawing.Color]::Transparent) }
        if ($null -ne $Image) {
            $edge = [single]($Height * $Scale)
            if ($Grayscale) {
                # Normalize the tinted export to exactly equal RGB channels.
                $matrix = [Drawing.Imaging.ColorMatrix]::new()
                $matrix.Matrix00 = 0.2126; $matrix.Matrix01 = 0.2126; $matrix.Matrix02 = 0.2126
                $matrix.Matrix10 = 0.7152; $matrix.Matrix11 = 0.7152; $matrix.Matrix12 = 0.7152
                $matrix.Matrix20 = 0.0722; $matrix.Matrix21 = 0.0722; $matrix.Matrix22 = 0.0722
                $attributes = [Drawing.Imaging.ImageAttributes]::new()
                try {
                    $attributes.SetColorMatrix($matrix)
                    $graphics.DrawImage($Image, [Drawing.Rectangle]::new(0, 0, $Width, $Height),
                        0, 0, $Image.Width, $Image.Height, [Drawing.GraphicsUnit]::Pixel, $attributes)
                } finally { $attributes.Dispose() }
            } else {
                $graphics.DrawImage($Image,
                    [Drawing.RectangleF]::new(($Width - $edge) / 2, ($Height - $edge) / 2, $edge, $edge))
            }
        }
        $canvas.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
        Write-Output ("{0}x{1} {2}" -f $Width, $Height, $Path.Substring($repoRoot.Length + 1))
    } finally { $graphics.Dispose(); $canvas.Dispose() }
}

# The two color appearances use the exact user-approved 1024px master.
$colorPath = Join-Path $masters 'icon-color.png'
$approved = [Drawing.Image]::FromFile($colorPath)
try {
    if ($approved.Width -ne 1024 -or $approved.Height -ne 1024) {
        throw 'The approved color master must be 1024x1024.'
    }
} finally { $approved.Dispose() }
Copy-Item -LiteralPath $colorPath -Destination (Join-Path $phone 'LineupAppIcon.png') -Force
Copy-Item -LiteralPath $colorPath -Destination (Join-Path $phone 'LineupAppIcon-Dark.png') -Force

$tinted = [Drawing.Image]::FromFile((Join-Path $masters 'icon-tinted.png'))
$mark = [Drawing.Image]::FromFile((Join-Path $masters 'brand-mark.png'))
try {
    Write-Image $tinted 1024 1024 (Join-Path $phone 'LineupAppIcon-Tinted.png') $true 1 $true
    Write-Image $mark 1024 1024 (Join-Path $repoRoot 'iPhone/Assets.xcassets/LineupBrandMark.imageset/LineupBrandMark.png') $false
    foreach ($size in @(@(400, 240, 'App Icon - Small', ''), @(800, 480, 'App Icon - Small', '@2x'), @(1280, 768, 'App Icon - Large', ''))) {
        $stack = Join-Path $television ($size[2] + '.imagestack')
        $suffix = $size[3]
        Write-Image $null $size[0] $size[1] (Join-Path $stack ("Background.imagestacklayer/Content.imageset/Background{0}.png" -f $suffix)) $true
        Write-Image $null $size[0] $size[1] (Join-Path $stack ("Middle.imagestacklayer/Content.imageset/Middle{0}.png" -f $suffix)) $false
        Write-Image $mark $size[0] $size[1] (Join-Path $stack ("Foreground.imagestacklayer/Content.imageset/Foreground{0}.png" -f $suffix)) $false 1.25
    }
    foreach ($size in @(@(1920, 720, 'Top Shelf Image', ''), @(3840, 1440, 'Top Shelf Image', '@2x'), @(2320, 720, 'Top Shelf Image Wide', ''), @(4640, 1440, 'Top Shelf Image Wide', '@2x'))) {
        $folder = $size[2]
        $filename = $folder.Replace(' ', '') + $size[3] + '.png'
        Write-Image $mark $size[0] $size[1] (Join-Path $television ($folder + '.imageset/' + $filename)) $true 0.95
    }
} finally { $tinted.Dispose(); $mark.Dispose() }
