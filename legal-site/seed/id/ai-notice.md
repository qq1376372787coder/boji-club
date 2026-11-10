---
title: Pemberitahuan Layanan AI
description: Lingkup fitur AI {{site_name}}, penyedia layanan, aturan pemrosesan dan penyimpanan data, penandaan konten, pembatasan penggunaan, dan klausul pengecualian.
version: 1.0.0
effective: 2026-10-27
updated: 2026-10-27
---

## 1. Lingkup Fitur AI

Fitur AI Produk ini meliputi: pembuatan rencana latihan, pengenalan foto makanan dan estimasi nutrisi, Laporan AI Harian, Interpretasi Latihan, analisis Tinjauan Tubuh Mingguan, percakapan Club AI, serta laporan harian/mingguan otomatis dan tindak lanjut otomatis setelah menutup aplikasi (opsional).

## 2. Penyedia Layanan AI

Tugas AI diproses oleh **DeepSeek (深度求索)** dan **MiniMax (稀宇科技)**, keduanya dialokasikan berdasarkan tugas dan status layanan serta saling menjadi cadangan; **tugas gambar hanya dikirim ke layanan yang mendukung pemrosesan gambar**. Tugas versi lama diproses sesuai lingkup layanan yang Anda konfirmasi saat itu. Penyedia layanan di atas hanya memproses data dalam lingkup tugas yang kami kuasakan, dan pemrosesan datanya terikat oleh kontrak dengan kami serta kebijakan privasi mereka sendiri.

## 3. Apa yang Anda Kirimkan

1. **Minimalisasi sesuai kebutuhan**: AI hanya mengirimkan data yang diperlukan untuk fitur tersebut sesuai tugas yang Anda mulai secara aktif (seperti catatan latihan, catatan makanan, data tubuh, rekapitulasi harian kesehatan, kuesioner tinjauan, atau pertanyaan Anda);
2. **Foto**: foto makanan dan foto tinjauan tubuh hanya dikirimkan ketika Anda secara aktif memfoto/memilih dan memulai pengenalan atau analisis; "unggah foto" Club AI terlebih dahulu membuat lampiran tertunda di perangkat, yang baru dikirimkan setelah Anda mengetuk kirim dan dapat dihapus sebelum pengiriman; gambar obrolan biasa tidak otomatis disimpan sebagai makanan atau rencana latihan;
3. **Suara**: rekaman suara tidak diunggah; transkripsi suara dilakukan oleh sistem secara lokal bila perangkat mendukung, dan hanya teks yang telah diperiksa yang digunakan untuk pengenalan makanan;
4. **Avatar**: tidak dikirim dalam permintaan AI;
5. **Mematikan analisis awan**: Anda dapat kapan saja mematikan analisis awan di "Pengaturan → Pemberitahuan Privasi"; setelah dimatikan, pengiriman lanjutan tugas yang belum selesai di perangkat dan polling hasil berhenti; tugas yang telah dikirim kepada penyedia layanan tidak dapat ditarik secara langsung dan mungkin masih akan selesai.

## 4. Pemrosesan dan Penyimpanan Data

- Teks permintaan, konteks, status, dan hasil tugas AI disimpan di server dan dikaitkan dengan akun Anda. Data disimpan selama akun masih aktif; saat ini kami tidak menghapus bidang tersebut secara otomatis berdasarkan usia tugas. Saat akun dihapus, data terkait diproses melalui proses penghapusan akun.
- Untuk tugas yang selesai, gagal, atau dibatalkan, pembersihan terjadwal menghapus byte gambar asli yang disematkan dalam permintaan setelah tugas berakhir lebih dari 24 jam. Pembersihan ini tidak menghapus teks, hasil, status, atau catatan makanan tersimpan yang terkait.
- Peristiwa inkremental untuk melanjutkan chat streaming disimpan hingga 30 hari. Penghapusan peristiwa ini tidak menghapus teks tugas, hasil, atau pesan chat tersimpan yang terkait.
- Konten yang dikirim ke penyedia model pihak ketiga dapat diproses atau disimpan berdasarkan pemberitahuan privasi dan ketentuan API yang berlaku. App tidak dapat menghapus secara langsung salinan yang disimpan penyedia.
## 5. Penandaan Konten AI

Berdasarkan 《人工智能生成合成内容标识办法》 (Metode Penandaan Konten yang Dihasilkan dan Disintesis oleh Kecerdasan Buatan) dan peraturan lainnya, kami menambahkan penanda eksplisit (seperti teks atau petunjuk "dibuat oleh AI") dan penanda implisit yang diperlukan pada konten yang dihasilkan AI, untuk membantu Anda membedakan dengan jelas antara Keluaran AI dan konten buatan manusia.

## 6. Ketepatan Keluaran

Keluaran AI dihasilkan secara otomatis oleh model dan **mungkin tidak akurat, tidak lengkap, kedaluwarsa, atau tidak sesuai dengan kondisi tubuh Anda**. Anda tidak boleh menjadikan Keluaran AI sebagai satu-satunya dasar untuk diagnosis medis, resep nutrisi, atau latihan intensitas tinggi, dan perlu menilai sendiri hal-hal berikut: apakah gerakan sesuai dengan tubuh Anda, apakah beban aman, apakah catatan makanan akurat, apakah data kesehatan lengkap, dan apakah foto tubuh memiliki keterbandingan. Selengkapnya lihat Peringatan Risiko Kesehatan dan Olahraga.

## 7. Pembatasan Penggunaan

1. Tidak boleh menggunakan fitur AI untuk menghasilkan atau menyebarkan informasi yang melanggar hukum, melanggar hak, pornografi, kekerasan, kebencian, berbahaya, atau palsu;
2. Tidak boleh memanggil secara massal dengan cara otomatis, melewati batas kuota keanggotaan, atau mengganggu stabilitas layanan;
3. Panggilan AI dapat dibatasi oleh kuota keanggotaan dan pembatasan laju; frekuensi penjadwalan otomatis dihitung terpisah dari penggunaan manual dan tidak menghabiskan tambahan jumlah panggilan harian keanggotaan;
4. Kami dapat melakukan pembatasan laju atau pembatasan lain terhadap penggunaan yang abnormal.

## 8. Penjelasan Kepatuhan Tiongkok Daratan

Ketika menyediakan layanan kecerdasan buatan generatif kepada pengguna Tiongkok Daratan, kami mematuhi 《生成式人工智能服务管理暂行办法》 (Tindakan Sementara Pengelolaan Layanan Kecerdasan Buatan Generatif), 《互联网信息服务算法推荐管理规定》 (Ketentuan Pengelolaan Rekomendasi Algoritma Layanan Informasi Internet), 《人工智能生成合成内容标识办法》 (Metode Penandaan Konten yang Dihasilkan dan Disintesis oleh Kecerdasan Buatan), dan sebagainya, serta melaksanakan kewajiban keamanan algoritma, penandaan konten, perlindungan anak di bawah umur, dan penanganan keluhan.

## 9. Umpan Balik dan Keluhan

Apabila Anda memiliki pertanyaan, keberatan, atau keluhan mengenai Keluaran AI atau cara pemrosesannya, silakan hubungi kami melalui {{contact_email}}, atau kirimkan melalui pintu masuk umpan balik di dalam aplikasi. Kami akan memproses dan menjawab segera setelah memverifikasi.
