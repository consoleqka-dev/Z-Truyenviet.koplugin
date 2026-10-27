## 3.18.12 (BUILD-1404) - 2026-10-27

### Bug Fixes
- **Về menu Truyện Việt mà sách vẫn mở bên dưới**: file "Trên máy" (và chương KOReader tự mở tiếp khi đọc hết file trước, sách mở từ File manager hay Lịch sử của KOReader) không được tính là chương của plugin, nên trang chủ mở đè lên sách còn đang chạy, còn `Quay lại Truyện Việt` không làm gì. Giờ mở trang chủ (nút trên thanh tiêu đề, mục `Mở Truyện Việt`, cử chỉ) hoặc `Danh sách chương` sẽ đóng mọi sách đang mở trước (KOReader lưu vị trí đọc). `Quay lại Truyện Việt` với sách ngoài plugin đóng sách rồi mở trang chủ; với chương của plugin vẫn về màn trước như cũ. Sách không đóng được (KOReader hỏi lưu thay đổi) thì chỉ thử một lần rồi vẫn mở trang chủ.

### Tests
- `spec/single_window_test.lua`: trang chủ đóng cả sách mở ngoài plugin, chỉ thử đóng một lần.
- `spec/reader_test.lua`: `returnToPlugin` đóng sách ngoài plugin; `Quay lại Truyện Việt` mở trang chủ với sách ngoài plugin, về màn trước với chương của plugin.
- `spec/main_menu_test.lua`: `Danh sách chương` đóng sách ngoài plugin trước khi mở.

## 3.18.11 (BUILD-1403) - 2026-10-26

### Bug Fixes
- **Danh sách tập của thư mục "Trên máy" không hiện tiến độ đọc**: các file đã đọc xong vẫn để trống, chỉ file đọc cuối có chữ `Đang đọc`. Giờ mỗi file hiện phần trăm KOReader đã lưu (`100%` khi đọc xong), file đọc cuối hiện `Đang đọc · N%`. File chưa mở vẫn để trống. Tiến độ chỉ đọc cho các dòng đang hiện trên trang.

### Tests
- `spec/chapter_list_flow_test.lua`: thư mục "Trên máy" hiện `100%` cho file đã đọc, `Đang đọc · 20%` cho file đọc cuối, để trống file chưa mở.

## 3.18.10 (BUILD-1402) - 2026-10-25

### Bug Fixes
- **"Thêm truyện trên máy" không thấy sách trên Kindle/Kobo**: khi chưa đặt thư mục thư viện và KOReader chưa có thư mục chính (home), plugin luôn quét `/sdcard/Books`, thư mục chỉ có trên Android. Giờ plugin quét thư mục đầu tiên có trên máy trong `/sdcard/Books`, `/mnt/us/documents` (Kindle), `/mnt/onboard` (Kobo). Thư mục đặt trong cài đặt và thư mục chính của KOReader vẫn được ưu tiên như trước.

### Tests
- `spec/library_import_test.lua`: chọn thư mục mặc định cho Android, Kindle, Kobo; `/sdcard/Books` thắng khi có; file trùng tên `documents` không tính; không có thư mục nào thì trả `/sdcard/Books`; cài đặt và `home_dir` vẫn được ưu tiên.

## 3.18.9 (BUILD-1401) - 2026-10-25

### Bug Fixes
- **Mục "Trên máy" báo mất sau khi đổi tên hoặc dời file**: Tủ truyện và Lịch sử đọc lưu đường dẫn tuyệt đối, nên đổi tên file (ví dụ bỏ số đầu tên một PDF) làm mục đó hiện `missing`. Giờ có hai lớp sửa:
  - Đổi tên hoặc dời file/thư mục trong File manager của KOReader (đổi tên, cắt–dán, dán nhiều file): mục trong Tủ truyện, Lịch sử đọc, bìa và thư mục liên kết của truyện online đi theo ngay. Tên mục đổi theo tên file mới, trừ khi bạn đã tự đặt tên khác.
  - File bị đổi tên ngoài KOReader (máy tính, app khác): khi mở Tủ truyện hoặc Lịch sử đọc, plugin tìm trong thư mục cũ file có cùng dấu vân tay nội dung (partial md5). Mục cũ chưa có dấu vân tay thì nhận khi có đúng một file cùng đuôi mà tên chứa tên cũ (hoặc ngược lại), ví dụ `713574649-How-to….pdf` → `How-to….pdf`. "Vol 1" không khớp nhầm "Vol 10". Mục thư mục không được dò.

### Tests
- `spec/local_relocate_test.lua`: đổi tên file (tên, bìa, cache bìa, lịch sử), giữ tên tự đặt, đổi tên thư mục bằng đường dẫn thật `/storage/emulated/0`, dời file, đường dẫn không liên quan; tìm lại bằng md5 và bằng tên, các trường hợp không đoán (hai ứng viên, "Vol 1"/"Vol 10", file đã có mục, mục thư mục), không dò lại thư mục không đổi; móc ReadHistory của KOReader.

## 3.18.8 (BUILD-1400) - 2026-10-25

### Bug Fixes
- **Nút "▶ Tiếp tục" ở trang chủ vào thẳng mục lục thay vì hỏi đọc tiếp**: nút này (và lệnh `Tiếp tục đọc`) gọi `openHistoryItem`, hàm này với truyện online chỉ mở trang truyện mà không truyền chương đọc cuối; hộp "Đọc tiếp: …?" chỉ có trong Lịch sử đọc. Hộp hỏi được tách thành `Browser:confirmContinue` và dùng chung cho Lịch sử đọc, nút Tiếp tục ở trang chủ và lệnh Tiếp tục đọc: `Đọc tiếp` mở đúng chương đọc cuối, `Mục lục` (hoặc `Danh sách tập` với thư mục trên máy) mở danh sách chương. Trang chủ chỉ đóng sau khi đã chọn.

### Features & Improvements
- **Tìm ảnh bìa lớn cho các truyện đã chọn**: màn chọn nhiều ở Tủ truyện (biểu tượng ✓, nay tên là `Chọn truyện`) thêm mục `Tìm ảnh bìa lớn cho N truyện đã chọn` cạnh `Xóa N truyện đã chọn`. Mục này bỏ bìa cũ như nút `Tìm lại ảnh bìa lớn` của từng truyện, tìm lại, lưu một lần, báo số bìa tìm được rồi quay về Tủ truyện.
- Bỏ nút `Tìm lại bìa lớn cho Tủ truyện` ở trang chủ; dùng `Chọn tất cả` rồi `Tìm ảnh bìa lớn…` để làm việc tương tự.

### Tests
- `spec/chapter_list_flow_test.lua`: hộp đọc tiếp ở Lịch sử và trang chủ (mở chương đọc cuối, `Mục lục` mở danh sách chương, trang chủ chỉ đóng sau khi chọn), lỗi nguồn đã gỡ; tìm bìa cho truyện đã chọn (không chọn/ngoại tuyến thì không tìm, chỉ tìm truyện đã chọn, xóa bìa cũ của truyện online, lưu và quay về Tủ truyện).

## 3.18.7 (BUILD-1399) - 2026-10-25

### Bug Fixes
- **Số chương mới nhất không tăng khi có chương mới**: đọc hết chương 56, bấm sang chương sau và plugin tải chương 57 vừa ra, nhưng Lịch sử đọc vẫn hiện `Chương 56`. Nguyên nhân: `latest_chapter` chỉ lấy từ dữ liệu tìm kiếm/nguồn, mục lục làm mới không nâng nó. Giờ `Storage.raiseLatestChapter` nâng số này theo chương lớn nhất trong mục lục (mở từ bản lưu, tải mới, làm mới nền) và theo chương đang đọc khi ghi Lịch sử. Tủ truyện được cập nhật cùng. Số chỉ tăng, không giảm; nguồn chỉ báo `N chương` giữ nguyên định dạng. Mục Lịch sử lưu từ trước cũng hiện đúng ngay khi mở.

