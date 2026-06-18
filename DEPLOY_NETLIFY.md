# 📦 Hướng Dẫn Deploy Lên Netlify

## ✅ Status
Build đã sẵn sàng! Folder `build/web/` chứa toàn bộ ứng dụng production.

## 🚀 Các Cách Deploy

### **Cách 1: Dùng Netlify CLI (Recommended)**

```bash
# Cài đặt Netlify CLI nếu chưa có
npm install -g netlify-cli

# Login vào Netlify
netlify login

# Deploy từ folder build/web
netlify deploy --prod --dir=build/web
```

### **Cách 2: Kéo-Thả Trên Netlify UI**

1. Vào https://app.netlify.com
2. Chọn "Add new site" → "Deploy manually"
3. Kéo thả folder `flutter_ui/build/web/` vào
4. Chờ deploy hoàn thành

### **Cách 3: Kết Nối GitHub (CI/CD Tự Động)**

1. Push `flutter_ui/` lên GitHub
2. Vào Netlify → "New site from Git"
3. Chọn repository GitHub của bạn
4. Chọn branch deploy (vd: `main`)
5. Cấu hình build:
   - **Build command:** `flutter build web --release`
   - **Publish directory:** `flutter_ui/build/web`
6. Deploy!

Lần sau khi push code mới, Netlify sẽ tự động build & deploy.

## 📋 Checklist Trước Deploy

- ✅ Build web hoàn thành (`build/web/` tồn tại)
- ✅ `netlify.toml` đã được tạo (SPA redirect config)
- ✅ Backend API URL đã cập nhật trong `lib/services/api_service.dart`
- ✅ CORS được cấu hình đúng trên backend

## 🔧 Cấu Hình Backend

Nếu backend chạy ở máy khác, cần cập nhật API endpoint:

File: `flutter_ui/lib/services/api_service.dart`

```dart
static const String baseUrl = 'https://your-api-domain.com'; // Thay URL backend của bạn
```

## 🌐 Domain & DNS

1. Nếu muốn custom domain:
   - Vào Site settings → Domain management
   - Add custom domain
   - Cập nhật DNS records của domain

2. HTTPS được cấp tự động bằng Let's Encrypt

## ✨ Có Sẵn Trong Project

- `netlify.toml` - Cấu hình Netlify (build, redirects, headers)
- `build/web/` - Production build, sẵn sàng deploy

Thế là xong! 🎉
