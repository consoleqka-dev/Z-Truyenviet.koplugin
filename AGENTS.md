# Hướng dẫn cho agent: Z-Truyenviet.koplugin

Plugin **Truyện Việt** cho KOReader, viết bằng Lua. Đây là bản hướng dẫn duy
nhất cho mọi agent: `CLAUDE.md`, `GEMINI.md`, `.agents/rules/` và skill
`truyenviet-dev` đều trỏ về file này. Muốn đổi quy trình thì sửa ở đây.

Mọi lệnh dưới đây chạy từ thư mục chứa file này (gốc repo git).

## Cấu trúc thư mục

| Đường dẫn | Nội dung |
| :--- | :--- |
| `truyenviet.koplugin/` | Mã plugin: `main.lua`, `truyenviet/*.lua`, `truyenviet/sources/` (mỗi nguồn truyện một file) |
| `spec/*_test.lua` | Unit test, chạy bằng `luajit` (`spec/parser_spec.lua` cần Busted, không nằm trong lệnh test chuẩn) |
| `scripts/build.sh` | Đóng gói `dist/truyenviet.koplugin.zip` |
| `scripts/*_live_test.lua` | Test gọi website thật, chỉ chạy khi sửa nguồn tương ứng |
| `dist/truyenviet.koplugin.zip` | Bản build. **Có được commit** dù `dist/` nằm trong `.gitignore` (file đã được theo dõi từ trước) |
| `Project_memory.md` | Bài học kinh nghiệm theo từng build, kiến trúc, nợ kỹ thuật |
| `CHANGELOG.md` | Lịch sử phiên bản cho người dùng |
| `docs/` | Tài liệu kiến trúc và nghiên cứu |

## Quy trình bắt buộc sau mỗi thay đổi mã plugin

Làm đủ các bước sau mỗi lần sửa lỗi, tối ưu hay thêm tính năng trong
`truyenviet.koplugin/`, không cần chờ người dùng nhắc.

### 1. Kiểm tra cú pháp

```sh
find truyenviet.koplugin -name "*.lua" -exec luajit -b {} /dev/null \;
```

Lệnh không in gì là đạt.

### 2. Chạy toàn bộ test

```sh
for f in spec/*_test.lua; do luajit "$f" >/dev/null || echo "FAIL $f"; done
```

Không có dòng `FAIL` nào là đạt. Sửa hay thêm hành vi thì thêm hoặc sửa test
trong `spec/` (mock các module KOReader như `ui/uimanager`, `ffi/util`,
`android` bằng `package.preload`, xem `spec/download_job_test.lua`).

### 3. Tăng phiên bản (khi người dùng thấy được thay đổi)

Thay đổi hành vi plugin (`feat`, `fix`) thì tăng patch và tăng BUILD thêm 1,
ví dụ `3.19.2 (BUILD-1407)` thành `3.19.3 (BUILD-1408)`. Chỉ sửa tài liệu,
test hay công cụ thì không tăng. Khi tăng, sửa đồng bộ cả bốn chỗ:

- `truyenviet.koplugin/truyenviet/version.lua`: `return "X.Y.Z (BUILD-N)"`.
- `CHANGELOG.md`: thêm mục mới trên cùng, dạng `## X.Y.Z (BUILD-N) - YYYY-MM-DD`.
- `Project_memory.md`: dòng **Phiên bản hiện tại** ở mục 1.
- `Project_memory.md`: thêm mục `### 4.N. <tiêu đề> (BUILD-N)` ngay trước
  `## 5. Nợ Kỹ thuật`, ghi nguyên nhân, cách sửa và bài học.

### 4. Build

```sh
./scripts/build.sh
```

Kiểm tra `dist/truyenviet.koplugin.zip` vừa được tạo lại.

### 5. Commit và push

```sh
git add -A
git commit -m "<feat|fix|chore|docs>(<phạm vi>): <tóm tắt tiếng Việt> (vX.Y.Z/BUILD-N)"
git push origin main
```

Xem mục Git bên dưới về mẫu commit và lỗi 403 khi push.

## Git

- **Remote:** `origin` là `consoleqka-dev/Z-Truyenviet.koplugin`, nơi push.
  `upstream` là `magicxlll/Z-Truyenviet.koplugin` của tác giả gốc: **không bao
  giờ push lên `upstream`**.
- **OTA đọc từ `upstream`:** `truyenviet/updater.lua` lấy phiên bản mới và file
  zip từ repo `magicxlll`. Push lên `origin` không làm máy người dùng nhận bản
  cập nhật OTA.
- **Nhánh:** commit thẳng lên `main`, không dùng nhánh phụ hay PR.
- **Tác giả commit:** `consoleqka-dev <consoleqka@gmail.com>`, đã đặt sẵn trong
  `~/.gitconfig`.
- **Mẫu commit:** conventional commit, phần tóm tắt viết tiếng Việt. Có tăng
  phiên bản thì thêm `(vX.Y.Z/BUILD-N)` ở cuối, ví dụ
  `feat(download): chỉ giữ màn hình sáng trong lúc tải nền (v3.19.3/BUILD-1408)`.
  Không tăng phiên bản thì bỏ phần này. Không ghi mã kế hoạch hay mã phase vào
  commit.