### Features & Improvements
- Dòng `Đang đọc` đổi `Chapter`/`Chap` ở đầu tên chương thành `Chương`, ví dụ `Đang đọc: Chương 57 · 80%`.

### Tests
- `spec/local_history_size_test.lua`: nâng số chương ở Lịch sử và Tủ truyện, không giảm khi đọc chương cũ, bỏ qua nguồn chỉ có tổng số chương và chương không có số.
- `spec/chapter_list_flow_test.lua`: làm mới nền và màn Lịch sử gọi nâng số chương.
- `spec/story_results_test.lua`: đổi `Chapter`/`Chap` thành `Chương`, chỉ thay nguyên từ.

## 3.18.6 (BUILD-1398) - 2026-10-25

### Features & Improvements
- **Lịch sử đọc hiện tiến độ chương đọc cuối**: dòng thứ ba thành `Đang đọc: Chapter 84 · 80%`. Tiến độ lấy cùng nguồn với nhãn `Đã tải · %` trong mục lục: chương trong tệp trọn bộ dùng tiến độ riêng của chương, chương lẻ và file "Trên máy" dùng tiến độ của cả file. Chương chưa tải hoặc chưa mở thì chỉ hiện tên chương, không hiện phần trăm giả.

### Tests
- `spec/story_results_test.lua`: định dạng `Đang đọc: … · N%`, vẫn hiện `0%`.
- `spec/chapter_list_flow_test.lua`: Lịch sử đọc gắn tiến độ cho file trên máy và chương online đã tải; bỏ qua chương chưa tải hoặc chưa có dữ liệu đọc.

## 3.18.5 (BUILD-1397) - 2026-10-25

### Features & Improvements
- **Nguồn MangaFreak (`ww3.mangafreak.me`, truyện tranh tiếng Anh)**: đưa vào repo nguồn đã chạy trên máy từ 23/10 nhưng trước đó chỉ có trên máy, chưa có trong git. Hỗ trợ tìm kiếm, Phổ biến, Mới cập nhật, Thể loại, Hoàn thành (chỉ trang đầu, do giới hạn của trang nguồn) và tải chương. Ảnh chương bị từ chối nếu thiếu trang hoặc sai thứ tự.

### Tests
- `spec/mangafreak_test.lua`: danh sách truyện và phân trang, mục lục (bỏ link lặp), ảnh chương (đủ trang, đúng thư mục, đúng thứ tự), tìm kiếm.
- `spec/parser_test.lua`: registry có 24 nguồn dựng sẵn.

## 3.18.4 (BUILD-1396) - 2026-10-25

### Features & Improvements
- **Lịch sử đọc hiện chương đọc cuối**: mỗi truyện có thêm dòng thứ ba `Đang đọc: <tên chương>` (mục "Trên máy" hiện tên file đang đọc). Trước đây tên chương chỉ xuất hiện trong hộp "Đọc tiếp".
- Đọc tệp trọn bộ mở từ Truyện Việt: lật sang chương khác thì Lịch sử đọc ghi chương đó. Nhờ vậy `Đang đọc` và `Đọc tiếp` theo đúng trang đang đọc, không dừng ở chương đã bấm lúc mở tệp.

### Tests
- `spec/story_results_test.lua`: dòng `Đang đọc` và thứ tự ưu tiên so với dòng dung lượng của Tủ truyện.
- `spec/reader_test.lua`: báo chương khi lật trang qua ranh giới chương trong tệp trọn bộ, mỗi chương chỉ báo một lần, không báo khi mở tệp mà không có chương đích.

## 3.18.3 (BUILD-1395) - 2026-10-23

### Features & Improvements
- Chương đã tải nhưng chưa mở/chưa có dữ liệu đọc hiện `Đã tải · -` thay vì `0%`, gồm các chương chưa đọc trong tệp trọn bộ. Chương có tiến độ đã lưu bằng 0 hoặc làm tròn về 0 vẫn hiện `0%` để phân biệt với chương chưa mở.

### Tests
- Phân biệt dữ liệu đọc thiếu/hỏng với tiến độ 0 hợp lệ; giữ tiến độ riêng của chương trong tệp gộp và kiểm tra nhãn trên danh sách chương khi mở lại.

## 3.18.2 (BUILD-1394) - 2026-10-23

### Features & Improvements
- Danh sách chương hiện tiến độ đọc cạnh trạng thái tải, ví dụ `Đã tải · 42%`. Chương đã tải nhưng chưa có dữ liệu đọc hiện `0%`. Tiến độ được lấy từ metadata KOReader khi mở lại mục lục, không mở/render từng chương.
- Với tệp trọn bộ có mục lục chương, lưu tiến độ riêng cho từng chương được mở từ Truyện Việt. Chỉ các chương thực sự đi qua mới được ghi; nhảy đến chương sau không đánh dấu các chương bị bỏ qua là đã đọc hết. Với metadata cũ chỉ có trang đọc cuối, khôi phục được phần trăm của chương chứa trang đó.

### Bug Fixes
- Bấm Next vượt trang cuối của chương cuối trong danh sách hiện có sẽ đóng reader và quay về danh sách chương của đúng bộ đó, thay vì chỉ hiện thông báo hết chương. Áp dụng cả khi mục lục đang làm mới hoặc ngoại tuyến; chuyển chương, phân trang và điều hướng trong tệp trọn bộ giữ nguyên.

### Tests
- `spec/reading_progress_test.lua`: tiến độ CBZ/HTML, metadata thiếu/hỏng, cache theo danh sách, khôi phục trang cũ và lưu riêng chương trong tệp trọn bộ.
- `spec/end_of_series_test.lua`: 23 trường hợp chạy Browser/Reader thật với adapter KOReader, gồm đóng reader trước khi hiện mục lục, Next liên tiếp, danh sách tăng/giảm, phân trang, tệp trọn bộ, ghi tiến độ sau khi nhảy tới chương và chương trước.
- `spec/chapter_list_flow_test.lua`: cập nhật kỳ vọng quay về mục lục ở cuối danh sách đang làm mới/ngoại tuyến.

## 3.18.1 (BUILD-1393) - 2026-10-23

### Features & Improvements
- **Nhận tệp trọn bộ**: một tệp truyện không có số chương trong tên nhưng có mục lục tự tạo trong `.sdr` (KOReader `handmade_toc`, ví dụ `Diamond-No-Ace-tron-bo.cbz`) được coi là chứa các chương "Chương X" trong mục lục.
  - Tủ truyện đếm các chương này thay vì đếm tệp là một chương. Số chương đã tải vượt số chương mới nhất (do có chương lẻ 411.1, 411.2...) thì hiện `Đã tải hết`.
  - Danh sách chương ghi `Đã tải` cho chương trong tệp trọn bộ. Tải hàng loạt, tải nền và tải trước bỏ qua các chương đó.
  - Bấm chương mở tệp trọn bộ ở trang đầu chương. Nếu trang đọc dở đã nằm trong chương đó thì giữ nguyên trang. `Chương tiếp theo` / `Chương trước` lật trang ngay trong tệp đang mở, hết tệp thì sang chương online như cũ.
  - `Xóa bản đã tải` và tự dọn chương cũ chỉ áp dụng cho file lẻ, không bao giờ đụng tệp trọn bộ.
- Chương CBZ không còn chèn ảnh bìa nhỏ làm trang đầu (bị phóng mờ).

