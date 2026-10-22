# Phase 1 — Bộ nhớ mục lục chương (`chapter_cache.lua`)

## Bối cảnh
Plugin hiện không lưu mục lục. `Browser:loadStoryPage` luôn gọi `source:getStoryPage` khi có Wi-Fi. Cần một chỗ lưu kết quả thô của nguồn (trước `ChapterOrder.apply`) theo từng trang mục lục.

## Yêu cầu
- Module mới `truyenviet.koplugin/truyenviet/chapter_cache.lua`, thuần Lua, không phụ thuộc UI.
- Thư mục: `Storage.cache_dir .. "/chapters"`, thêm `Storage:getChapterCacheDir()` cùng kiểu `getCoverCacheDir`.
- Khóa: `source_id .. "|" .. story.url .. "|" .. page`; tên file `Util.stableHash(khóa) .. ".bin"`.
- Nội dung: `string.buffer.encode({ v = 1, saved_at = os.time(), data = { story, page, total_pages, chapters } })`. Chỉ chép các trường dữ liệu thuần. Nếu encode lỗi thì không lưu và ghi `Debug.write`.
- Ghi nguyên tử: ghi ra file `.tmp` rồi `os.rename`.
- API:
  - `ChapterCache.get(source_id, url, page)` trả về `data, saved_at`, hoặc `nil` khi thiếu file, decode lỗi hay `v` khác 1. File hỏng thì xóa đi.
  - `ChapterCache.put(source_id, url, page, page_data)`.
  - `ChapterCache.clear()`.
  - `ChapterCache.newChapterCount(old_chapters, new_chapters)`: số chương có `url` chưa có trong danh sách cũ.
  - `ChapterCache.isAvailable()`: trả về false khi không có `string.buffer`. Khi đó `get` luôn trả `nil` và `put` không làm gì.
- Dọn bớt: sau `put`, nếu có hơn 120 file thì xóa các file có thời điểm sửa cũ nhất cho tới khi còn 100.
- Hằng `ChapterCache.ttl = 600` (10 phút).

## Các bước
1. Thêm `Storage:getChapterCacheDir()` vào `storage.lua`.
2. Viết `chapter_cache.lua`.
3. Viết `spec/chapter_cache_test.lua`. Mock `datastorage` theo mẫu `spec/local_history_size_test.lua`, dùng thư mục tạm thật để ghi file. Các ca cần kiểm:
   - ghi rồi đọc lại đúng nội dung;
   - các trang khác nhau dùng khóa khác nhau;
   - file hỏng trả về `nil` và bị xóa;
   - dọn bớt về đúng 100 file;
   - `newChapterCount` đếm đúng;
   - bảng có chứa function thì không ghi và không lỗi.

## Kiểm tra
`luajit spec/chapter_cache_test.lua` chạy qua; `luajit -b` biên dịch được file mới.

## Rủi ro
Mục lục 435 chương nặng khoảng 40–60 KB. Tối đa 100 file, tức khoảng 6 MB trên `/sdcard`.
