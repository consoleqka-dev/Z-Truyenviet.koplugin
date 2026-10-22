# Phase 4 — Kiểm thử, build, thử trên máy

## Tự động (đã chạy)
- `for f in spec/*_test.lua; do luajit "$f"; done` — 36/36 qua, gồm `download_job_test` và `download_chapters_flow_test` mới.
- `find truyenviet.koplugin -name "*.lua" -exec luajit -b {} /dev/null \;`
- `./scripts/build.sh` → `dist/truyenviet.koplugin.zip`.
- `version.lua` 3.18.0 (BUILD-1392), `CHANGELOG.md`, `Project_memory.md`.

## Trên máy (chờ người dùng xác nhận mới cài)
1. Sao lưu plugin hiện tại vào `/sdcard/koreader/backup-<ngày>/before-BUILD-1392`.
2. TruyenQQ: tải 20 chương. Trong lúc tải:
   - cuộn danh sách;
   - mở một truyện khác đã tải, lật trang;
   - xem thanh trạng thái `⤓ x/y`.
3. Menu → Truyện Việt → `⤓ Hủy tải nền`: không còn `.part` trong thư mục truyện.
4. Tải lại rồi Exit giữa chừng: KOReader thoát ngay; mở lại, các chương xong vẫn còn.
5. Nguồn chữ async (vd. docln/metruyen): tải 10 chương, kiểm tra hộp hỏi gộp file khi xong.
6. Xem `truyenviet/debug.log` có lỗi `[Tải nền]` không.