### Tests
- `spec/offline_chapters_test.lua`: đếm chương của tệp trọn bộ, tệp chỉ có một chương trong mục lục vẫn là file thường, đường dẫn và trang của chương, chương tại một trang, đọc lại mục lục khi sidecar đổi.
- `spec/reader_test.lua`: nhảy trang sau khi KOReader khôi phục trang đọc dở, giữ trang đang đọc trong cùng chương, lật trang tại chỗ, không hiện vị trí theo thư mục cho tệp trọn bộ.
- `spec/story_results_test.lua`: `Đã tải 412/412` và `Đã tải hết`.

## 3.18.0 (BUILD-1392) - 2026-10-22

### Features & Improvements
- **Tải chương chạy nền thật sự**: tải chương (danh sách chương, tải theo khoảng) nay chạy trong tiến trình con. Giao diện không còn đứng trong lúc tải; vẫn cuộn danh sách, mở truyện khác và lật trang được. Mỗi lúc chỉ tải nền một truyện. Bấm tải truyện khác khi đang bận thì hiện hộp `Hủy tải nền` / `Đóng`.
- **Tiến độ khi đang đọc**: đang mở sách thì ô tiến độ nổi được ẩn. Tiến độ hiện trên thanh trạng thái của reader (`⤓ 5/20`), tải xong chỉ hiện báo nhỏ, không bật hộp thoại. Không đọc thì giữ hộp hỏi gộp file như cũ.
- **Hủy tải nền**: mục `⤓ Hủy tải nền (x/y)` trong menu Truyện Việt của KOReader. Hủy thì dừng tiến trình con và xóa file `.part` ngay.
- Tiến trình con không có tiến độ mới quá 10 phút thì tự hủy. Máy không fork được thì tải theo cách cũ.

### Bug Fixes
- **Ô tiến độ nổi nuốt mọi lần chạm**: ô tiến độ là cửa sổ thường và liên tục được đưa lên trên, nên mọi lần chạm (kể cả nút Hủy, menu) đều tới nó và bị bỏ. Nay nó là toast: luôn nằm trên nhưng không chặn chạm.
- **Exit không thoát được khi đang tải**: KOReader chỉ thoát khi không còn cửa sổ nào; ô tiến độ còn trong ngăn xếp nên Exit bị treo. Nay Exit/Restart đóng ô tiến độ và hủy việc tải nền (từ reader và từ trình duyệt file).

### Tests
- `spec/download_job_test.lua` (mới): thành công, tiến độ đọc từ file, lỗi trong task, đang bận, hủy (dọn `.part` đồng bộ), treo, không có kết quả, không fork được.
- `spec/download_chapters_flow_test.lua` (mới): ô tiến độ là toast, ẩn khi đang đọc, hộp hỏi hủy khi bận, xử lý xong/hủy/Exit/lỗi, Exit đóng ô tiến độ, dự phòng cách cũ.
- `spec/chapter_downloader_test.lua`: chế độ tiến trình con không yield, báo tiến độ mọi chương, không ghi settings.
- `spec/reader_test.lua`: tiến độ trên thanh trạng thái, Exit/Restart hủy việc tải nền.

## 3.17.8 (BUILD-1391) - 2026-10-22

### Bug Fixes
- **Exit về màn Lịch sử thay vì thoát KOReader**: khi KOReader khởi động vào Lịch sử (hoặc đang mở Bộ sưu tập) rồi Truyện Việt mở một chương, danh sách đó vẫn nằm dưới reader. Exit chỉ đóng reader, còn danh sách đó nên KOReader không thoát mà hiện Lịch sử. KOReader tự đóng Lịch sử/Bộ sưu tập khi mở sách từ đó; nay Truyện Việt cũng đóng chúng trước khi mở chương, nên Exit thoát hẳn. Đóng chương rồi đóng Truyện Việt sẽ về trình duyệt file thay vì Lịch sử.

### Tests
- `spec/reader_test.lua`: mở chương đóng Lịch sử và Bộ sưu tập (của trình duyệt file và của reader) trước khi mở reader, kể cả khi chuyển chương; không có danh sách nào cũng không lỗi.

## 3.17.7 (BUILD-1390) - 2026-10-22

### Bug Fixes
- **Exit không thoát KOReader khi đang đọc chương của Truyện Việt**: Exit (hay Restart) trong menu KOReader chỉ đóng reader rồi để KOReader tự thoát khi không còn cửa sổ nào. Plugin lại mở danh sách chương khi reader đóng, nên KOReader quay về danh sách chương thay vì thoát. Nay khi KOReader Exit/Restart, plugin kết thúc phiên đọc mà không mở lại Truyện Việt. Đóng chương bình thường vẫn quay về danh sách chương như cũ.
- **Log khi reader đóng**: mỗi lần reader đóng ghi một dòng vào `truyenviet-debug.txt` kèm lý do (KOReader Exit/Restart, Truyện Việt đóng chương, quay về Truyện Việt, chương cũ khi chuyển chương).

### Tests
- `spec/reader_test.lua`: Exit và Restart không mở lại danh sách chương và không chặn sự kiện của KOReader; reader mở sau đó vẫn quay về plugin khi đóng.

## 3.17.6 (BUILD-1389) - 2026-10-22

### Bug Fixes
- **Hết chương bấm next không sang chương tiếp**: mở một chương từ Truyện Việt khi chương khác vẫn đang mở (ví dụ đang đọc truyện A rồi mở chương của truyện B) thì reader cũ đóng sau khi chương mới đã mở và tắt phiên đọc của plugin. Từ đó hết chương hay chọn "Chương tiếp theo" đều không làm gì. Nay mỗi lần mở chương là một phiên riêng; reader cũ đóng muộn không còn tắt phiên mới hay mở lại màn Truyện Việt.
- **Nhiều cửa sổ Truyện Việt chồng lên nhau**: mỗi lần mở Truyện Việt (menu, cử chỉ, nút trên thanh tiêu đề, tự mở khi khởi động) trước đây thêm một lớp cửa sổ mới. Nay mở trang chủ thì đóng hết cửa sổ Truyện Việt cũ (không mở lại màn trước của chúng). Nếu đang đọc chương mở từ Truyện Việt thì chương được đóng trước (KOReader vẫn lưu vị trí đọc) rồi mới mở trang chủ. Sách mở ngoài plugin không bị đóng.

### Tests
- `spec/reader_test.lua`: chuyển chương khi reader còn mở, hết chương rồi sang chương tiếp, đóng reader bình thường vẫn quay về plugin.
- `spec/single_window_test.lua`: mở trang chủ nhiều lần chỉ còn một cửa sổ, cửa sổ cũ không chạy callback quay về, đóng chương của plugin trước khi mở trang chủ, không đụng sách mở ngoài plugin.

## 3.17.5 (BUILD-1388) - 2026-10-22

### Features & Improvements
- **Mở Truyện Việt khi khởi động KOReader**: tuỳ chọn mới trong menu Truyện Việt của KOReader (mặc định tắt). Plugin tự mở Truyện Việt một lần mỗi lần KOReader khởi động, nằm trên màn Lịch sử / Yêu thích nếu KOReader mở vào đó. Không dùng profile "on KOReader start" vì khi KOReader khởi động vào màn Lịch sử, sự kiện của profile chỉ tới màn Lịch sử và bị bỏ qua.
- **"Chương X/Y" khi mở chương từ bất kỳ đâu**: file nằm trong thư mục tải của plugin (`truyenviet/<nguồn>/<truyện>/`) mở từ Lịch sử, trình duyệt file của KOReader... hiện vị trí trong số chương đã tải của truyện đó. Mở từ danh sách chương của Truyện Việt vẫn hiện vị trí trên tổng số chương của mục lục như BUILD-1387.

