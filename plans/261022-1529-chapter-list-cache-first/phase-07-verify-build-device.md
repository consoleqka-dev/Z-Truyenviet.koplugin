# Phase 7 — Kiểm thử, build, thử trên máy

## Trên máy tính
1. `find truyenviet.koplugin -name "*.lua" -exec luajit -b {} /dev/null \;`
2. Chạy toàn bộ `spec/*.lua` bằng `luajit` từ thư mục gốc repo.
3. Cập nhật:
   - `version.lua` lên 3.17.0 (BUILD-1383);
   - `CHANGELOG.md`;
   - `Project_memory.md`.
4. Chạy `./scripts/build.sh` và kiểm tra trong zip có `chapter_cache.lua` và `background_fetch.lua`.
5. Không commit hay push khi chưa hỏi.

## Trên máy (chỉ làm sau khi người dùng xác nhận cài)
1. Sao lưu thư mục plugin và `settings/truyenviet.lua` vào `/sdcard/koreader/backup-<ngày>/before-BUILD-1383`, rồi báo đường dẫn.
2. Cài bản build qua adb. Không cài OTA đè và giữ bản vá `truyenqq.lua`, `updater.lua`.
3. Danh sách thử:
   - [ ] **Mở truyện lần đầu:** có hộp chờ như cũ. Mở lại ngay: hiện tức thì với `Cập nhật lúc …`.
   - [ ] **Đợi hơn 10 phút rồi mở lại:** `⟳ Đang lấy chương mới…` hiện, sau đó đổi trạng thái. Trong lúc chờ vẫn cuộn và mở chương được.
   - [ ] **Mở chương trong lúc tải nền:** đọc được, và chuyển chương kế không lỗi.
   - [ ] **Tắt Wi-Fi rồi mở truyện:** thấy `Ngoại tuyến · danh sách lưu lúc …`.
   - [ ] **`settings/truyenviet.lua`:** thời điểm sửa không đổi khi mở truyện không có thay đổi.
   - [ ] **Quay về Tủ truyện nhiều lần:** không chậm dần. So sánh thời gian bằng log `Debug.verbose`.
   - [ ] **"Chỉ xóa chương đã tải, giữ trong Tủ truyện"** trên một truyện thử:
     - truyện còn trong Tủ truyện;
     - nhãn "Đã tải" mất;
     - "Đọc tiếp" vẫn tải lại được.
   - [ ] **Không còn tiến trình con mồ côi:** `adb shell ps -A | grep -i koreader` chỉ có tiến trình chính.
4. Dọn dẹp:
   - chạy `adb kill-server`;
   - không để file tạm dưới `/tmp`;
   - xóa các bản kéo về máy tính.

## Rollback
- Chép lại thư mục plugin và settings từ `before-BUILD-1383`.
- Thư mục `truyenviet/cache/chapters/` có thể xóa bất kỳ lúc nào.
