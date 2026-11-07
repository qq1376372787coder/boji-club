---
title: Pernyataan Penghapusan Akun dan Penghapusan Data
description: Cara menghapus akun {{site_name}}, apa yang dihapus setelah penghapusan, konten apa yang mungkin disimpan dalam waktu singkat, serta hal-hal yang perlu diperhatikan mengenai pembatalan langganan.
version: 1.0.0
effective: 2026-10-27
updated: 2026-10-27
---

## 1. Cara Menghapus Akun

Anda dapat memilih "Hapus Akun" pada halaman "Saya" di dalam aplikasi, atau mengajukan permintaan penghapusan melalui {{contact_email}}.

Untuk melindungi keamanan akun, kami mungkin meminta Anda menyelesaikan salah satu verifikasi berikut: masuk ke akun saat ini; verifikasi masuk Apple atau nomor telepon; memasukkan kata konfirmasi penghapusan yang jelas; atau verifikasi identitas melalui layanan pelanggan.

## 2. Apa yang Dihapus Setelah Penghapusan

Setelah penghapusan selesai, kami akan menghapus atau menganonimkan data berikut:

- Profil akun, kredensial masuk, dan catatan manfaat keanggotaan
- Rencana latihan, catatan latihan, dan catatan set
- Catatan makanan, data nutrisi, dan foto makanan yang telah disinkronkan
- Rekapitulasi kesehatan dan status sinkronisasi
- Pemetaan tugas AI, laporan AI sisi server, dan audit tugas
- Ringkasan tinjauan mingguan dan berkas media server yang terkait akun
- Umpan balik pengguna beserta lampirannya
- Pengikatan perangkat dan catatan pengiriman notifikasi dorong

Foto tubuh yang tersimpan lokal di aplikasi akan dihapus bersamaan dengan pembersihan data akun atau dihapus oleh Anda di dalam aplikasi. Meng-uninstal aplikasi akan menghapus data lokal dalam sandbox perangkat, namun **tidak dapat menghapus berkas yang telah Anda simpan ke galeri sistem atau salinan yang telah Anda bagikan kepada orang lain**—salinan tersebut Anda kelola sendiri.

## 3. Konten yang Mungkin Tidak Dapat Dihapus Segera

Konten berikut mungkin tidak sepenuhnya hilang pada saat penghapusan:

1. Cadangan basis data dan berkas (ditimpa sesuai siklus rotasi cadangan);
2. Log audit keamanan dan anti-penyalahgunaan (disimpan untuk melaksanakan kewajiban hukum);
3. Konten yang telah dikirim kepada layanan model pihak ketiga (terikat oleh kebijakan penyimpanan penyedia tersebut);
4. Gambar yang telah dihasilkan serta Anda unduh atau bagikan secara aktif;
5. Catatan transaksi yang disimpan oleh Apple, RevenueCat, atau penyedia layanan pihak ketiga lainnya sesuai kebijakan masing-masing.

Kami akan menghapus atau menganonimkan data yang dapat diidentifikasi sesegera mungkin sesuai rotasi cadangan dan aturan penyimpanan internal. Setelah permintaan penghapusan diterima, akun segera dinonaktifkan; tugas pembersihan terus dieksekusi di latar belakang dan otomatis mencoba ulang item yang gagal.

## 4. Menghapus Foto Makanan

Setelah Anda menghapus makanan dalam catatan makanan, foto dan catatan terkait di perangkat akan dihapus dari data akun saat ini; foto yang telah disinkronkan ke awan juga dihapus bersamaan, namun cadangan atau cache pihak ketiga mungkin baru benar-benar hilang setelah rotasi. Kegagalan pembersihan foto asli di awan akan masuk ke antrean khusus untuk percobaan ulang otomatis, tanpa perlu Anda mengoperasikannya kembali.

## 5. Menghapus Foto Tubuh

Foto tinjauan mingguan secara bawaan tersimpan di perangkat lokal. Setelah Anda menghapus tinjauan atau foto, perangkat lokal akan menghapus berkas fotonya. Gambar yang telah dikirim kepada layanan AI tidak dapat dijamin ditarik segera dari server pihak ketiga: sisi server menghapus input asli setelah tugas berhasil; input tinjauan mingguan dihapus setelah gagal final; input tugas gagal lainnya disimpan maksimal 7 hari. Penghapusan akun akan membersihkan input, hasil, dan audit tugas terkait.

## 6. Mencabut Otorisasi Data Kesehatan

Anda dapat mencabut izin pembacaan/penulisan data kesehatan Produk ini di Apple Health atau pengaturan sistem. Setelah pencabutan, aplikasi tidak lagi membaca data kesehatan baru; rekapitulasi kesehatan yang telah tersimpan mungkin masih tersimpan dalam catatan akun, dan Anda dapat terus menghapusnya atau menghapus akun.

## 7. Hal-Hal yang Perlu Diperhatikan tentang Langganan dan Keanggotaan

- **Penghapusan akun tidak otomatis membatalkan langganan Apple**. Mohon batalkan perpanjangan otomatis pada halaman pengelolaan "Langganan" Apple ID terlebih dahulu, baru kemudian ajukan penghapusan akun, untuk menghindari pemotongan biaya yang berlanjut;
- Pengembalian dana atas langganan yang telah dibayar ditangani melalui Apple sesuai Kebijakan Pembelian, Langganan, dan Pengembalian Dana;
- Penghapusan akun dan pembatalan perpanjangan otomatis adalah dua operasi yang terpisah.

## 8. Pencabutan Otorisasi Apple

Bila layanan pencabutan Apple telah dikonfigurasi dan akun menyimpan kredensial pembaruan, penghapusan akun sekaligus mencabut otorisasi Anda atas Produk ini melalui Sign in with Apple. Untuk akun lama atau bila layanan pencabutan tidak dikonfigurasi, mohon cabut otorisasi secara manual di iOS **Pengaturan → [Nama Anda] → Masuk & Keamanan (atau Kata Sandi & Keamanan) → Aplikasi yang Menggunakan Apple ID**.

## 9. Pemeriksaan Status dan Pendaftaran Ulang

Bila kredensial penghapusan hilang, Anda dapat melakukan verifikasi ulang dan memeriksa status penanganan menggunakan akun Apple yang digunakan saat mengajukan penghapusan; sistem tidak akan membuat atau memulihkan akun hanya berdasarkan penanda di perangkat lokal. Ringkasan kredensial penghapusan dan ringkasan identitas Apple yang digunakan untuk pemeriksaan status disimpan maksimal 30 hari setelah pembersihan selesai, selanjutnya dihapus.

Berkas ekspor di perangkat lokal, cadangan snapshot perubahan dua perangkat yang bersamaan, dan cadangan teks rencana lama akan dihapus bersama pembersihan akun di perangkat lokal; berkas yang Anda simpan atau bagikan ke lokasi lain Anda kelola sendiri, dan aplikasi tidak dapat menghapus salinan tersebut.

## 10. Hubungi Kami

Bila Anda tidak dapat menyelesaikan penghapusan akun atau penghapusan data di dalam aplikasi, silakan hubungi:

- Email: {{contact_email}}


Saat mengajukan, mohon nyatakan "Penghapusan Akun" atau "Penghapusan Data", dan bekerja sama menyelesaikan verifikasi identitas. Kami akan menyelesaikan penanganan dalam batas waktu yang ditentukan (umumnya tidak lebih dari 15 hari kerja) setelah verifikasi dan memberitahukan hasilnya kepada Anda.