### Tests
- `spec/open_on_start_test.lua`: tuỳ chọn tắt mặc định, chỉ mở một lần mỗi lần khởi động, công tắc trong menu.
- `spec/chapter_position_test.lua`: `ChapterPosition.downloadFolder` (đúng cấp thư mục, bỏ `cache`, `/sdcard` và `/storage/emulated/0`).
- `spec/reader_test.lua`: vị trí theo số chương đã tải và thứ tự ưu tiên với vị trí từ danh sách chương.

## 3.17.4 (BUILD-1387) - 2026-10-22

### Features & Improvements
- **Vị trí chương trên thanh trạng thái**: khi mở chương từ danh sách chương của Truyện Việt, thanh trạng thái hiện "Chương 14/20" theo thứ tự đọc (chương cũ nhất là 1, kể cả khi mục lục xếp mới nhất trước). Mục lục chia nhiều trang hiện thêm "· trang 2/5" vì chỉ biết số chương của trang đang mở. File trong thư mục "Trên máy" hiện "Tập 3/12" theo số file đọc được trong thư mục. Số tự cập nhật khi chuyển chương trước/sau. File mở thẳng từ trình duyệt file của KOReader không hiện gì. Dùng mục "External content" của thanh trạng thái (bật trong menu thanh trạng thái nếu đang tắt).

### Tests
- `spec/chapter_position_test.lua`: thứ tự đọc, mục lục nhiều trang, chương đã tải, thư mục "Trên máy" qua `/sdcard` và `/storage/emulated/0`.
- `spec/reader_test.lua`: `Reader:setPosition` / `Reader:positionText`.

## 3.17.3 (BUILD-1386) - 2026-10-22

### Bug Fixes
- **Cử chỉ và profile mở Truyện Việt không chạy ở trình duyệt file / Lịch sử**: các action đăng ký kèm `reader = true`, mà Dispatcher của KOReader hiểu cờ này là "chỉ khi đang đọc sách" nên bỏ qua lệnh ở màn Home. Vì vậy chạm góc gán "Truyện Việt" và profile tự chạy lúc khởi động không làm gì. Đã bỏ cờ này ở 6 action chung: mở Truyện Việt, Tiếp tục đọc, Lịch sử đọc, Đã tải xuống, Tải từ Google Drive, Kiểm tra cập nhật OTA. Danh sách chương, Chương tiếp/trước, Về nguồn vẫn chỉ chạy khi đang đọc. Tên action không đổi nên cử chỉ và profile đã gán tự hoạt động lại.

### Tests
- `spec/dispatcher_actions_test.lua`: cờ của các action và khả năng chạy trong trình duyệt file / khi đọc.

## 3.17.2 (BUILD-1385) - 2026-10-22

### Bug Fixes
- **Bìa file "Trên máy" trong Lịch sử đọc** (vd. PDF "How to Design Better UI Components"): `showStories` chỉ đọc bìa cho truyện có nguồn trong `SourceRegistry`, mà mục "Trên máy" không có nguồn nên bị bỏ qua. Tủ truyện vẫn có bìa vì đi qua `LocalLibrary.annotate`. Giờ mục "Trên máy" cũng lấy bìa từ CoverCache và hiện tên nguồn "Trên máy".

### Tests
- `spec/chapter_list_flow_test.lua`: bìa và tên nguồn của mục "Trên máy" trong `showStories`.

## 3.17.1 (BUILD-1384) - 2026-10-22

### Bug Fixes
- **Quay lại đúng trang**: mở một truyện ở trang 2, 3… của Tủ truyện (hoặc danh sách tìm kiếm, Lịch sử đọc) rồi back thì danh sách mở lại ở trang chứa truyện đó thay vì trang 1. Áp dụng cho cả mục "Trên máy" và sau "Chỉ xóa chương đã tải".
- **Bìa trong Lịch sử đọc**: lịch sử lưu bản chụp truyện lúc đọc nên thiếu bìa tìm được sau đó (bìa từ nguồn khác, bìa trích từ file). Giờ Lịch sử đọc lấy bìa của mục Tủ truyện tương ứng.

### Tests
- `spec/story_results_test.lua`: `StoryResults:showStoryPage`.
- `spec/local_history_size_test.lua`: `LocalLibrary.copyFavoriteCovers`.

## 3.17.0 (BUILD-1383) - 2026-10-22

### Features & Improvements
- **Mở truyện từ Tủ truyện nhanh hơn**: mục lục của mỗi trang được lưu lại (`chapter_cache`, tối đa 120 file). Lần mở sau hiện ngay từ bản lưu, không chờ mạng. Bản lưu quá 10 phút thì lấy lại trong tiến trình nền (`background_fetch`), xong thì cập nhật danh sách tại chỗ, giữ trang đang xem.
- **Dòng trạng thái đầu mục lục**: "⟳ Đang lấy chương mới…", "Có N chương mới · HH:MM", "Đã là mới nhất · HH:MM", "Cập nhật lúc HH:MM · chạm để làm mới", "Không cập nhật được · chạm để thử lại", "Ngoại tuyến · danh sách lưu lúc HH:MM". Chạm (trừ lúc đang lấy) để tải lại ngay. Lần đầu mở một truyện thì không có dòng này.
- **Chương sau/trước tìm lúc bấm**: đọc tới chương cuối trong lúc đang làm mới thì chuyển được sang chương vừa có; nếu chưa xong thì báo "Đang lấy chương mới, thử lại sau giây lát.".
- **Chỉ xóa chương đã tải, giữ trong Tủ truyện** (truyện online): nút trong hộp xóa truyện và trong menu giữ truyện ("Xóa chương đã tải… (N file · X)"). Với thư mục gắn ngoài chỉ xóa file trùng tên chương do plugin đặt (theo mục lục đã lưu), kèm `.sdr`.
- Mở lại truyện không đổi gì thì không ghi lại file settings; dung lượng thư mục trong Tủ truyện được nhớ trong phiên (tính lại khi thư mục hoặc thư mục con trực tiếp đổi).

### Tests
- `spec/chapter_cache_test.lua`, `spec/background_fetch_test.lua`, `spec/chapter_list_flow_test.lua` (luồng mở mục lục với widget giả).
- Mở rộng `spec/storage_test.lua`, `spec/local_history_size_test.lua`, `spec/favorite_removal_test.lua`.

## 3.16.1 (BUILD-1382) - 2026-10-22

### Bug Fixes
- **KOReader crash khi mở lại Truyện Việt** sau khi đọc một file "Trên máy" có tên dài (ví dụ PDF Jeff Johnson): dòng "▶ Tiếp tục" ở menu gốc đặt tên file vào cột bên phải, mà Menu của KOReader không giới hạn cột này → phần tên còn lại có độ rộng âm và `textwidget.lua` báo `makeLine (width must be strictly positive)`. Cột bên phải giờ rút gọn còn tối đa 24 ký tự (thêm "…"), và bỏ hẳn khi tên tập trùng tên truyện (file lẻ). Tên tác giả trong kết quả Dilib cũng được rút gọn như vậy.

### Tests
- `spec/shorten_test.lua`: `Util.shorten` (ASCII, tiếng Việt nhiều byte, đúng giới hạn, nil).

## 3.16.0 (BUILD-1381) - 2026-10-22

### Features & Improvements
- **Dung lượng trong Tủ truyện**: dòng thứ 3 "Dung lượng: X" (file plugin tải về, thư mục đã gắn, file/thư mục "Trên máy" kèm `.sdr`).
- **Xóa truyện hiện dung lượng**: nút "Xóa … (N file · X)", hộp xác nhận ghi tổng và dung lượng từng đường dẫn; chế độ chọn nhiều hiện dung lượng từng truyện và tổng các truyện đã chọn.

