# Phase 2 — Tải nền trong tiến trình con (`background_fetch.lua`)

## Bối cảnh
- **Không dùng được cách không chặn đang có.** Nhánh `AsyncPool` + Copas bỏ qua `force_luasec`, trong khi TruyenQQ bắt buộc dùng tùy chọn này.
- **Không dùng được Trapper.** `Trapper:dismissableRunInSubprocess` có fork tiến trình con, nhưng phải chạy trong coroutine và hiện hộp chờ, nên người dùng không thao tác được trong lúc chờ.
- **Cách làm.** Dùng thẳng `ffi/util` của KOReader, đúng như Trapper làm bên trong:
  - `runInSubProcess(func, true)`;
  - `isSubProcessDone`;
  - `getNonBlockingReadSize`;
  - `readAllFromFD`;
  - `terminateSubProcess`.

  Phần thăm dò kết quả chạy bằng `UIManager:scheduleIn` nên không chặn UI.

## Yêu cầu
- Module mới `truyenviet.koplugin/truyenviet/background_fetch.lua`.
- `BackgroundFetch.run(key, task, on_done, opts)` chạy như sau.
  - **Tiến trình con:** gọi `pcall(task)`, mã hóa kết quả bằng `string.buffer.encode({ ok, result, err })`, rồi `writeToFD(fd, str, true)`.
  - **Tiến trình cha, khi chờ:** thăm dò lần đầu sau 0,25 giây. Cứ sau 4 lần thì nhân đôi khoảng chờ, tối đa 1 giây.
  - **Tiến trình cha, khi có dữ liệu:** đọc hết, giải mã, rồi gọi `on_done(ok, result, err)` qua `UIManager:nextTick`. Sau đó thu dọn tiến trình con để không thành zombie, theo cách `collect_and_clean` của Trapper.
  - **Quá hạn:** hạn chờ là `opts.timeout`, mặc định 45 giây. Hết hạn thì gọi `terminateSubProcess`, thu dọn, rồi gọi `on_done(false, nil, "Quá thời gian chờ")`.
  - **Mỗi lúc chỉ chạy một việc.** Nếu việc cùng `key` đang chạy, chỉ thêm callback vào việc đó. Nếu là `key` khác, hủy việc cũ (callback của việc cũ nhận `false, nil, "cancelled"`) rồi mới chạy việc mới.
  - **Không fork được** (`runInSubProcess` lỗi hoặc không có `string.buffer`): trả về `false` ngay.
- Thêm `BackgroundFetch.isRunning(key)` và `BackgroundFetch.cancel(key)`.
- Tiến trình con không gọi `UIManager` hay `Storage`.

## Các bước
1. Viết `background_fetch.lua`.
2. Viết `spec/background_fetch_test.lua`:
   - Mock `ffi/util`: `runInSubProcess` chạy `func` ngay và ghi kết quả vào một fd giả trong bộ nhớ.
   - Mock `UIManager`: các việc đặt lịch được đưa vào hàng đợi rồi chạy tay từng nhịp.
   - Các ca cần kiểm:
     - chạy thành công;
     - `task` báo lỗi;
     - quá hạn;
     - gọi lại với cùng `key` chỉ fork một lần;
     - gọi với `key` khác thì hủy việc cũ;
     - `runInSubProcess` thất bại.

## Kiểm tra
`luajit spec/background_fetch_test.lua` chạy qua.

## Rủi ro
- **Kết quả lớn hơn bộ đệm pipe (64 KB).** Tiến trình con sẽ chờ ở lệnh ghi cho tới khi bên cha đọc. Bên cha vẫn bắt đầu đọc khi `getNonBlockingReadSize ~= 0`, giống Trapper, nên không bị kẹt.
- **Fork khi đang mở trình đọc.** Android sao chép bộ nhớ theo kiểu copy-on-write. Plugin đã từng fork trên Poke3 khi đóng gói chương; vẫn kiểm tra lại ở phase 7.
