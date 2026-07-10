# Chạy app. Lỗi "EGL Error: Context Lost (12302)" đã xử lý ở backend:
# chỉ dùng nvenc (NVIDIA) hoặc CPU cho ffmpeg, KHÔNG dùng qsv/amf (GPU tích hợp)
# — vì encode trên GPU tích hợp giành GPU với giao diện Flutter -> driver reset.
$exe = Join-Path $PSScriptRoot "build\windows\x64\runner\Release\reup_flutter.exe"
if (-not (Test-Path $exe)) {
    $exe = Join-Path $PSScriptRoot "build\windows\x64\runner\Debug\reup_flutter.exe"
}

if (Test-Path $exe) {
    Write-Host "Launching: $exe"
    & $exe
} else {
    Write-Host "Chưa có bản build — chạy dev qua flutter run."
    flutter run -d windows
}