### Bug Fixes
- **Lịch sử đọc bỏ sót mục "Trên máy"** (ví dụ VAGABOND): file mở trực tiếp không đi qua trình đọc của plugin nên không được ghi. Giờ mỗi lần KOReader mở một file thuộc mục "Trên máy" (từ Tủ truyện, File manager hay lịch sử KOReader; `/sdcard` và `/storage/emulated/0` coi là một) thì Lịch sử đọc ghi lại tập đang đọc.
- **Tiếp tục đọc / Danh sách chương / Lịch sử đọc với mục "Trên máy"**: trước đây báo "Nguồn truyện không còn khả dụng". Giờ "Đọc tiếp" mở lại đúng tập (KOReader nhớ trang), "Danh sách tập" mở danh sách file trong thư mục và đánh dấu tập "Đang đọc".
- **Icon không hiển thị**: các emoji không có trong font của KOReader (📖📋📜💾🏠🔄🔍📚📦🔀🎨👤🤖🗑🚀🎉, ký tự U+FE0F) hiện thành ô vuông trong menu chính, cử chỉ, danh mục nguồn và thông báo. Thay bằng ký hiệu có sẵn trong font: ▶ ☰ ⟲ ⤓ ⌂ ↻ ⌕ ☷ ⧉ ⇅ ✎ ● ⚙ ✕ ⚡.

### Tests
- `spec/main_menu_test.lua`: cập nhật theo quy ước hiện tại — plugin cố ý không có `onShow`/`onOpen` (KOReader phát sự kiện Show/Open tới mọi module, sẽ mở lại trình duyệt đè lên chương vừa mở); ZenOS tìm thấy `show`.
- `spec/font_helper_test.lua`: viết lại theo cách nạp font hiện tại (đường dẫn tuyệt đối trong thư mục plugin, đăng ký vào `FontList:getFontList()`, patch v2 có marker); kiểm cả trường hợp thiếu file font và font hỏng.

## 3.15.1 (BUILD-1380) - 2026-10-22

### Bug Fixes
- **Tìm trên tất cả nguồn tự mở một truyện**: trong lúc tìm (chặn giao diện ~15s) cú chạm vào nút "Tìm" bị giữ lại, rồi rơi vào hàng kết quả nằm đúng chỗ đó khi danh sách hiện ra. Sau mọi thao tác chờ (`withLoading`), input tồn đọng giờ bị bỏ trong ~0,8s.
- **Tủ truyện**: bỏ nút **Xóa** trên từng hàng vì che dòng "Đã tải X/N" của truyện đã hoàn thành. Xóa qua biểu tượng ✓ trên thanh tiêu đề (chọn một hay nhiều truyện) hoặc giữ truyện → "Xóa khỏi tủ truyện".

## 3.15.0 (BUILD-1379) - 2026-10-22

### Features & Improvements
- **Xóa truyện khỏi Tủ truyện**:
  - Mỗi hàng trong Tủ truyện có nút **Xóa**; giữ truyện → "Xóa khỏi tủ truyện" và nút trong danh sách chương dùng cùng hộp thoại.
  - Hai lựa chọn: **Xóa khỏi Tủ truyện và cả file đã tải** (hiện số file) hoặc **Chỉ xóa khỏi Tủ truyện (giữ file)**. Lựa chọn 1 hỏi lại kèm danh sách đường dẫn trước khi xóa vĩnh viễn.
  - "File của truyện" gồm thư mục plugin tải về, thư mục trên máy đã gắn (`offline_dir`), và file/thư mục của mục "Trên máy" kèm thư mục `.sdr`.
  - Biểu tượng ✓ trên thanh tiêu đề mở chế độ chọn nhiều: ☐/☑ từng truyện, **Chọn tất cả / Bỏ chọn tất cả**, "Xóa N truyện đã chọn" (lưu Tủ truyện một lần).
  - Không bao giờ xóa `/`, đường dẫn tương đối hoặc có `..`, thư mục gốc plugin, thư mục dữ liệu KOReader, thư viện sách, `home_dir`, `/sdcard` hay thư mục cha của chúng; mục bị bỏ qua được báo lại.
  - Lịch sử đọc không bị đụng tới.

## 3.14.0 (BUILD-1378) - 2026-10-22

### Features & Improvements
- **Thêm truyện trên máy vào Tủ truyện** (menu chính):
  - Quét thư mục plugin tải về (`<koreader>/truyenviet/<nguồn>/<truyện>`, kể cả thư mục rỗng) và thư viện sách (setting `local_library_dirs`, `home_dir` của KOReader, mặc định `/sdcard/Books`).
  - Thư mục plugin được ghép với URL online qua Tủ truyện, lịch sử, tìm kiếm trên nguồn, rồi so khớp bỏ hậu tố số (`darwin-jihen-21048` → `darwin-jihen`, không tạo mục trùng).
  - Thư mục sách có file chương dạng `<slug>-chap-N` được **gắn** (`offline_dir`) vào truyện online sẵn có thay vì tạo mục mới; không di chuyển file nào.
  - Thư mục/file còn lại thành mục **"Trên máy"** (source `local`, url là đường dẫn). Chạm để mở file hoặc danh sách tập; giữ để xóa khỏi Tủ truyện (giữ file), tìm lại bìa, mở trong trình quản lý file.
  - Danh sách xác nhận ☑/☐ trước khi thêm; mục online không ghép được liệt kê riêng. Chạy lại không thêm trùng.
- **Dòng phụ Tủ truyện**: `Đã tải X/N`, `Đã tải X chương`, `Chưa tải`, `Trên máy · N tập`; đếm cả chương trong thư mục đã gắn.
- **Ảnh bìa lớn** (`truyenviet/cover_finder.lua`): WeebCentral 400x600 (truyện tranh, tên trùng hoàn toàn) → `og:image` trang truyện → bìa đang lưu → trang bìa trong file trên máy (PNG ≤600px). Mỗi ứng viên được tải và kiểm tra là ảnh thật. Lệnh mới "Tìm lại bìa lớn cho Tủ truyện"; mục cũ "Tải lại ảnh bìa" đổi thành "Tìm lại ảnh bìa lớn".
- **Mở Tủ truyện tự làm mới** số chương (cũ hơn 12 giờ, tối đa 12 mục) và bìa còn thiếu (tối đa 4 mục, mỗi mục thử lại sau 12 giờ), hạn 15s; lưu lại `meta_time`/`cover_time`. Tắt tìm bìa tự động khi bật chế độ nhanh.

### Bug Fixes
- Xóa truyện khỏi Tủ truyện chỉ xóa bản tải trong thư mục plugin; thư mục trên máy đã gắn không bao giờ bị xóa.
- `Storage:listFavorites` trả bản sao để trường hiển thị không lọt vào settings.

## 3.13.0 (BUILD-1377) - 2026-10-22

### Features & Improvements
- **Chương mới nhất & trạng thái "Hoàn thành" cho mọi nguồn**:
  - Dòng phụ của mỗi truyện trong kết quả tìm kiếm và danh sách duyệt nguồn hiển thị `Nguồn · Chương N · Hoàn thành` (N là số chương mới nhất site ghi, giữ phần thập phân như `Chương 12.5`). Nguồn chỉ biết tổng số chương thì hiện `Nguồn · N chương`.
  - Nguồn tự gán `latest_chapter`/`chapter_count`/`completed` ngay từ trang tìm kiếm khi có sẵn; nguồn nào không có thì khai báo `Source:fetchSearchMeta(story)` (đúng 1 request rẻ nhất) và `SearchService:enrichMeta` tự bổ sung cho tối đa 12 truyện đầu còn thiếu chương mới nhất hoặc trạng thái (song song, 2 request/nguồn, hạn chót 8s, cache theo URL).
  - generic_source: thêm khoá tuỳ chọn `search.latest_chapter_pattern`.
