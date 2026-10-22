# Phase 3 — Nối vào giao diện

## browser.lua
- `FloatingProgress` thành `toast = true`: luôn nằm trên nhưng không chặn chạm. Thêm `onExit`/`onRestart` để tự đóng ngay (để ngăn xếp cửa sổ rỗng thì KOReader mới thoát).
- `runInBackground` (vẫn dùng cho `downloadAsBundle` và nhánh dự phòng) bỏ `bringToFront` liên tục; ô tiến độ là toast nên không cần.
- `Browser:downloadChapters`:
  - Có việc đang chạy: hộp hỏi `Hủy tải nền` / `Đóng`.
  - `DownloadJob.isAvailable()`:
    - chạy qua `NetworkMgr:runWhenOnline`, **không** bọc `Trapper:wrap`;
    - dọn `.part` trước khi bắt đầu;
    - `DownloadJob.start` với task gọi `ChapterDownloader:download(..., { subprocess = true, on_progress = report })`.
  - Ô tiến độ hiện khi không có `ReaderUI.instance`, đóng khi đang mở sách (đồng bộ ở mỗi lần thăm dò).
  - Xong việc: `addDocument(first_path)`, cập nhật view nếu còn hiện. Đang đọc thì chỉ hiện `Notification`; không đọc thì giữ hộp hỏi gộp file như cũ. Bị hủy thì báo "Đã hủy tải nền". Lỗi thì `showError`.
  - Không chạy nền được: giữ đường cũ `runInBackground`.

## reader.lua
- Trong post-init: `DownloadJob.subscribe(fn)`.
  - Có tiến độ: gắn hàm nội dung thanh trạng thái (nếu chưa gắn) rồi `footer:onUpdateFooter(footer_visible)` khi chữ đổi.
  - Xong: gỡ hàm.
- `onCloseWidget` thì `unsubscribe`.
- `onExit`/`onRestart`: `DownloadJob.cancel("exit")` nếu module đã nạp.

## main.lua
- Mục `⤓ Hủy tải nền` trong `sub_items`, chữ theo tiến độ (`text_func`), chỉ bật khi có việc (`enabled_func`). Dùng `package.loaded` để không nạp module khi chưa cần.
- `TruyenViet:onExit`/`onRestart`: hủy việc tải nền (cho trường hợp Exit từ File manager).
