# ClearMix Panel Kontrol Listesi

Elle yapılan arayüz doğrulaması için adım adım liste. Her maddede **ne görülmesi gerektiği** yazılı.
Çalıştırma: `open -n build/ClearMix.app`, ardından menü çubuğundaki dalga ikonundan paneli aç.

## Hazırlık
- [ ] İlk açılışta gelen iki izin penceresini onayla: *Sistem Ses Kaydı* ve *Mikrofon*. Onaysız ses satırları boş gelir.
- [ ] Başka bir uygulamada ses başlat (ör. tarayıcıda video); satırlar ancak ses çalarken oluşur.

## A. Sesler sekmesi
- [ ] Üstte `[ Sesler | Mikrofon ]` segmenti, sağında yenile ve dişli düğmeleri var; segment sekmeyi değiştiriyor.
- [ ] Ses çalan uygulama satırı: ikon, ad, `%100` yüzde, kaydırıcı + canlı ölçer, mute düğmesi, `⌄` menüsü. Uzun ad üç noktayla kısalıyor, taşmıyor.
- [ ] Kaydırıcıyı sürükle → yüzde değişir, ölçer düşer; çift tık → %100'e döner.
- [ ] Mute → ikon `slash` olur, ölçer sıfırlanır, kaydırıcı soluklaşır; tekrar basınca eski seviye döner.
- [ ] Çıkış rozeti: hiç yönlendirilmemişse soluk `Çıkış ⌄`. Tıkla → "Ana Çıkış" + cihaz listesi, aktif olanda tik.
- [ ] Rozetten bir cihaz seç → tik yer değiştirir; `⌄` menüsündeki "Çıkış Cihazı" alt menüsü aynı listeyi gösterir.
- [ ] `⌄` menüsü: "10-Bant EQ" (ayrı sayfa, 10 kaydırıcı + 7 preset), "Listeye sabitle" (satırda pin ikonu), "%100'e sıfırla".
- [ ] Alt bölümde ana ses: çıkış cihazı menüsü ("Sistem Varsayılanı" + cihazlar), ses kaydırıcısı, tümünü sessize alma. F11/F12 ile kaydırıcı kendiliğinden güncellenir.
- [ ] Ses çalmıyorken boş durum: "Ses çalan uygulama yok" + "Bir uygulama ses çalmaya başladığında satırı burada görünür."

## B. Mikrofon sekmesi
- [ ] Cihaz menüsü ("MacBook Air Mikrofonu") + **Başlat**; basınca ikon dolar, düğme kırmızı **Kapat** olur.
- [ ] İşleme kartı: RNNoise anahtarı, "Güç" kaydırıcısı + yüzde, "Gürültü Kapısı" (açınca **Eşik** belirir), "Kazanç" (çift tık → 0 dB).
- [ ] Önce/Sonra ölçerleri canlı; sağda gecikme (~40 ms). "A/B Dinle" turuncuya döner, "Kendimi duy" vurgulanır (sesi hoparlörden duyarsın).
- [ ] Kararlılık testi kartı: varsayılan metin "Mikrofon hattını 1 dakika izleyip çıtırtı/kesinti olup olmadığını sayar." + **"1 dk test et"**.
- [ ] Test başlat → ilerleme çarkı + geri sayım (`70 sn` → `0 sn`), düğme devre dışı; ~70 sn sonra yeşil tik + "Kararlılık testi geçti: 60 sn boyunca çıtırtı/kesinti yok."
- [ ] Mikrofon kapalıyken test başlat → mikrofonu kendisi açar; açamazsa turuncu ikon + "Mikrofon başlatılamadı." (sonsuz bekleme yok).
- [ ] BlackHole kartı: kurulu değilse turuncu uyarı + "Nasıl kurulur / Komutu kopyala / Kontrol et"; "Nasıl kurulur" sihirbazın 2. adımını açar.

## C. Ayarlar (dişli)
- [ ] "Profil": Oyun/Toplantı'ya geçince satır kazançları değişir, "Standart"a dönünce eski değerler geri gelir.
- [ ] "Dil / Language": English'e alınca **tüm** metinler İngilizce (özellikle kararlılık kartı ve "Raporu dosyaya kaydet").
- [ ] Anahtarlar: sistem sesleri, otomatik kısma, oturum açılışında başlat (yalnızca `.app` iken etkin), global kısayollar.
- [ ] "Sistem Sesi İzni" / "Mikrofon İzni" doğru ayar sayfalarını açar; "Kurulum Sihirbazı" 1. adımdan başlar.
- [ ] **"Raporu dosyaya kaydet"** → kaydetme paneli (varsayılan `ClearMix-tanilama.txt`). Dosyada `Mic Running:`, `Mic Stats:`, `Stability Test:`, `Active Taps` satırları var; test öncesi `çalıştırılmadı`, sonrası `GEÇTİ — …`.
- [ ] Durum satırı son işlemi gösteriyor ("Rapor kaydedildi: …"). "ClearMix'ten Çık" uygulamayı kapatır, ses normale döner.

## D. Kurulum sihirbazı
- [ ] 3 adım: izinler (mikrofon + sistem sesi, yeşil/turuncu ikonlar) → BlackHole (kuruluysa yeşil kutu, değilse kurulum düğmesi + Bluetooth ipucu) → Discord/Zoom/OBS yönergesi + "Test Et (Kendimi Dinle)".
- [ ] "Atla" sihirbazı kapatır ve bir daha açılışta çıkmaz.

## E. Genel görünüm
- [ ] Panel 356 pt genişliğinde, hiçbir kart ya da kaydırıcı yatay taşmıyor.
- [ ] Koyu temada metinler okunur, kart arka planları uyumlu.
- [ ] Menü çubuğu ikonu durumu yansıtıyor (mikrofon açık / tümü kapalı / normal).
- [ ] Panel açıkken CPU'yu kontrol et (Aktivite İzleme); boşta ~%1 civarında kalmalı.

## Raporlama
Madde numarası + görülen + beklenen yeterli (ör. "22: panel açıldı ama dosya yazılmadı, hata da yok").