- **Tìm kiếm nhanh hơn (chạy song song)**:
  - Module mới `truyenviet/async_pool.lua`: chạy nhiều tác vụ trên Copas với giới hạn đồng thời và hạn chót, an toàn khi gọi lồng (không gọi `copas.step` trong thread của pool).
  - `HttpClient:request` tự chuyển sang `requestAsync` khi chạy trong pool (timeout 10s, 1 lần thử lại, bỏ curl fallback); `requestAsync` hỗ trợ `max_retries`, `no_curl` và trả đủ headers/mã lỗi như bản đồng bộ.
  - `SearchService:search` chạy tối đa 6 nguồn cùng lúc, hạn chót 15s/lượt; nguồn quá hạn báo `"<Nguồn>: quá thời gian (15s)"` mà không chặn kết quả nguồn khác. Thứ tự/điểm sắp xếp giữ nguyên. Thử lại tuần tự một lần cho nguồn lỗi TLS. Cache kết quả 10 phút (30 mục).
  - Bổ sung số chương và tải bìa chạy song song (`CoverCache:prefetch` chuyển sang AsyncPool).
  - Bỏ các vòng Copas riêng trong đường tìm kiếm của TruyenQQ (`fillCompletedStatus`) và ZetTruyen (`fillChapterCounts`).

### Bug Fixes (nguồn)
- akaytruyen: tham số tìm kiếm đúng là `key_word` (trước đây site bỏ qua từ khoá).
- metruyenchuvn: tên miền mới `metruyenchu.com.vn`.
- cbunu: tên miền mới `cucbongunu.com`, tìm kiếm `/tim-kiem.html?q=`, danh sách hoàn thành `/da-hoan`.
- docln: tham số tìm kiếm `keywords`.
- haccbl, dualeotruyenfull: tìm kiếm qua API JSON `/wp-json/initlise/v1/search` (loại bài spam).
- metruyenvn: tìm kiếm qua `admin-ajax.php` (`action=searchtax`).
- truyendich: tìm kiếm qua API `/api/novels/search` (trang HTML render phía client nên trước đây luôn rỗng); sửa nhãn `Trạng thái`.
- truyendich: chuyển sang `truyendich.space` (`.ai`/`.fit` bị chặn TLS từ VN, làm mọi lượt tìm chờ hết 15s); URL yêu thích/lịch sử tên miền cũ tự đổi sang tên miền mới.
- dualeo: tắt mặc định một lần (mọi tên miền đều hết hạn kết nối từ VN); bật lại trong cài đặt nguồn thì giữ nguyên.
- conduongbachu: bỏ request `/?s=` thừa.
- xtruyen: sửa nhãn `Trạng thái` trong chi tiết truyện.
- generic_source: sửa thứ tự tham số `getChapterAsync`, sửa lỗi `story_block_pattern` nhiều capture; thêm khoá tuỳ chọn `search.item_marker`, `chapter_count_pattern`, `completed_pattern`.

## 3.12.0 (BUILD-1375) - 2026-10-08

### Features & Bug Fixes
- **Chuẩn hóa Font Tiếng Việt với Be Vietnam Pro (Vietnamese Font Standardization)**:
  - Thay thế toàn bộ font cũ `ComicHelvetic-Light.ttf` (vốn bị lỗi khuyết các glyphs dấu thanh phức tạp như `ấ`, `ồ`, `ừ`, `ầ`, `ớ` hiển thị thành khoảng trắng) bằng font chuẩn tiếng Việt **Be Vietnam Pro** (`BeVietnamPro-Regular.ttf` & `BeVietnamPro-Medium.ttf`).
  - Cập nhật `truyenviet/font_helper.lua` hỗ trợ sao chép, tự động đăng ký với KOReader `FontList` và cung cấp UI patch hệ thống cho toàn bộ giao diện (Menu, Popup, Ô văn bản, Tiêu đề).
  - Tự động phát hiện và nâng cấp các User Patch cũ (`patches/2--ui-font.lua`) từ ComicHelvetic sang Be Vietnam Pro, tự động khắc phục triệt để lỗi mất chữ cho người dùng mà không cần thao tác lại.
  - Cập nhật font nhúng và CSS template trong `document_builder.lua` sang Be Vietnam Pro.
  - Bổ sung bộ kiểm thử đơn vị `spec/font_helper_test.lua`.
- **Tích hợp Tương thích Launcher ZenOS (`xZenLabs/zen-os`)**:
  - Nghiên cứu cơ chế quét plugin của ZenOS Launcher (`modules/menu/app_launcher/plugin_scan.lua`).
  - Triển khai đầy đủ các phương thức khởi chạy chuẩn (`onShow`, `show`, `open`, `launch`, `onOpen`, `onTruyenviet`) trên lớp `TruyenViet`, cho phép ZenOS Launcher kích hoạt 1-chạm trực tiếp vào màn hình chính của Truyện Việt.
  - Chuẩn hóa tiêu đề mục menu thành tên gọn gàng `"Truyện Việt"` (loại bỏ emoji `🔥` và đuôi version khỏi tiêu đề menu gốc), giúp ZenOS tự động sắp xếp chính xác theo thứ tự chữ cái dưới chữ **T** (nằm giữa Terminal và Tweak document settings trên Trang 1 của danh sách "Choose plugin menu").
  - Đăng ký `self.ui.truyenviet = self` trong `TruyenViet:init()` để ZenOS nhận diện phiên bản live instance trong giao diện KOReader.
  - Bổ sung các bài kiểm thử tự động tương thích ZenOS Launcher trong `spec/main_menu_test.lua`.

## 3.11.0 (BUILD-1372) - 2026-10-08

### Features & Improvements
- **Tự động Cập nhật Phiên bản mới qua OTA (Automatic OTA Updates)**:
  - Bổ sung module chuyên biệt `truyenviet/updater.lua` quản lý toàn diện quy trình kiểm tra, so sánh phiên bản ngữ nghĩa (semantic versioning), tải về và giải nén cài đặt bản cập nhật OTA.
  - Tự động kiểm tra bản cập nhật ngầm khi khởi động plugin (sau 8s khi hệ thống mạng ổn định, không chặn UI).
  - So sánh phiên bản chặt chẽ theo `major.minor.patch (BUILD-xxxx)`, chỉ gợi ý nâng cấp khi phiên bản từ GitHub thực sự mới hơn.
  - Tự động trích xuất tóm tắt nhật ký thay đổi (`CHANGELOG.md`) từ máy chủ để hiển thị nội dung cập nhật mới cho người dùng trước khi xác nhận tải.
  - Kiểm tra tính toàn vẹn gói cập nhật ZIP (kích thước tối thiểu và Magic Bytes `PK\3\4`), giải nén trực tiếp vào thư mục `plugins` của KOReader với cơ chế dự phòng `busybox unzip`.
  - Hỗ trợ khởi động lại KOReader ngay lập tức (`restartKOReader`) sau khi cập nhật thành công.
  - Tích hợp cấu hình linh hoạt trong Cài đặt nâng cao: Bật/Tắt tự động kiểm tra OTA, tùy chọn tần suất kiểm tra (mỗi lần mở / mỗi 24 giờ / mỗi tuần), và ghi nhớ phiên bản bỏ qua.
  - Đăng ký Dispatcher Action `truyenviet_check_update` và menu kiểm tra thủ công trong Menu chính.
  - Bổ sung bộ kiểm thử đơn vị `spec/updater_test.lua` với 34 assertions.

## 3.10.0 (BUILD-1370) - 2026-10-07

