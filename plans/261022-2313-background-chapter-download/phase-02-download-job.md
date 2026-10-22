# Phase 2 — Module DownloadJob

## Thiết kế
`truyenviet/download_job.lua` dựa theo `background_fetch.lua` nhưng dành cho việc dài:

- `start{ key, title, total, progress_path, task(report), cleanup(), on_done(ok, result, err), on_poll(status) }`:
  - fork bằng `ffiutil.runInSubProcess(fn, true)`;
  - trong con: `math.randomseed` lại (tránh trùng tên file tạm với tiến trình con khác), rồi `pcall(task, report)`;
  - `report(status)` ghi `done total downloaded failed` vào `progress_path..".tmp"` rồi `os.rename` (nguyên tử);
  - kết quả `Util.plainData` qua `string.buffer` vào pipe.
- Tiến trình chính thăm dò mỗi 1 s:
  - đọc file tiến độ, gọi `on_poll(status)`, báo cho các `subscribe`;
  - thấy pipe đọc được hoặc con đã thoát thì đọc kết quả và gọi `on_done`.
- Hủy (`cancel(reason)`), dùng chung cho Exit:
  - `terminateSubProcess` (SIGKILL cả nhóm) và `collectLater`;
  - gọi `cleanup()` **đồng bộ** (xóa `.part` ngay, không chờ nextTick vì KOReader có thể thoát trước);
  - xóa file tiến độ; `on_done(false, nil, reason)`.
- Treo: không có tiến độ mới quá `stall_timeout` (600 s) thì tự hủy với lý do "Tải nền bị treo".
- API phụ: `isAvailable()`, `isRunning()`, `status()`, `progressText()` (`"⤓ 5/20"`), `subscribe(fn)`/`unsubscribe(fn)`.
- `Storage:getDownloadProgressPath()` trả `<root>/cache/download.progress`.

## Kiểm tra
`spec/download_job_test.lua` với UIManager đồng hồ ảo và fork giả (theo `background_fetch_test.lua`):
- thành công;
- tiến độ đọc từ file;
- lỗi trong task;
- hủy (gọi `cleanup` đồng bộ, đã kill, `on_done` nhận `"cancelled"`);
- treo;
- không fork được thì trả `false`;
- đang chạy thì từ chối việc thứ hai;
- subscriber nhận cập nhật rồi `nil` khi xong.
