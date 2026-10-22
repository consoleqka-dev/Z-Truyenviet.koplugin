# Phase 6 — Xóa chương đã tải nhưng vẫn giữ truyện trong Tủ truyện

## Bối cảnh
- `Browser:confirmRemoveStories` (browser.lua, khoảng dòng 244) hiện có ba nút:
  - "Xóa khỏi Tủ truyện và cả file đã tải";
  - "Chỉ xóa khỏi Tủ truyện (giữ file)";
  - "Hủy".
- Chưa có cách nào giải phóng bộ nhớ mà vẫn giữ truyện để đọc tiếp.
- Các nơi gọi `confirmRemoveStories`:
  - `toggleFavorite`;
  - xóa nhiều truyện (`selectFavoritesToRemove`);
  - giữ tay trên một truyện → "Xóa khỏi Tủ truyện…".
- Chương của truyện online nằm ở hai nơi:
  1. **Thư mục plugin** `Storage:getDownloadDir(source_id, url)`. Mọi thứ trong đó đều do plugin tạo, kể cả `.sdr` của KOReader.
  2. **Thư mục gắn ngoài** `Storage:getLinkedDir(story)`. Đây là thư mục của người dùng. `getChapterPath` lưu chương tải mới vào thẳng thư mục này, đặt tên theo `chapterFileName` (`urlLeaf(chapter.url) .. ".html" | ".cbz"`). Thư mục cũng chứa file người dùng tự chép vào.
- `LocalLibrary.deleteTargets` hiện xóa **cả** thư mục gắn ngoài khi xóa truyện. Tính năng mới không được làm vậy.

## Yêu cầu

### Phạm vi xóa (chỉ truyện online, tức `not LocalLibrary.isLocal(story)`)
- **Thư mục plugin:** xóa toàn bộ thư mục, kể cả các thư mục `.sdr` bên trong. Bỏ qua thư mục nằm trong `protectedDirs()`, giống luồng xóa hiện tại.
- **Thư mục gắn ngoài:** chỉ xóa những file khớp **đúng tên** plugin đặt cho một chương trong mục lục đã lưu (phase 1). Thư mục `.sdr` đi kèm của những file đó (`<tên bỏ đuôi>.sdr`, cùng quy tắc với `deleteTargets`) cũng bị xóa.
  - File khác tên thì không đụng tới.
  - Bản thân thư mục gắn ngoài được giữ lại.
  - Nếu truyện chưa có mục lục lưu thì không xóa gì trong thư mục gắn ngoài, và thông báo kết quả nói rõ điều này.
  - Đây là câu hỏi mở số 3.
- **Truyện "Trên máy"** (local) trong lựa chọn: không làm gì, và tính vào số "bỏ qua".
- **Dữ liệu giữ nguyên:**
  - bản ghi Tủ truyện;
  - lịch sử đọc;
  - `offline_dir`;
  - mục lục lưu.
- **Dọn bộ nhớ sau khi xóa:**
  - các mục `size_cache` liên quan (phase 5);
  - chỉ mục ngoại tuyến (`getOfflineIndex`), tự tính lại vì thời điểm sửa của thư mục đã đổi.

### Module `local_library.lua`
- Thêm `LocalLibrary.downloadTargets(story, chapters_by_page)`, trả về `{ dirs = {...}, files = {...} }`. `chapters_by_page` lấy từ `ChapterCache` ở bên gọi, để `local_library` không phụ thuộc `ChapterCache`.
- Thêm `LocalLibrary.collectDownloadTargets(stories, protected, chapter_lookup)`:
  - gộp đích xóa của nhiều truyện và bỏ trùng;
  - trả về `targets`, `skipped_local`, `skipped_protected`, `linked_without_index`.
- Thêm `LocalLibrary.removeDownloads(stories, opts)`. Hàm dùng lại `removeTree` và **không** gọi `Storage:removeFavorites`. Kết quả trả về: `{ stories = n, deleted_files, failed = {}, skipped = {}, linked_kept = {} }`.
- Đếm số file và dung lượng bằng `countFiles` / `sizeOf` trên chính danh sách đích, để con số hiện ra khớp với thứ bị xóa.