### Features & Improvements
- **Tích hợp Tải Ebook từ Google Drive (Google Drive Integration)**:
  - Bổ sung module `gdrive_downloader.lua` hỗ trợ tải ebook trực tiếp từ các liên kết chia sẻ công khai Google Drive (`/file/d/`, `?id=`, `/open?id=`, hoặc File ID trực tiếp).
  - Tự động vượt qua màn hình cảnh báo quét virus của Google Drive đối với file dung lượng lớn qua trích xuất `confirm` token và quản lý phiên Cookie.
  - Tự động nhận diện định dạng file thông qua Magic Bytes (`%PDF`, `PK\3\4` EPUB/CBZ, `Rar!` CBR, `BOOKMOBI`) và Content-Disposition header.
  - Hỗ trợ toàn diện các định dạng: `.epub`, `.cbz`, `.cbr`, `.mobi`, `.pdf`, `.azw3`, `.txt`, `.fb2`, `.djvu`.
  - Tích hợp giao diện `showGDriveDownloadDialog` trong `Browser` và Dispatcher action `truyenviet_gdrive_download`, hỗ trợ nút "Mở đọc ngay" sau khi tải hoàn tất.
- **Sửa Lỗi & Tối Ưu Hệ Thống (Bug Fixes & Refactoring)**:
  - Khắc phục lỗi `coroutine.yield across C-call boundary` trong `chapter_downloader.lua` khi chạy ngoài coroutine.
  - Sửa lỗi sắp xếp mục lục chương trong `conduongbachu.lua` ưu tiên số chương thực tế trước khi so sánh chuỗi.
  - Chuẩn hóa forward-compatibility với Lua 5.4+ (loại bỏ gán lại biến lặp `for`).
  - Sửa toàn bộ 15 test suite kiểm thử đơn vị (`spec/`), bổ sung 20 assertions mới cho Google Drive downloader.
  - Dọn dẹp mã nguồn thừa (`test_aeslua.lua`).

## 3.8.0 (BUILD-1368) - 2026-08-09

### Feature & Fixes
- **Nguồn `xtruyen`**:
  - Tích hợp thành công module giải nén Zlib (`ffi/zlib`) và giải mã chuỗi Base64 tùy biến để xử lý nội dung mã hóa `data_x` của nguồn `xtruyen.vn` trực tiếp trên KOReader. Khắc phục triệt để lỗi "Không tìm thấy nội dung chương" khi đọc truyện.
  - Bổ sung cơ chế trích xuất tên chương thật từ nội dung tải về (do Cloudflare chặn API mục lục), hiển thị đúng tên trên thanh tiêu đề khi đọc truyện.
  - Tự động sinh danh sách mục lục (Chương 1, Chương 2,...) để vượt qua lớp bảo vệ JS Challenge của Cloudflare đối với các API AJAX ẩn.
- **Hệ thống (ZenUI)**:
  - Cập nhật cờ `plugin = true` cho toàn bộ các đường dẫn nhanh (Dispatcher actions) như "Tiếp tục đọc", "Lịch sử đọc", "Đã tải xuống", giúp tính năng nhận diện chính xác và hiển thị đầy đủ bên trong mục Plugin của giao diện.
# Changelog

## 3.7.0 (BUILD-1341) - 2026-07-29

### Codex

- Giữ nguyên phiên bản ổn định `3.7.0`, chỉ tăng internal build từ 1340 lên
  1341 để đối chiếu kiểm thử tối ưu riêng nguồn AkayTruyen.
- Parse trang chủ đúng ba DOM section một lần, cache dữ liệu đã bóc tách thay
  vì giữ HTML gần 900 KB. Gom anchor ảnh/title theo URL và tái dùng cover từ
  mục Hot cho Truyện đang ra; không phát sinh request ảnh/trang bổ sung.
- Chuyển mục lục sang endpoint chính thức
  `/search-chapters?search=&page=N` (khoảng 140 KB/page thay cho trang truyện
  gần 469 KB), vẫn fallback trang đầy đủ nếu endpoint lỗi. Siết parser theo
  `chapter-link-mobile` + prefix truyện để không nhận link hành động.
- Thêm `getChapterAsync` và giới hạn `max_concurrent = 1` để rolling prefetch
  không dùng request đồng bộ chặn UI. Parser chương cắt thẳng vùng
  `#chapter-content` trước `chapter-nav`, chỉ sanitize phần nội dung cần thiết.
- Regression Akay đạt 39 assertion, 35 file Lua compile. Live test đạt Hot
  36/36 cover, Đang ra 32/32, Hoàn thành 4/4, Chủ đề 18/18; tìm kiếm đúng,
  *Chung Cực Truyền Kỳ* đủ 324 chương/7 trang và chương mới có 25.425 ký tự.

## 3.4.3 (BUILD-1325) - 2026-07-29

### Codex

- Làm lại phân trang nguồn **Con Đường Bá Chủ** theo REST API WordPress tăng
  dần: mở một trang chỉ tải đúng một trang API, còn `Tải tất cả` chỉ lưu chỉ
  mục khi đã nhận đủ toàn bộ số bài mà `X-WP-Total` công bố. Request lỗi giữa
  chừng không còn bị cache thành danh sách chương cụt.
- Giữ từng bài WordPress theo URL, bao gồm hai bài cùng số **3059** và slug
  legacy `/3399-vo-de/`; kiểm tra không bỏ sót bài chính truyện và không tự
  sinh chương không tồn tại **3509**.
- Cô lập lỗi tải ảnh bìa khi tìm kiếm và giới hạn prefetch tối đa 10 ảnh để
  tránh treo hoặc thiếu bộ nhớ KOReader.
- Không thử lại lần hai một nguồn tìm kiếm đã ném exception; chỉ fallback bỏ
  dấu khi lần đầu trả về danh sách hợp lệ nhưng rỗng.
- Thêm regression/live test: 18 assertion parser, kiểm tra lỗi REST giữa trang,
  live 3.752 bài chính truyện/76 trang, 15/16/6 chương ngoại truyện, tìm kiếm
  4 kết quả không lỗi và tải chương đầu/cuối.

## 3.3.8 (BUILD-1320) - 2026-07-29

### Codex

- Thêm source **Con Đường Bá Chủ** (`conduongbachu.com`) cho danh mục,
  tìm kiếm, mục lục và đọc chương.
- Dùng WordPress REST index (`categories=3`, 100 bài/trang) để lấy toàn bộ
  bài chương; fallback sang `<select class="chapter-selector">` nếu REST API
  bị tắt. Dedupe theo số chương để xử lý dữ liệu website có bài 3059 trùng.
- Hỗ trợ URL slug bất thường như `/3399-vo-de/`, lấy số chương từ tiêu đề
  hiển thị thay vì đoán từ slug. Không tự tạo chương 3509 vì website hiện
  không có bài tương ứng.
- Parser nội dung chỉ giữ các đoạn văn trong `entry-content`, loại phần
  giới thiệu tìm kiếm và metadata trình đọc audio; giữ liên kết chương trước/sau.
- Cứng hóa SearchService: không để source trả dữ liệu sai định dạng làm crash
  vòng lặp tìm kiếm; bỏ qua kết quả thiếu `source_id`/URL/tiêu đề, chặn query
  rỗng và cô lập lỗi từng nguồn.
- Kiểm thử: 17 assertion source, 17 assertion chapter order, search regression,
  35 file Lua compile; live KOReader đạt 76 trang và 3.751 chương duy nhất.

## 3.3.7 (BUILD-1319) - 2026-07-29

### Codex

- Sửa crash khi chạm mép trên để mở menu trong ReaderUI: plugin từng dùng
  `sorting_hint="tools_settings"`, không tồn tại trong
  `reader_menu_order.lua`; chuyển sang menu `tools` hợp lệ và xác minh trực
  tiếp bằng `MenuSorter` của KOReader.
