---
title: Mở truyện ngay từ mục lục đã lưu, cập nhật chương mới chạy nền; xóa chương đã tải nhưng giữ trong Tủ truyện
status: đã code xong BUILD-1383 2026-10-22 — chờ thử trên máy
created: 2026-10-22
target_build: 3.17.0 (BUILD-1383)
---

# Mở truyện nhanh: mục lục lưu sẵn + cập nhật nền

## Kết quả mong muốn
- Mở một truyện online đã từng mở: danh sách chương hiện ngay (mục tiêu dưới 0,5 giây trên Poke3, hiện tại 1,5–3 giây cộng hộp "Đang tải").
- Dòng đầu danh sách là dòng trạng thái. Plugin lấy chương mới trong tiến trình con nên vẫn cuộn và mở chương được trong lúc chờ.
- Không lấy lại nếu mục lục lưu chưa quá 10 phút.
- Không ghi lại `settings/truyenviet.lua` khi thông tin truyện không đổi (đề xuất 2).
- Quay về Tủ truyện không quét lại dung lượng thư mục chưa thay đổi (đề xuất 3).
- Khi xóa truyện online có thêm lựa chọn "Chỉ xóa chương đã tải, giữ trong Tủ truyện" để giải phóng bộ nhớ mà vẫn đọc tiếp được.

## Ràng buộc
- Lua 5.1/LuaJIT của KOReader; không gọi `coroutine.yield` khi không có coroutine.
- Giữ nguyên bản vá cục bộ `truyenqq.lua` (`force_luasec = true`) và `updater.lua`; không cài OTA đè.
- Tiến trình con chỉ tải và phân tích HTML; không đụng UI, không ghi settings.
- Chỉ cài lên máy sau khi người dùng xác nhận; trước đó sao lưu vào `/sdcard/koreader/backup-<ngày>/before-BUILD-1383`.

## Ngoài phạm vi
- Không đổi cách tải chương, tải ảnh, tìm kiếm, làm mới số chương ở Tủ truyện.
- Không lưu dung lượng thư mục ra file (chỉ nhớ trong phiên chạy KOReader).
- Lần mở đầu tiên của một truyện (chưa có mục lục lưu) vẫn chậm như hiện tại.

## Các phase

| # | Phase | File chính | Phụ thuộc | Trạng thái |
|---|---|---|---|---|
| 1 | [Bộ nhớ mục lục chương](phase-01-chapter-cache.md) | `chapter_cache.lua` (mới) | — | xong |
| 2 | [Chạy tải nền trong tiến trình con](phase-02-background-fetch.md) | `background_fetch.lua` (mới) | — | xong |
| 3 | [Luồng mở truyện và dòng trạng thái](phase-03-browser-flow.md) | `browser.lua` | 1, 2 | xong |
| 4 | [Bỏ ghi Tủ truyện khi không đổi](phase-04-skip-unchanged-favorite.md) | `storage.lua` | — | xong |
| 5 | [Nhớ dung lượng thư mục](phase-05-size-cache.md) | `local_library.lua` | — | xong |
| 6 | [Xóa chương đã tải, giữ trong Tủ truyện](phase-06-delete-downloads-keep-favorite.md) | `local_library.lua`, `browser.lua` | 1, 5 | xong |
| 7 | [Kiểm thử, build, thử trên máy](phase-07-verify-build-device.md) | spec, CHANGELOG, version | 1–6 | spec + build xong; chưa thử trên máy |

## Tiêu chí nghiệm thu
1. Mở truyện TruyenQQ đã có mục lục lưu: danh sách hiện mà không có hộp "Đang tải danh sách chương".
2. Dòng trạng thái lần lượt hiện `⟳ Đang lấy chương mới…` rồi một trong: `Có N chương mới · HH:MM`, `Đã là mới nhất · HH:MM`, `Không cập nhật được · chạm để thử lại`.
3. Trong lúc đang lấy, cuộn trang và mở chương vẫn hoạt động.
4. Có chương mới: danh sách cập nhật tại chỗ, giữ trang đang xem.
5. Mở lại trong vòng 10 phút: không có tiến trình con nào chạy; dòng trạng thái `Cập nhật lúc HH:MM · chạm để làm mới`.
6. Ngoại tuyến có mục lục lưu: hiện mục lục lưu với `Ngoại tuyến · danh sách lưu lúc HH:MM`.
7. "Đọc tiếp" và chuyển chương kế trong trình đọc vẫn đúng, kể cả khi chương kế vừa được phát hiện nhờ cập nhật nền.
8. Mở truyện không có thay đổi: `settings/truyenviet.lua` giữ nguyên thời điểm sửa đổi.
9. Quay về Tủ truyện lần thứ hai trong phiên: không quét lại thư mục chưa đổi.
10. Hộp xóa của truyện online có nút `Chỉ xóa chương đã tải, giữ trong Tủ truyện (N file · dung lượng)`; xóa xong truyện vẫn ở Tủ truyện, lịch sử đọc giữ nguyên, chương mất nhãn "Đã tải" và tải lại được.
11. Thư mục gắn ngoài không bao giờ bị xóa; trong đó chỉ file trùng đúng tên plugin đặt (theo mục lục lưu) mới bị xóa.
12. Toàn bộ spec cũ và mới đều qua; `luajit -b` biên dịch được mọi file; build ra zip.

## Rủi ro chính
- `fork` trên Android khi đang mở trình đọc: plugin đã dùng `Trapper:dismissableRunInSubprocess` (cũng fork) trên Poke3 nên coi là an toàn; vẫn kiểm tra trên máy ở phase 7.
- Nguồn cần đăng nhập/cookie: thay đổi cookie trong tiến trình con bị mất. Lỗi thì dòng trạng thái báo, chạm để tải theo cách cũ (chặn, trong tiến trình chính).
- `string.buffer` không có (LuaJIT quá cũ): tính năng tự tắt, hành vi như hiện tại.
- Xóa chương đã tải làm mất vị trí đọc trong trang (nằm trong `.sdr`); lịch sử chương đã đọc vẫn còn.

## Rollback
Khôi phục thư mục plugin từ bản sao lưu `before-BUILD-1383`. Thư mục `truyenviet/cache/chapters/` có thể xóa an toàn bất cứ lúc nào.

## Quyết định (2026-10-22)
1. Không thêm việc xóa mục lục lưu vào nút "Xóa bộ nhớ đệm ảnh bìa"; nút giữ nguyên.
2. Chấp nhận dung lượng thư mục chỉ nhớ trong phiên KOReader.
3. Thư mục gắn ngoài: chỉ xóa file trùng đúng tên plugin đặt theo mục lục đã lưu.
