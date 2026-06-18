# 🚀 Deploy Frontend + Backend Guide

## 📋 Tóm Tắt Kế Hoạch

| Thành Phần | Nền Tảng | URL |
|-----------|---------|-----|
| **Frontend** (Flutter Web) | Netlify | `reup-xxx.netlify.app` |
| **Backend** (FastAPI) | Render.com | `reup-backend.onrender.com` |

---

## ✅ BƯỚC 1: Chuẩn Bị Repo (GitHub)

### 1.1 Push Code Lên GitHub
```bash
# Nếu chưa có repo
git init
git add .
git commit -m "Initial commit: Frontend + Backend"
git branch -M main
git remote add origin https://github.com/YOUR_USERNAME/reup-video.git
git push -u origin main
```

Cấu trúc repo:
```
reup-video/
├── backend/              # FastAPI Backend
├── flutter_ui/           # Flutter Web Frontend
├── requirements.txt      # Backend dependencies
├── Procfile             # Render config (đã tạo)
└── .gitignore           # Ignore sensitive files
```

---

## 🔧 BƯỚC 2: Deploy Backend Lên Render.com

### 2.1 Tạo Tài Khoản
1. Vào https://render.com
2. Đăng ký với GitHub (chọn "Sign up with GitHub")
3. Cho phép Render truy cập GitHub

### 2.2 Tạo Web Service
1. Dashboard → **New +** → **Web Service**
2. Kết nối GitHub repo của bạn
3. Điền thông tin:

| Trường | Giá Trị |
|--------|--------|
| **Name** | `reup-backend` |
| **Runtime** | `Python 3` |
| **Build Command** | `pip install -r requirements.txt` |
| **Start Command** | `python -m uvicorn backend.main:app --host 0.0.0.0 --port $PORT` |
| **Environments** | (Để trống - không cần secrets bây giờ) |

4. Chọn **Free** tier
5. Click **Create Web Service**

### 2.3 Chờ Deploy Hoàn Thành
- Render sẽ tự động build & deploy
- Xem logs tại dashboard
- Khi xong, sẽ có URL: `https://reup-backend.onrender.com`

✅ **Lưu lại URL này** - dùng cho bước 4

---

## 🎨 BƯỚC 3: Cập Nhật Frontend API URL

### 3.1 Sửa api_service.dart

File: `flutter_ui/lib/services/api_service.dart`

```dart
class ApiService {
  static String host = '127.0.0.1';
  static int port = 8000;

  // ⚠️ BƯỚC 3: Thay https://reup-backend.onrender.com
  static String backendUrl = 'https://reup-backend.onrender.com';
  
  // ... phần còn lại không đổi
}
```

### 3.2 Rebuild Frontend
```bash
cd flutter_ui
flutter clean
flutter build web --release
```

### 3.3 Commit & Push
```bash
git add .
git commit -m "Update API URL to Render backend"
git push origin main
```

---

## 🌐 BƯỚC 4: Deploy Frontend Lên Netlify

### 4.1 Tạo Tài Khoản Netlify
1. Vào https://netlify.com
2. Đăng ký với GitHub
3. Cho phép Netlify truy cập GitHub

### 4.2 Tạo Site Mới
1. Netlify Dashboard → **Add new site** → **Import an existing project**
2. Chọn **GitHub**
3. Chọn repo `reup-video` của bạn
4. Cấu hình build:

| Trường | Giá Trị |
|--------|--------|
| **Branch to deploy** | `main` |
| **Build command** | `cd flutter_ui && flutter build web --release` |
| **Publish directory** | `flutter_ui/build/web` |

5. Click **Deploy site**

### 4.3 Chờ Build Hoàn Thành
- Netlify sẽ tự động build & deploy mỗi khi push code
- Khi xong, có URL: `https://reup-xxx.netlify.app`

---

## ✨ BƯỚC 5: Cấu Hình Domain (Optional)

### 5.1 Custom Domain Netlify
1. Netlify → Site settings → Domain management
2. **Add custom domain**
3. Trỏ DNS domain của bạn theo hướng dẫn Netlify

### 5.2 Custom Domain Render (Backend)
1. Render → Service settings → Custom Domains
2. **Add custom domain**
3. Cập nhật DNS tương ứng

---

## 🧪 BƯỚC 6: Test

### 6.1 Test Frontend
```
Trình duyệt: https://reup-xxx.netlify.app
```

### 6.2 Test Backend API
```bash
curl -X GET https://reup-backend.onrender.com/health

# Hoặc test submit video
curl -X POST https://reup-backend.onrender.com/records/submit \
  -H "Content-Type: application/json" \
  -d '{"items":[{"url":"https://www.douyin.com/...", "use_music":false}], "save_to":"drive"}'
```

---

## 🔐 Bảo Mật - Environment Variables

Nếu có secrets (API keys, credentials), thêm vào Render:

### Trong Render Dashboard:
1. Service → **Environment** → **Add Environment Variable**
2. Ví dụ:
   ```
   GOOGLE_CREDENTIALS=/path/to/credentials.json
   ```

### Trong Python Code:
```python
import os
credentials_path = os.getenv("GOOGLE_CREDENTIALS")
```

---

## 🔄 Quy Trình Update Sau Này

**Lần sau muốn cập nhật:**

```bash
# 1. Sửa code (frontend hoặc backend)
git add .
git commit -m "Update feature X"
git push origin main

# 2. Netlify + Render tự động rebuild & deploy
# - Netlify: thay đổi flutter_ui/
# - Render: thay đổi backend/
```

---

## 📊 Giám Sát & Logs

**Netlify:**
- Dashboard → Site → Deploys → View logs

**Render:**
- Dashboard → Service → Logs

---

## ❌ Troubleshooting

### Frontend không kết nối Backend
```
Giải pháp: 
- Kiểm tra backendUrl trong api_service.dart
- CORS cấu hình trong main.py (đã cấu hình ở dòng allow_origins=["*"])
```

### Build fail trên Netlify
```
Lý do: flutter build web chưa được install
Giải pháp: 
- Thêm SDK vào build command
flutter pub get && flutter build web --release
```

### Backend timeout
```
Lý do: Free tier Render sleep sau 15 phút không dùng
Giải pháp: Upgrade lên paid tier, hoặc dùng uptime monitor
```

---

## 💰 Chi Phí

| Dịch Vụ | Free Tier | Giới Hạn |
|---------|----------|---------|
| **Netlify** | Unlimited | Bandwidth 100GB/tháng |
| **Render** | $0 | Sleep sau 15 phút idle |

**Upgrade Render:**
- Starter: $7/tháng (always on)
- Standard: $15/tháng

---

**Chúc bạn deploy thành công! 🎉**

Nếu gặp vấn đề, hãy check logs trên Netlify + Render dashboard.
