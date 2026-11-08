---
title: Hướng dẫn Xóa tài khoản và Xóa dữ liệu
description: Cách xóa tài khoản {{site_name}}, những gì sẽ bị xóa sau khi xóa, nội dung nào có thể được lưu giữ ngắn hạn, cùng các lưu ý khi hủy đăng ký.
version: 1.0.0
effective: 2026-10-27
updated: 2026-10-27
---

## 1. Cách xóa tài khoản

Bạn có thể chọn "Xóa tài khoản" trong "Cài đặt → Tài khoản" trong ứng dụng, hoặc gửi yêu cầu xóa tài khoản qua {{contact_email}}.

Để bảo vệ an toàn tài khoản, Chúng tôi có thể yêu cầu Bạn hoàn thành một trong các xác minh sau: đăng nhập vào tài khoản hiện tại; xác minh đăng nhập Apple hoặc số điện thoại; nhập cụm từ xác nhận xóa rõ ràng; xác minh danh tính thông qua bộ phận chăm sóc khách hàng.

## 2. Những gì sẽ bị xóa sau khi xóa tài khoản

Sau khi hoàn tất xóa tài khoản, Chúng tôi sẽ xóa hoặc ẩn danh hóa các dữ liệu sau:

- Hồ sơ tài khoản, thông tin đăng nhập và bản ghi quyền lợi hội viên
- Kế hoạch tập luyện, nhật ký tập luyện và bản ghi số hiệp
- Nhật ký ăn uống, dữ liệu dinh dưỡng và ảnh bữa ăn đã đồng bộ
- Tổng hợp sức khỏe và trạng thái đồng bộ
- Ánh xạ nhiệm vụ AI, báo cáo AI phía máy chủ và kiểm toán nhiệm vụ
- Tóm tắt đánh giá tuần và tệp phương tiện máy chủ liên quan đến tài khoản
- Phản hồi người dùng và tệp đính kèm
- Ràng buộc thiết bị và bản ghi gửi thông báo

Ảnh cơ thể được lưu cục bộ trong ứng dụng sẽ bị xóa cùng với quá trình dọn dẹp dữ liệu tài khoản hoặc do Bạn xóa trong ứng dụng. Gỡ cài đặt ứng dụng sẽ xóa dữ liệu cục bộ trong sandbox của thiết bị, nhưng **không thể xóa các tệp Bạn đã lưu vào thư viện ảnh hệ thống hoặc đã chia sẻ bản sao cho người khác** — các bản sao này do Bạn tự quản lý.

## 3. Nội dung có thể không được xóa ngay

Các nội dung sau có thể không biến mất hoàn toàn ngay tại thời điểm xóa tài khoản:

1. Sao lưu cơ sở dữ liệu và tệp (được ghi đè theo chu kỳ luân chuyển sao lưu);
2. Nhật ký kiểm toán an ninh và chống lạm dụng (lưu giữ để thực hiện nghĩa vụ pháp lý);
3. Nội dung đã gửi cho dịch vụ mô hình bên thứ ba (chịu ràng buộc của chính sách lưu giữ riêng của nhà cung cấp đó);
4. Ảnh đã tạo và Bạn chủ động tải xuống hoặc chia sẻ;
5. Bản ghi giao dịch mà Apple, RevenueCat hoặc nhà cung cấp bên thứ ba khác lưu giữ theo chính sách của họ.

Chúng tôi sẽ xóa hoặc ẩn danh hóa dữ liệu có thể nhận dạng sớm nhất có thể theo chu kỳ luân chuyển sao lưu và quy tắc lưu giữ nội bộ. Sau khi tiếp nhận yêu cầu xóa, tài khoản bị vô hiệu hóa ngay lập tức; nhiệm vụ dọn dẹp tiếp tục được thực hiện ở nền và tự động thử lại các mục thất bại.

## 4. Xóa ảnh bữa ăn

Sau khi Bạn xóa một bữa ăn trong nhật ký ăn uống, ảnh trên máy và bản ghi tương ứng sẽ bị gỡ khỏi dữ liệu tài khoản hiện tại; ảnh đã đồng bộ lên đám mây được xóa đồng bộ, sao lưu hoặc bộ nhớ đệm của bên thứ ba có thể chỉ biến mất hoàn toàn sau khi luân chuyển. Việc dọn dẹp ảnh gốc trên đám mây nếu thất bại sẽ vào hàng đợi độc lập để tự động thử lại, Bạn không cần thao tác lại.

