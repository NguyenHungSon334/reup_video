Hướng dẫn triển khai (Web, Netlify/Vercel) — Reup Video

Mục đích
- Hướng dẫn từng bước build và deploy frontend (Flutter web) và chạy backend (FastAPI).
- Bao gồm cách thiết lập CI/CD để tự động deploy lên Netlify hoặc Vercel.

Liệt kê file liên quan
- Backend entry: [backend/main.py](backend/main.py#L1)
- Frontend API service: [flutter_ui/lib/services/api_service.dart](flutter_ui/lib/services/api_service.dart#L1)
- Thư mục web build: `flutter_ui/build/web`

Yêu cầu trước
- Git, GitHub repo đã kết nối
- Flutter (>=3.x) cài đặt và `flutter` trong PATH
- Python 3.8+ và `pip`
- Node.js + npm (để dùng netlify-cli/vercel cli trong CI local testing)

1) Chạy local (phát triển và thử nghiệm)

1.1 Cài dependency backend
```powershell
cd "c:\Project\Reup video"
python -m pip install -r backend/requirements.txt
```

1.2 Build Flutter web (tạo tài nguyên tĩnh)
```powershell
cd "c:\Project\Reup video\flutter_ui"
# Lần đầu nếu project chưa hỗ trợ web
flutter create . --platforms web
# Build web
flutter build web
```

1.3 Chạy backend (FastAPI) và serve web tĩnh
- Backend đã cấu hình để serve `flutter_ui/build/web` nếu tồn tại (xem [backend/main.py](backend/main.py#L1)).
```powershell
cd "c:\Project\Reup video"
python -m backend.main
```
- Mở browser: `http://localhost:8000`
- API health: `http://localhost:8000/health`

Ghi chú: frontend khi chạy trên web sử dụng đường dẫn API tương đối nếu không đặt `API_BASE_URL` (xem phần Build-time env).

2) Build-time biến môi trường cho API (production)
- Khi deploy lên Netlify/Vercel bạn thường đặt API hosted ở nơi khác (ví dụ `https://api.example.com`).
- Sử dụng `--dart-define` khi build để chèn URL backend:
```bash
flutter build web --release --dart-define=API_BASE_URL=https://api.example.com
```
- Trong code `ApiService` hiện đã đọc biến build-time này. Nếu `API_BASE_URL` rỗng thì frontend sử dụng đường dẫn tương đối.

3) Deploy lên Netlify (CI via GitHub Actions)

3.1 Tạo secret trên GitHub repo (Settings → Secrets):
- `NETLIFY_AUTH_TOKEN` — token cá nhân Netlify
- `NETLIFY_SITE_ID` — ID site trên Netlify
- `API_BASE_URL` — (nếu backend host riêng) URL backend production

3.2 Thêm workflow mẫu `.github/workflows/deploy-netlify.yml` (ví dụ):
```yaml
name: Build & Deploy Flutter Web → Netlify
on:
  push:
    branches: [ main ]
jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: 'stable'
      - run: flutter pub get
      - run: flutter build web --release --dart-define=API_BASE_URL=${{ secrets.API_BASE_URL }}
      - name: Deploy to Netlify
        env:
          NETLIFY_AUTH_TOKEN: ${{ secrets.NETLIFY_AUTH_TOKEN }}
          NETLIFY_SITE_ID: ${{ secrets.NETLIFY_SITE_ID }}
        run: npx netlify-cli deploy --dir=flutter_ui/build/web --site=$NETLIFY_SITE_ID --auth=$NETLIFY_AUTH_TOKEN --prod
```

4) Deploy lên Vercel (CI via GitHub Actions)

4.1 Tạo secret trên GitHub repo:
- `VERCEL_TOKEN`
- `API_BASE_URL` (nếu cần)

4.2 Workflow mẫu `.github/workflows/deploy-vercel.yml`:
```yaml
name: Build & Deploy Flutter Web → Vercel
on:
  push:
    branches: [ main ]
jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: subosito/flutter-action@v2
        with:
          flutter-version: 'stable'
      - run: flutter pub get
      - run: flutter build web --release --dart-define=API_BASE_URL=${{ secrets.API_BASE_URL }}
      - name: Deploy to Vercel
        env:
          VERCEL_TOKEN: ${{ secrets.VERCEL_TOKEN }}
        run: npx vercel --prod --confirm --token $VERCEL_TOKEN --cwd flutter_ui/build/web
```
Ghi chú: với Vercel thường bạn dùng `vercel` config trên dashboard; dùng CLI như trên sẽ upload nội dung thư mục build.

5) CORS và bảo mật
- Backend (FastAPI) hiện cho phép `allow_origins=["*"]` — phù hợp testing, production nên hạn chế domain cụ thể.
- KHÔNG commit các file nhạy cảm (`config.json`, `backend/credentials.json`, `backend/token.json`). `.gitignore` trong repo đã loại trừ các file này.
- Nếu GitHub repo có Push Protection, đảm bảo secrets không nằm trong commit lịch sử. Nếu đã commit trước đó, phải xóa lịch sử hoặc rotate secrets.

6) Host backend (gợi ý)
- Bạn có thể host backend trên: Render, Railway, Fly.io, Heroku, hoặc một VM (DigitalOcean, AWS EC2).
- Sau khi host backend, lấy URL và đặt vào `API_BASE_URL` secret để frontend gọi đúng endpoint.

7) Deploy thủ công (không dùng CI)
- Build local và upload `flutter_ui/build/web` lên Netlify (drag&drop) hoặc Vercel (project upload) qua dashboard.

8) Build desktop / macOS (tương lai)
- Windows:
```powershell
cd flutter_ui
flutter build windows
```
- macOS (trên mac):
```bash
cd flutter_ui
flutter build macos
```
- Lưu ý: desktop build không dùng `build/web` — đây là native app; backend có thể chạy như một service riêng nếu cần tích hợp.

9) Kiểm tra sau deploy
- Truy cập domain frontend (Netlify/Vercel URL) và kiểm tra các API call hoạt động như mong muốn.
- Kiểm tra `Network` tab trong DevTools để xác nhận API gọi tới `API_BASE_URL` đúng.

10) Thêm vào repo (tuỳ chọn)
- Bạn có thể thêm file workflow mẫu trong `.github/workflows/` (tôi có thể tạo giúp nếu bạn muốn).
- Thêm file `README_DEPLOY.md` (đã tạo) vào repo root để lưu hướng dẫn này.

---

Nếu bạn muốn, tôi có thể tự động tạo file workflow cho Netlify hoặc Vercel và commit lên nhánh `main`. Chọn Netlify hay Vercel, và cho tôi biết URL backend production (hoặc để trống để dùng đường dẫn tương đối).