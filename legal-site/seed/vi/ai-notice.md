---
title: Giới thiệu về Dịch vụ AI
description: Phạm vi tính năng AI của {{site_name}}, nhà cung cấp, quy tắc xử lý và lưu giữ dữ liệu, gắn nhãn nội dung, giới hạn sử dụng và miễn trừ trách nhiệm.
version: 1.0.0
effective: 2026-10-27
updated: 2026-10-27
---

## 1. Phạm vi tính năng AI

Các tính năng AI của Sản phẩm bao gồm: tạo kế hoạch tập luyện, nhận dạng ảnh bữa ăn và ước lượng dinh dưỡng, Báo cáo AI hàng ngày, Phân tích bài tập, phân tích Đánh giá cơ thể hàng tuần, trò chuyện Club AI, cùng báo cáo tự động hàng ngày/hàng tuần tùy chọn và theo dõi tự động sau khi đóng ứng dụng.

## 2. Nhà cung cấp dịch vụ AI

Nhiệm vụ AI được xử lý bởi **DeepSeek** và **MiniMax**, hai bên được phân bổ theo nhiệm vụ và trạng thái dịch vụ, dự phòng chéo cho nhau; **nhiệm vụ loại hình ảnh chỉ được gửi đến dịch vụ hỗ trợ xử lý ảnh**. Nhiệm vụ phiên bản cũ được xử lý theo phạm vi dịch vụ Bạn đã xác nhận lúc đó. Các nhà cung cấp nêu trên chỉ xử lý dữ liệu trong phạm vi nhiệm vụ được Chúng tôi ủy quyền, việc xử lý dữ liệu của họ chịu ràng buộc của hợp đồng với Chúng tôi và chính sách quyền riêng tư riêng của họ.

## 3. Bạn sẽ gửi những gì

1. **Tối thiểu hóa theo nhu cầu**: AI theo nhiệm vụ Bạn chủ động khởi tạo, chỉ gửi dữ liệu cần thiết cho chức năng lần đó (như nhật ký tập luyện, nhật ký ăn uống, hồ sơ cơ thể, tổng hợp sức khỏe theo ngày, bảng hỏi đánh giá hoặc câu hỏi của Bạn);
2. **Ảnh**: ảnh bữa ăn và ảnh đánh giá cơ thể chỉ được gửi khi Bạn chủ động chụp, chọn và khởi tạo nhận dạng hoặc phân tích; chức năng "tải ảnh lên" của Club AI trước tiên tạo tệp đính kèm chờ gửi trên máy, chỉ gửi đi sau khi Bạn nhấn gửi, có thể gỡ bỏ trước khi gửi; ảnh trò chuyện thông thường sẽ không được tự động lưu thành bữa ăn hay kế hoạch tập luyện;
3. **Giọng nói**: bản ghi âm giọng nói không tải lên, phần chuyển giọng nói thành văn bản do hệ thống thực hiện cục bộ khi thiết bị hỗ trợ, chỉ văn bản đã kiểm tra được dùng cho nhận dạng ăn uống;
4. **Ảnh đại diện**: không được gửi trong yêu cầu AI;
5. **Tắt Phân tích đám mây**: Bạn có thể tắt Phân tích đám mây bất cứ lúc nào trong "Cài đặt → Lưu ý quyền riêng tư"; sau khi tắt, sẽ ngừng tiếp tục gửi các nhiệm vụ chưa hoàn thành trên máy và vòng lặp nhận kết quả; nhiệm vụ đã gửi cho nhà cung cấp không thể thu hồi ngay lập tức và có thể vẫn hoàn thành.

## 4. Xử lý và lưu trữ dữ liệu

