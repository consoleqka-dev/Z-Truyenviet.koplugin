# Phase 4 — Không ghi Tủ truyện khi thông tin không đổi (`storage.lua`)

## Bối cảnh
- **Hiện trạng:** `Storage:updateFavorite` gọi `addFavorite`, và hàm này luôn gọi `persistSetting`. Kết quả là toàn bộ file `settings/truyenviet.lua` (khoảng 42 KB) bị ghi lại sau mỗi lần tải mục lục.
- **Ghi chú:** trường `details` là một bảng.

## Yêu cầu
- **Bỏ qua lần ghi không cần thiết:** trong `addFavorite`, sau khi dựng `record`, so sánh sâu `record` với bản ghi trước (`previous`). Nếu giống nhau thì trả về `true` mà không ghi file. Bước dựng `record` vẫn gồm phần giữ các trường trong `KEPT_FAVORITE_FIELDS` và phần giữ ảnh bìa lớn.
- **Hàm so sánh:** thêm hàm cục bộ `sameValue(a, b)` để so sánh sâu các bảng chỉ chứa dữ liệu.
- **Giữ nguyên:** `mergeFavorites` và `removeFavorites`.

## Các bước
1. Thêm `sameValue` và nhánh bỏ qua trong `addFavorite`.
2. Bổ sung `spec/storage_test.lua` với các ca:

   | Thay đổi | Kết quả mong đợi |
   |---|---|
   | Dữ liệu giống hệt | Không gọi `flush` |
   | `latest_chapter` khác | Có gọi `flush` |
   | `details` là bảng khác đối tượng nhưng cùng nội dung | Không ghi |

## Kiểm tra
- Spec storage chạy qua.
- `favorite_removal_test.lua` cho kết quả như trước.

## Rủi ro
Thấp. Nếu so sánh nhầm "khác" thì plugin vẫn ghi file, đúng như hành vi hiện tại.