- **Push bị 403:** máy có hai tài khoản GitHub. Credential helper `osxkeychain`
  có thể đưa ra tài khoản `annguyenbinh-pga`, không có quyền ghi vào repo.
  Push bằng tài khoản `gh` đang dùng thay vì keychain:

  ```sh
  gh auth status   # tài khoản active phải là consoleqka-dev
  git -c credential.helper= -c 'credential.helper=!gh auth git-credential' push origin main
  ```

  Nếu tài khoản active không phải `consoleqka-dev` thì chạy
  `gh auth switch -u consoleqka-dev` trước.

## Cài thử lên máy Android (Boox) qua adb

Máy thử là Boox Poke3 (Android 10, package `org.koreader.launcher`), dữ liệu
KOReader ở `/sdcard/koreader/`.

1. **Đảm bảo không có lượt tải nền đang chạy:** file
   `/sdcard/koreader/truyenviet/cache/download.progress` không tồn tại.
2. **Dừng KOReader và sao lưu bản đang cài:**

   ```sh
   adb shell am force-stop org.koreader.launcher
   adb shell 'mkdir -p /sdcard/koreader/backup-YYYY-MM-DD && cp -r /sdcard/koreader/plugins/truyenviet.koplugin /sdcard/koreader/backup-YYYY-MM-DD/'
   ```

3. **Đẩy bản build:**

   ```sh
   rm -rf /tmp/tv-deploy && mkdir /tmp/tv-deploy && unzip -q dist/truyenviet.koplugin.zip -d /tmp/tv-deploy
   adb push /tmp/tv-deploy/truyenviet.koplugin/. /sdcard/koreader/plugins/truyenviet.koplugin/
   ```

   `adb push` không xóa file cũ trên máy. Nếu bản mới xóa hay đổi tên file thì
   xóa thư mục plugin trên máy (sau khi đã sao lưu) rồi mới push.

4. **Mở lại và kiểm tra phiên bản:**

   ```sh
   adb shell monkey -p org.koreader.launcher -c android.intent.category.LAUNCHER 1
   adb shell cat /sdcard/koreader/plugins/truyenviet.koplugin/truyenviet/version.lua
   ```

### Log và file cần biết trên máy

| Đường dẫn / lệnh | Nội dung |
| :--- | :--- |
| `/sdcard/koreader/truyenviet/truyenviet-debug.txt` | Log của plugin (`Debug.write`), có giờ địa phương |
| `/sdcard/koreader/crash.log` | Log lỗi của KOReader |
| `adb logcat -d -b all -v time` | Log hệ thống. KOReader ghi với tag `KOReader`; giấc ngủ CPU hiện là `suspend entry` |
| `/sdcard/koreader/settings.reader.lua` | Cài đặt KOReader. Chỉ sửa khi KOReader đã dừng, sao lưu trước |
| `/sdcard/koreader/truyenviet/<nguồn>/<truyện>/` | Chương đã tải (`.cbz`, `.html`) và thư mục `.sdr` lưu tiến độ đọc |

### Điều khiển giao diện qua adb

- Chụp màn hình: `adb exec-out screencap -p > /tmp/s.png`.
- Mở menu KOReader: `adb shell input keyevent KEYCODE_MENU`. Vuốt từ mép trên
  sẽ mở Control Center của Boox, không phải menu KOReader.
- Kiểm tra màn hình có bị giữ sáng không:
  `adb shell 'dumpsys window windows | grep -A30 "koreader.launcher.MainActivity}:" | grep -m1 "fl="'`
  (có `KEEP_SCREEN_ON` là đang giữ) và `adb shell dumpsys power | grep "Wake Locks"`.
- Không tự bật Wi-Fi hay đổi cài đặt hệ thống của máy; hỏi người dùng.

## Nguyên tắc viết mã

- **Môi trường:** Lua 5.1/LuaJIT của KOReader. Không dùng tính năng của Lua
  5.4+ (ví dụ gán lại biến lặp trong vòng lặp generic `for`).
- **An toàn coroutine:** không gọi `coroutine.yield()` trực tiếp mà không kiểm
  tra `if coroutine.running() then coroutine.yield(...) end`.
- **Tiến trình con tải nền** (`truyenviet/download_job.lua`): không đụng UI,
  settings hay coroutine của tiến trình chính.
- **Sắp xếp chương:** so sánh số chương dạng số (`a.number < b.number`) trước,
  rồi mới fallback sang `Util.naturalCompare`.
- **Giới hạn RAM máy e-ink:** không log chuỗi nhị phân lớn vào file debug; giới
  hạn prefetch ảnh bìa tối đa 10 ảnh.
- **Mạng:** dùng `truyenviet/http_client.lua` để có fallback `curl` khi lỗi SSL
  trên máy cũ.
- Hướng dẫn thêm hoặc sửa nguồn truyện: `.agents/skills/truyenviet-dev/SKILL.md`.