- Nội dung yêu cầu, ngữ cảnh, trạng thái và kết quả của tác vụ AI được lưu trên máy chủ và liên kết với tài khoản của Bạn. Dữ liệu được giữ trong thời gian tài khoản còn tồn tại; hiện chúng tôi không tự động xóa các trường này theo tuổi của tác vụ. Khi xóa tài khoản, dữ liệu liên quan được xử lý theo quy trình xóa tài khoản.
- Với tác vụ đã hoàn tất, thất bại hoặc bị hủy, quy trình dọn dẹp định kỳ sẽ xóa byte ảnh gốc được nhúng trong yêu cầu sau khi tác vụ kết thúc quá 24 giờ. Việc này không xóa văn bản, kết quả, trạng thái hoặc nhật ký bữa ăn đã lưu liên quan.
- Các sự kiện tăng dần dùng để tiếp tục trò chuyện trực tuyến được lưu tối đa 30 ngày. Xóa các sự kiện này không xóa nội dung tác vụ, kết quả hoặc tin nhắn trò chuyện đã lưu.
- Nội dung gửi đến dịch vụ mô hình bên thứ ba có thể được xử lý hoặc lưu giữ theo thông báo quyền riêng tư và điều khoản API áp dụng của nhà cung cấp. App không thể trực tiếp xóa bản sao do nhà cung cấp nắm giữ.
## 5. Gắn nhãn nội dung AI

Căn cứ quy định của 《人工智能生成合成内容标识办法》 (Biện pháp gắn nhãn nội dung do trí tuệ nhân tạo tạo sinh và tổng hợp) và các quy định khác, Chúng tôi thêm nhãn rõ ràng (như chữ hoặc lời nhắc "Do AI tạo ra") và nhãn ẩn cần thiết cho nội dung do AI tạo ra, giúp Bạn phân biệt rõ đầu ra AI với nội dung do con người tạo.

## 6. Độ chính xác của đầu ra

Đầu ra AI được mô hình tự động tạo ra, **có thể không chính xác, không đầy đủ, lỗi thời hoặc không phù hợp với tình trạng cơ thể của Bạn**. Bạn không nên coi đầu ra AI là căn cứ duy nhất cho chẩn đoán y khoa, đơn dinh dưỡng hoặc tập luyện cường độ cao; cần tự phán đoán các vấn đề sau: bài tập có phù hợp với cơ thể Bạn không, trọng lượng có an toàn không, nhật ký ăn uống có chính xác không, dữ liệu sức khỏe có đầy đủ không, ảnh cơ thể có tính so sánh được không. Xem chi tiết tại "Cảnh báo Rủi ro Sức khỏe và Tập luyện".

## 7. Giới hạn sử dụng

1. Không được sử dụng tính năng AI để tạo, lan truyền thông tin vi phạm pháp luật, xâm phạm quyền lợi người khác, khiêu dâm, bạo lực, thù hận, nguy hiểm hoặc giả mạo;
2. Không được dùng phương tiện tự động gọi hàng loạt, vượt qua giới hạn hạn mức hội viên hoặc can thiệp vào sự ổn định của dịch vụ;
3. Việc gọi AI có thể bị giới hạn bởi hạn mức hội viên và tần suất; tần suất tự động lên lịch được tính riêng với sử dụng thủ công, không chiếm thêm số lần gọi hàng ngày của hội viên;
4. Chúng tôi có thể giới hạn tần suất hoặc hạn chế đối với sử dụng bất thường.

## 8. Thông tin tuân thủ tại Trung Quốc đại lục

Khi cung cấp dịch vụ trí tuệ nhân tạo tạo sinh cho người dùng tại Trung Quốc đại lục, Chúng tôi tuân thủ các quy định như 《生成式人工智能服务管理暂行办法》 (Biện pháp tạm thời quản lý dịch vụ trí tuệ nhân tạo tạo sinh), 《互联网信息服务算法推荐管理规定》 (Quy định quản lý khuyến nghị thuật toán của dịch vụ thông tin Internet), 《人工智能生成合成内容标识办法》 (Biện pháp gắn nhãn nội dung do trí tuệ nhân tạo tạo sinh và tổng hợp), thực hiện các nghĩa vụ an toàn thuật toán, gắn nhãn nội dung, bảo vệ người chưa thành niên và xử lý khiếu nại.

## 9. Phản hồi và khiếu nại

Nếu có câu hỏi, ý kiến bất đồng hoặc khiếu nại về đầu ra AI hoặc phương thức xử lý, vui lòng liên hệ Chúng tôi qua {{contact_email}}, hoặc gửi qua mục phản hồi trong ứng dụng. Chúng tôi sẽ xử lý và trả lời kịp thời sau khi xác minh.