## 5. Xóa ảnh cơ thể

Ảnh đánh giá hàng tuần mặc định được lưu trên thiết bị. Sau khi Bạn xóa đánh giá hoặc xóa ảnh, máy sẽ gỡ bỏ tệp ảnh. Không thể bảo đảm các ảnh đã gửi cho dịch vụ AI được thu hồi ngay lập tức từ máy chủ bên thứ ba: đầu vào phía máy chủ được xóa sau khi nhiệm vụ thành công; đầu vào đánh giá tuần được xóa sau khi thất bại cuối cùng; đầu vào các nhiệm vụ thất bại khác được giữ tối đa 7 ngày. Việc xóa tài khoản sẽ dọn dẹp các đầu vào nhiệm vụ, kết quả và kiểm toán liên quan.

## 6. Thu hồi ủy quyền dữ liệu sức khỏe

Bạn có thể thu hồi quyền đọc/ghi dữ liệu sức khỏe của Sản phẩm trong Apple Health hoặc cài đặt hệ thống. Sau khi thu hồi, ứng dụng không đọc thêm dữ liệu sức khỏe mới; tổng hợp sức khỏe đã lưu có thể vẫn còn trong bản ghi tài khoản, Bạn có thể tiếp tục xóa hoặc xóa tài khoản.

## 7. Lưu ý về đăng ký và hội viên

- **Xóa tài khoản không tự động hủy đăng ký của Apple**. Vui lòng hủy tự động gia hạn trong trang quản lý "Đăng ký" của Apple ID trước, rồi mới yêu cầu xóa tài khoản, để tránh tiếp tục bị trừ phí;
- Hoàn tiền cho đăng ký đã thanh toán được xử lý qua Apple theo "Chính sách Mua hàng, Đăng ký và Hoàn tiền";
- Xóa tài khoản và hủy tự động gia hạn là hai thao tác độc lập.

## 8. Thu hồi ủy quyền Apple

Khi đã cấu hình dịch vụ thu hồi của Apple và tài khoản lưu thông tin xác thực làm mới, việc xóa tài khoản sẽ đồng thời thu hồi ủy quyền của Bạn đối với Sản phẩm qua Sign in with Apple. Với tài khoản cũ hoặc khi chưa cấu hình dịch vụ thu hồi, vui lòng tự thu hồi ủy quyền trong iOS **Cài đặt → [Tên của Bạn] → Đăng nhập và Bảo mật (hoặc Mật khẩu và Bảo mật) → Các ứng dụng đăng nhập bằng Apple ID**.

## 9. Kiểm tra trạng thái và đăng ký lại

Khi mất chứng từ xóa tài khoản, có thể dùng Apple ID đã dùng lúc yêu cầu xóa để xác minh lại và kiểm tra trạng thái xử lý; hệ thống sẽ không tạo hay khôi phục tài khoản chỉ dựa vào cờ ghi trên máy. Bản tóm tắt chứng từ xóa tài khoản và bản tóm tắt định danh Apple dùng để kiểm tra trạng thái được giữ tối đa 30 ngày sau khi hoàn tất dọn dẹp, sau đó bị xóa.

Các tệp xuất trên máy, bản sao lưu ảnh chụp nhanh khi hai thiết bị sửa đổi đồng thời và bản sao lưu văn bản kế hoạch cũ sẽ bị xóa cùng với quá trình dọn dẹp trên máy của tài khoản; các tệp Bạn lưu riêng hoặc chia sẻ đến nơi khác do Bạn tự quản lý, ứng dụng không thể xóa các bản sao này.

## 10. Liên hệ với Chúng tôi

Nếu không thể hoàn tất xóa tài khoản hoặc xóa dữ liệu trong ứng dụng, vui lòng liên hệ:

- Email: {{contact_email}}


Khi gửi yêu cầu, vui lòng nêu rõ "Xóa tài khoản" hoặc "Xóa dữ liệu" và phối hợp hoàn thành xác minh danh tính. Chúng tôi sẽ hoàn thành xử lý trong thời hạn theo quy định (thường không quá 15 ngày làm việc) sau khi xác minh và thông báo kết quả cho Bạn.
