---
title: Tải chương trong tiến trình con — giao diện không đơ, Hủy/Exit có tác dụng ngay, vừa tải vừa đọc truyện khác
status: đã code xong BUILD-1392 2026-10-22 — chờ thử trên máy
created: 2026-10-22
target_build: 3.18.0 (BUILD-1392)
---

# Tải chương nền bằng tiến trình con (phương án B)

## Nguyên nhân (đã kiểm chứng trong mã)
- `runInBackground` chạy `ChapterDownloader:download` trong coroutine của tiến trình chính. Coroutine chỉ nhường UI **giữa hai chương**; trong một chương, `getChapter` đồng bộ (TruyenQQ `force_luasec`, timeout 15/60 s, 3 lần thử) và vòng `copas.step()` của `buildComic` (tới 300 s) chặn hẳn giao diện.
- `FloatingProgress` không phải toast nhưng bị `bringToFront` liên tục, nên luôn là cửa sổ trên cùng. `UIManager:sendEvent` giao chạm cho cửa sổ trên cùng, cửa sổ này bỏ qua chạm, và danh sách bên dưới không `is_always_active`, nên **mọi chạm bị nuốt**.
- KOReader chỉ thoát khi ngăn xếp cửa sổ rỗng. `FloatingProgress` vẫn nằm trong ngăn xếp nên Exit không thoát được, và việc tải không có cờ hủy.

## Kết quả mong muốn
- Bấm tải N chương: việc tải chạy trong tiến trình con. Giao diện chính vẫn cuộn, mở chương và đọc bình thường, kể cả truyện khác đã tải.
- Ô tiến độ nhỏ góc dưới (`⤓ Tên truyện 5/20`) chỉ hiện chữ, không chặn chạm, tự ẩn khi đang mở sách.
- Trong trình đọc, thanh trạng thái có thêm `⤓ 5/20`, cập nhật khi xong mỗi chương.
- Hủy được ngay từ menu Truyện Việt (`⤓ Hủy tải nền (5/20)`), có ở cả trình đọc lẫn File manager. Bấm tải khi đang có việc thì hiện hộp hỏi hủy.
- Exit/Restart KOReader: dừng tiến trình con, xóa `.part`, đóng ô tiến độ, KOReader thoát ngay.
- Xong việc: cập nhật danh sách nếu còn mở. Đang đọc thì chỉ hiện thông báo nhỏ; không đọc thì hỏi gộp file như cũ.

## Ràng buộc
- Tiến trình con không đụng UI, không ghi settings, không gọi `coroutine.yield`, không dùng JNI/NetworkMgr. Tiến trình chính làm `addDocument`.
- Giữ nguyên bản vá cục bộ `truyenqq.lua`/`updater.lua`; không cài OTA đè.
- Mỗi lúc một việc tải nền.
- Không có `string.buffer` hoặc không fork được thì chạy theo cách cũ (coroutine) và ô tiến độ cũng là toast.
- Chỉ cài lên máy sau khi người dùng xác nhận; trước đó sao lưu vào `/sdcard/koreader/backup-<ngày>/before-BUILD-1392`.

## Ngoài phạm vi
- Không xếp hàng nhiều truyện (bấm tải truyện thứ hai thì hỏi hủy việc đang chạy).
- `downloadAsBundle`, tải trước chương kế (prefetch), mở chương và gộp file giữ nguyên.
- Không giữ máy thức trong lúc tải (autosuspend như hiện tại).

## Các phase

| # | Phase | File chính | Phụ thuộc | Trạng thái |
|---|---|---|---|---|
| 1 | [Chế độ tiến trình con cho ChapterDownloader](phase-01-downloader-subprocess-mode.md) | `chapter_downloader.lua` | — | xong |
| 2 | [Module DownloadJob](phase-02-download-job.md) | `download_job.lua` (mới), `storage.lua` | 1 | xong |
| 3 | [Nối vào giao diện](phase-03-ui-wiring.md) | `browser.lua`, `reader.lua`, `main.lua` | 2 | xong |
| 4 | [Kiểm thử, build, thử trên máy](phase-04-verify-build-device.md) | spec, CHANGELOG, version | 1–3 | spec + build xong; chưa thử trên máy |

## Tiêu chí nghiệm thu
1. Đang tải 20 chương TruyenQQ: cuộn danh sách, mở chương đã tải, lật trang đều phản hồi trong khoảng 1 s.
2. Đang đọc một truyện khác: thanh trạng thái hiện `⤓ x/y`, tăng dần; không có hộp nào bật lên giữa chừng.
3. Menu → Truyện Việt → `⤓ Hủy tải nền`: tiến trình con dừng trong 1 s, không còn `.part`, các chương đã xong vẫn còn.
4. Exit khi đang tải: KOReader thoát ngay, không còn tiến trình con.
5. Tải xong khi không đọc: danh sách cập nhật nhãn "Đã tải" và hỏi gộp file như cũ.
6. Lỗi một vài chương: thông báo cuối liệt kê tối đa 5 lỗi như cũ.
7. Toàn bộ spec cũ và mới đều qua; `luajit -b` biên dịch được mọi file; build ra zip.

## Rủi ro chính
- Tiến trình con thừa hưởng trạng thái Copas của tiến trình chính (luồng tải trước còn dở có thể chạy tiếp trong con). Kết quả bị bỏ, không ghi settings; chấp nhận.
- Bị giết giữa lúc `replaceFile` chép qua thiết bị khác (`/tmp` → thẻ nhớ) có thể để lại file chưa đủ. Android không có `/tmp` nên đi nhánh `rename` nguyên tử.
- Cookie/đăng nhập thay đổi trong tiến trình con bị mất (giống tải mục lục nền đã có).
- Một chương kẹt quá 10 phút không có tiến độ: tự hủy và báo "Tải nền bị treo".