- Thay Sort chỉ đảo các chương của trang hiện tại bằng điều hướng toàn mục lục:
  A-Z nhảy tới trang chứa chương đầu, Z-A nhảy tới trang chứa chương mới nhất.
  Giữ đúng chiều khi chuyển trang và khi đọc tiếp qua ranh giới trang.
- Đánh dấu Akay là nguồn có mục lục giảm dần và thêm module
  `chapter_order.lua` để tính trang biên, chiều hiển thị và trang đọc kế tiếp.
- Nhận diện màn hình khóa VIP theo markup thực tế, không lưu nó thành nội dung
  chương. Tránh nhận nhầm CSS dùng chung là khóa VIP.
- Thêm đăng nhập Akay hợp lệ bằng CSRF + session cookie, lưu tài khoản qua
  CredentialManager và bổ sung mục quản lý tài khoản trong Quản lý nguồn.
  Chương VIP vẫn yêu cầu tài khoản thực sự có quyền.
- Kiểm tra live toàn bộ 6 chương *Ngoại Truyện - Chúa Tể Chi Lộ*: phiên công
  khai chỉ nhận màn hình “Truy cập bị hạn chế”; plugin hiện báo rõ yêu cầu VIP.
- Thêm regression test menu ReaderUI, chapter order, khóa VIP và phiên đăng
  nhập. Tổng kiểm tra mục tiêu: 17 assertion sort, 26 assertion Akay và 34 file
  Lua compile.

## 3.3.6 (BUILD-1318) - 2026-07-29

### Codex

- Tái hiện đúng lỗi B-1317 ở luồng **Truyện đang ra**: các route
  `/danh-sach/truyen-*` của AkayTruyen đã trả `404`, trong khi Browser chỉ
  hiển thị thông báo lỗi tổng quát.
- Thay `getUpdating`, `getHot` và `getCompleted` bằng parser ba mục tương ứng
  trên trang chủ Akay (`section-stories-new`, `section-stories-hot`,
  `section-stories-full`), tránh phụ thuộc route đã bị xóa; kết quả live hiện
  lần lượt có 31, 35 và 4 truyện.
- Bỏ `X-Requested-With: XMLHttpRequest` khỏi request HTML. Akay trả `500` cho
  URL chương khi có header này, còn request trình duyệt thông thường trả `200`.
  Đồng bộ source Lua, JSON bundled, generator output và SPEC.
- Thêm regression assertion bảo đảm request trang chương không gửi header AJAX.
- E2E trong runtime KOReader: Akay “Truyện đang ra”/“Hot”/“Hoàn thành” đọc
  được, *Chung Cực Truyền Kỳ* có 7 trang chương và chương live tải được
  (23.896 ký tự); Storya vẫn đọc được 20 truyện/163 trang để đối chiếu.

## 3.3.5 (BUILD-1317) - 2026-07-29

### Codex

- Xác định nguyên nhân runtime chính: `custom_sources/akaytruyen.json` đóng gói
  trùng ID đã ghi đè module Lua AkayTruyen, khiến bản sửa trong
  `sources/akaytruyen.lua` không được KOReader sử dụng.
- Không cho JSON đóng gói ghi đè nguồn Lua tích hợp; vẫn cho phép JSON do người
  dùng cài trong thư mục dữ liệu chủ động ghi đè.
- Hỗ trợ đầy đủ cả URL chương mới (`/chuong-N-slug`) và URL legacy
  (`/N-slug`, `/slug`) bằng class `chapter-link-mobile`, đồng thời loại link
  hành động/giới thiệu có cùng prefix truyện.
- Dừng và báo lỗi nếu một trang mục lục tải thất bại, rỗng hoặc lặp dữ liệu;
  không còn trả về danh sách thiếu như thể đã thành công.
- Truyền đúng lỗi lấy mục lục từ nguồn lên hai luồng “Tải tất cả các chương” và
  “Tải thành 1 bộ”.
- Đồng bộ rule AkayTruyen trong JSON, Source Generator và tài liệu SPEC.
- Thêm regression test riêng cho AkayTruyen. Kiểm thử live trong môi trường
  KOReader xác nhận *Chung Cực Truyền Kỳ* có 7 trang và đủ 323 chương duy nhất.

## 3.3.4 (BUILD-1316) - 2026-07-28

### Claude Code

- Cải thiện lấy tiêu đề tìm kiếm khi AkayTruyen tách anchor ảnh và anchor tên.
- Lọc anchor chương theo cấu trúc class/nội dung và bổ sung điều hướng chương
  bằng icon chevron.
- Phiên điều tra tiếp theo trong `session01.md` phát hiện URL chương legacy,
  nhưng bản sửa nháp còn nhận quá rộng mọi URL con và chưa phát hiện JSON trùng
  ID ghi đè module Lua.

## 3.3.3 (BUILD-1315) - 2026-07-28

### Claude Code

- Thêm nguồn AkayTruyen, AJAX header `X-Requested-With`, đọc số trang từ
  `jump-input max`, và luồng lấy toàn bộ trang chương.
- Sửa crash menu ReaderUI và các thay đổi gộp sách được ghi nhận trong
  `MEMORY.md`.

## 3.0.1

- Cập nhật parser cho metruyenvn, aztruyen, truyenc, giatocvuongtai, và dualeotruyenfull.
- Thêm cờ force_luasec cho truyenqq để sửa lỗi HTTPS trên Kobo.
- Sửa lỗi crash liên quan đến check nil trong Storage:isFavorite.
- Sửa lỗi Cloudflare 403.

## 1.0.4

- Sửa vòng đời widget để Back, tìm kiếm, lịch sử và phân trang không tạo nhiều màn hình chồng nhau.
- Sửa luồng mở/thoát Reader và chuyển chương để không văng về FileManager.
- Giữ bản chương cũ nếu tải lại thất bại; chỉ thay file sau khi dựng bản mới thành công.
- Chặn ảnh bìa lỗi, kích thước danh sách không hợp lệ và exception khi ghi cài đặt.
- Khôi phục đúng tên miền mặc định sau khi xóa tên miền tùy chỉnh.

## 0.3.0

- Xóa truyện khỏi tủ sẽ cập nhật danh sách và phân trang ngay, không cần thoát ra vào lại.
- Sửa lỗi báo sai `Không thể lưu trạng thái nguồn` khi bật lại TruyenQQ hoặc Dưa Leo.
- Xác nhận gói plugin dùng chung trên KOReader Android, Kindle và Kobo.
- Thêm xem mô tả và thông tin truyện khi giữ một kết quả.
- Thêm tải hàng loạt các chương chưa có trong trang mục lục hiện tại.
- Sửa luồng bật lại nguồn đã tắt và luôn hiển thị trạng thái nguồn ở trang chính.
- Bỏ tích hợp danh mục VBook Extensions.

## 0.2.0

- Thêm nguồn truyện tranh Dưa Leo Truyện.
- Chạm vào từng nguồn để duyệt truyện đã hoàn thành, tìm riêng theo nguồn, lọc thể loại và chuyển trang.
- Thêm tìm kiếm đồng thời nhiều nguồn, chuẩn hóa tiếng Việt và xếp hạng kết quả.
- Hiển thị ảnh bìa, tên truyện và nguồn trong danh sách kết quả.
- Thêm cache ảnh bìa và giao diện kết quả có phân trang.
- Thêm quản lý bật/tắt nguồn và đồng bộ danh mục Darkrai9x/vbook-extensions.
- Bổ sung kiểm thử parser Dưa Leo và thuật toán tìm kiếm.

## 0.1.0

- Thêm nguồn truyện chữ TruyenFull.
- Thêm nguồn manga TruyenQQ.
- Thêm tìm kiếm, tủ truyện và danh sách chương.
- Thêm bộ dựng HTML và CBZ.
- Thêm tích hợp mở tài liệu bằng KOReader.
