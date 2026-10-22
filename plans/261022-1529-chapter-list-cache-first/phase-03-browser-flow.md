# Phase 3 — Luồng mở truyện và dòng trạng thái (`browser.lua`)

## Bối cảnh
- **`Browser:loadStoryPage`** (khoảng dòng 2346):
  - có Wi-Fi: `runOnline` → `withLoading` → `source:getStoryPage`;
  - không có Wi-Fi: `getLocalChapters`.
- **`showChapterList`** (khoảng dòng 2940) dựng `items` rồi gọi `showView` để tạo `ListView`. `ListView` kế thừa `Menu` của KOReader.
- **`Menu:switchItemTable(nil, items, -1)`** thay danh sách nhưng giữ trang hiện tại. Điều này đã được đối chiếu với mã nguồn KOReader.
- **`openChapter`** tính `next_chapter`/`prev_chapter` ngay lúc mở. Vì vậy chương mới tìm thấy sau đó sẽ không được dùng.

## Yêu cầu

### loadStoryPage
Thêm tham số cuối `force_refresh`.

1. Có mục lục lưu và không `force_refresh`:
   - Chép dữ liệu lưu sang `page_data`, gán `page_data.cache_saved_at`, rồi gọi `ChapterOrder.apply`.
   - Mở chương tự động hoặc hiện danh sách như hiện tại.
   - Gán `refresh_state` theo bảng sau:

     | Điều kiện | `refresh_state` | Việc làm thêm |
     |---|---|---|
     | Không có Wi-Fi | `"offline"` | — |
     | Mục lục lưu chưa quá `ChapterCache.ttl` | `"fresh"` | — |
     | Còn lại | `"running"` | gọi `startRefresh` |

   - Ở bước này không gọi `runWhenOnline`.
2. Không có mục lục lưu và đang ngoại tuyến: giữ nhánh `getLocalChapters`.
3. Không có mục lục lưu, hoặc có `force_refresh`: giữ nhánh `loadOnline` (chặn, hiện hộp chờ). Thêm:
   - gọi `ChapterCache.put` với dữ liệu thô;
   - gán `refresh_state = "done"`.

### startRefresh
Gọi `BackgroundFetch.run(khóa trang, function() return source:getStoryPage(story, page) end, on_done)`.

**Khi thành công:**
1. Gọi `ChapterCache.put` rồi `Storage:updateFavorite`. Theo phase 4, hàm này bỏ qua nếu dữ liệu không đổi.
2. Tính `n = newChapterCount` và cập nhật `page_data` tại chỗ:
   - `chapters`, đã áp `ChapterOrder.apply` theo `chapter_sort` hiện tại;
   - `total_pages`;
   - các trường của `story`.
3. Gán `refresh_state = "done"`, `new_count = n`, `refreshed_at = os.time()`.
4. Nếu view còn mở:
   - có chương mới hoặc số trang thay đổi: dựng lại `items` rồi gọi `view:switchItemTable(nil, items, -1)`;
   - còn lại: chỉ đổi chữ dòng trạng thái và gọi `view:updateItems()`.

**Khi thất bại** (trừ trường hợp bị hủy):
- gán `refresh_state = "failed"`;
- ghi `Debug.write`;
- cập nhật dòng trạng thái.

### showChapterList và dòng trạng thái
- Tách phần dựng `items` thành `buildChapterItems(self, page_data, source, on_return_callback)`.
- Lưu view vào `page_data.view`.
- Phần tử đầu danh sách là dòng trạng thái, chỉ hiện khi `refresh_state ~= nil`:

| refresh_state | Chữ hiển thị | Chạm vào |
|---|---|---|
| running | `⟳ Đang lấy chương mới…` | không làm gì |
| done, n>0 | `Có n chương mới · HH:MM` | làm mới |
| done, n=0 | `Đã là mới nhất · HH:MM` | làm mới |
| fresh | `Cập nhật lúc HH:MM · chạm để làm mới` | làm mới |
| failed | `Không cập nhật được · chạm để thử lại` | làm mới |
| offline | `Ngoại tuyến · danh sách lưu lúc HH:MM` | `runOnline` rồi làm mới |

"Làm mới" nghĩa là `closeAndRun(view, loadStoryPage(…, force_refresh = true))`, đi theo nhánh chặn như hiện nay. Lần đầu mở một truyện thì không có dòng trạng thái.

### openChapter: tìm chương kề lúc cần
- Chuyển vòng lặp tìm chương kề thành hàm `findNeighbors()`, gọi bên trong `on_next_chapter` và `on_prev_chapter`.
- Không còn chương kế và không còn trang sau thì thông báo theo `refresh_state`:

  | refresh_state | Thông báo |
  |---|---|
  | `running` | `Đang lấy chương mới, thử lại sau giây lát.` |
  | `failed` hoặc `offline` | `Đã tới chương cuối trong danh sách đã lưu (chưa cập nhật được).` |
  | trường hợp khác | giữ thông báo cũ |

### Cài đặt
Không đổi nút "Xóa bộ nhớ đệm ảnh bìa" (người dùng không cần).

## Các bước
1. Tách `buildChapterItems`. Hành vi không đổi; chạy lại toàn bộ spec.
2. Thêm nhánh đọc mục lục lưu và `startRefresh`.
3. Thêm dòng trạng thái và phần cập nhật tại chỗ.
4. Đổi `openChapter` sang tìm chương kề lúc cần.
5. Thêm `Debug.verbose` đo thời gian:
   - từ lúc bấm truyện tới lúc hiện danh sách;
   - thời gian tải nền.

## Kiểm tra
- Chạy toàn bộ spec cùng `spec/compile_test.lua`.
- Luồng giao diện được thử trên máy ở phase 7.

## Rủi ro
- **Kết quả về khi view đã đóng:** kiểm tra cờ `_truyenviet_closed`. Mục lục vẫn được lưu.
- **Đổi trang hoặc thứ tự khi đang lấy:** việc cũ bị hủy, lần mở sau sẽ lấy lại.
