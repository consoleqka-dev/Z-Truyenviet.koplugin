# Phase 5 — Nhớ dung lượng thư mục (`local_library.lua`)

## Bối cảnh
- **Đường gọi hiện tại:** `loadFavorites()` gọi `LocalLibrary.annotate`, hàm này gọi `storySize` cho từng truyện, và `storySize` gọi `sizeOf`. `sizeOf` duyệt đệ quy và gọi `stat` cho mọi file.
- **Tần suất:** việc này chạy mỗi lần mở Tủ truyện và mỗi lần quay về Tủ truyện.
- **Quy mô hiện có:** Tủ truyện có 24 mục. Trong đó 14 mục "Trên máy" và 4 mục có `offline_dir`.
- **Vì sao chậm:** `stat` trên `/sdcard` của Android chạy chậm vì đi qua FUSE.
- **Mẫu có sẵn:** `Storage:getOfflineIndex` đã nhớ kết quả trong bộ nhớ, dựa theo thời điểm sửa của thư mục.

## Yêu cầu
- Thêm bảng cục bộ `size_cache[path] = { signature, bytes, subdirs }`, chỉ giữ trong bộ nhớ.
- Thêm `sizeOfCached(path)`. `storySize` dùng hàm này; còn `sizeOf` vẫn dùng cho phần xác nhận xóa.
- Chữ ký của một đường dẫn:

  | Loại | Thành phần chữ ký |
  |---|---|
  | File | kích thước và thời điểm sửa |
  | Thư mục | thời điểm sửa của thư mục, kèm thời điểm sửa của các thư mục con trực tiếp đã ghi nhớ |

  Thêm hoặc xóa thư mục con làm thời điểm sửa của thư mục cha thay đổi, nên không cần liệt kê lại thư mục.
- `LocalLibrary.removeStories` và `LocalLibrary.removeDownloads` (phase 6) xóa các mục cache của đường dẫn bị xóa và của mọi đường dẫn bên trong nó.
- Giới hạn đã biết: file thêm vào ở cấp sâu hơn thư mục con trực tiếp sẽ chỉ được tính sau khi khởi động lại KOReader. Xem câu hỏi mở số 2.

## Các bước
1. Thêm `size_cache` và `sizeOfCached`, rồi sửa `storySize` để dùng nó.
2. Xóa mục cache khi xóa file.
3. Bổ sung `spec/local_history_size_test.lua` với các ca:
   - lần gọi thứ hai không gọi `lfs.dir` (đếm số lần gọi trong mock);
   - đổi thời điểm sửa của thư mục gốc hoặc của thư mục con thì tính lại;
   - sau khi xóa thì không còn dùng giá trị cũ.

## Kiểm tra
`luajit spec/local_history_size_test.lua` chạy qua và các assertion cũ giữ nguyên.

## Rủi ro
Dung lượng hiển thị có thể lệch tạm thời trong trường hợp giới hạn nêu trên. Phần xóa không bị ảnh hưởng vì vẫn dùng `sizeOf`.