### Giao diện (`browser.lua`, `confirmRemoveStories`)
- Thêm nút ở vị trí **đầu tiên**. Nút chỉ hiện khi trong lựa chọn có ít nhất một truyện online còn file đã tải:
  `Chỉ xóa chương đã tải, giữ trong Tủ truyện (%d file · %s)`
- Bấm nút thì hiện `ConfirmBox`:
  - Nội dung: `Xóa %d file chương đã tải (%s) của %d truyện?\nTruyện vẫn ở Tủ truyện, lịch sử đọc giữ nguyên; có thể tải lại sau.`
  - Nếu có truyện gắn thư mục ngoài, thêm dòng: `File bạn tự chép vào thư mục gắn ngoài sẽ được giữ nguyên.`
- Nút xác nhận `Xóa chương`. Hàm `removeDownloads` chạy trong `withLoading("Đang xóa chương đã tải…")`.
- Thông báo kết quả qua `InfoMessage`, ví dụ:
  `Đã xóa 312 file (85,4 MB) của 2 truyện.\nBỏ qua 1 truyện trên máy.\n1 truyện gắn thư mục ngoài chưa có mục lục lưu nên giữ nguyên file trong đó.`
- Sau khi xóa:
  - **Không** gọi `view:removeStory`.
  - Gọi callback mới `on_downloads_removed(result)` để làm mới Tủ truyện (dung lượng, số chương ngoại tuyến), ví dụ `view:refreshFavorites()` hoặc mở lại `showFavorites` ở trang hiện tại, tùy hàm nào đang có.
  - Với lựa chọn nhiều truyện: đóng view chọn như luồng hiện tại.
- Các nút cũ giữ nguyên.

### Thêm lối vào khi giữ tay trên truyện
Trong menu giữ tay trên truyện online ở Tủ truyện, thêm mục `Xóa chương đã tải…`:
- dùng chung hộp xác nhận ở trên;
- chỉ hiện khi truyện có file đã tải.

## Các bước
1. Viết `downloadTargets`, `collectDownloadTargets`, `removeDownloads` trong `local_library.lua`, và dọn `size_cache` sau khi xóa.
2. Bổ sung `spec/favorite_removal_test.lua`. Dùng hệ thống file giả, mỗi ca kèm kết quả mong đợi:
   - **Truyện online có thư mục plugin:**
     - thư mục bị xóa hết;
     - bản ghi Tủ truyện vẫn còn;
     - `flush` không được gọi.
   - **Truyện gắn thư mục ngoài có mục lục lưu:**
     - chỉ file trùng tên plugin và `.sdr` của chúng bị xóa;
     - `ghi-chu.txt` và `chuong-1-tu-chep.html` (khác tên) còn nguyên;
     - thư mục gắn ngoài vẫn còn.
   - **Truyện gắn thư mục ngoài không có mục lục lưu:** không xóa gì; truyện nằm trong `linked_kept`.
   - **Lựa chọn trộn local và online:** truyện local không bị đụng tới.
   - **Thư mục được bảo vệ:** bị bỏ qua.
3. Thêm nút, hộp xác nhận và thông báo vào `confirmRemoveStories`, cùng callback làm mới.
4. Thêm mục "Xóa chương đã tải…" vào menu giữ tay.

## Kiểm tra
- `luajit spec/favorite_removal_test.lua` chạy qua; các ca cũ không đổi.
- Thử trên máy ở phase 7 với một truyện TruyenQQ đã tải vài chương:
  - xóa xong, truyện vẫn ở Tủ truyện, dung lượng hiện `0 B` hoặc không còn hiện;
  - các chương mất nhãn "Đã tải";
  - "Đọc tiếp" vẫn tải lại được chương qua mạng.

## Rủi ro
- **Mất vị trí đọc trong `.sdr`.** Vị trí đọc theo trang nằm trong `.sdr` cạnh file chương, nên sẽ mất. Lịch sử đọc của plugin (chương nào) vẫn còn. Thông báo xác nhận đã nói "lịch sử đọc giữ nguyên"; không hứa giữ vị trí trong trang.
- **Xóa nhầm file của người dùng.** Đã giới hạn bằng cách chỉ xóa file trùng đúng tên do plugin sinh ra từ mục lục lưu.
