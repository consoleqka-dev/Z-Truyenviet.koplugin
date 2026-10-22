---
title: Nhận "tệp trọn bộ" qua mục lục .sdr — đếm chương, đánh dấu Đã tải, mở đúng trang chương
status: đang làm
created: 2026-10-23
target_build: 3.18.1 (BUILD-1393)
---

# Tệp trọn bộ (bundle) có mục lục tự tạo

## Bối cảnh (đã kiểm chứng)
- Diamond No Ace có `Diamond-No-Ace-tron-bo.cbz` (3,5 GB, 418 chương) và `Diamond-No-Ace-tron-bo.sdr/metadata.cbz.lua`. Trong đó `handmade_toc` = `{ {depth=1, page=N, title="Chương X"}, ... }`.
- `getOfflineIndex` chỉ lấy số chương từ tên file. Tên tệp gộp không có số chương, nên Tủ truyện hiện "23/412" (22 file lẻ + 1 tệp gộp).
- `isDownloaded`/`getChapterPath` chỉ tìm file lẻ, nên chương trong tệp gộp bị coi là chưa tải và có thể bị tải lại.
- KOReader chạy `postReaderReadyCallback` *sau* `ReadSettings` (khôi phục `last_page`). Gửi `GotoPage` ở đó sẽ không bị trang cũ ghi đè.

## Kết quả mong muốn
1. Tủ truyện đếm cả chương trong mục lục tệp gộp (không đếm chính tệp gộp). Hiện "Đã tải 418/418"; khi số chương đã tải lớn hơn tổng thì hiện "Đã tải hết".
2. Danh sách chương ghi "Đã tải" cho mọi chương có trong tệp gộp. Tải hàng loạt, tải trước (prefetch) và tải nền đều bỏ qua các chương này.
3. Bấm chương có trong tệp gộp thì mở tệp gộp và nhảy tới trang đầu của chương đó. "Chương tiếp/trước" tính theo trang đang đọc: chương đích nằm cùng tệp gộp đang mở thì nhảy trang tại chỗ, không mở lại tệp.

## Thiết kế
- `storage.lua`:
  - `Storage.readHandmadeToc(path)` đọc `handmade_toc` qua `DocSettings` (pcall). Hàm trả về bảng mục lục và đường dẫn sidecar.
  - `getOfflineIndex` dùng hàm này cho file truyện không có số chương trong tên. Nếu mục lục có ≥2 chương có số thì file đó là tệp gộp. Index có thêm:
    - `bundles[name]`: danh sách `{number, page}` theo trang.
    - `bundle_by_number[number]`: `{file, page}`.
  - Cache index còn kiểm thêm thời điểm sửa sidecar.
  - `countOfflineChapters` đếm số chương trong tệp gộp.
  - Hàm mới `getBundleChapter(source, story, chapter)` trả về `path, page`.
  - Hàm mới `bundleChapterAt(path, page)` trả về số chương tại một trang.
  - Hàm mới `hasChapterFile` (= `isDownloaded` cũ). `isDownloaded` = có file lẻ **hoặc** có trong tệp gộp.
- `widgets/story_results.lua`: thêm nhánh "Đã tải hết" khi downloaded > total.
- `reader.lua`:
  - `Reader:setStartPage(path, page)`: trang cần nhảy tới, áp dụng trong `postReaderReadyCallback`.
  - `Reader:gotoPageInOpenBook(path, page)`: tệp đang mở thì nhảy tại chỗ.
- `browser.lua openChapter`: chương có trong tệp gộp và không `force` thì mở tệp gộp. Neighbor tính theo chương tại trang hiện tại. "Xóa bản đã tải" và tự dọn chương cũ chỉ áp dụng cho file lẻ (`hasChapterFile`).

## Ràng buộc
- Không sửa hay xóa tệp gộp, sidecar hay file lẻ của người dùng. Hỏi trước khi xóa 22 file lẻ trùng.
- Thiếu `docsettings` (spec, KOReader cũ) thì hoạt động như cũ.
- Giữ bản vá cục bộ `truyenqq.lua`/`updater.lua`; không cài OTA đè.
- Trước khi cài lên máy, sao lưu plugin cũ vào `/sdcard/koreader/backup-20261023/`.

## Ngoài phạm vi
- Gộp CBZ bằng plugin (hộp "gộp file" hiện chỉ gộp chữ).
- Thanh trạng thái "Chương X/Y" khi đọc tệp gộp (KOReader đã hiện tên chương theo mục lục).

## Kiểm chứng
- Spec mới `spec/bundle_chapters_test.lua` kiểm tra đếm, đánh dấu, đường dẫn/trang, chương tại trang và nhãn "Đã tải hết". Chạy lại toàn bộ spec cũ.
- `luajit -b` mọi file `.lua`, chạy `./scripts/build.sh`.
- Trên máy: Tủ truyện hiện "Đã tải hết" hoặc "418/…", danh sách chương có "Đã tải", bấm "Chương 200" thì mở đúng trang.
