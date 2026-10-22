# Phase 1 — Chế độ tiến trình con cho ChapterDownloader

## Bối cảnh
`ChapterDownloader:download` đang `coroutine.yield` vô điều kiện ở nhánh async và ghi `G_reader_settings` khi chương đầu xong. Trong tiến trình con, `yield` sẽ nhảy về mã của tiến trình chính đã bị sao chép, còn ghi settings sẽ ghi đè file của tiến trình chính.

## Yêu cầu
- Thêm tham số `opts`: `opts.subprocess` (bool) và `opts.on_progress(status)`.
- Khi `opts.subprocess`:
  - không `yield`;
  - chờ Copas bằng `copas.step()` có chặn;
  - không `addDocument`/`flush`.
- Kết quả có thêm `first_path` (chương đầu tiên tải được) để tiến trình chính `addDocument`.
- `on_progress` nhận `{ done, total, downloaded, failed }` sau mỗi chương (cả chương bỏ qua).
- Mọi `yield` còn lại đều kiểm tra `coroutine.running()`.

## File
- `truyenviet/chapter_downloader.lua`

## Kiểm tra
- `spec/chapter_downloader_test.lua`: chế độ subprocess không yield (chạy trong coroutine vẫn chết ngay sau một lần resume), `on_progress` đếm đủ, có `first_path`, không gọi `G_reader_settings`.
